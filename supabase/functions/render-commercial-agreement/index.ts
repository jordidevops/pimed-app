import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createAdminDataClient, createUserClient } from "../_shared/supabase.ts";
import { createGotenbergClientFromConfig, GotenbergError } from "../_shared/gotenberg-client.ts";
import { renderLiquid } from "../_shared/liquid-renderer.ts";
import { injectHtmlSignatureMarkers } from "../_shared/signing-field-map.ts";
import { signedCommercialPdfUrl } from "../_shared/persist-commercial-pdf.ts";
import { buildAgreementTemplateContext } from "../_shared/commercial-agreement-context.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "render-commercial-agreement";
const DOCUMENTS_BUCKET = "documents";

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function asUuid(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null;
}

Deno.serve(async (req) => {
  initObservability(FEATURE);
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return json(405, { error: { code: "method_not_allowed", message: "POST" } });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json(401, { error: { code: "unauthorized", message: "Token invàlid o expirat" } });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: { code: "invalid_json", message: "JSON invàlid" } });
  }

  const versionId = asUuid(body.version_id);
  if (!versionId) {
    return json(400, { error: { code: "missing_version_id", message: "version_id és obligatori" } });
  }

  const headerTenantId = asUuid(req.headers.get("x-tenant-id"));

  try {
    const userClient = createUserClient(req);
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      return json(401, { error: { code: "unauthorized", message: "Token invàlid o expirat" } });
    }

    const { data: version, error: versionErr } = await userClient
      .from("commercial_agreement_versions")
      .select("*")
      .eq("id", versionId)
      .maybeSingle();
    if (versionErr || !version) {
      return json(404, { error: { code: "agreement_version_not_found", message: "Versió no trobada" } });
    }

    const versionTenantId = asUuid(version.tenant_id);
    if (!versionTenantId) {
      return json(404, { error: { code: "agreement_version_not_found", message: "Versió no trobada" } });
    }
    if (headerTenantId && headerTenantId !== versionTenantId) {
      return json(403, { error: { code: "tenant_mismatch", message: "El tenant no coincideix amb la versió" } });
    }

    // Owner/manager global only — rendering is expensive (Gotenberg + storage).
    const { data: membership, error: membershipErr } = await userClient
      .from("tenant_members")
      .select("role")
      .eq("tenant_id", versionTenantId)
      .eq("user_id", user.id)
      .eq("is_active", true)
      .is("site_id", null)
      .in("role", ["owner", "manager"])
      .maybeSingle();
    if (membershipErr) {
      return json(500, { error: { code: "membership_check_failed", message: "No s'ha pogut verificar el rol" } });
    }
    if (!membership) {
      return json(403, { error: { code: "forbidden", message: "Cal rol owner o manager" } });
    }

    const admin = createAdminClient();
    const adminData = createAdminDataClient();
    const renderedId = asUuid(version.rendered_document_id);
    if (renderedId && version.status !== "draft") {
      const { data: latest } = await admin
        .from("document_versions")
        .select("id, file_path_or_url")
        .eq("document_id", renderedId)
        .order("version_number", { ascending: false })
        .limit(1)
        .maybeSingle();
      const downloadUrl = latest?.file_path_or_url
        ? await signedCommercialPdfUrl(admin, latest.file_path_or_url)
        : null;
      return json(200, {
        status: "ready",
        rendered_document_id: renderedId,
        version_id: latest?.id ?? null,
        download_url: downloadUrl,
        already_ready: true,
      });
    }
    if (version.status !== "draft") {
      return json(409, { error: { code: "agreement_version_immutable", message: "La versió ja no és esborrany" } });
    }

    const { data: agreement } = await adminData
      .from("commercial_agreements")
      .select("*")
      .eq("id", version.agreement_id)
      .maybeSingle();
    if (!agreement) {
      return json(404, { error: { code: "agreement_not_found", message: "Acord no trobat" } });
    }

    const quoteId = asUuid(version.source_quote_id);
    const { data: quote } = quoteId
      ? await adminData
          .from("commercial_documents")
          .select("*")
          .eq("id", quoteId)
          .maybeSingle()
      : { data: null };
    const { data: lines } = quoteId
      ? await adminData
          .from("commercial_document_lines")
          .select("*")
          .eq("document_id", quoteId)
          .order("position", { ascending: true })
      : { data: [] };

    if (quoteId && !quote) {
      return json(404, { error: { code: "quote_not_found", message: "Pressupost origen no trobat" } });
    }

    const terms = (version.terms_snapshot ?? {}) as Record<string, unknown>;
    const locale =
      (quote?.locale as string | null) ||
      (typeof terms.locale === "string" ? terms.locale : null) ||
      "ca";
    const { data: localeRow } = await adminData
      .from("document_template_locales")
      .select("html_content, locale")
      .eq("template_id", version.full_body_template_id)
      .eq("is_active", true)
      .in("locale", [locale, "ca"])
      .limit(2);
    const htmlContent = (localeRow ?? []).find((row) => row.locale === locale)?.html_content
      ?? (localeRow ?? []).find((row) => row.locale === "ca")?.html_content;
    if (!htmlContent) {
      return json(400, { error: { code: "agreement_template_invalid", message: "La plantilla d'acord no té HTML" } });
    }

    const seller = (quote?.seller_snapshot ?? {}) as Record<string, unknown>;
    const buyer = (quote?.buyer_snapshot ?? {}) as Record<string, unknown>;
    const { data: tenant } = await adminData
      .from("tenants")
      .select("name")
      .eq("id", version.tenant_id)
      .maybeSingle();

    let buyerName =
      typeof buyer.display_name === "string" ? buyer.display_name : null;
    let sellerName =
      typeof seller.display_name === "string" ? seller.display_name : null;
    if (!buyerName && agreement.client_id) {
      const { data: contact } = await adminData
        .from("contacts")
        .select("display_name")
        .eq("id", agreement.client_id)
        .maybeSingle();
      buyerName = contact?.display_name ?? null;
    }
    if (!sellerName) {
      sellerName = tenant?.name ?? null;
    }

    // Prefer cycle dates when present (operational window); fall back to contractual version.
    let startsOn = version.starts_on ?? null;
    let endsOn = version.ends_on ?? null;
    let nextBillingOn = version.next_billing_on ?? null;
    const { data: agreementRow } = await adminData
      .from("commercial_agreements")
      .select("active_cycle_id")
      .eq("id", agreement.id)
      .maybeSingle();
    const cycleId = asUuid(agreementRow?.active_cycle_id);
    if (cycleId) {
      const { data: cycle } = await adminData
        .from("commercial_agreement_cycles")
        .select("starts_on, ends_on")
        .eq("id", cycleId)
        .maybeSingle();
      if (cycle) {
        startsOn = cycle.starts_on ?? startsOn;
        endsOn = cycle.ends_on ?? endsOn;
      }
    }
    const { data: billingState } = await adminData
      .from("commercial_agreement_billing_state")
      .select("next_billing_on")
      .eq("agreement_id", agreement.id)
      .maybeSingle();
    if (billingState?.next_billing_on) {
      nextBillingOn = billingState.next_billing_on;
    }

    const context = buildAgreementTemplateContext({
      agreementId: agreement.id,
      agreementStatus: agreement.status,
      agreementKind: agreement.kind,
      workGate: agreement.work_gate,
      startsOn,
      endsOn,
      noticeDays: version.notice_days ?? null,
      sla: {
        responseHours: version.sla_response_hours ?? null,
        resolutionHours: version.sla_resolution_hours ?? null,
        coverageNotes: version.sla_coverage_notes ?? null,
      },
      billing: {
        cadence: version.billing_cadence ?? null,
        amountCents: version.billing_amount_cents ?? null,
        currency: version.billing_currency ?? null,
        anchorDay: version.billing_anchor_day ?? null,
        nextBillingOn,
      },
      quoteId: quote?.id ?? null,
      quoteNumber: quote?.doc_number ?? null,
      quoteContentHash: String(
        version.source_quote_content_hash ?? quote?.content_hash ?? "",
      ) || null,
      quoteDocumentId: version.source_quote_document_id,
      locale,
      currency: (quote?.currency as string | null) ?? "EUR",
      subtotal: Number(quote?.subtotal ?? 0),
      total: Number(quote?.total ?? 0),
      lines: (lines ?? []).map((line) => ({
        name: line.name,
        description: line.description,
        unit: line.unit,
        quantity: line.quantity,
        unit_price: line.unit_price,
        discount_pct: line.discount_pct,
        tax_rate: line.tax_rate,
        line_subtotal: line.line_subtotal,
        line_total: line.line_total,
      })),
      tenantName: tenant?.name ?? "",
      sellerName,
      buyerName,
    });

    const rendered = await renderLiquid(htmlContent, context);
    const html = injectHtmlSignatureMarkers(rendered).html;
    const { data: cfg, error: cfgErr } = await admin.rpc("get_pdf_converter_config");
    if (cfgErr) throw new Error(cfgErr.message);
    const client = createGotenbergClientFromConfig((cfg ?? {}) as Record<string, unknown>);
    const title = quote?.doc_number
      ? `Contracte ${quote.doc_number}`.trim()
      : `Acord marc ${agreement.id.slice(0, 8)}`;
    const pdfBytes = await client.htmlToPdf(html, { profile: "pdf" });
    const path = `${version.tenant_id}/agreements/${version.id}/${crypto.randomUUID()}/contracte.pdf`;
    const { error: uploadErr } = await admin.storage.from(DOCUMENTS_BUCKET).upload(path, pdfBytes, {
      contentType: "application/pdf",
      upsert: false,
    });
    if (uploadErr) throw new Error(uploadErr.message);

    const { data: created, error: createErr } = await admin.rpc(
      "create_commercial_agreement_rendered_document_internal",
      {
        p_version_id: version.id,
        p_title: title,
        p_file_path_or_url: path,
        p_mime_type: "application/pdf",
        p_size_bytes: pdfBytes.byteLength,
        p_created_by: user.id,
      },
    );
    if (createErr || !created) {
      const { error: removeErr } = await admin.storage.from(DOCUMENTS_BUCKET).remove([path]);
      if (removeErr) {
        try {
          await admin.rpc("record_commercial_agreement_render_orphan", {
            p_tenant_id: versionTenantId,
            p_version_id: version.id,
            p_storage_path: path,
            p_created_by: user.id,
          });
        } catch (orphanErr) {
          log("error", FEATURE, "orphan record failed", {
            extra: { path, error: (orphanErr as Error).message },
          });
        }
      }
      throw new Error(createErr?.message ?? "agreement_pdf_missing");
    }
    const payload = created as { document?: { id?: string }; version?: { id?: string } };
    const downloadUrl = await signedCommercialPdfUrl(admin, path);
    return json(200, {
      status: "ready",
      rendered_document_id: payload.document?.id ?? null,
      version_id: payload.version?.id ?? null,
      download_url: downloadUrl,
    });
  } catch (e) {
    const unreachable = e instanceof GotenbergError && e.isUnreachable;
    captureException(e, { feature: FEATURE });
    log("error", FEATURE, "render agreement failed", {
      extra: { error: (e as Error).message, unreachable },
    });
    if (unreachable) {
      return json(503, {
        status: "unavailable",
        error: { code: "gotenberg_unavailable", message: (e as Error).message },
      });
    }
    return json(500, {
      status: "error",
      error: { code: "render_failed", message: (e as Error).message ?? "render_failed" },
    });
  }
});
