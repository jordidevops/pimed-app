/*
  Edge Function: process-signing-token
  Endpoint públic per a la pàgina /sign/:token (signar o rebutjar).
*/

import { corsHeaders }       from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { deleteStagingPdf }  from "../_shared/native-signing-staging.ts";
import {
  buildNativeSignLink,
  createSignedDocumentDownloadUrl,
  enqueueNativeSigningConfirmationEmail,
  enqueueNativeSigningRequestEmail,
} from "../_shared/native-signing-email.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { defaultSlowHandler, log, timedCall } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "process-signing-token";
const STAMP_SLOW_MS = 15_000;

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function getClientIp(req: Request): string | null {
  return (
    req.headers.get("CF-Connecting-IP") ??
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    null
  );
}

type RequestBody = {
  token:              string;
  action?:            "sign" | "decline";
  signature_base64?:  string;
  reason?:            string | null;
  ip_address?:        string | null;
  user_agent?:        string | null;
  geolocation?:       { lat: number; lon: number } | null;
};

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  }

  const db = createAdminClient();

  let body: RequestBody;
  try {
    body = await req.json() as RequestBody;
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (!body.token) {
    return new Response(JSON.stringify({ error: "missing_token" }), {
      status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const action = body.action ?? "sign";
  const ipAddress = body.ip_address ?? getClientIp(req);
  const userAgent = body.user_agent ?? req.headers.get("user-agent");

  // ── Rebuig ────────────────────────────────────────────────────────────────
  if (action === "decline") {
    const { data: sessionJson } = await db.rpc("lookup_signing_session_by_token", {
      p_token: body.token,
    });
    const session = sessionJson as { id: string; status: string } | null;
    if (!session) {
      return new Response(JSON.stringify({ error: "token_not_found" }), {
        status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (session.status !== "signed" && session.status !== "cancelled") {
      await db.rpc("log_signing_evidence", {
        p_session_id:  session.id,
        p_event_type:  "declined",
        p_ip_address:  ipAddress,
        p_user_agent:  userAgent,
        p_metadata:    body.reason ? { reason: body.reason } : {},
      }).catch(() => {});
    }

    const { data: declineResult, error: declineErr } = await db.rpc(
      "decline_signing_session_public",
      { p_token: body.token, p_reason: body.reason ?? null },
    );

    if (declineErr) {
      return new Response(JSON.stringify({ error: declineErr.message }), {
        status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const declined = declineResult as Record<string, unknown>;
    if (declined.error) {
      return new Response(JSON.stringify({ error: declined.error }), {
        status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const stagingPath = declined.staging_storage_path as string | null;
    await deleteStagingPdf(db, stagingPath);

    if (declined.submission_id) {
      await db.rpc("append_signing_event", {
        p_submission_id: declined.submission_id as string,
        p_event_type:    "form.declined",
        p_event_source:  "signer",
        p_signer_email:  null,
        p_signer_name:   null,
        p_status_after:  "declined",
        p_payload:       { reason: body.reason ?? null, native: true },
      }).catch((e: Error) => log("warn", FEATURE, "form.declined event failed", { extra: { error: e.message } }));
    }

    return new Response(JSON.stringify({ success: true, declined: true }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // ── Signar ────────────────────────────────────────────────────────────────
  if (!body.signature_base64) {
    return new Response(JSON.stringify({ error: "missing_required_fields" }), {
      status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const { data: sessionJson, error: sessErr } = await db.rpc(
    "lookup_signing_session_by_token",
    { p_token: body.token },
  );

  if (sessErr || !sessionJson) {
    return new Response(JSON.stringify({ error: "token_not_found" }), {
      status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const session = sessionJson as {
    id: string;
    tenant_id: string;
    status: string;
    expires_at: string;
    signer_name: string | null;
    signer_email: string | null;
    signer_role: string | null;
    signing_type: string;
    signing_group_id: string | null;
    signer_order: number;
    total_signers: number;
  };

  if (session.status === "signed") {
    return new Response(JSON.stringify({ error: "already_signed" }), {
      status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (session.status === "cancelled") {
    return new Response(JSON.stringify({ error: "session_declined" }), {
      status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (new Date(session.expires_at) < new Date()) {
    await db.rpc("update_signing_session_service", {
      p_session_id: session.id,
      p_status:     "expired",
    });
    return new Response(JSON.stringify({ error: "token_expired" }), {
      status: 410, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  await db.rpc("update_signing_session_service", {
    p_session_id:  session.id,
    p_ip_address:  ipAddress,
    p_user_agent:  userAgent,
    p_geolocation: body.geolocation ?? null,
  });

  await db.rpc("log_signing_evidence", {
    p_session_id:  session.id,
    p_event_type:  "signed",
    p_ip_address:  ipAddress,
    p_user_agent:  userAgent,
    p_geolocation: body.geolocation ?? null,
    p_metadata:    { signing_type: session.signing_type },
  });

  const stampStarted = Date.now();
  const stampRes = await timedCall(
    FEATURE,
    "stamp-pdf-signatures",
    STAMP_SLOW_MS,
    () => fetch(`${SUPABASE_URL}/functions/v1/stamp-pdf-signatures`, {
      method: "POST",
      headers: {
        "Content-Type":  "application/json",
        "Authorization": `Bearer ${SERVICE_ROLE_KEY}`,
      },
      body: JSON.stringify({
        session_id:               session.id,
        client_signature_base64:  body.signature_base64,
        ip_address:               ipAddress,
        user_agent:               userAgent,
        geolocation:              body.geolocation ?? null,
      }),
    }),
    defaultSlowHandler(FEATURE, "stamp-pdf-signatures", STAMP_SLOW_MS),
  );

  if (!stampRes.ok) {
    const errText = await stampRes.text().catch(() => "");
    let errData: Record<string, unknown> = {};
    try { errData = errText ? JSON.parse(errText) as Record<string, unknown> : {}; } catch { /* */ }
    const errMsg = (errData.error as string | undefined)
      ?? (errData.detail as string | undefined)
      ?? (stampRes.status === 502 || stampRes.status === 504 ? "stamp_timeout" : "stamp_failed");
    const durationMs = Date.now() - stampStarted;

    log("error", FEATURE, "Stamp failed", {
      tenantId: session.tenant_id,
      correlationId: session.id,
      durationMs,
      extra: { status: stampRes.status, error: errMsg },
    });

    const operationLog = createOperationLogService(db);
    await operationLog.log({
      tenantId: session.tenant_id,
      integrationType: "signing",
      operationCode: "native_sign_stamp",
      status: "failed",
      title: "No s'ha pogut aplicar la signatura al PDF",
      message: errMsg.slice(0, 200),
      errorCode: errMsg,
      errorMessage: errMsg,
      correlationId: session.id,
      entityType: "signing_session",
      entityId: session.id,
      durationMs,
      durationThresholdMs: STAMP_SLOW_MS,
      externalService: "stamp-pdf-signatures",
      isRetryable: stampRes.status >= 500,
    });

    if (stampRes.status >= 500 || isInfrastructureBug(new Error(errMsg))) {
      captureException(new Error(errMsg), {
        feature: FEATURE,
        tenantId: session.tenant_id,
        correlationId: session.id,
      });
    }

    return new Response(JSON.stringify({ error: errMsg }), {
      status: stampRes.status >= 400 ? stampRes.status : 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const stampData = await stampRes.json() as {
    success: boolean;
    result_version_id: string | null;
    audit_job_id: string | null;
  };

  const signedAt = new Date().toISOString();
  let docTitle = "Document";

  if (stampData.result_version_id) {
    const { data: verRow } = await db
      .from("document_versions")
      .select("document_id")
      .eq("id", stampData.result_version_id)
      .maybeSingle();
    if (verRow?.document_id) {
      const { data: docRow } = await db
        .from("documents")
        .select("title")
        .eq("id", verRow.document_id as string)
        .maybeSingle();
      if (docRow?.title) docTitle = docRow.title as string;
    }
  }

  let allSigned = session.total_signers <= 1 || !session.signing_group_id;

  if (session.signing_group_id) {
    const { data: nextSessionJson } = await db.rpc("advance_native_signing_group", {
      p_completed_session_id: session.id,
    });

    if (nextSessionJson) {
      allSigned = false;
      const next = nextSessionJson as {
        session_id: string;
        token: string;
        signer_email: string | null;
        signer_name: string | null;
        signer_role: string | null;
        signer_order: number;
        total_signers: number;
        expires_at: string;
      };

      if (next.signer_email) {
        const nextEmail = await enqueueNativeSigningRequestEmail(db, {
          tenantId:      session.tenant_id,
          sessionId:     next.session_id,
          toEmail:       next.signer_email,
          signerName:    next.signer_name,
          signerRole:    next.signer_role,
          documentTitle: docTitle,
          signLink:      buildNativeSignLink(next.token),
          expiresAt:     next.expires_at,
          currentOrder:  next.signer_order + 1,
          totalSigners:  next.total_signers,
          isNextSigner:  true,
        });
        if (!nextEmail.queued) {
          log("warn", FEATURE, "Next signer email not queued", {
            tenantId: session.tenant_id,
            correlationId: session.id,
            extra: { error: nextEmail.error },
          });
        }
      }
    } else {
      allSigned = true;
      if (stampData.result_version_id) {
        const downloadUrl = await createSignedDocumentDownloadUrl(db, stampData.result_version_id);
        if (downloadUrl) {
          const { data: recipientsJson } = await db.rpc("list_signing_group_recipients", {
            p_session_id: session.id,
          });
          const recipients = (Array.isArray(recipientsJson) ? recipientsJson : []) as Array<{
            session_id: string;
            signer_email: string;
            signer_name: string | null;
          }>;

          const groupKey = session.signing_group_id ?? session.id;
          for (const recipient of recipients) {
            if (!recipient.signer_email) continue;
            const confirmResult = await enqueueNativeSigningConfirmationEmail(db, {
              tenantId:          session.tenant_id,
              sessionId:         recipient.session_id,
              toEmail:           recipient.signer_email,
              signerName:        recipient.signer_name,
              documentTitle:     docTitle,
              signedDocumentUrl: downloadUrl,
              signedAt,
              groupKey,
            });
            if (!confirmResult.queued) {
              log("warn", FEATURE, "Confirmation email not queued", {
                tenantId: session.tenant_id,
                correlationId: session.id,
                extra: { email: recipient.signer_email, error: confirmResult.error },
              });
            }
          }
        }
      }
    }
  }

  log("info", FEATURE, "Session signed", {
    tenantId: session.tenant_id,
    correlationId: session.id,
    extra: { allSigned },
  });

  return new Response(JSON.stringify({
    success:           true,
    all_signed:        allSigned,
    result_version_id: stampData.result_version_id,
    audit_job_id:      stampData.audit_job_id,
  }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
