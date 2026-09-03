import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient, createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "request-document-upload";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_PUBLIC_URL = Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;
const DOCUMENTS_BUCKET = "documents";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface RequestBody {
  tenant_id: string;
  filename: string;
  size_bytes: number;
  mime_type?: string;
}

interface UploadResponse {
  upload_url: string;
  method: "PUT";
  path: string;
}

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------

class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "AppError";
  }
}

function jsonError(status: number, code: string, message: string): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Body validation
// ---------------------------------------------------------------------------

function sanitizeFileName(name: string): string {
  return name.replace(/[^\w.\-]/g, "_").slice(0, 200);
}

async function parseBody(req: Request): Promise<RequestBody> {
  let raw: Record<string, unknown>;
  try {
    raw = await req.json();
  } catch {
    throw new AppError(400, "invalid_json", "Request body must be valid JSON");
  }
  if (!raw.tenant_id || typeof raw.tenant_id !== "string") {
    throw new AppError(400, "missing_tenant_id", "tenant_id és obligatori");
  }
  if (!raw.filename || typeof raw.filename !== "string") {
    throw new AppError(400, "missing_filename", "filename és obligatori");
  }
  if (typeof raw.size_bytes !== "number" || raw.size_bytes <= 0) {
    throw new AppError(400, "invalid_size", "size_bytes ha de ser un número positiu");
  }
  return {
    tenant_id: raw.tenant_id as string,
    filename: raw.filename as string,
    size_bytes: raw.size_bytes as number,
    mime_type: typeof raw.mime_type === "string" ? raw.mime_type : undefined,
  };
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

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

    // ── 1. Autenticar usuari via JWT (createUserClient respecta RLS) ──────────
    const userClient = createUserClient(req);
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      return jsonError(401, "unauthorized", "Token invàlid o expirat");
    }

    // ── 2. Verificar coherència tenant_id (header vs body) ────────────────────
    // El header x-tenant-id és el tenant actiu injectat per TenantContext.
    // Si l'usuari manipula el body per enviar un tenant_id diferent, rebutgem.
    const headerTenantId = req.headers.get("x-tenant-id");
    if (headerTenantId && headerTenantId !== body.tenant_id) {
      return jsonError(403, "tenant_mismatch", "tenant_id no coincideix amb el context actiu");
    }

    // ── 3. Verificar membresia al tenant via RLS (userClient) ─────────────────
    // Aquesta query es fa via userClient — si l'usuari no és membre, retorna buit.
    const { data: membership, error: memberError } = await userClient
      .from("tenant_members")
      .select("role")
      .eq("tenant_id", body.tenant_id)
      .eq("user_id", user.id)
      .eq("is_active", true)
      .single();

    if (memberError || !membership) {
      return jsonError(403, "not_a_member", "No ets membre d'aquest tenant");
    }

    if (membership.role === "viewer") {
      return jsonError(403, "forbidden", "Els viewers no poden pujar documents");
    }

    const adminClient = createAdminClient();

    // ── 4. Kill Switch + Quota check (Drive + Documents combined) ─────────────
    await checkKillSwitchAndQuota(adminClient, body.tenant_id, body.size_bytes);

    // ── 5. Generar path i URL de pujada (adminClient per Storage) ─────────────
    // El control d'accés ja s'ha fet als passos 1-4 via userClient + quota RPC.
    // Ara usem adminClient exclusivament per a l'operació de Storage.
    const fileUuid = crypto.randomUUID();
    const safeName = sanitizeFileName(body.filename);
    const storagePath = `${body.tenant_id}/${fileUuid}/${safeName}`;
    const { data: signedData, error: signError } = await adminClient.storage
      .from(DOCUMENTS_BUCKET)
      .createSignedUploadUrl(storagePath);

    if (signError || !signedData) {
      log("error", FEATURE, "Storage signed URL error", {
        tenantId: body.tenant_id,
        extra: { error: signError?.message },
      });
      return jsonError(500, "storage_error", "No s'ha pogut generar la URL de pujada");
    }

    // Reemplaça l'URL interna de Docker per la URL pública si estem en local dev
    const uploadUrl = signedData.signedUrl.replace(SUPABASE_URL, SUPABASE_PUBLIC_URL);

    const response: UploadResponse = {
      upload_url: uploadUrl,
      method: "PUT",
      path: storagePath,
    };

    return new Response(JSON.stringify(response), {
      status: 201,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    if (err instanceof AppError) {
      return jsonError(err.status, err.code, err.message);
    }
    const message = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "Unexpected error", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return jsonError(500, "internal_error", "Error intern del servidor");
  }
});

// ---------------------------------------------------------------------------
// Kill Switch + Quota (Drive + Documents combined via check_upload_eligibility)
// ---------------------------------------------------------------------------

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  return `${(bytes / 1024 ** 3).toFixed(2)} GB`;
}

async function checkKillSwitchAndQuota(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
  sizeBytes: number,
): Promise<void> {
  const { data, error: queryError } = await adminClient.rpc("check_upload_eligibility", {
    p_tenant_id: tenantId,
    p_size_bytes: sizeBytes,
  });

  if (queryError) {
    log("error", FEATURE, "Eligibility check error", {
      tenantId,
      extra: { error: queryError.message },
    });
    throw new AppError(500, "eligibility_check_failed", "Error verificant elegibilitat");
  }

  if (!data || data.length === 0) {
    throw new AppError(404, "tenant_not_found", "Tenant no trobat");
  }

  const result = data[0];

  if (result.storage_blocked) {
    throw new AppError(
      403,
      "storage_blocked",
      result.storage_blocked_reason ?? "Storage bloquejat per l'administrador",
    );
  }

  if (result.quota_exceeded) {
    throw new AppError(
      413,
      "quota_exceeded",
      `Quota superada: ${formatBytes(Number(result.current_bytes))} / ${formatBytes(Number(result.max_bytes))} usats`,
    );
  }
}
