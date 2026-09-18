/*
  Edge Function: sign-document-router
  ─────────────────────────────────────
  Orquestrador de signatura i generació documental.

  Suporta:
    · source_type = document_existing  → fitxer existent al DMS (document_versions)
    · source_type = template_locale    → locale d'una plantilla (document_template_locales)
    · action = sign                    → enviar a DocuSeal (one-off, sense repositori persistent)
    · action = generate_only           → crear nova document_version sense firma

  Mode de signatura:
    · platform: clau DocuSeal de l'entorn (DOCUSEAL_API_KEY), consumeix crèdit atòmic
    · byo:      clau del tenant llegida de Supabase Vault via RPC get_docuseal_key_for_signing

  Idempotència:
    · Si s'envia external_id i ja existeix una submission completada, es retorna error.
    · DocuSeal rep external_id per poder deduplicar al webhook.

  Testeig local:
    supabase functions serve sign-document-router --env-file supabase/functions/.env.local
*/

import { corsHeaders }                        from "../_shared/cors.ts";
import { createUserClient, createAdminClient, createAdminDataClient } from "../_shared/supabase.ts";
import { renderLiquid }                        from "../_shared/liquid-renderer.ts";
import { renderDocx }                          from "../_shared/docx-renderer.ts";
import { buildContext }                        from "../_shared/context-builder.ts";
import { createGotenbergClientFromConfig, GotenbergError } from "../_shared/gotenberg-client.ts";
import {
  buildNativeSignLink,
  enqueueNativeSigningRequestEmail,
} from "../_shared/native-signing-email.ts";
import {
  buildNativeSignersSnapshot,
  emitNativeSubmissionCreated,
} from "../_shared/native-signing-completion.ts";
import {
  injectHtmlSignatureMarkers,
  injectDocxSignatureMarkers,
  resolveAndPersistFieldMap,
  type SigningFieldMeta,
} from "../_shared/signing-field-map.ts";

// ---------------------------------------------------------------------------
// Entorn
// ---------------------------------------------------------------------------

const SUPABASE_URL          = Deno.env.get("SUPABASE_URL")!;
const EXT_SUPABASE_URL      = Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;
const DOCUSEAL_API_KEY           = Deno.env.get("DOCUSEAL_API_KEY") ?? "";
const DOCUSEAL_API_URL           = Deno.env.get("DOCUSEAL_API_URL") ?? "https://api.docuseal.eu";
// URL base del portal de signatura (derivan d'API URL): api.docuseal.eu → docuseal.eu
const DOCUSEAL_SIGNING_BASE_URL  = DOCUSEAL_API_URL.replace("://api.", "://");

const DOCUMENTS_BUCKET          = "documents";
const DOCUMENT_TEMPLATES_BUCKET = "document-templates";
const SERVICE_ROLE_KEY          = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TENANT_PORTAL_URL         = Deno.env.get("TENANT_PORTAL_URL") ?? "http://localhost:5173";

import { kickPdfQueueWorker } from "../_shared/kick-pdf-queue.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "sign-document-router";

// ---------------------------------------------------------------------------
// Caché in-memory de fitxers de plantilla
// Viu mentre la instància Deno està calenta (~5-15 min d'inactivitat).
// Només s'aplica al bucket document-templates (fitxers immutables per ús).
// Els documents d'usuari (DMS) NO es cachetegen perquè poden canviar.
// ---------------------------------------------------------------------------
const TEMPLATE_CACHE_TTL_MS = 10 * 60 * 1000; // 10 minuts

interface TemplateCacheEntry {
  data:       Uint8Array;
  mimeType:   string;
  cachedAt:   number;
}

const templateCache = new Map<string, TemplateCacheEntry>();

// ---------------------------------------------------------------------------
// Tipus
// ---------------------------------------------------------------------------

type SourceType    = "document_existing" | "template_locale";
type Action        = "sign" | "generate_only" | "sign_native";
type OutputFormat  = "native" | "pdf";
type OutputProfile = "pdf" | "pdfa2b" | "pdfa3b";
type NativeSignType = "presential" | "remote";

interface Signer {
  email: string;
  name:  string;
  role?: string;
  order?: number;  // ordre de signatura 0-indexed per DocuSeal
}

type NotificationMode = 'docuseal_auto' | 'app_manual' | 'app_auto_all' | 'app_auto_sequential';

interface SignerLink {
  order:       number;
  email:       string;
  role:        string;
  signing_url: string | null;
}

interface RequestBody {
  tenant_id:                    string;
  action:                       Action;
  source_type:                  SourceType;
  client_request_id?:           string;
  source_document_version_id?:  string;
  source_template_locale_id?:   string;
  folder_id?:                   string;
  document_title?:              string;
  document_category?:           string;
  signers?:                     Signer[];
  /** Context nested canònic. Ex.: { input: { custom_note: '...' }, Treballador: {...} } */
  context?:                     Record<string, unknown>;
  /** Mode de notificació per a aquesta submissió. Si no s'especifica, hereta el default del tenant. */
  notification_mode?:           NotificationMode;
  /** Binding de rols/prefixos a entitats per resolució server-side de variables path-based.
   *  Clau = nom del rol (e.g. "Treballador") o prefix directe (e.g. "site").
   *  Resolució: {{Treballador.full_name}} → employees.full_name sense heurística. */
  context_refs?:                Record<string, { entity_type: string; entity_id: string }>;
  metadata?:                    Record<string, unknown>;
  /** Si true, afegeix camps de signatura posicionals al PDF (per PDFs sense etiquetes DocuSeal). */
  use_explicit_fields?:         boolean;
  /** HTML ja renderitzat pel frontend per a plantilles text/html.
   *  Quan és present, el servidor l'utilitza directament sense re-renderitzar amb LiquidJS.
   *  No afecta plantilles DOCX, PDF ni les cues d'email. */
  pre_rendered_content?:        string;
  /** Format de sortida: 'native' (defecte) o 'pdf' (Gotenberg). */
  output_format?:               OutputFormat;
  /** Perfil PDF: 'pdf' | 'pdfa2b' | 'pdfa3b'. El backend valida segons el cas d'ús. */
  output_profile?:              OutputProfile;
  /** Per a action=sign_native: tipus de firma (presencial o remota). */
  native_sign_type?:            NativeSignType;
  /** Per a sign_native remota: email del signant. */
  signer_email?:                string;
  /** Per a sign_native: nom del signant. */
  signer_name?:                 string;
  /** Per a sign_native: rol del signant. */
  signer_role?:                 string;
  /** Worker intern (attendance-protocol-publish): usuari gestor que inicia la publicació. */
  initiated_by_user_id?:       string;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code:   string,
    message: string,
  ) {
    super(message);
    this.name = "AppError";
  }
}

function resolveNativeSigners(body: RequestBody): Signer[] {
  if (Array.isArray(body.signers) && body.signers.length > 0) {
    return body.signers.map((s, i) => ({
      email: s.email,
      name:  s.name ?? s.email,
      role:  s.role,
      order: s.order ?? i,
    }));
  }
  if (body.signer_email) {
    return [{
      email: body.signer_email,
      name:  body.signer_name ?? body.signer_email,
      role:  body.signer_role,
      order: 0,
    }];
  }
  return [];
}

function mapTemplateRenderError(err: unknown): AppError | null {
  const msg = (err as Error)?.message ?? String(err);
  if (msg.startsWith("template_syntax_error:")) {
    return new AppError(
      400,
      "invalid_template_syntax",
      msg.replace(/^template_syntax_error:\s*/i, "").trim() || "Sintaxi de plantilla invàlida",
    );
  }
  if (msg.startsWith("invalid_docx_template:")) {
    return new AppError(
      400,
      "invalid_docx_template",
      msg.replace(/^invalid_docx_template:\s*/i, "").trim() || "Plantilla DOCX invàlida",
    );
  }
  if (msg.startsWith("docx_render_error:")) {
    return new AppError(
      400,
      "invalid_docx_template",
      msg.replace(/^docx_render_error:\s*/i, "").trim() || "Error renderitzant la plantilla DOCX",
    );
  }
  return null;
}

async function renderLiquidSafe(
  template: string,
  context: Record<string, unknown>,
): Promise<string> {
  try {
    return await renderLiquid(template, context);
  } catch (err) {
    throw mapTemplateRenderError(err) ?? err;
  }
}

function renderDocxSafe(
  input: Uint8Array,
  context: Record<string, unknown>,
): Uint8Array {
  try {
    return renderDocx(input, context);
  } catch (err) {
    throw mapTemplateRenderError(err) ?? err;
  }
}

function jsonOk(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function jsonError(status: number, code: string, message: string): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function getIdempotencyKey(req: Request, body: RequestBody): string {
  const headerKey = req.headers.get("Idempotency-Key") ?? req.headers.get("idempotency-key");
  if (headerKey && headerKey.trim().length > 0) return headerKey.trim();
  if (body.client_request_id && body.client_request_id.trim().length > 0) return body.client_request_id.trim();
  return crypto.randomUUID();
}

function sanitizeFileName(name: string): string {
  const normalized = name.trim() || "document";
  const cleaned = normalized.replace(/[^\w.\-]/g, "_").replace(/_+/g, "_").slice(0, 200);
  return cleaned || "document";
}

function rolloutBucket(input: string): number {
  let hash = 5381;
  for (let i = 0; i < input.length; i += 1) {
    hash = ((hash << 5) + hash) + input.charCodeAt(i);
    hash |= 0;
  }
  return Math.abs(hash) % 100;
}

async function isTenantSigningFeatureEnabled(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
): Promise<boolean> {
  const { data: enabled, error } = await adminClient.rpc("is_tenant_feature_enabled", {
    p_tenant_id:   tenantId,
    p_feature_key: "tenant_signing_enabled",
  });

  if (error) {
    throw new AppError(500, "feature_flag_error", `Error llegint feature flag: ${error.message}`);
  }

  return Boolean(enabled);
}

// ---------------------------------------------------------------------------
// Validació del body
// ---------------------------------------------------------------------------

async function parseBody(req: Request): Promise<RequestBody> {
  let raw: Record<string, unknown>;
  try {
    raw = await req.json();
  } catch {
    throw new AppError(400, "invalid_json", "Request body must be valid JSON");
  }

  if (typeof raw.tenant_id !== "string" || !raw.tenant_id)
    throw new AppError(400, "missing_tenant_id", "tenant_id és obligatori");
  if (raw.action !== "sign" && raw.action !== "generate_only" && raw.action !== "sign_native")
    throw new AppError(400, "invalid_action", "action ha de ser 'sign', 'generate_only' o 'sign_native'");
  if (raw.source_type !== "document_existing" && raw.source_type !== "template_locale")
    throw new AppError(400, "invalid_source_type", "source_type ha de ser 'document_existing' o 'template_locale'");
  if (raw.source_type === "document_existing" && typeof raw.source_document_version_id !== "string")
    throw new AppError(400, "missing_source_document_version_id", "source_document_version_id és obligatori per source_type=document_existing");
  if (raw.source_type === "template_locale" && typeof raw.source_template_locale_id !== "string")
    throw new AppError(400, "missing_source_template_locale_id", "source_template_locale_id és obligatori per source_type=template_locale");
  if (raw.client_request_id !== undefined && typeof raw.client_request_id !== "string")
    throw new AppError(400, "invalid_client_request_id", "client_request_id ha de ser string");
  if (raw.action === "sign_native") {
    if (raw.native_sign_type !== undefined &&
        raw.native_sign_type !== "presential" &&
        raw.native_sign_type !== "remote") {
      throw new AppError(400, "invalid_native_sign_type", "native_sign_type ha de ser 'presential' o 'remote'");
    }
    if (raw.native_sign_type === "remote") {
      const hasFlat = typeof raw.signer_email === "string" && raw.signer_email.length > 0;
      const hasList = Array.isArray(raw.signers) && raw.signers.length > 0;
      if (!hasFlat && !hasList) {
        throw new AppError(400, "missing_signers", "Cal indicar signer_email o signers[] per sign_native remote");
      }
    }
  }
    if (raw.action === "sign_native" && Array.isArray(raw.signers)) {
      for (const s of raw.signers as unknown[]) {
        const signer = s as Record<string, unknown>;
        if (signer.order !== undefined && (typeof signer.order !== "number" || !Number.isInteger(signer.order) || (signer.order as number) < 0))
          throw new AppError(400, "invalid_signer_order", `signer.order ha de ser un enter >= 0 (rebut: ${signer.order})`);
      }
    }
    if (raw.action === "sign") {
    if (!Array.isArray(raw.signers) || raw.signers.length === 0)
      throw new AppError(400, "missing_signers", "signers és obligatori per action=sign");
    for (const s of raw.signers as unknown[]) {
      const signer = s as Record<string, unknown>;
      if (typeof signer.email !== "string" || !signer.email)
        throw new AppError(400, "invalid_signer", "Cada signer ha de tenir email");
      if (signer.order !== undefined && (typeof signer.order !== "number" || !Number.isInteger(signer.order) || (signer.order as number) < 0))
        throw new AppError(400, "invalid_signer_order", `signer.order ha de ser un enter >= 0 (rebut: ${signer.order})`);
    }
  }
  if (raw.context !== undefined) {
    if (typeof raw.context !== "object" || raw.context === null || Array.isArray(raw.context))
      throw new AppError(400, "invalid_context", "context ha de ser un objecte");
  }
  if (raw.variables !== undefined) {
    throw new AppError(
      400,
      "legacy_variables_not_supported",
      "El camp variables no està suportat. Usa context.input.",
    );
  }
  if (raw.context_refs !== undefined) {
    if (typeof raw.context_refs !== "object" || raw.context_refs === null || Array.isArray(raw.context_refs))
      throw new AppError(400, "invalid_context_refs", "context_refs ha de ser un objecte");
    for (const [key, ref] of Object.entries(raw.context_refs as Record<string, unknown>)) {
      const r = ref as Record<string, unknown>;
      if (typeof r?.entity_type !== "string" || typeof r?.entity_id !== "string")
        throw new AppError(400, "invalid_context_refs", `context_refs["${key}"] requereix entity_type i entity_id string`);
    }
  }

  return raw as unknown as RequestBody;
}

function getContextInput(
  body: RequestBody,
): Record<string, unknown> {
  const maybeCtx = body.context;
  if (!maybeCtx || typeof maybeCtx !== "object" || Array.isArray(maybeCtx)) return {};
  const maybeInput = (maybeCtx as Record<string, unknown>).input;
  if (!maybeInput || typeof maybeInput !== "object" || Array.isArray(maybeInput)) return {};
  return maybeInput as Record<string, unknown>;
}

/**
 * Variables manuals del contracte canònic: context.input.
 */
function getManualInputVariables(
  body: RequestBody,
): Record<string, unknown> | undefined {
  const input = getContextInput(body);
  return Object.keys(input).length > 0 ? input : undefined;
}

/**
 * Variables per pre-emplenar camps PDF de DocuSeal.
 * Només primitives (string/number/boolean) perquè el contracte de DocuSeal és key->string.
 */
function getPdfPrefillVariables(
  body: RequestBody,
): Record<string, string> | undefined {
  const raw = getContextInput(body);
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(raw)) {
    if (value === null || value === undefined) continue;
    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
      out[key] = String(value);
    }
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

// ---------------------------------------------------------------------------
// Obtenció del fitxer font de Storage
// ---------------------------------------------------------------------------

interface SourceFile {
  bucket:            string | null;  // null per text/html (no Storage)
  path:              string | null;  // null per text/html
  htmlContent?:      string;         // contingut HTML per template text/html
  mimeType:          string;
  name:              string;
  documentId:        string | null;
  /** Variables schema del template locale (per resolució context_refs). Null per document_existing. */
  variablesSchema?:  Record<string, unknown> | null;
  /** Mapeig de blocs de contingut desat a la plantilla pare. Null si no s'aplica. */
  blockMapping?:     Record<string, string> | null;
  /** template_type de la plantilla pare ('html' | 'docx'). */
  templateType?:     string | null;
}

async function resolveSourceFile(
  adminClient: ReturnType<typeof createAdminClient>,
  body: RequestBody,
): Promise<SourceFile> {

  if (body.source_type === "document_existing") {
    const { data: ver, error } = await adminClient
      .from("active_documents")
      .select("id, file_path_or_url, mime_type, storage_type, title")
      .eq("tenant_id", body.tenant_id)
      .eq("version_id", body.source_document_version_id!)
      .limit(1)
      .maybeSingle();

    if (error) {
      log("error", FEATURE, "active_documents query error", {
        extra: {
          version_id: body.source_document_version_id,
          error: error.message,
          code: error.code,
        },
      });
      throw new AppError(404, "source_not_found", `Document version no trobada o no activa: ${error.message}`);
    }
    if (!ver)
      throw new AppError(404, "source_not_found", "Document version no trobada o no activa");
    if (ver.storage_type !== "native")
      throw new AppError(400, "unsupported_storage_type", "Només documents natius (storage_type=native) es poden enviar a signar");

    const mimeType = ver.mime_type ?? "application/octet-stream";
    if (!mimeType.includes("pdf") && !mimeType.includes("docx") &&
        !mimeType.includes("openxmlformats") && !mimeType.includes("msword"))
      throw new AppError(400, "unsupported_mime_type", "Només DOCX i PDF estan suportats per a signatura");

    return {
      bucket:     DOCUMENTS_BUCKET,
      path:       ver.file_path_or_url!,
      mimeType,
      name:       ver.title ?? "document",
      documentId: (ver.id as string | undefined) ?? null,
    };
  }

  // template_locale: consulta detail view per obtenir html_content i variables_schema
  const { data: loc, error } = await adminClient
    .from("document_template_locale_detail")
    .select("storage_path, mime_type, template_id, html_content, variables_schema")
    .eq("id", body.source_template_locale_id!)
    .eq("is_active", true)
    .single();

  if (error || !loc)
    throw new AppError(404, "template_locale_not_found", "Template locale no trobada o no activa");

  const mimeType = (loc.mime_type as string | null) ?? "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
  const locName   = body.document_title ?? `template-${body.source_template_locale_id}`;
  const variablesSchema = (loc as unknown as { variables_schema: Record<string, unknown> | null }).variables_schema ?? null;

  // Llegir default_block_mapping i template_type de la plantilla pare
  let blockMapping: Record<string, string> | null = null;
  let templateType: string | null = null;
  const parentTemplateId = (loc as unknown as { template_id: string | null }).template_id;
  if (parentTemplateId) {
    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data: tmpl } = await (adminClient as any)
        .from("document_templates")
        .select("default_block_mapping, template_type")
        .eq("id", parentTemplateId)
        .maybeSingle();
      if (tmpl?.default_block_mapping && typeof tmpl.default_block_mapping === "object") {
        blockMapping = tmpl.default_block_mapping as Record<string, string>;
      }
      templateType = (tmpl?.template_type as string | null) ?? null;
    } catch (_e) {
      // Non-critical: si no es pot llegir el mapeig, continuem sense blocs
      log("warn", FEATURE, "Could not read default_block_mapping", {
        extra: { template_id: parentTemplateId },
      });
    }
  }

  // Branca HTML: contingut directament de la BD, sense Storage
  if (mimeType === "text/html") {
    const htmlContent = (loc as unknown as { html_content: string | null }).html_content;
    if (!htmlContent)
      throw new AppError(500, "html_content_missing", "Template HTML sense contingut (html_content és NULL)");
    // Assegurar extensió .html al nom del fitxer
    const htmlName = locName.endsWith(".html") ? locName : `${locName}.html`;
    return {
      bucket:      null,
      path:        null,
      htmlContent,
      mimeType,
      name:        htmlName,
      documentId:  null,
      variablesSchema,
      blockMapping,
      templateType,
    };
  }

  // Branca DOCX/PDF: fitxer a Storage
  return {
    bucket:     DOCUMENT_TEMPLATES_BUCKET,
    path:       (loc.storage_path as string | null)!,
    mimeType,
    name:       locName,
    documentId: null,
    variablesSchema,
    blockMapping,
    templateType,
  };
}

// ---------------------------------------------------------------------------
// Descarregar fitxer de Storage com ArrayBuffer
// Els fitxers del bucket document-templates es cachetegen 10 min en memòria.
// ---------------------------------------------------------------------------

async function downloadFile(
  adminClient: ReturnType<typeof createAdminClient>,
  bucket: string,
  path:   string,
): Promise<{ data: Uint8Array; mimeType: string }> {
  // Caché només per a plantilles (immutables durant l'ús)
  if (bucket === DOCUMENT_TEMPLATES_BUCKET) {
    const cacheKey = `${bucket}:${path}`;
    const cached   = templateCache.get(cacheKey);
    if (cached && (Date.now() - cached.cachedAt) < TEMPLATE_CACHE_TTL_MS) {
      log("debug", FEATURE, "template cache HIT", { extra: { path } });
      return { data: cached.data, mimeType: cached.mimeType };
    }

    const { data, error } = await adminClient.storage.from(bucket).download(path);
    if (error || !data)
      throw new AppError(500, "storage_download_error", `No s'ha pogut descarregar el fitxer: ${error?.message ?? "desconegut"}`);

    const buffer   = new Uint8Array(await data.arrayBuffer());
    const mimeType = data.type;
    templateCache.set(cacheKey, { data: buffer, mimeType, cachedAt: Date.now() });
    log("debug", FEATURE, "template cache MISS", {
      extra: { path, bytes: buffer.byteLength },
    });
    return { data: buffer, mimeType };
  }

  // Documents d'usuari: sempre frescos, sense caché
  const { data, error } = await adminClient.storage.from(bucket).download(path);
  if (error || !data)
    throw new AppError(500, "storage_download_error", `No s'ha pogut descarregar el fitxer: ${error?.message ?? "desconegut"}`);

  const buffer = new Uint8Array(await data.arrayBuffer());
  return { data: buffer, mimeType: data.type };
}

// ---------------------------------------------------------------------------
// Renderitza els blocs de contingut assignats a una plantilla.
//
// - PAGE_HEADER / PAGE_FOOTER → van a Gotenberg com header.html / footer.html.
//   NO s'injecten al context del cos del document.
// - DOCUMENT_HEADER / DOCUMENT_FOOTER → s'injecten a ctx.document_header / ctx.document_footer.
// - CUSTOM → s'injecten a ctx.custom_block_<slug> (slug = clau del mapeig en minúscules).
// ---------------------------------------------------------------------------

interface RenderedBlocks {
  /** Blocs per injectar al context LiquidJS del cos del document (DOCUMENT_* i CUSTOM). */
  bodyBlocks:     Record<string, string>;
  /** HTML per a la capçalera de pàgina Gotenberg (PAGE_HEADER). Null si no n'hi ha. */
  pageHeaderHtml: string | null;
  /** HTML per al peu de pàgina Gotenberg (PAGE_FOOTER). Null si no n'hi ha. */
  pageFooterHtml: string | null;
}

const BLOCK_TYPE_PAGE_HEADER     = "PAGE_HEADER";
const BLOCK_TYPE_PAGE_FOOTER     = "PAGE_FOOTER";
const BLOCK_TYPE_DOCUMENT_HEADER = "DOCUMENT_HEADER";
const BLOCK_TYPE_DOCUMENT_FOOTER = "DOCUMENT_FOOTER";
const BLOCK_TYPE_CUSTOM          = "CUSTOM";

async function resolveRenderedBlocks(
  adminClient:  ReturnType<typeof createAdminDataClient>,
  blockMapping: Record<string, string> | null | undefined,
  tenantId:     string,
  context:      Record<string, unknown>,
): Promise<RenderedBlocks> {
  const empty: RenderedBlocks = { bodyBlocks: {}, pageHeaderHtml: null, pageFooterHtml: null };
  if (!blockMapping || Object.keys(blockMapping).length === 0) return empty;

  const mappingEntries = Object.entries(blockMapping) as [string, string][];
  const blockUuids = [...new Set(mappingEntries.map(([, v]) => v).filter(Boolean))];
  if (blockUuids.length === 0) return empty;

  // Fetch actiu: blocs de sistema (is_platform_default=true) O del tenant actual
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data: blocks, error } = await (adminClient as any)
    .from("document_content_blocks")
    .select("id, block_type, format, content")
    .in("id", blockUuids)
    .eq("is_active", true)
    .or(`is_platform_default.eq.true,tenant_id.eq.${tenantId}`);

  if (error) {
    log("warn", FEATURE, "resolveRenderedBlocks query error", {
      extra: { error: error.message },
    });
    return empty;
  }

  type BlockRow = { id: string; block_type: string; format: string; content: string };
  const blockMap = new Map<string, BlockRow>((blocks as BlockRow[]).map((b) => [b.id, b]));

  const result: RenderedBlocks = { bodyBlocks: {}, pageHeaderHtml: null, pageFooterHtml: null };

  for (const [mappingKey, blockId] of mappingEntries) {
    const block = blockMap.get(blockId);
    if (!block) continue; // bloc esborrat o inactiu: ignorem silenciosament

    let rendered: string;
    try {
      rendered = block.format === "HTML" || block.format === "TEXT"
        ? await renderLiquidSafe(block.content, context)
        : block.content;
    } catch (err) {
      log("warn", FEATURE, "Error rendering block", {
        extra: { block_id: blockId, error: (err as Error).message },
      });
      rendered = "";
    }

    const blockType = block.block_type as string;
    if (blockType === BLOCK_TYPE_PAGE_HEADER) {
      result.pageHeaderHtml = rendered;
    } else if (blockType === BLOCK_TYPE_PAGE_FOOTER) {
      result.pageFooterHtml = rendered;
    } else if (blockType === BLOCK_TYPE_DOCUMENT_HEADER) {
      result.bodyBlocks["document_header"] = rendered;
    } else if (blockType === BLOCK_TYPE_DOCUMENT_FOOTER) {
      result.bodyBlocks["document_footer"] = rendered;
    } else if (blockType === BLOCK_TYPE_CUSTOM) {
      // Slug = clau del mapeig normalitzada: minúscules, només alfanumèric i _
      const slug = mappingKey.toLowerCase().replace(/[^a-z0-9_]/g, "_");
      result.bodyBlocks[`custom_block_${slug}`] = rendered;
    }
  }

  return result;
}

// ---------------------------------------------------------------------------

async function resolveDocusealKey(
  adminClient: ReturnType<typeof createAdminClient>,
  userClient:  ReturnType<typeof createUserClient>,
  tenantId:    string,
): Promise<{ apiKey: string; apiUrl: string }> {
  const { data: cfg, error } = await adminClient
    .from("tenant_signing_status")
    .select("mode, docuseal_api_url, is_active, admin_disabled, effective_is_active")
    .eq("tenant_id", tenantId)
    .single();

  if (error || !cfg)
    throw new AppError(404, "signing_config_not_found", "Configuració de signatura no trobada per a aquest tenant. Activa les firmes a Configuració → Firmes.");
  if (cfg.admin_disabled)
    throw new AppError(403, "signing_disabled_by_admin", "La signatura digital ha estat desactivada pels administradors del portal");
  if (!cfg.effective_is_active)
    throw new AppError(403, "signing_disabled", "La signatura digital no està activa per a aquest tenant. Activa-la a Configuració → Firmes.");

  const apiUrl = (cfg.docuseal_api_url as string | null) ?? DOCUSEAL_API_URL;

  if (cfg.mode === "platform") {
    if (!DOCUSEAL_API_KEY)
      throw new AppError(500, "platform_key_missing", "DOCUSEAL_API_KEY no configurat a l'entorn del servidor");
    log("debug", FEATURE, "platform mode DocuSeal key resolved", {
      tenantId,
      extra: { key_length: DOCUSEAL_API_KEY.length, key_prefix: `${DOCUSEAL_API_KEY.slice(0, 4)}***`, url: apiUrl },
    });
    return { apiKey: DOCUSEAL_API_KEY, apiUrl };
  }

  // mode = byo → RPC per llegir de Vault
  const { data: key, error: rpcErr } = await userClient
    .rpc("get_docuseal_key_for_signing", { p_tenant_id: tenantId });

  if (rpcErr || !key)
    throw new AppError(500, "byo_key_error", rpcErr?.message ?? "No s'ha pogut obtenir la clau DocuSeal BYO");

  const byoKey = key as string;
  log("debug", FEATURE, "byo mode DocuSeal key resolved", {
    tenantId,
    extra: { key_length: byoKey.length, key_prefix: `${byoKey.slice(0, 4)}***`, url: apiUrl },
  });
  return { apiKey: byoKey, apiUrl };
}

// ---------------------------------------------------------------------------
// Consumir crèdit (mode platform, atòmic)
// ---------------------------------------------------------------------------

async function consumeCredit(
  userClient: ReturnType<typeof createUserClient>,
  tenantId:   string,
): Promise<void> {
  const { error } = await userClient.rpc("consume_signing_credit", {
    p_tenant_id: tenantId,
  });
  if (error)
    throw new AppError(402, "credit_error", error.message);
}

// ---------------------------------------------------------------------------
// Crear signing_submission a la BD (status=pending)
// ---------------------------------------------------------------------------

async function createSubmissionRecord(
  adminClient:               ReturnType<typeof createAdminClient>,
  body:                      RequestBody,
  initiatedBy:               string,
  externalId:                string,
  sourceDocumentId:          string | null,
  documentTitle:             string,
  options?: {
    signing_provider?:   string;
    native_group_id?:    string | null;
    notification_mode?:  string | null;
    metadata?:           Record<string, unknown> | null;
  },
): Promise<string> {
  // Usa RPC SECURITY DEFINER perquè data.signing_submissions no és accessible
  // via PostgREST directament (schema "data" no exposat).
  const { data: newId, error } = await adminClient.rpc("create_signing_submission", {
    p_tenant_id:                   body.tenant_id,
    p_source_type:                 body.source_type,
    p_source_document_id:          sourceDocumentId ?? null,
    p_source_document_version_id:  body.source_document_version_id ?? null,
    p_source_template_locale_id:   body.source_template_locale_id ?? null,
    p_document_title:              documentTitle,
    p_external_id:                 externalId,
    p_signers:                     body.signers ?? [],
    p_initiated_by:                initiatedBy,
    p_submitted_at:                new Date().toISOString(),
    p_metadata:                    options?.metadata ?? body.metadata ?? null,
    p_signing_provider:            options?.signing_provider ?? "docuseal",
    p_native_group_id:             options?.native_group_id ?? null,
    p_notification_mode:           options?.notification_mode ?? body.notification_mode ?? null,
  });

  if (error || !newId)
    throw new AppError(500, "submission_create_error", `No s'ha pogut crear la submission: ${error?.message ?? "desconegut"}`);

  return newId as string;
}

// ---------------------------------------------------------------------------
// Helpers per a PDFs sense etiquetes: camps posicionals de signatura
// ---------------------------------------------------------------------------

/** Extreu el nombre de pàgines d'un PDF llegint el camp /Count del page tree. */
function getPdfPageCount(data: Uint8Array): number {
  const text = new TextDecoder("latin1").decode(data);
  // El darrer /Count és el de l'arbre de pàgines arrel
  const matches = Array.from(text.matchAll(/\/Count\s+(\d+)/g));
  if (matches.length === 0) return 1;
  return parseInt(matches[matches.length - 1][1], 10) || 1;
}

/** Genera camps de signatura posicionals per a cada signant (un per pàgina). */
function buildDefaultSignatureFields(
  signers: Signer[],
  pageCount: number,
): Record<string, unknown>[] {
  // Fins a 2 signants en columnes; més signants s'apilen verticalment
  const xPositions = [0.05, 0.55];
  return signers.map((s, idx) => {
    const x = xPositions[idx] ?? Math.min(0.05 + (idx - 2) * 0.15, 0.75);
    return {
      name:     s.role ?? `Signer ${idx + 1}`,
      type:     "signature",
      role:     s.role ?? `Signer ${idx + 1}`,
      required: true,
      areas:    Array.from({ length: pageCount }, (_, i) => ({
        page: i + 1, x, y: 0.85, w: 0.38, h: 0.07,
      })),
    };
  });
}

// ---------------------------------------------------------------------------
// Enviar a DocuSeal (one-off, sense repositori persistent de templates)
// ---------------------------------------------------------------------------

async function submitToDocuseal(
  apiKey:             string,
  apiUrl:             string,
  fileData:           Uint8Array,
  mimeType:           string,
  fileName:           string,
  externalId:         string,
  signers:            Signer[],
  variables?:         Record<string, string>,
  sendEmail?:         boolean,
  useExplicitFields?: boolean,
): Promise<{ submissionId: string; signingUrl?: string; signerLinks: SignerLink[] }> {

  const isDocx = mimeType.includes("docx") || mimeType.includes("openxmlformats");
  const endpoint = isDocx ? `${apiUrl}/submissions/docx` : `${apiUrl}/submissions/pdf`;

  // DocuSeal espera JSON amb el fitxer en base64 (NO multipart/form-data)
  const base64File = btoa(
    Array.from(fileData, (b) => String.fromCharCode(b)).join(""),
  );

  // Nom del document sense extensió
  const docName = fileName.replace(/\.[^.]+$/, "") || "document";

  // BUG-1 FIX: assignar external_id a TOTS els submitters (format: "{externalId}:s{idx}")
  // El webhook fa strip del sufix ":sN" per trobar la submission per external_id.
  const submitters = signers.map((s, idx) => ({
    email:       s.email,
    name:        s.name,
    role:        s.role ?? `Signer ${idx + 1}`,
    order:       s.order ?? idx,
    external_id: `${externalId}:s${idx}`,
  }));

  const requestBody: Record<string, unknown> = {
    documents: [{ name: docName, file: base64File }],
    submitters,
    send_email: sendEmail ?? false,
  };

  // PDFs sense etiquetes DocuSeal: afegir camps de signatura posicionals per a cada signant
  if (useExplicitFields && !isDocx) {
    const pageCount = getPdfPageCount(fileData);
    const fields = buildDefaultSignatureFields(signers, pageCount);
    (requestBody.documents as Array<Record<string, unknown>>)[0].fields = fields;
    log("info", FEATURE, "use_explicit_fields enabled", {
      extra: { fields: fields.length, page_count: pageCount },
    });
  }

  // [[key]] content variables: DocuSeal substitueix els placeholders pel valor abans de mostrar el document als signants
  if (variables && Object.keys(variables).length > 0) {
    requestBody.variables = variables;
  }

  const res = await fetch(endpoint, {
    method:  "POST",
    headers: {
      "X-Auth-Token":  apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(requestBody),
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new AppError(
      502,
      "docuseal_error",
      `DocuSeal ha retornat error ${res.status}: ${body.slice(0, 200)}`,
    );
  }

  const result = await res.json() as Record<string, unknown>;
  const submissionId   = String(result.id ?? "");
  const allSubmitters  = Array.isArray(result.submitters)
    ? (result.submitters as Array<Record<string, unknown>>)
    : [];
  const firstSigner    = allSubmitters[0];

  // Extreure URL per a cada signant: embed_src oficial o slug com a fallback
  // BUG-2 FIX: usar DOCUSEAL_SIGNING_BASE_URL en lloc de docuseal.eu hardcoded
  const signerLinks: SignerLink[] = allSubmitters.map((s, idx) => ({
    order:       idx,
    email:       String(s.email ?? ""),
    role:        String(s.role ?? ""),
    signing_url: typeof s.embed_src === "string"
      ? s.embed_src
      : (typeof s.slug === "string" ? `${DOCUSEAL_SIGNING_BASE_URL}/s/${s.slug}` : null),
  }));

  const signingUrl = signerLinks[0]?.signing_url ?? undefined;

  // Si algun signant no té signing_url (p.ex. signant 2+ en mode seqüencial),
  // re-fetch la submission de DocuSeal per obtenir els slugs actualitzats.
  if (signerLinks.some(l => l.signing_url === null) && submissionId) {
    try {
      const refetchRes = await fetch(`${apiUrl}/submissions/${submissionId}`, {
        headers: { "X-Auth-Token": apiKey },
      });
      if (refetchRes.ok) {
        const refetchedSub = await refetchRes.json() as Record<string, unknown>;
        const refetchedSubmitters = Array.isArray(refetchedSub.submitters)
          ? refetchedSub.submitters as Array<Record<string, unknown>>
          : [];
        for (const link of signerLinks) {
          if (link.signing_url === null) {
            const match = refetchedSubmitters.find(
              fs => String(fs.email ?? "") === link.email,
            );
            if (match) {
              link.signing_url = typeof match.embed_src === "string"
                ? match.embed_src
                : (typeof match.slug === "string"
                    ? `${DOCUSEAL_SIGNING_BASE_URL}/s/${match.slug}`
                    : null);
            }
          }
        }
        log("info", FEATURE, "Re-fetch DocuSeal submission resolved signing URLs", {
          extra: {
            submission_id: submissionId,
            resolved: signerLinks.filter(l => l.signing_url !== null).length,
            total: signerLinks.length,
          },
        });
      } else {
        log("warn", FEATURE, "Re-fetch DocuSeal submission failed", {
          extra: { submission_id: submissionId, status: refetchRes.status },
        });
      }
    } catch (refetchErr) {
      log("warn", FEATURE, "Re-fetch DocuSeal submission error", {
        extra: { submission_id: submissionId, error: (refetchErr as Error).message },
      });
    }
  }

  log("info", FEATURE, "DocuSeal submission created", {
    extra: {
      submission_id: submissionId,
      submitters: allSubmitters.length,
      first_url: signerLinks[0]?.signing_url ?? "N/A",
      send_email: sendEmail ?? false,
    },
  });

  return { submissionId, signingUrl, signerLinks };
}

// ---------------------------------------------------------------------------
// Enviar HTML a DocuSeal (POST /submissions/html — HTML pre-renderitzat)
// ---------------------------------------------------------------------------

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const DEFAULT_HTML_CSS = `
  body { font-family: Arial, Helvetica, sans-serif; font-size: 11pt; line-height: 1.5; margin: 2cm; color: #111; }
  h1, h2, h3, h4 { margin-top: 1.2em; margin-bottom: 0.4em; }
  p  { margin: 0 0 0.7em; }
  table { border-collapse: collapse; width: 100%; margin-bottom: 1em; }
  th, td { border: 1px solid #aaa; padding: 6px 10px; text-align: left; vertical-align: top; }
  th { background: #f2f2f2; font-weight: 600; }
  @media print { body { margin: 1.5cm; } }
`;

function buildHtml5Document(bodyFragment: string, title: string): string {
  const safeTitle = escapeHtml(title.replace(/\.html$/i, ""));
  return `<!DOCTYPE html>
<html lang="ca">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${safeTitle}</title>
  <style>${DEFAULT_HTML_CSS}</style>
</head>
<body>
${bodyFragment}
</body>
</html>`;
}

async function submitHtmlToDocuseal(
  apiKey:      string,
  apiUrl:      string,
  htmlContent: string,
  fileName:    string,
  externalId:  string,
  signers:     Signer[],
  sendEmail?:  boolean,
): Promise<{ submissionId: string; signingUrl?: string; signerLinks: SignerLink[] }> {

  const docName = fileName.replace(/\.[^.]+$/, "") || "document";

  // BUG-1 FIX: external_id per a TOTS els submitters
  const submitters = signers.map((s, idx) => ({
    email:       s.email,
    name:        s.name,
    role:        s.role ?? `Signer ${idx + 1}`,
    order:       s.order ?? idx,
    external_id: `${externalId}:s${idx}`,
  }));

  const requestBody = {
    html:       htmlContent,
    name:       docName,
    submitters,
    send_email: sendEmail ?? false,
  };

  let res = await fetch(`${apiUrl}/submissions/html`, {
    method:  "POST",
    headers: {
      "X-Auth-Token":  apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(requestBody),
  });

  // Compatibilitat amb instancies DocuSeal que no exposen /submissions/html.
  // Fallback: crear template HTML temporal i crear submissio via template_id.
  if (!res.ok && res.status === 422) {
    const firstBody = await res.text().catch(() => "");
    if (firstBody.includes("template_ids or documents is required")) {
      const signatureFields = submitters
        .map((s) => `<p><signature-field role=\"${escapeHtml(String(s.role ?? ""))}\"></signature-field></p>`)
        .join("\n");
      const templateHtml = `${htmlContent}\n<div data-generated-signatures=\"true\">${signatureFields}</div>`;

      const templateRes = await fetch(`${apiUrl}/templates/html`, {
        method:  "POST",
        headers: {
          "X-Auth-Token":  apiKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          name: `${docName} (runtime)`,
          html: templateHtml,
        }),
      });

      if (!templateRes.ok) {
        const templateBody = await templateRes.text().catch(() => "");
        throw new AppError(
          502,
          "docuseal_error",
          `DocuSeal HTML template fallback error ${templateRes.status}: ${templateBody.slice(0, 200)}`,
        );
      }

      const templateJson = await templateRes.json() as Record<string, unknown>;
      const templateId = templateJson.id;
      if (typeof templateId !== "number" && typeof templateId !== "string") {
        throw new AppError(502, "docuseal_error", "DocuSeal HTML template fallback sense template id");
      }

      res = await fetch(`${apiUrl}/submissions`, {
        method:  "POST",
        headers: {
          "X-Auth-Token":  apiKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          template_id: templateId,
          submitters,
          send_email: sendEmail ?? false,
        }),
      });

      if (!res.ok) {
        const secondBody = await res.text().catch(() => "");
        throw new AppError(
          502,
          "docuseal_error",
          `DocuSeal HTML fallback error ${res.status}: ${secondBody.slice(0, 200)}`,
        );
      }
    } else {
      throw new AppError(502, "docuseal_error", `DocuSeal HTML error ${res.status}: ${firstBody.slice(0, 200)}`);
    }
  }

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new AppError(502, "docuseal_error", `DocuSeal HTML error ${res.status}: ${body.slice(0, 200)}`);
  }

  const result = await res.json() as Record<string, unknown>;
  const submissionId  = String(result.submission_id ?? result.id ?? "");
  let allSubmitters = Array.isArray(result.submitters)
    ? (result.submitters as Array<Record<string, unknown>>)
    : [];

  // El fallback /submissions pot retornar un submitter en lloc de la submissio completa.
  if (allSubmitters.length === 0 && submissionId) {
    try {
      const refetchRes = await fetch(`${apiUrl}/submissions/${submissionId}`, {
        headers: { "X-Auth-Token": apiKey },
      });
      if (refetchRes.ok) {
        const refetched = await refetchRes.json() as Record<string, unknown>;
        allSubmitters = Array.isArray(refetched.submitters)
          ? (refetched.submitters as Array<Record<string, unknown>>)
          : [];
      }
    } catch {
      // best-effort
    }
  }

  // BUG-2 FIX: usar DOCUSEAL_SIGNING_BASE_URL
  const signerLinks: SignerLink[] = allSubmitters.map((s, idx) => ({
    order:       idx,
    email:       String(s.email ?? ""),
    role:        String(s.role ?? ""),
    signing_url: typeof s.embed_src === "string"
      ? s.embed_src
      : (typeof s.slug === "string" ? `${DOCUSEAL_SIGNING_BASE_URL}/s/${s.slug}` : null),
  }));

  const signingUrl = signerLinks[0]?.signing_url ?? undefined;

  log("info", FEATURE, "DocuSeal HTML submission created", {
    extra: {
      submission_id: submissionId,
      submitters: allSubmitters.length,
      send_email: sendEmail ?? false,
    },
  });

  return { submissionId, signingUrl, signerLinks };
}

// ---------------------------------------------------------------------------
// Actualitzar submission amb docuseal_submission_id (status=in_progress)
// ---------------------------------------------------------------------------

async function updateSubmissionAfterDocuseal(
  adminClient:          ReturnType<typeof createAdminClient>,
  submissionId:         string,
  tenantId:             string,
  docusealSubmissionId: string,
  signingUrl?:          string,
  notificationMode?:    NotificationMode,
): Promise<void> {
  const { error } = await adminClient
    .from("signing_submissions")
    .update({
      docuseal_submission_id: docusealSubmissionId,
      status:                 "in_progress",
      docuseal_signing_url:   signingUrl ?? null,
      last_event_at:          new Date().toISOString(),
      ...(notificationMode ? { notification_mode: notificationMode } : {}),
    })
    .eq("id", submissionId)
    .eq("tenant_id", tenantId);

  if (error)
    log("error", FEATURE, "Could not update submission after DocuSeal", {
      extra: { submission_id: submissionId, error: error.message },
    });
}

// ---------------------------------------------------------------------------
// Crear registres normalitzats de signing_submitters i encuar notificació inicial
// ---------------------------------------------------------------------------

async function persistSignerLinks(
  adminClient:     ReturnType<typeof createAdminClient>,
  submissionId:    string,
  tenantId:        string,
  signerLinks:     SignerLink[],
  signers:         Signer[],
  externalId:      string,
): Promise<void> {
  if (signerLinks.length === 0 && signers.length === 0) return;

  // Prefer the role the caller configured (signers[]) over DocuSeal's internal label
  // (DocuSeal may return "First Party"/"Second Party" when PDF field tags use wrong
  //  format or when roles don't match; we always want to show what the user set up).
  const rows = signerLinks.map((link, idx) => ({
    submission_id:         submissionId,
    tenant_id:             tenantId,
    signer_order:          link.order,
    role:                  signers[idx]?.role || link.role || null,
    email:                 link.email,
    name:                  signers[idx]?.name ?? "",
    external_submitter_id: `${externalId}:s${idx}`,
    signing_url:           link.signing_url,
    status:                "pending",
  }));

  // DocuSeal sometimes returns fewer submitters than we sent (e.g. when PDF field tags
  // use wrong role syntax). Augment the missing ones so total_signers stays correct and
  // the signing flow can recover once signing_url is available (e.g. via webhook).
  if (signers.length > signerLinks.length) {
    log("warn", FEATURE, "DocuSeal returned fewer submitters than sent", {
      extra: { returned: signerLinks.length, sent: signers.length },
    });
    for (let idx = signerLinks.length; idx < signers.length; idx++) {
      rows.push({
        submission_id:         submissionId,
        tenant_id:             tenantId,
        signer_order:          idx,
        role:                  signers[idx]?.role ?? null,
        email:                 signers[idx]?.email ?? "",
        name:                  signers[idx]?.name ?? "",
        external_submitter_id: `${externalId}:s${idx}`,
        signing_url:           null,
        status:                "pending",
      });
    }
  }

  const { error } = await adminClient
    .from("signing_submitters")
    .upsert(rows, { onConflict: 'submission_id,signer_order' });

  if (error)
    log("error", FEATURE, "Error persisting signing_submitters", {
      extra: { submission_id: submissionId, error: error.message },
    });
}

async function enqueueInitialNotifications(
  adminClient:      ReturnType<typeof createAdminClient>,
  submissionId:     string,
  notificationMode: NotificationMode,
  signerLinks:      SignerLink[],
): Promise<void> {
  if (notificationMode === 'docuseal_auto' || notificationMode === 'app_manual') return;

  const ordersToNotify = notificationMode === 'app_auto_all'
    ? signerLinks.map((_, i) => i)     // tots immediatament
    : [0];                             // app_auto_sequential: només el primer

  for (const order of ordersToNotify) {
    try {
      // supabase-js mai llança; cal destructurar { error } explícitament
      const { error: notifErr } = await adminClient.rpc('enqueue_signing_notification', {
        p_submission_id: submissionId,
        p_signer_order:  order,
        p_reason:        'initial',
      });
      if (notifErr) {
        log("warn", FEATURE, "Error enqueueing initial notification", {
          extra: { submission_id: submissionId, order, error: notifErr.message },
        });
      }
    } catch (e) {
      log("warn", FEATURE, "Network error enqueueing initial notification", {
        extra: { submission_id: submissionId, order, error: (e as Error).message },
      });
    }
  }
}

// ---------------------------------------------------------------------------
// generate_only: pujar fitxer com a nova document_version al DMS
// ---------------------------------------------------------------------------

async function generateOnlyVersion(
  adminClient:  ReturnType<typeof createAdminClient>,
  userClient:   ReturnType<typeof createUserClient>,
  body:         RequestBody,
  fileData:     Uint8Array,
  sourceFile:   SourceFile,
  initiatedBy:  string,
): Promise<Record<string, unknown>> {

  // Calculem path una sola vegada: serveix tant per nova versió com per document nou
  const uuid      = crypto.randomUUID();
  const safeName  = `${uuid}/${sanitizeFileName(sourceFile.name)}`;
  const path      = `${body.tenant_id}/${safeName}`;
  const blob      = new Blob([fileData], { type: sourceFile.mimeType });

  const { error: uploadErr } = await adminClient.storage
    .from(DOCUMENTS_BUCKET)
    .upload(path, blob, { contentType: sourceFile.mimeType, upsert: false });

  if (uploadErr)
    throw new AppError(500, "storage_upload_error", `Error pujant fitxer generat: ${uploadErr.message}`);

  // document_existing: afegir versió al document pare existent
  if (body.source_type === "document_existing" && body.source_document_version_id) {
    // Llegir document_id de la versió font via adminClient
    const { data: ver, error } = await adminClient
      .from("active_documents")
      .select("id")
      .eq("version_id", body.source_document_version_id)
      .single();

    if (error || !ver) throw new AppError(404, "document_not_found", "Document no trobat");
    const documentId = ver.id as string;

    const { data: verData, error: verErr } = await userClient.rpc("add_document_version", {
      p_document_id:      documentId,
      p_file_path_or_url: path,
      p_mime_type:        sourceFile.mimeType,
      p_size_bytes:       fileData.length,
      p_storage_type:     "native",
    });

    if (verErr) {
      const lowerMsg = verErr.message.toLowerCase();
      if (lowerMsg.includes("access denied") || lowerMsg.includes("owner or manager")) {
        throw new AppError(403, "forbidden", "No tens permisos per generar una nova versió d'aquest document");
      }
      throw new AppError(500, "version_create_error", `Error creant versió: ${verErr.message}`);
    }

    const parsed = typeof verData === "string" ? JSON.parse(verData) : verData;
    log("info", FEATURE, "generate_only completed (existing document)", {
      extra: { document_id: documentId, initiated_by: initiatedBy },
    });
    return { document_id: documentId, ...(parsed as Record<string, unknown>) };
  }

  // template_locale: crear document nou amb la primera versió ja apuntant al path pujat
  const title = body.document_title ?? `Generated-${new Date().toISOString().slice(0, 10)}`;
  const { data: rpcData, error: rpcErr } = await userClient.rpc("create_document_with_version", {
    p_tenant_id:        body.tenant_id,
    p_folder_id:        body.folder_id ?? null,
    p_title:            title,
    p_file_path_or_url: path,
    p_mime_type:        sourceFile.mimeType,
    p_size_bytes:       fileData.length,
    p_storage_type:     "native",
    ...(body.document_category ? { p_category: body.document_category } : {}),
  });

  if (rpcErr || !rpcData) {
    const msg = rpcErr?.message ?? "No s'ha pogut crear el document";
    const lowerMsg = msg.toLowerCase();
    if (lowerMsg.includes("access denied") || lowerMsg.includes("owner or manager")) {
      throw new AppError(403, "forbidden", "No tens permisos per generar documents a partir de plantilles");
    }
    throw new AppError(500, "document_create_error", msg);
  }

  const created = typeof rpcData === "string" ? JSON.parse(rpcData) : rpcData;
  const createdRecord = created as Record<string, unknown>;
  const docNode = createdRecord.document as Record<string, unknown> | undefined;
  const createdDocumentId = (typeof docNode?.id === "string")
    ? docNode.id
    : (typeof createdRecord.document_id === "string" ? createdRecord.document_id : null);

  if (!createdDocumentId) {
    throw new AppError(500, "document_create_error", "Resposta RPC sense document.id");
  }

  log("info", FEATURE, "generate_only completed (new document)", {
    extra: { document_id: createdDocumentId, initiated_by: initiatedBy },
  });
  return { ...(createdRecord as Record<string, unknown>), document_id: createdDocumentId };
}

function extractGeneratedDocumentRefs(
  result: Record<string, unknown>,
): { documentId: string | null; versionId: string | null } {
  const documentNode = result.document as Record<string, unknown> | undefined;
  const versionNode  = result.version as Record<string, unknown> | undefined;

  const documentId = typeof result.document_id === "string"
    ? result.document_id
    : typeof result.documentId === "string"
      ? result.documentId
      : typeof documentNode?.id === "string"
        ? documentNode.id
        : null;

  const versionId = typeof result.version_id === "string"
    ? result.version_id
    : typeof result.versionId === "string"
      ? result.versionId
      : typeof versionNode?.id === "string"
        ? versionNode.id
        : typeof result.id === "string"
          ? result.id
          : null;

  return { documentId, versionId };
}

async function persistGenerateOnlySignerSnapshot(
  adminClient: ReturnType<typeof createAdminClient>,
  body: RequestBody,
  initiatedBy: string,
  sourceFile: SourceFile,
  generated: { documentId: string | null; versionId: string | null },
): Promise<void> {
  if (!body.signers || body.signers.length === 0) return;
  if (!generated.documentId || !generated.versionId) return;

  const externalId = `generate-only:${generated.versionId}`;
  const nowIso = new Date().toISOString();
  try {
    const { data: existing } = await adminClient
      .from("signing_submissions")
      .select("id")
      .eq("tenant_id", body.tenant_id)
      .eq("external_id", externalId)
      .maybeSingle();

    let submissionId = (existing?.id as string | undefined) ?? null;

    if (!submissionId) {
      const { data: newId, error: rpcError } = await adminClient.rpc("create_signing_submission", {
        p_tenant_id:                   body.tenant_id,
        p_source_type:                 "document_existing",
        p_source_document_id:          generated.documentId,
        p_source_document_version_id:  generated.versionId,
        p_source_template_locale_id:   body.source_template_locale_id ?? null,
        p_document_title:              body.document_title ?? sourceFile.name,
        p_external_id:                 externalId,
        p_signers:                     body.signers,
        p_initiated_by:                initiatedBy,
        p_submitted_at:                nowIso,
        p_metadata:                    { generated_only_snapshot: true },
      });
      if (rpcError || !newId) {
        log("warn", FEATURE, "Could not create signers snapshot (generate_only)", {
          extra: { error: rpcError?.message ?? "unknown" },
        });
        return;
      }
      submissionId = newId as string;
    }

    const { error: updateError } = await adminClient
      .from("signing_submissions")
      .update({
        source_document_id:         generated.documentId,
        source_document_version_id: generated.versionId,
        result_document_version_id: generated.versionId,
        source_template_locale_id:  body.source_template_locale_id ?? null,
        document_title:             body.document_title ?? sourceFile.name,
        status:                     "cancelled",
        status_reason:              "generate_only_snapshot",
        signers:                    body.signers,
        completed_at:               null,
        last_event_at:              nowIso,
        metadata:                   { generated_only_snapshot: true },
      })
      .eq("tenant_id", body.tenant_id)
      .eq("id", submissionId);

    if (updateError) {
      log("warn", FEATURE, "Could not update signers snapshot (generate_only)", {
        extra: { error: updateError.message },
      });
    }
  } catch (err) {
    log("warn", FEATURE, "Could not persist signers snapshot (generate_only)", {
      extra: { error: (err as Error).message },
    });
  }
}

// ---------------------------------------------------------------------------
// Handler principal
// ---------------------------------------------------------------------------

async function logSigningRouterFailure(
  adminClient: ReturnType<typeof createAdminClient>,
  params: {
    tenantId: string;
    submissionId: string;
    operationCode: string;
    title: string;
    message: string;
    errorCode?: string;
    err?: unknown;
  },
): Promise<void> {
  const operationLog = createOperationLogService(adminClient);
  await operationLog.log({
    tenantId: params.tenantId,
    integrationType: "signing",
    operationCode: params.operationCode,
    status: "failed",
    title: params.title,
    message: params.message.slice(0, 200),
    errorCode: params.errorCode,
    errorMessage: params.message,
    correlationId: params.submissionId,
    entityType: "signing_submission",
    entityId: params.submissionId,
    externalService: "docuseal",
    isRetryable: false,
  });
  if (params.err && isInfrastructureBug(params.err)) {
    captureException(params.err, {
      feature: FEATURE,
      tenantId: params.tenantId,
      correlationId: params.submissionId,
    });
  }
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonError(405, "method_not_allowed", "Només POST");
  }

  try {
    const body = await parseBody(req);

    // ── 1. Autenticar usuari (o worker intern de protocol horari) ─────────────
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.startsWith("Bearer ") ? authHeader.slice("Bearer ".length) : "";
    const workerSource = req.headers.get("x-worker-source");

    let userClient: ReturnType<typeof createUserClient>;
    let user: { id: string };
    let membership: { role: string };

    const isInternalProtocolWorker =
      !!SERVICE_ROLE_KEY &&
      token === SERVICE_ROLE_KEY &&
      workerSource === "attendance-protocol-publish" &&
      typeof body.initiated_by_user_id === "string" &&
      body.initiated_by_user_id.length > 0;

    if (isInternalProtocolWorker) {
      const bootstrapAdmin = createAdminClient();
      const { data: memberRow, error: memberError } = await bootstrapAdmin
        .from("tenant_members")
        .select("role")
        .eq("tenant_id", body.tenant_id)
        .eq("user_id", body.initiated_by_user_id!)
        .eq("is_active", true)
        .maybeSingle();

      if (memberError || !memberRow || !["owner", "manager"].includes(memberRow.role)) {
        return jsonError(403, "forbidden", "Initiator must be owner or manager");
      }

      user = { id: body.initiated_by_user_id! };
      membership = { role: memberRow.role };
      userClient = bootstrapAdmin as ReturnType<typeof createUserClient>;
    } else {
      userClient = createUserClient(req);
      const { data: { user: authUser }, error: authError } = await userClient.auth.getUser();
      if (authError || !authUser) {
        return jsonError(401, "unauthorized", "Token invàlid o expirat");
      }
      user = authUser;

      const { data: memberData, error: memberError } = await userClient
        .from("tenant_members")
        .select("role")
        .eq("tenant_id", body.tenant_id)
        .eq("user_id", user.id)
        .eq("is_active", true)
        .single();

      if (memberError || !memberData) {
        return jsonError(403, "not_a_member", "No ets membre d'aquest tenant");
      }
      membership = memberData;
    }

    // ── 2. Coherència header/body tenant_id ──────────────────────────────────
    const headerTenantId = req.headers.get("x-tenant-id");
    if (headerTenantId && headerTenantId !== body.tenant_id)
      return jsonError(403, "tenant_mismatch", "tenant_id no coincideix amb el context actiu");

    const adminClient = createAdminClient();
    const adminDataClient = createAdminDataClient();

    // ── 3. Verificar rol (skip duplicat si worker intern ja validat) ─────────
    if (!isInternalProtocolWorker) {
      if (membership.role === "viewer") {
        return jsonError(403, "forbidden", "Els viewers no poden iniciar signatures");
      }
      if (body.action === "generate_only" && membership.role !== "owner" && membership.role !== "manager") {
        return jsonError(403, "forbidden", "Cal rol owner o manager per generar documents des de plantilles");
      }
    }

    // ── 3.1 Rollout gate per feature flag ───────────────────────────────────
    const signingFeatureEnabled = await isTenantSigningFeatureEnabled(adminClient, body.tenant_id);
    if (!signingFeatureEnabled) {
      return jsonError(403, "feature_disabled", "Signing no està habilitat per aquest tenant");
    }

    // ── 4. Localitzar fitxer font ─────────────────────────────────────────────
    const sourceFile = await resolveSourceFile(adminClient, body);

    // ── 5. Branching per action ───────────────────────────────────────────────
    if (body.action === "generate_only") {
      const outputFormat  = body.output_format ?? "native";
      const manualInput   = getManualInputVariables(body);
      let fileBytes: Uint8Array;
      let htmlForPdf: string | null = null;
      let generateOnlyPageHeaderHtml: string | null = null;
      let generateOnlyPageFooterHtml: string | null = null;

      if (sourceFile.mimeType === "text/html" && sourceFile.htmlContent !== undefined) {
        let rendered: string;
        if (body.pre_rendered_content) {
          rendered = body.pre_rendered_content;
        } else {
          const ctx = await buildContext({
            baseContext:     body.context,
            contextRefs:     body.context_refs,
            manualVariables: manualInput,
            tenantId:        body.tenant_id,
            adminClient:     adminDataClient,
          });
          const { bodyBlocks, pageHeaderHtml, pageFooterHtml } =
            await resolveRenderedBlocks(adminDataClient, sourceFile.blockMapping, body.tenant_id, ctx);
          generateOnlyPageHeaderHtml = pageHeaderHtml;
          generateOnlyPageFooterHtml = pageFooterHtml;
          Object.assign(ctx, bodyBlocks);
          rendered = await renderLiquidSafe(sourceFile.htmlContent, ctx);
        }
        const fullHtml = buildHtml5Document(rendered, sourceFile.name);
        fileBytes = new TextEncoder().encode(fullHtml);
        htmlForPdf = fullHtml;
      } else {
        const { data: rawBytes } = await downloadFile(adminClient, sourceFile.bucket!, sourceFile.path!);
        const isDocxSource = sourceFile.mimeType.includes("docx") ||
                             sourceFile.mimeType.includes("openxmlformats");
        if (isDocxSource) {
          const ctx = await buildContext({
            baseContext:     body.context,
            contextRefs:     body.context_refs,
            manualVariables: manualInput,
            tenantId:        body.tenant_id,
            adminClient:     adminDataClient,
          });
          // Blocs de contingut: injectar body blocks al context (DOCX: no page header/footer)
          const { bodyBlocks } = await resolveRenderedBlocks(adminDataClient, sourceFile.blockMapping, body.tenant_id, ctx);
          Object.assign(ctx, bodyBlocks);
          fileBytes = renderDocxSafe(rawBytes, ctx);
        } else {
          fileBytes = rawBytes;
        }
      }

      // ── PDF output: camí síncron o asíncron ────────────────────────────────
      if (outputFormat === "pdf") {
        const pdfConfig = await adminClient.rpc("get_pdf_converter_config");
        const cfg = (pdfConfig.data ?? {}) as Record<string, unknown>;

        if (cfg["pdf_enabled"] !== true) {
          throw new AppError(
            400,
            "pdf_disabled",
            "La conversió a PDF no està habilitada per aquest tenant. Contacta amb l'administrador o genera el document en format natiu (DOCX/HTML).",
          );
        }

        {
          const isDocxSrc    = sourceFile.mimeType.includes("docx") || sourceFile.mimeType.includes("openxmlformats");
          const outputProfile = (body.output_profile ?? cfg["unsigned_pdf_profile"] ?? "pdf") as "pdf"|"pdfa2b"|"pdfa3b";
          const syncMaxKb     = Number(cfg["sync_html_max_kb"] ?? 500);
          const fileSizeKb    = fileBytes.byteLength / 1024;
          const canSync       = !isDocxSrc && htmlForPdf !== null && fileSizeKb < syncMaxKb;

          if (canSync && htmlForPdf) {
            // Camí síncron: HTML petit → Gotenberg directament
            try {
              const gotClient = createGotenbergClientFromConfig(cfg);
              const pdfBytes  = await gotClient.htmlToPdf(htmlForPdf, {
                profile:    outputProfile,
                headerHtml: generateOnlyPageHeaderHtml ?? undefined,
                footerHtml: generateOnlyPageFooterHtml ?? undefined,
              });

              // Crear versió PDF directament
              const pdfName   = sourceFile.name.replace(/\.html$/, "") + ".pdf";
              const pdfPath   = `${body.tenant_id}/${crypto.randomUUID()}/${sanitizeFileName(pdfName)}`;
              const { error: upErr } = await adminClient.storage
                .from(DOCUMENTS_BUCKET)
                .upload(pdfPath, new Blob([pdfBytes], { type: "application/pdf" }), {
                  contentType: "application/pdf", upsert: false,
                });
              if (upErr) throw new AppError(500, "storage_upload_error", `PDF upload error: ${upErr.message}`);

              // Crear document/versió via RPC
              const title = body.document_title ?? `Generated-${new Date().toISOString().slice(0, 10)}`;
              const { data: rpcData, error: rpcErr } = await userClient.rpc("create_document_with_version", {
                p_tenant_id:        body.tenant_id,
                p_folder_id:        body.folder_id ?? null,
                p_title:            title,
                p_file_path_or_url: pdfPath,
                p_mime_type:        "application/pdf",
                p_size_bytes:       pdfBytes.byteLength,
                p_storage_type:     "native",
                p_category:         body.document_category ?? null,
              });
              if (rpcErr || !rpcData) throw new AppError(500, "document_create_error", rpcErr?.message ?? "create_document error");

              const created = (typeof rpcData === "string" ? JSON.parse(rpcData) : rpcData) as Record<string, unknown>;
              log("info", FEATURE, "generate_only PDF sync completed", {
                extra: { output_profile: outputProfile },
              });
              return jsonOk({ action: "generate_only", output_format: "pdf", output_profile: outputProfile, ...created }, 201);

            } catch (gotErr) {
              if (gotErr instanceof GotenbergError && gotErr.isUnreachable) {
                // Fallback a cua asíncrona si Gotenberg no és accessible
                log("warn", FEATURE, "Gotenberg unreachable — falling back to async queue");
              } else if (gotErr instanceof AppError) {
                throw gotErr;
              } else {
                log("warn", FEATURE, "Gotenberg sync error — falling back to async queue", {
                  extra: { error: (gotErr as Error).message },
                });
              }
            }
          }

          // Camí asíncron: pujar intermediate i crear job
          const intermediateName = sanitizeFileName(sourceFile.name);
          const intermediatePath = `${body.tenant_id}/intermediate/${crypto.randomUUID()}/${intermediateName}`;
          const intermediateBlob = new Blob([fileBytes], { type: sourceFile.mimeType });

          const { error: intUpErr } = await adminClient.storage
            .from(DOCUMENTS_BUCKET)
            .upload(intermediatePath, intermediateBlob, { contentType: sourceFile.mimeType, upsert: false });
          if (intUpErr) throw new AppError(500, "storage_upload_error", `Intermediate upload error: ${intUpErr.message}`);

          const idempKey = getIdempotencyKey(req, body);
          const { data: jobData, error: jobErr } = await userClient.rpc("create_pdf_job", {
            p_tenant_id:                body.tenant_id,
            p_source_type:              body.source_type === "template_locale" ? "template_locale" : "document_existing",
            p_source_ref_id:            body.source_template_locale_id ?? body.source_document_version_id ?? null,
            p_template_type:            isDocxSrc ? "docx" : "html",
            p_document_title:           body.document_title ?? sourceFile.name,
            p_output_profile:           outputProfile,
            p_folder_id:                body.folder_id ?? null,
            p_idempotency_key:          idempKey,
            p_metadata:                 {
              ...(body.metadata ?? {}),
              ...(body.document_category ? { category: body.document_category } : {}),
              ...(body.document_category === "attendance" ? { attendance_protocol: true } : {}),
            },
            p_intermediate_path:        intermediatePath,
            p_intermediate_size_bytes:  fileBytes.byteLength,
          });

          if (jobErr || !jobData) throw new AppError(500, "job_create_error", jobErr?.message ?? "create_pdf_job error");
          const job = jobData as { job_id: string; idempotent_replay: boolean };

          kickPdfQueueWorker(SUPABASE_URL, SERVICE_ROLE_KEY);
          log("info", FEATURE, "generate_only PDF async job created", {
            extra: { job_id: job.job_id },
          });
          return jsonOk({
            action:            "generate_only",
            output_format:     "pdf",
            output_profile:    outputProfile,
            job_id:            job.job_id,
            status:            "queued",
            idempotent_replay: job.idempotent_replay,
          }, 202);
        }
      }
      // ── Fi PDF output ──────────────────────────────────────────────────────
      const result = await generateOnlyVersion(
        adminClient, userClient, body, fileBytes, sourceFile, user.id,
      );

      await persistGenerateOnlySignerSnapshot(
        adminClient, body, user.id, sourceFile, extractGeneratedDocumentRefs(result),
      );

      return jsonOk({ action: "generate_only", output_format: "native", ...result }, 201);
    }

    // action = sign_native ──────────────────────────────────────────────────────
    if (body.action === "sign_native") {
      const signingType = body.native_sign_type ?? "presential";
      const signersList = resolveNativeSigners(body);
      const nativeExternalId = `native:${getIdempotencyKey(req, body)}`;
      const docTitleNative = body.document_title ?? sourceFile.name.replace(/\.[^.]+$/, "");

      if (signingType === "remote" && signersList.length === 0) {
        throw new AppError(400, "missing_signers", "Cal indicar almenys un signant per firma remota");
      }

      // Idempotència: mateixa clau → mateixa submission (sense duplicar sessions)
      const { data: existingNative } = await adminClient
        .from("signing_submissions")
        .select("id, status, metadata")
        .eq("tenant_id", body.tenant_id)
        .eq("external_id", nativeExternalId)
        .eq("signing_provider", "native")
        .maybeSingle();

      if (existingNative) {
        const meta = (existingNative.metadata ?? {}) as Record<string, unknown>;
        return jsonOk({
          action:              "sign_native",
          signing_type:        signingType,
          submission_id:       existingNative.id,
          session_id:          meta.primary_session_id ?? null,
          document_version_id: meta.source_document_version_id ?? null,
          document_id:         meta.source_document_id ?? null,
          status:              existingNative.status,
          idempotent_replay:   true,
        }, 200);
      }

      // Verificar native_signing_enabled
      const { data: pdfCfgNative } = await adminClient.rpc("get_pdf_converter_config");
      const cfgNative = (pdfCfgNative ?? {}) as Record<string, unknown>;
      if (cfgNative["native_signing_enabled"] !== true) {
        return jsonError(403, "native_signing_disabled", "La firma nativa no està activada. Activeu-la a l'admin portal.");
      }

      const fallbackSigners = (signingType === "remote" && signersList.length > 0
        ? signersList
        : [{
            email: body.signer_email ?? null,
            name:  body.signer_name ?? null,
            role:  body.signer_role ?? null,
            order: 0,
          }]
      ).map((s, i) => ({ role: s.role, order: s.order ?? i }));

      // Renderitzar contingut (HTML o DOCX) + marques [[SIG:role]] per detecció al PDF
      const manualInputNative = getManualInputVariables(body);
      let fileBytesNative: Uint8Array;
      let htmlForSigning: string | null = null;
      let signatureRoles: string[] = [];
      let signatureFieldMetas: SigningFieldMeta[] = [];
      const isDocxNative = sourceFile.mimeType.includes("docx") || sourceFile.mimeType.includes("openxmlformats");
      let nativePageHeaderHtml: string | null = null;
      let nativePageFooterHtml: string | null = null;

      if (sourceFile.mimeType === "text/html" && sourceFile.htmlContent !== undefined) {
        const rendered = body.pre_rendered_content
          ?? await (async () => {
               const ctx = await buildContext({
                 baseContext:     body.context,
                 contextRefs:     body.context_refs,
                 manualVariables: manualInputNative,
                 tenantId:        body.tenant_id,
                 adminClient:     adminDataClient,
               });
               const { bodyBlocks, pageHeaderHtml, pageFooterHtml } =
                 await resolveRenderedBlocks(adminDataClient, sourceFile.blockMapping, body.tenant_id, ctx);
               nativePageHeaderHtml = pageHeaderHtml;
               nativePageFooterHtml = pageFooterHtml;
               Object.assign(ctx, bodyBlocks);
               return renderLiquidSafe(sourceFile.htmlContent!, ctx);
             })();
        const marked = injectHtmlSignatureMarkers(rendered);
        signatureRoles = marked.roles;
        signatureFieldMetas = marked.fieldMetas;
        htmlForSigning   = buildHtml5Document(marked.html, sourceFile.name);
        fileBytesNative  = new TextEncoder().encode(htmlForSigning);
      } else {
        const { data: rawBytesNative } = await downloadFile(adminClient, sourceFile.bucket!, sourceFile.path!);
        if (isDocxNative) {
          const ctx = await buildContext({
            baseContext:     body.context,
            contextRefs:     body.context_refs,
            manualVariables: manualInputNative,
            tenantId:        body.tenant_id,
            adminClient:     adminDataClient,
          });
          const { bodyBlocks } = await resolveRenderedBlocks(adminDataClient, sourceFile.blockMapping, body.tenant_id, ctx);
          Object.assign(ctx, bodyBlocks);
          const renderedDocx = renderDocxSafe(rawBytesNative, ctx);
          const markedDocx = injectDocxSignatureMarkers(renderedDocx);
          signatureRoles = markedDocx.roles;
          signatureFieldMetas = markedDocx.fieldMetas;
          fileBytesNative = markedDocx.bytes;
        } else {
          fileBytesNative = rawBytesNative;
        }
      }

      // ── Intenta generar el PDF síncronament amb Gotenberg ──────────────────────
      // (mateixa estratègia que generate_only; fallback a cua si Gotenberg no respon)
      let syncVersionId:   string | null = null;
      let syncDocumentId:  string | null = null;
      let asyncPdfJobId:   string | null = null;
      let pdfBytesForFieldMap: Uint8Array | null = null;

      try {
        if (cfgNative["pdf_enabled"] !== true) throw new Error("pdf_disabled");

        const gotNative = createGotenbergClientFromConfig(cfgNative);
        let pdfBytesNative: Uint8Array;

        if (!isDocxNative && htmlForSigning) {
          pdfBytesNative = await gotNative.htmlToPdf(htmlForSigning, {
            profile:    "pdfa2b",
            headerHtml: nativePageHeaderHtml ?? undefined,
            footerHtml: nativePageFooterHtml ?? undefined,
          });
        } else if (isDocxNative) {
          pdfBytesNative = await gotNative.docxToPdf(fileBytesNative, { profile: "pdfa2b" });
        } else {
          pdfBytesNative = fileBytesNative; // ja és PDF
        }
        pdfBytesForFieldMap = pdfBytesNative;

        const titleNative  = body.document_title ?? sourceFile.name.replace(/\.[^.]+$/, "");
        const pdfNameNative = sanitizeFileName(titleNative) + "_to_sign.pdf";
        const pdfPathNative = `${body.tenant_id}/${crypto.randomUUID()}/${pdfNameNative}`;

        const { error: upErrNative } = await adminClient.storage
          .from(DOCUMENTS_BUCKET)
          .upload(pdfPathNative, new Blob([pdfBytesNative], { type: "application/pdf" }), {
            contentType: "application/pdf", upsert: false,
          });
        if (upErrNative) throw upErrNative;

        const { data: rpcNative, error: rpcErrNative } = await userClient.rpc("create_document_with_version", {
          p_tenant_id:        body.tenant_id,
          p_folder_id:        body.folder_id ?? null,
          p_title:            titleNative,
          p_file_path_or_url: pdfPathNative,
          p_mime_type:        "application/pdf",
          p_size_bytes:       pdfBytesNative.byteLength,
          p_storage_type:     "native",
        });
        if (rpcErrNative || !rpcNative) throw new Error(rpcErrNative?.message ?? "create_document error");

        const createdNative = (typeof rpcNative === "string" ? JSON.parse(rpcNative) : rpcNative) as Record<string, unknown>;
        syncDocumentId = ((createdNative?.document as Record<string,unknown>)?.id ?? createdNative?.document_id ?? null) as string | null;
        syncVersionId  = ((createdNative?.version as Record<string,unknown>)?.id ?? createdNative?.version_id ?? null) as string | null;

        log("info", FEATURE, "sign_native PDF sync completed", {
          extra: { document_id: syncDocumentId, version_id: syncVersionId },
        });

      } catch (gotErrNative) {
        const isUnreachable = gotErrNative instanceof GotenbergError && gotErrNative.isUnreachable;
        const isPdfDisabled = (gotErrNative as Error).message === "pdf_disabled";

        if (!isUnreachable && !isPdfDisabled) {
          throw new AppError(500, "pdf_generation_error", (gotErrNative as Error).message);
        }
        // Gotenberg no accessible o PDF desactivat: caure al camí asíncron
        log("warn", FEATURE, "sign_native async fallback", {
          extra: { reason: isPdfDisabled ? "pdf disabled" : "Gotenberg unreachable" },
        });
      }

      // ── Camí asíncron (fallback) ────────────────────────────────────────────────
      if (!syncVersionId) {
        const intermNameNative = sanitizeFileName(sourceFile.name);
        const intermPathNative = `${body.tenant_id}/intermediate/${crypto.randomUUID()}/${intermNameNative}`;
        const { error: intErrNative } = await adminClient.storage
          .from(DOCUMENTS_BUCKET)
          .upload(intermPathNative, new Blob([fileBytesNative], { type: sourceFile.mimeType }), {
            contentType: sourceFile.mimeType, upsert: false,
          });
        if (intErrNative) throw new AppError(500, "storage_upload_error", `Intermediate upload error: ${intErrNative.message}`);

        const idempKeyNative = getIdempotencyKey(req, body);
        const { data: jobDataNative, error: jobErrNative } = await userClient.rpc("create_pdf_job", {
          p_tenant_id:               body.tenant_id,
          p_source_type:             body.source_type === "template_locale" ? "template_locale" : "document_existing",
          p_source_ref_id:           body.source_template_locale_id ?? body.source_document_version_id ?? null,
          p_template_type:           isDocxNative ? "docx" : "html",
          p_document_title:          body.document_title ?? sourceFile.name,
          p_output_profile:          "pdfa2b",
          p_folder_id:               body.folder_id ?? null,
          p_idempotency_key:         idempKeyNative + "-pdf",
          p_metadata:                {
            native_signing:   true,
            signing_type:     signingType,
            signature_roles:  signatureRoles.length > 0
              ? signatureRoles
              : fallbackSigners
                .map((s) => s.role)
                .filter((role): role is string => Boolean(role)),
            fallback_signers: fallbackSigners,
            field_metas:      signatureFieldMetas,
          },
          p_intermediate_path:       intermPathNative,
          p_intermediate_size_bytes: fileBytesNative.byteLength,
        });
        if (jobErrNative || !jobDataNative) throw new AppError(500, "job_create_error", jobErrNative?.message ?? "create_pdf_job error");
        asyncPdfJobId = (jobDataNative as { job_id: string }).job_id;
        kickPdfQueueWorker(SUPABASE_URL, SERVICE_ROLE_KEY);
      }

      // ── Crear sessió(s) de signatura ───────────────────────────────────────────
      const groupId      = crypto.randomUUID();
      const totalSigners = Math.max(signersList.length, 1);
      const primarySigner = signersList[0] ?? {
        email: body.signer_email ?? null,
        name:  body.signer_name ?? null,
        role:  body.signer_role ?? null,
        order: 0,
      };

      type CreatedSession = {
        session_id: string;
        token: string;
        expires_at: string;
        signer_order?: number;
      };
      const createdSessions: CreatedSession[] = [];

      const sessionsToCreate = signingType === "remote" && signersList.length > 0
        ? signersList
        : [primarySigner];

      for (let i = 0; i < sessionsToCreate.length; i++) {
        const s = sessionsToCreate[i];
        const { data: sessData, error: sessErr } = await userClient.rpc("create_signing_session", {
          p_tenant_id:           body.tenant_id,
          p_document_version_id: syncVersionId ?? (body.source_type === "document_existing" ? (body.source_document_version_id ?? null) : null),
          p_signing_type:        signingType,
          p_signer_name:         s.name ?? null,
          p_signer_email:        s.email ?? null,
          p_signer_role:         s.role ?? null,
          p_pdf_job_id:          asyncPdfJobId ?? null,
          p_signing_group_id:    groupId,
          p_signer_order:        s.order ?? i,
          p_total_signers:       totalSigners,
        });
        if (sessErr || !sessData) {
          throw new AppError(500, "session_create_error", sessErr?.message ?? "create_signing_session error");
        }
        createdSessions.push(sessData as CreatedSession);
      }

      // Mapa de camps de signatura (overlay stamp-pdf-signatures)
      if (pdfBytesForFieldMap) {
        const persistRoles = signatureRoles.length > 0
          ? signatureRoles
          : sessionsToCreate
            .map((s) => s.role?.trim())
            .filter((role): role is string => Boolean(role));
        await resolveAndPersistFieldMap(adminClient, {
          pdfBytes:       pdfBytesForFieldMap,
          roles:          persistRoles,
          signers:        sessionsToCreate.map((s, i) => ({
            role:  s.role,
            order: s.order ?? i,
          })),
          fieldMetas:     signatureFieldMetas,
          signingGroupId: groupId,
        });
      }

      const sessionNative = createdSessions[0] as CreatedSession;

      // ── Submission Hub: fila al Centre de signatures ─────────────────────────────
      const signersSnapshot = buildNativeSignersSnapshot(
        sessionsToCreate,
        createdSessions,
        signingType,
      );

      const submissionId = await createSubmissionRecord(
        adminClient,
        { ...body, signers: signersSnapshot as unknown as Signer[] },
        user.id,
        nativeExternalId,
        syncDocumentId ?? sourceFile.documentId,
        docTitleNative,
        {
          signing_provider:  "native",
          native_group_id:   groupId,
          notification_mode: signingType === "remote" ? (body.notification_mode ?? "app_auto_sequential") : null,
          metadata: {
            native:                   true,
            signing_type:             signingType,
            primary_session_id:       sessionNative.session_id,
            session_ids:              createdSessions.map(s => s.session_id),
            source_document_id:       syncDocumentId ?? sourceFile.documentId,
            source_document_version_id: syncVersionId ?? body.source_document_version_id ?? null,
          },
        },
      );

      // Actualitzar versió font a la submission si el PDF síncron ja existeix
      if (syncVersionId) {
        await adminClient
          .from("signing_submissions")
          .update({ source_document_version_id: syncVersionId })
          .eq("id", submissionId)
          .eq("tenant_id", body.tenant_id);
      }

      await emitNativeSubmissionCreated(adminClient, submissionId, signingType);

      const signLinkRemote = signingType === "remote"
        ? buildNativeSignLink(sessionNative.token)
        : null;

      let emailQueued = false;
      let emailError: string | undefined;

      if (signingType === "remote") {
        const notificationMode = "app_auto_sequential";
        const notifyOrders = notificationMode === "app_auto_all"
          ? createdSessions.map((_, idx) => idx)
          : notificationMode === "app_manual"
            ? []
            : [0];

        const docTitle = body.document_title ?? sourceFile.name;

        for (const order of notifyOrders) {
          const sess = createdSessions[order];
          const signer = sessionsToCreate[order];
          if (!signer.email || !sess?.token) continue;

          const emailResult = await enqueueNativeSigningRequestEmail(adminClient, {
            tenantId:      body.tenant_id,
            sessionId:     sess.session_id,
            toEmail:       signer.email,
            signerName:    signer.name ?? null,
            signerRole:    signer.role ?? null,
            documentTitle: docTitle,
            signLink:      buildNativeSignLink(sess.token),
            expiresAt:     sess.expires_at,
            currentOrder:  order + 1,
            totalSigners,
            isNextSigner:  order > 0,
          });
          if (order === 0) {
            emailQueued = emailResult.queued;
            emailError  = emailResult.error;
          }
        }
      }

      const remoteExtras = signingType === "remote" ? {
        signing_url:  signLinkRemote,
        email_queued: emailQueued,
        ...(emailError ? { email_error: emailError } : {}),
      } : {};

      // Resposta: sync (200 + version_id) o async (202 + pdf_job_id)
      if (syncVersionId) {
        return jsonOk({
          action:              "sign_native",
          signing_type:        signingType,
          submission_id:       submissionId,
          session_id:          sessionNative.session_id,
          document_version_id: syncVersionId,
          document_id:         syncDocumentId,
          expires_at:          sessionNative.expires_at,
          status:              "ready",
          ...remoteExtras,
        }, 200);
      }
      return jsonOk({
        action:        "sign_native",
        signing_type:  signingType,
        submission_id: submissionId,
        session_id:    sessionNative.session_id,
        pdf_job_id:    asyncPdfJobId,
        expires_at:    sessionNative.expires_at,
        status:        "pending",
        ...remoteExtras,
      }, 202);
    }

    // action = sign ────────────────────────────────────────────────────────────
    const externalId = getIdempotencyKey(req, body);

    // Idempotència de request: si ja existeix una submission amb la mateixa clau,
    // retornem la mateixa resposta i no repetim consum de crèdit ni crida a DocuSeal.
    const { data: existingSubmission } = await adminClient
      .from("signing_submissions")
      .select("id, status, docuseal_submission_id, docuseal_signing_url")
      .eq("tenant_id", body.tenant_id)
      .eq("external_id", externalId)
      .maybeSingle();

    if (existingSubmission) {
      return jsonOk({
        action:                 "sign",
        submission_id:          existingSubmission.id,
        docuseal_submission_id: existingSubmission.docuseal_submission_id,
        signing_url:            existingSubmission.docuseal_signing_url,
        status:                 existingSubmission.status,
        idempotent_replay:      true,
      }, 200);
    }

    const { apiKey, apiUrl } = await resolveDocusealKey(adminClient, userClient, body.tenant_id);

    // Determinar mode per consumir crèdit
    const { data: cfg } = await adminClient
      .from("tenant_signing_status")
      .select("mode, default_notification_mode")
      .eq("tenant_id", body.tenant_id)
      .single();

    if (cfg?.mode === "platform") {
      await consumeCredit(userClient, body.tenant_id);
    }

    // Crear submission (draft → pending)
    const submissionId  = await createSubmissionRecord(
      adminClient, body, user.id, externalId,
      sourceFile.documentId,
      sourceFile.name,
    );

    // Determinar mode de notificació efectiu (submission override o default de tenant)
    const notificationMode: NotificationMode = body.notification_mode ??
      ((cfg as Record<string, unknown>)?.default_notification_mode as NotificationMode | undefined) ??
      'app_auto_sequential';
    // Mapeja mode → send_email a DocuSeal
    const docusealSendEmail = notificationMode === 'docuseal_auto';

    // Enviar a DocuSeal: branca HTML o DOCX/PDF
    let docusealResult: { submissionId: string; signingUrl?: string; signerLinks: SignerLink[] };
    try {
      const manualInput = getManualInputVariables(body);
      // Construir context unificat (LiquidJS/Docxtemplater)
      const ctx = await buildContext({
        baseContext:     body.context,
        contextRefs:     body.context_refs,
        manualVariables: manualInput,
        tenantId:        body.tenant_id,
        adminClient:     adminDataClient,
      });

      // Blocs de contingut: injectar body blocks al context
      // page header/footer s'usen per a Gotenberg (no per a DocuSeal directament)
      const { bodyBlocks } = await resolveRenderedBlocks(
        adminDataClient, sourceFile.blockMapping, body.tenant_id, ctx,
      );
      Object.assign(ctx, bodyBlocks);

      if (sourceFile.mimeType === "text/html" && sourceFile.htmlContent !== undefined) {
        // HTML: si el frontend ja envia el contingut renderitzat, usar-lo directament.
        // En cas contrari, renderitzar amb LiquidJS.
        const renderedHtml = body.pre_rendered_content
          ?? await renderLiquidSafe(sourceFile.htmlContent, ctx);
        docusealResult = await submitHtmlToDocuseal(
          apiKey, apiUrl,
          renderedHtml,
          sourceFile.name,
          externalId,
          body.signers!,
          docusealSendEmail,
        );
      } else {
        // DOCX: pre-renderitzar amb Docxtemplater → DocuSeal rep el DOCX final
        // PDF: passar sense modificar (DocuSeal gestiona els camps interactius)
        const { data: fileBytes } = await downloadFile(adminClient, sourceFile.bucket!, sourceFile.path!);
        const isDocxSource = sourceFile.mimeType.includes("docx") ||
                             sourceFile.mimeType.includes("openxmlformats");
        const finalBytes = isDocxSource ? renderDocxSafe(fileBytes, ctx) : fileBytes;
        // Per PDF: context.input es passa a DocuSeal per pre-emplenar camps
        const pdfVars = !isDocxSource ? getPdfPrefillVariables(body) : undefined;
        docusealResult = await submitToDocuseal(
          apiKey, apiUrl, finalBytes, sourceFile.mimeType,
          sourceFile.name, externalId, body.signers!,
          pdfVars,
          docusealSendEmail,
          body.use_explicit_fields ?? false,
        );
      }
    } catch (docusealErr) {
      const errMsg = (docusealErr as Error).message;
      await adminClient
        .from("signing_submissions")
        .update({ status: "error", error_message: errMsg, last_event_at: new Date().toISOString() })
        .eq("id", submissionId)
        .eq("tenant_id", body.tenant_id);

      await logSigningRouterFailure(adminClient, {
        tenantId: body.tenant_id,
        submissionId,
        operationCode: "submit_to_docuseal",
        title: "No s'ha pogut enviar el document a DocuSeal",
        message: errMsg,
        errorCode: "docuseal_submit_failed",
        err: docusealErr,
      });

      // Restituir crèdit si era platform mode (best-effort)
      if (cfg?.mode === "platform") {
        const { data: compensated, error: compensationError } = await adminClient.rpc(
          "compensate_signing_credit",
          {
            p_tenant_id: body.tenant_id,
            p_submission_id: submissionId,
          },
        );

        if (compensationError) {
          log("error", FEATURE, "Credit compensation failed", {
            tenantId: body.tenant_id,
            correlationId: submissionId,
            extra: { error: compensationError.message },
          });
        } else {
          log("error", FEATURE, "DocuSeal error — credit compensation applied", {
            tenantId: body.tenant_id,
            correlationId: submissionId,
            extra: { compensated: Boolean(compensated) },
          });
        }
      }
      throw docusealErr;
    }

    // Actualitzar submission amb IDs de DocuSeal i mode de notificació
    await updateSubmissionAfterDocuseal(
      adminClient, submissionId, body.tenant_id,
      docusealResult.submissionId, docusealResult.signingUrl,
      notificationMode,
    );

    // Persistir signants normalitzats a signing_submitters
    await persistSignerLinks(
      adminClient, submissionId, body.tenant_id,
      docusealResult.signerLinks, body.signers ?? [], externalId,
    );

    // Encuar notificacions inicials per a modes app-managed
    await enqueueInitialNotifications(
      adminClient, submissionId, notificationMode, docusealResult.signerLinks,
    );

    log("info", FEATURE, "sign flow completed", {
      extra: {
        submission_id: submissionId,
        docuseal_id: docusealResult.submissionId,
        notification_mode: notificationMode,
        signers: docusealResult.signerLinks.length,
      },
    });

    return jsonOk({
      action:                 "sign",
      submission_id:          submissionId,
      docuseal_submission_id: docusealResult.submissionId,
      signing_url:            docusealResult.signingUrl ?? null,
      signer_links:           docusealResult.signerLinks,
      notification_mode:      notificationMode,
      status:                 "in_progress",
    }, 201);

  } catch (err) {
    if (err instanceof AppError)
      return jsonError(err.status, err.code, err.message);
    log("error", FEATURE, "Unexpected error", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    captureException(err, { feature: FEATURE });
    return jsonError(500, "internal_error", "Error intern del servidor");
  }
});
