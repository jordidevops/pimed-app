import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createAdminDataClient, createUserClient } from "../_shared/supabase.ts";
import {
  buildCommercialDocumentHtml,
  type CommercialDocumentHtmlInput,
  type CommercialDocumentLine,
} from "../_shared/commercial-document-html.ts";
import { createGotenbergClientFromConfig, GotenbergError } from "../_shared/gotenberg-client.ts";
import { kickPdfQueueWorker } from "../_shared/kick-pdf-queue.ts";
import { renderLiquid } from "../_shared/liquid-renderer.ts";
import {
  persistCommercialRenderedPdf,
  signedCommercialPdfUrl,
} from "../_shared/persist-commercial-pdf.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "render-commercial-document";
const DOCUMENTS_BUCKET = "documents";
const PENDING_JOB_STATUSES = new Set(["queued", "processing", "failed"]);

type AppError = { status: number; code: string; message: string };

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function err(error: AppError): Response {
  return json(error.status, { error: { code: error.code, message: error.message } });
}

function asObject<T extends Record<string, unknown>>(value: unknown): T {
  return (value && typeof value === "object" && !Array.isArray(value) ? value : {}) as T;
}

function asUuid(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null;
}

async function getGotenbergConfig(
  admin: ReturnType<typeof createAdminClient>,
): Promise<Record<string, unknown>> {
  const { data, error } = await admin.rpc("get_pdf_converter_config");
  if (error) throw new Error(`get_pdf_converter_config: ${error.message}`);
  return (data ?? {}) as Record<string, unknown>;
}

async function latestVersionPath(
  admin: ReturnType<typeof createAdminClient>,
  documentId: string,
): Promise<{ versionId: string; path: string } | null> {
  const { data, error } = await admin
    .from("document_versions")
    .select("id, file_path_or_url, version_number")
    .eq("document_id", documentId)
    .order("version_number", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error || !data?.file_path_or_url) return null;
  return { versionId: data.id as string, path: data.file_path_or_url as string };
}

async function signedReadyPayload(
  admin: ReturnType<typeof createAdminClient>,
  renderedDocumentId: string,
  extra: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  const latest = await latestVersionPath(admin, renderedDocumentId);
  const downloadUrl = latest ? await signedCommercialPdfUrl(admin, latest.path) : null;
  return {
    status: "ready",
    rendered_document_id: renderedDocumentId,
    version_id: latest?.versionId ?? null,
    download_url: downloadUrl,
    ...extra,
  };
}

async function loadLogoUrl(
  adminData: ReturnType<typeof createAdminDataClient>,
  tenantId: string,
  snapshotLogo: string | null | undefined,
): Promise<string | null> {
  if (snapshotLogo?.trim()) return snapshotLogo.trim();
  const { data } = await adminData
    .from("email_configs")
    .select("logo_url")
    .eq("tenant_id", tenantId)
    .limit(1)
    .maybeSingle();
  const logo = typeof data?.logo_url === "string" ? data.logo_url.trim() : "";
  return logo || null;
}

async function loadTenantName(
  adminData: ReturnType<typeof createAdminDataClient>,
  tenantId: string,
): Promise<string> {
  const { data } = await adminData.from("tenants").select("name").eq("id", tenantId).maybeSingle();
  return typeof data?.name === "string" ? data.name : "";
}

async function renderTemplateBlocks(
  adminData: ReturnType<typeof createAdminDataClient>,
  templateId: string | null,
  tenantId: string,
  context: Record<string, unknown>,
): Promise<{
  pageHeaderHtml: string | null;
  pageFooterHtml: string | null;
  documentHeaderHtml: string | null;
  documentFooterHtml: string | null;
}> {
  const empty = {
    pageHeaderHtml: null as string | null,
    pageFooterHtml: null as string | null,
    documentHeaderHtml: null as string | null,
    documentFooterHtml: null as string | null,
  };
  if (!templateId) return empty;

  const { data: template } = await adminData
    .from("document_templates")
    .select("id, default_block_mapping, is_active")
    .eq("id", templateId)
    .maybeSingle();
  if (!template?.is_active) return empty;

  const mapping = asObject<Record<string, string>>(template.default_block_mapping);
  const blockIds = [...new Set(Object.values(mapping).filter((id) => typeof id === "string" && id))];
  if (blockIds.length === 0) return empty;

  const { data: blocks, error } = await adminData
    .from("document_content_blocks")
    .select("id, block_type, format, content")
    .in("id", blockIds)
    .eq("is_active", true)
    .or(`is_platform_default.eq.true,tenant_id.eq.${tenantId}`);
  if (error || !blocks) {
    log("warn", FEATURE, "content blocks query failed", { extra: { error: error?.message } });
    return empty;
  }

  const byId = new Map(
    (blocks as Array<{ id: string; block_type: string; format: string; content: string }>).map(
      (b) => [b.id, b],
    ),
  );

  for (const [, blockId] of Object.entries(mapping)) {
    const block = byId.get(blockId);
    if (!block) continue;
    let rendered = block.content ?? "";
    if (block.format === "HTML" || block.format === "TEXT") {
      try {
        rendered = await renderLiquid(block.content, context);
      } catch (e) {
        log("warn", FEATURE, "block liquid failed", {
          extra: { block_id: block.id, error: (e as Error).message },
        });
        rendered = "";
      }
    }
    if (block.block_type === "PAGE_HEADER") empty.pageHeaderHtml = rendered;
    else if (block.block_type === "PAGE_FOOTER") empty.pageFooterHtml = rendered;
    else if (block.block_type === "DOCUMENT_HEADER") empty.documentHeaderHtml = rendered;
    else if (block.block_type === "DOCUMENT_FOOTER") empty.documentFooterHtml = rendered;
  }
  return empty;
}

async function enqueueCommercialPdfJob(params: {
  admin: ReturnType<typeof createAdminClient>;
  tenantId: string;
  documentId: string;
  title: string;
  html: string;
  userId: string | null;
  clientOpId: string;
  regenerate: boolean;
}): Promise<string> {
  const htmlPath =
    `${params.tenantId}/commercial/${params.documentId}/intermediate/${crypto.randomUUID()}.html`;
  const htmlBytes = new TextEncoder().encode(params.html);
  const { error: uploadErr } = await params.admin.storage
    .from(DOCUMENTS_BUCKET)
    .upload(htmlPath, new Blob([htmlBytes], { type: "text/html" }), {
      contentType: "text/html;charset=utf-8",
      upsert: false,
    });
  if (uploadErr) throw new Error(`intermediate upload: ${uploadErr.message}`);

  const { data: jobData, error: jobErr } = await params.admin.rpc("create_pdf_job", {
    p_tenant_id: params.tenantId,
    p_source_type: "commercial_document",
    p_source_ref_id: params.documentId,
    p_template_type: "html",
    p_document_title: params.title,
    p_output_profile: "pdf",
    p_idempotency_key: params.regenerate
      ? `commercial-pdf-${params.documentId}-${params.clientOpId}`
      : `commercial-pdf-${params.documentId}`,
    p_metadata: {
      type: "commercial_document",
      commercial_document_id: params.documentId,
      client_op_id: params.clientOpId,
    },
    p_intermediate_path: htmlPath,
    p_intermediate_size_bytes: htmlBytes.byteLength,
  });
  if (jobErr || !jobData) throw new Error(jobErr?.message ?? "create_pdf_job failed");

  const job = typeof jobData === "string" ? JSON.parse(jobData) : jobData;
  const jobId = (job as { job_id?: string }).job_id;
  if (!jobId) throw new Error("create_pdf_job missing job_id");

  await params.admin.rpc("set_commercial_pdf_job", {
    p_document_id: params.documentId,
    p_pdf_job_id: jobId,
  });

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  kickPdfQueueWorker(supabaseUrl, serviceKey);
  return jobId;
}

Deno.serve(async (req: Request) => {
  initObservability({ feature: FEATURE });

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return err({ status: 405, code: "method_not_allowed", message: "Només POST" });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return err({ status: 401, code: "unauthorized", message: "Token invàlid o expirat" });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return err({ status: 400, code: "invalid_json", message: "JSON invàlid" });
  }

  const documentId = asUuid(body.document_id);
  const clientOpId = asUuid(body.client_op_id) ?? crypto.randomUUID();
  const regenerate = body.regenerate === true;
  if (!documentId) {
    return err({ status: 400, code: "missing_document_id", message: "document_id és obligatori" });
  }

  try {
    const userClient = createUserClient(req);
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      return err({ status: 401, code: "unauthorized", message: "Token invàlid o expirat" });
    }

    const { data: doc, error: docErr } = await userClient
      .from("commercial_documents")
      .select("*")
      .eq("id", documentId)
      .maybeSingle();
    if (docErr) {
      return err({ status: 400, code: "document_read_failed", message: docErr.message });
    }
    if (!doc) {
      return err({ status: 404, code: "document_not_found", message: "Document no trobat" });
    }

    const row = doc as Record<string, unknown>;
    const tenantId = String(row.tenant_id);
    const status = String(row.status ?? "");
    if (status === "draft") {
      return err({ status: 409, code: "document_not_issued", message: "El document encara és esborrany" });
    }

    const admin = createAdminClient();
    const adminData = createAdminDataClient();
    const renderedId = asUuid(row.rendered_document_id);
    const existingJobId = asUuid(row.pdf_job_id);

    if (renderedId && !regenerate) {
      return json(200, await signedReadyPayload(admin, renderedId, { already_ready: true }));
    }

    if (existingJobId && !regenerate && !renderedId) {
      const { data: job } = await admin
        .from("document_pdf_jobs")
        .select("id, status, result_document_id")
        .eq("id", existingJobId)
        .maybeSingle();
      if (job && PENDING_JOB_STATUSES.has(String(job.status))) {
        return json(202, {
          status: "pending",
          pdf_job_id: existingJobId,
          html_fallback: true,
        });
      }
      if (job?.result_document_id) {
        await admin.rpc("link_commercial_rendered_document", {
          p_document_id: documentId,
          p_dms_document_id: job.result_document_id,
          p_client_op_id: clientOpId,
          p_pdf_job_id: existingJobId,
        });
        return json(200, await signedReadyPayload(admin, String(job.result_document_id)));
      }
    }

    const { data: lines, error: linesErr } = await userClient
      .from("commercial_document_lines")
      .select("*")
      .eq("document_id", documentId)
      .order("position", { ascending: true });
    if (linesErr) {
      return err({ status: 400, code: "lines_read_failed", message: linesErr.message });
    }

    const seller = asObject<CommercialDocumentHtmlInput["seller_snapshot"]>(row.seller_snapshot);
    const logoUrl = await loadLogoUrl(adminData, tenantId, seller.logo_url);
    if (logoUrl) seller.logo_url = logoUrl;

    const htmlInput: CommercialDocumentHtmlInput = {
      doc_type: String(row.doc_type),
      doc_number: (row.doc_number as string | null) ?? null,
      status,
      seller_snapshot: seller,
      buyer_snapshot: asObject(row.buyer_snapshot),
      service_address_snapshot: asObject(row.service_address_snapshot),
      terms_text: (row.terms_text as string | null) ?? null,
      locale: (row.locale as string | null) ?? "ca",
      currency: (row.currency as string | null) ?? "EUR",
      subtotal: Number(row.subtotal ?? 0),
      tax_breakdown: Array.isArray(row.tax_breakdown)
        ? (row.tax_breakdown as CommercialDocumentHtmlInput["tax_breakdown"])
        : [],
      total: Number(row.total ?? 0),
      show_prices: row.show_prices !== false,
      issued_at: (row.issued_at as string | null) ?? null,
      valid_until: (row.valid_until as string | null) ?? null,
      lines: ((lines ?? []) as CommercialDocumentLine[]),
    };

    const tenantName = await loadTenantName(adminData, tenantId);
    const templateId = asUuid(row.document_template_id);
    const blocks = await renderTemplateBlocks(adminData, templateId, tenantId, {
      tenant: { name: tenantName, logo_url: logoUrl },
      seller,
      buyer: htmlInput.buyer_snapshot,
      document: {
        doc_type: htmlInput.doc_type,
        doc_number: htmlInput.doc_number,
        locale: htmlInput.locale,
        status: htmlInput.status,
      },
    });

    const html = buildCommercialDocumentHtml(htmlInput, {
      documentHeaderHtml: blocks.documentHeaderHtml ?? undefined,
      documentFooterHtml: blocks.documentFooterHtml ?? undefined,
    });
    const title = `${htmlInput.doc_type} ${htmlInput.doc_number ?? ""}`.trim();

    const cfg = await getGotenbergConfig(admin);
    const pdfEnabled = cfg["pdf_enabled"] === true;
    let lastError = "";

    // Commercial PDF uses Gotenberg directly. pdf_enabled only gates the async
    // signing queue; with it false the worker would skip the job anyway.
    try {
      const client = createGotenbergClientFromConfig(cfg);
      const pdfBytes = await client.htmlToPdf(html, {
        profile: "pdf",
        headerHtml: blocks.pageHeaderHtml ?? undefined,
        footerHtml: blocks.pageFooterHtml ?? undefined,
      });
      const persisted = await persistCommercialRenderedPdf({
        admin,
        tenantId,
        commercialDocumentId: documentId,
        title,
        createdBy: user.id,
        clientOpId,
        pdfBytes,
      });
      const downloadUrl = await signedCommercialPdfUrl(admin, persisted.path);
      return json(200, {
        status: "ready",
        rendered_document_id: persisted.documentId,
        version_id: persisted.versionId,
        download_url: downloadUrl,
      });
    } catch (e) {
      lastError = (e as Error).message ?? String(e);
      log("warn", FEATURE, "sync Gotenberg failed", {
        tenantId,
        extra: { error: lastError, unreachable: e instanceof GotenbergError && e.isUnreachable },
      });
    }

    if (pdfEnabled) {
      try {
        const jobId = await enqueueCommercialPdfJob({
          admin,
          tenantId,
          documentId,
          title,
          html,
          userId: user.id,
          clientOpId,
          regenerate,
        });
        return json(200, {
          status: "pending",
          pdf_job_id: jobId,
          html_fallback: true,
        });
      } catch (e) {
        lastError = (e as Error).message ?? lastError;
        log("warn", FEATURE, "queue fallback failed", {
          tenantId,
          extra: { error: (e as Error).message },
        });
      }
    }

    return json(200, {
      status: "unavailable",
      html_fallback: true,
      error: lastError || "gotenberg_unavailable",
    });
  } catch (e) {
    captureException(e, { feature: FEATURE });
    log("error", FEATURE, "render failed", { extra: { error: (e as Error).message } });
    return err({
      status: 500,
      code: "render_failed",
      message: (e as Error).message ?? "render_failed",
    });
  }
});
