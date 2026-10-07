import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { sha256Bytes, bytesToPostgresHex } from "../_shared/employee-portal/crypto.ts";
import { requireCustomerPortalBffAuth } from "../_shared/customer-portal/internal-auth.ts";

const FEATURE = "resolve-customer-portal-commercial";
const HEX_64_RE = /^[0-9a-f]{64}$/;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const KINDS = new Set(["quotes_agreements", "delivery_notes", "invoices"]);
const ACTIONS = new Set([
  "list_documents",
  "list_summary",
  "get_quote_or_agreement",
  "get_delivery_note",
  "get_invoice",
  "list_pending_decisions",
  "get_pending_decision",
  "decline_pending_decision",
  "accept_pending_decision",
  "bridge_docuseal_pending_decision",
]);
const DETAIL_ACTIONS = new Set([
  "get_quote_or_agreement",
  "get_delivery_note",
  "get_invoice",
  "get_pending_decision",
  "decline_pending_decision",
  "accept_pending_decision",
  "bridge_docuseal_pending_decision",
]);
/** CS-D59: staff portal sessions must not mutate or obtain signing bridges. */
const STAFF_FORBIDDEN_ACTIONS = new Set([
  "decline_pending_decision",
  "accept_pending_decision",
  "prepare_pending_decision_sign",
  "bridge_docuseal_pending_decision",
]);
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const DOCUMENTS_BUCKET = "documents";
const PDF_EXPIRY_SECONDS = 15 * 60;

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_PUBLIC_URL = Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "private, no-store",
      "X-Robots-Tag": "noindex, nofollow",
      "Referrer-Policy": "no-referrer",
    },
  });
}

function denied(code = "not_found"): Response {
  return jsonResponse(404, { error: code });
}

function clientIp(req: Request): string | null {
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) return fwd.split(",")[0]?.trim() || null;
  return req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip");
}

async function rejectStaffCommercialMutation(
  admin: ReturnType<typeof createAdminClient>,
  hash: string,
  action: string,
  ip: string | null,
  ua: string | undefined,
): Promise<Response | null> {
  if (!STAFF_FORBIDDEN_ACTIONS.has(action)) {
    return null;
  }

  const { data, error } = await admin.rpc("resolve_customer_portal_commercial", {
    p_session_token_hash: hash,
    p_action: "list_summary",
    p_ip_address: ip,
    p_user_agent: ua,
    p_request_id: crypto.randomUUID(),
  });
  if (error) {
    log("error", FEATURE, "staff mutation gate resolve failed", {
      extra: { error: error.message, action },
    });
    // Fail closed for forbidden mutations (CS-D59).
    return jsonResponse(503, { error: "staff_gate_unavailable" });
  }

  const row = data as Record<string, unknown> | null;
  if (row?.ok === true && row.actor_type === "staff") {
    return jsonResponse(403, { error: "forbidden" });
  }
  return null;
}

function scrubStaffPendingDetail(detail: Record<string, unknown>): Record<string, unknown> {
  const scrubbed = { ...detail };
  scrubbed.can_decide = false;
  scrubbed.decide_available = false;
  scrubbed.accept_available = false;
  scrubbed.decline_available = false;
  scrubbed.provider_continue_available = false;
  delete scrubbed.docuseal_signing_url;
  delete scrubbed.signing_url;
  delete scrubbed.docuseal_bridge_url;
  delete scrubbed.provider_signing_url;
  return scrubbed;
}

function scrubPublicDetail(detail: Record<string, unknown>): Record<string, unknown> {
  const publicDetail: Record<string, unknown> = { ...detail };
  // Never leak storage paths or internal DMS/commercial UUIDs to the browser.
  delete publicDetail.pdf_file_path;
  delete publicDetail.pdf_storage_type;
  delete publicDetail.pdf_document_id;
  delete publicDetail.source_quote_id;
  delete publicDetail.document_version_id;
  const versionId = typeof publicDetail.pdf_version_id === "string"
    ? publicDetail.pdf_version_id
    : null;
  const hasPdfFlag = publicDetail.has_pdf === true;
  publicDetail.has_pdf = hasPdfFlag || Boolean(versionId);
  // pdf_version_id is only needed server-side for signed URL minting.
  delete publicDetail.pdf_version_id;
  return publicDetail;
}

async function enrichDetailPdf(
  admin: ReturnType<typeof createAdminClient>,
  detail: Record<string, unknown>,
  includePdfUrl: boolean,
): Promise<Record<string, unknown>> {
  const storageType = typeof detail.pdf_storage_type === "string"
    ? detail.pdf_storage_type
    : null;
  const filePath = typeof detail.pdf_file_path === "string"
    ? detail.pdf_file_path
    : null;
  const versionId = typeof detail.pdf_version_id === "string"
    ? detail.pdf_version_id
    : null;

  const publicDetail = scrubPublicDetail(detail);

  if (!includePdfUrl || !versionId || !filePath) {
    return publicDetail;
  }

  if (storageType === "external_link") {
    return { ...publicDetail, pdf_url: filePath, has_pdf: true };
  }

  const { data: signed, error } = await admin.storage
    .from(DOCUMENTS_BUCKET)
    .createSignedUrl(filePath, PDF_EXPIRY_SECONDS);

  if (error || !signed?.signedUrl) {
    log("warn", FEATURE, "pdf sign failed", {
      extra: { error: error?.message, version_id: versionId },
    });
    return publicDetail;
  }

  const pdfUrl = SUPABASE_URL
    ? signed.signedUrl.replace(SUPABASE_URL, SUPABASE_PUBLIC_URL)
    : signed.signedUrl;

  return { ...publicDetail, pdf_url: pdfUrl, has_pdf: true };
}

Deno.serve(async (req: Request) => {
  initObservability();

  const unauthorized = await requireCustomerPortalBffAuth(req);
  if (unauthorized) return unauthorized;

  if (req.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  let body: {
    session_token?: string;
    action?: string;
    kind?: string;
    cursor_sort?: string | null;
    cursor_id?: string | null;
    limit?: number;
    target_id?: string | null;
    item_kind?: string | null;
    include_pdf_url?: boolean;
    reason?: string | null;
    actor_name?: string | null;
    actor_role?: string | null;
    client_op_id?: string | null;
    signature_base64?: string | null;
    signer_name?: string | null;
  };
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { error: "invalid_body" });
  }

  if (!body.session_token || !HEX_64_RE.test(body.session_token)) {
    return denied();
  }

  const action = typeof body.action === "string" && body.action.trim()
    ? body.action.trim()
    : "list_documents";

  const kind = typeof body.kind === "string" && body.kind.trim()
    ? body.kind.trim()
    : "quotes_agreements";
  if (action === "list_documents" && !KINDS.has(kind)) {
    return jsonResponse(400, { error: "invalid_kind" });
  }

  if (DETAIL_ACTIONS.has(action) || STAFF_FORBIDDEN_ACTIONS.has(action)) {
    if (
      DETAIL_ACTIONS.has(action) &&
      (!body.target_id || !UUID_RE.test(body.target_id))
    ) {
      return jsonResponse(400, { error: "invalid_target" });
    }
  }

  const limit =
    typeof body.limit === "number" && Number.isFinite(body.limit)
      ? Math.max(1, Math.min(Math.trunc(body.limit), 50))
      : 20;

  const ip = clientIp(req);
  const ua = req.headers.get("user-agent") ?? undefined;
  const auditRequestId = crypto.randomUUID();
  const admin = createAdminClient();

  try {
    const hash = bytesToPostgresHex(await sha256Bytes(body.session_token));

    // CS-D59: staff 403 before invalid_action (covers future prepare/bridge)
    const staffMutationDenied = await rejectStaffCommercialMutation(
      admin,
      hash,
      action,
      ip,
      ua,
    );
    if (staffMutationDenied) {
      return staffMutationDenied;
    }

    if (!ACTIONS.has(action)) {
      return jsonResponse(400, { error: "invalid_action" });
    }

    if (action === "bridge_docuseal_pending_decision") {
      const { data, error } = await admin.rpc(
        "continue_customer_portal_pending_docuseal",
        {
          p_session_token_hash: hash,
          p_request_id: body.target_id,
          p_ip_address: ip,
          p_user_agent: ua,
          p_audit_request_id: auditRequestId,
        },
      );

      if (error) {
        log("error", FEATURE, "docuseal continue failed", {
          extra: { error: error.message },
        });
        return jsonResponse(500, { error: "internal_error" });
      }

      const row = data as Record<string, unknown> | null;
      if (!row || row.ok !== true) {
        const code = typeof row?.code === "string" ? row.code : "not_found";
        if (code === "module_disabled" || code === "forbidden") {
          return jsonResponse(403, { error: code });
        }
        if (
          code === "provider_not_docuseal" ||
          code === "provider_pending"
        ) {
          return jsonResponse(409, { error: code });
        }
        if (row?.already_decided === true) {
          return jsonResponse(200, {
            action: "bridge_docuseal_pending_decision",
            actor_type: "grant",
            request_id: auditRequestId,
            result: {
              request_id: row.request_id,
              status: row.status,
              already_decided: true,
              decided_via: row.decided_via ?? null,
              decided_at: row.decided_at ?? null,
            },
          });
        }
        return denied();
      }

      return jsonResponse(200, {
        action: "bridge_docuseal_pending_decision",
        actor_type: "grant",
        request_id: auditRequestId,
        result: {
          request_id: row.request_id,
          redirect_url: typeof row.redirect_url === "string"
            ? row.redirect_url
            : null,
        },
      });
    }

    if (action === "decline_pending_decision") {
      const clientOpId = typeof body.client_op_id === "string" &&
          UUID_RE.test(body.client_op_id)
        ? body.client_op_id
        : crypto.randomUUID();
      const evidence: Record<string, unknown> = {
        reason: typeof body.reason === "string" ? body.reason.trim() || null : null,
      };
      if (typeof body.actor_name === "string" && body.actor_name.trim()) {
        evidence.actor_name = body.actor_name.trim();
      }
      if (typeof body.actor_role === "string" && body.actor_role.trim()) {
        evidence.actor_role = body.actor_role.trim();
      }

      const { data, error } = await admin.rpc(
        "apply_customer_portal_pending_decision",
        {
          p_session_token_hash: hash,
          p_request_id: body.target_id,
          p_outcome: "declined",
          p_evidence: evidence,
          p_client_op_id: clientOpId,
          p_ip_address: ip,
          p_user_agent: ua,
          p_audit_request_id: auditRequestId,
        },
      );

      if (error) {
        log("error", FEATURE, "decline failed", { extra: { error: error.message } });
        return jsonResponse(500, { error: "internal_error" });
      }

      const row = data as Record<string, unknown> | null;
      if (!row || row.ok !== true) {
        const code = typeof row?.code === "string" ? row.code : "not_found";
        if (code === "module_disabled" || code === "forbidden") {
          return jsonResponse(403, { error: code });
        }
        if (
          code === "actor_name_required" ||
          code === "actor_role_required" ||
          code === "outcome_not_supported" ||
          code === "provider_not_supported"
        ) {
          return jsonResponse(400, { error: code });
        }
        if (code === "apply_failed") {
          return jsonResponse(409, { error: code });
        }
        return denied();
      }

      // B9: after portal decline, supersede + best-effort cancel DocuSeal
      if (row.applied === true && typeof body.target_id === "string") {
        try {
          await admin.rpc("supersede_commercial_bridge_submissions_for_request", {
            p_request_id: body.target_id,
          });
          const { cancelSupersededCommercialDocuseal } = await import(
            "../_shared/docuseal-cancel-superseded.ts"
          );
          await cancelSupersededCommercialDocuseal({
            adminClient: admin,
            requestId: body.target_id,
          });
        } catch (cancelErr) {
          log("warn", FEATURE, "post-decline DocuSeal cancel skipped", {
            extra: {
              error: cancelErr instanceof Error
                ? cancelErr.message
                : String(cancelErr),
            },
          });
        }
      }

      return jsonResponse(200, {
        action: "decline_pending_decision",
        actor_type: "grant",
        request_id: auditRequestId,
        result: {
          request_id: row.request_id,
          status: row.status,
          applied: row.applied === true,
          already_decided: row.already_decided === true,
          decided_via: row.decided_via,
          decided_at: row.decided_at,
        },
      });
    }

    if (action === "accept_pending_decision") {
      const signature = typeof body.signature_base64 === "string"
        ? body.signature_base64.trim()
        : "";
      if (!signature || signature.length < 32) {
        return jsonResponse(400, { error: "missing_signature" });
      }

      // Body signer_name is intentionally ignored; SQL resolves named_person / shared_mailbox.
      const evidence: Record<string, unknown> = {};
      if (typeof body.actor_name === "string" && body.actor_name.trim()) {
        evidence.actor_name = body.actor_name.trim();
      }
      if (typeof body.actor_role === "string" && body.actor_role.trim()) {
        evidence.actor_role = body.actor_role.trim();
      }

      const { data: prep, error: prepErr } = await admin.rpc(
        "prepare_customer_portal_pending_accept",
        {
          p_session_token_hash: hash,
          p_request_id: body.target_id,
          p_evidence: evidence,
          p_ip_address: ip,
          p_user_agent: ua,
          p_audit_request_id: auditRequestId,
        },
      );

      if (prepErr) {
        log("error", FEATURE, "prepare accept failed", {
          extra: { error: prepErr.message },
        });
        return jsonResponse(500, { error: "internal_error" });
      }

      const prepRow = prep as Record<string, unknown> | null;
      if (!prepRow || prepRow.ok !== true) {
        const code = typeof prepRow?.code === "string" ? prepRow.code : "not_found";
        if (code === "module_disabled" || code === "forbidden") {
          return jsonResponse(403, { error: code });
        }
        if (
          code === "actor_name_required" ||
          code === "actor_role_required" ||
          code === "provider_not_supported" ||
          code === "missing_signature"
        ) {
          return jsonResponse(400, { error: code });
        }
        if (code === "native_session_missing") {
          return jsonResponse(409, { error: code });
        }
        return denied();
      }

      if (prepRow.already_decided === true) {
        const st = typeof prepRow.status === "string" ? prepRow.status : null;
        return jsonResponse(200, {
          action: "accept_pending_decision",
          actor_type: "grant",
          request_id: auditRequestId,
          result: {
            request_id: prepRow.request_id,
            status: st,
            applied: false,
            already_decided: true,
            decided_via: typeof prepRow.decided_via === "string"
              ? prepRow.decided_via
              : null,
            decided_at: typeof prepRow.decided_at === "string"
              ? prepRow.decided_at
              : null,
          },
        });
      }

      const sessionId = typeof prepRow.session_id === "string"
        ? prepRow.session_id
        : null;
      if (!sessionId || !SUPABASE_SERVICE_ROLE_KEY) {
        return jsonResponse(500, { error: "internal_error" });
      }

      await admin.rpc("update_signing_session_service", {
        p_session_id: sessionId,
        p_ip_address: ip,
        p_user_agent: ua,
      }).catch(() => {});

      const stampRes = await fetch(
        `${SUPABASE_URL}/functions/v1/stamp-pdf-signatures`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
          },
          body: JSON.stringify({
            session_id: sessionId,
            client_signature_base64: signature,
            ip_address: ip,
            user_agent: ua,
          }),
        },
      );

      if (!stampRes.ok) {
        const errText = await stampRes.text().catch(() => "");
        log("error", FEATURE, "portal stamp failed", {
          extra: { status: stampRes.status, body: errText.slice(0, 400) },
        });
        return jsonResponse(502, { error: "stamp_failed" });
      }

      const requestId = typeof prepRow.request_id === "string"
        ? prepRow.request_id
        : body.target_id;
      const { data: outcomeRaw, error: outcomeErr } = await admin.rpc(
        "get_commercial_decision_request_status_service",
        { p_request_id: requestId },
      );
      if (outcomeErr) {
        log("error", FEATURE, "post-stamp status read failed", {
          extra: { error: outcomeErr.message },
        });
        return jsonResponse(500, { error: "internal_error" });
      }
      const outcome = outcomeRaw as Record<string, unknown> | null;
      const status = typeof outcome?.status === "string" ? outcome.status : null;
      if (status !== "accepted" && status !== "declined") {
        log("error", FEATURE, "stamp ok but decision not applied", {
          extra: { request_id: requestId, status },
        });
        return jsonResponse(409, { error: "apply_failed", status: status ?? "open" });
      }

      return jsonResponse(200, {
        action: "accept_pending_decision",
        actor_type: "grant",
        request_id: auditRequestId,
        result: {
          request_id: requestId,
          status,
          applied: status === "accepted",
          already_decided: status === "declined",
          decided_via: typeof outcome?.decided_via === "string"
            ? outcome.decided_via
            : null,
          decided_at: typeof outcome?.decided_at === "string"
            ? outcome.decided_at
            : null,
          stamped: true,
        },
      });
    }

    const { data, error } = await admin.rpc("resolve_customer_portal_commercial", {
      p_session_token_hash: hash,
      p_action: action,
      p_kind: kind,
      p_cursor_sort: body.cursor_sort ?? null,
      p_cursor_id: body.cursor_id ?? null,
      p_limit: limit,
      p_ip_address: ip,
      p_user_agent: ua,
      p_request_id: auditRequestId,
      p_target_id: body.target_id ?? null,
      p_item_kind: body.item_kind ?? null,
    });

    if (error) {
      log("error", FEATURE, "resolve failed", { extra: { error: error.message } });
      return jsonResponse(500, { error: "internal_error" });
    }

    const row = data as Record<string, unknown> | null;
    if (!row || row.ok !== true) {
      if (row?.code === "module_disabled") {
        return jsonResponse(403, { error: "module_disabled" });
      }
      return denied();
    }

    let detail: Record<string, unknown> | undefined;
    if (row.detail && typeof row.detail === "object") {
      detail = await enrichDetailPdf(
        admin,
        row.detail as Record<string, unknown>,
        body.include_pdf_url === true,
      );
      if (action === "get_pending_decision") {
        const actorType = row.actor_type === "staff" ? "staff" : "grant";
        if (actorType === "staff") {
          detail = scrubStaffPendingDetail(detail);
        } else {
          const open = detail.status === "open";
          const canAct =
            detail.decline_available === true ||
            detail.accept_available === true ||
            detail.provider_continue_available === true;
          detail.can_decide = open && canAct;
        }
      }
    }

    const actorType = row.actor_type === "staff" ? "staff" : "grant";

    return jsonResponse(200, {
      actor_type: actorType,
      action: row.action,
      kind: row.kind,
      grant_id: row.grant_id,
      tenant_id: row.tenant_id,
      client_account_contact_id: row.client_account_contact_id,
      modules: row.modules,
      pending_decisions_count:
        typeof row.pending_decisions_count === "number"
          ? row.pending_decisions_count
          : undefined,
      principal_kind:
        typeof row.principal_kind === "string" ? row.principal_kind : undefined,
      items: row.items ?? [],
      detail,
      request_id: auditRequestId,
    });
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, { error: "internal_error" });
  }
});
