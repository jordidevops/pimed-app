import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient, createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "get-document-url";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_PUBLIC_URL = Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;
const DOCUMENTS_BUCKET = "documents";
const MAX_EXPIRY_SECONDS = 7 * 24 * 3600; // 7 dies
const DEFAULT_EXPIRY_SECONDS = 3600; // 1 hora

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface RequestBody {
  version_id: string;
  expiry_seconds?: number;
  /** Optional: context of this URL access, used for audit logging when required_permissions are set. */
  source?: "preview" | "download";
  /** Public signing flow: validates access via document_signing_sessions.signing_token */
  signing_token?: string;
}

interface UrlResponse {
  url: string;
  storage_type: string;
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

async function parseBody(req: Request): Promise<RequestBody> {
  let raw: Record<string, unknown>;
  try {
    raw = await req.json();
  } catch {
    throw new AppError(400, "invalid_json", "Request body must be valid JSON");
  }
  if (!raw.version_id || typeof raw.version_id !== "string") {
    throw new AppError(400, "missing_version_id", "version_id és obligatori");
  }
  const expiry = raw.expiry_seconds != null ? Number(raw.expiry_seconds) : undefined;
  if (expiry !== undefined && (isNaN(expiry) || expiry <= 0)) {
    throw new AppError(400, "invalid_expiry", "expiry_seconds ha de ser un número positiu");
  }
  const source = raw.source === "preview" ? "preview" : "download";
  const signing_token = typeof raw.signing_token === "string" && raw.signing_token.length > 0
    ? raw.signing_token
    : undefined;
  return {
    version_id: raw.version_id as string,
    expiry_seconds: expiry,
    source,
    signing_token,
  };
}

// ---------------------------------------------------------------------------
// Version row + signed URL helpers
// ---------------------------------------------------------------------------

interface VersionRow {
  id: string;
  storage_type: string;
  file_path_or_url: string | null;
  document_id: string;
}

async function buildSignedUrlResponse(
  version: VersionRow,
  expiry: number,
  auditUserId: string | null,
  source: "preview" | "download",
): Promise<Response> {
  if (!version.file_path_or_url) {
    return jsonError(422, "no_file_path", "La versió no té ruta de fitxer");
  }

  const adminClient = createAdminClient();

  if (version.storage_type === "external_link") {
    if (auditUserId) {
      fireAndForgetAudit(adminClient, auditUserId, version.document_id, version.id, source);
    }
    const response: UrlResponse = {
      url: version.file_path_or_url,
      storage_type: "external_link",
    };
    return new Response(JSON.stringify(response), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const { data: signed, error: signError } = await adminClient.storage
    .from(DOCUMENTS_BUCKET)
    .createSignedUrl(version.file_path_or_url, expiry);

  if (signError || !signed) {
    log("error", FEATURE, "Storage sign error", {
      extra: { error: signError?.message },
    });
    return jsonError(500, "storage_error", "No s'ha pogut generar la URL de descàrrega");
  }

  const downloadUrl = signed.signedUrl.replace(SUPABASE_URL, SUPABASE_PUBLIC_URL);

  if (auditUserId) {
    fireAndForgetAudit(adminClient, auditUserId, version.document_id, version.id, source);
  }

  const response: UrlResponse = {
    url: downloadUrl,
    storage_type: "native",
  };

  return new Response(JSON.stringify(response), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function resolveVersionViaSigningToken(
  body: RequestBody,
  expiry: number,
): Promise<{ version: VersionRow } | Response> {
  const adminClient = createAdminClient();

  const { data: sessionJson, error: sessionError } = await adminClient.rpc(
    "lookup_signing_session_by_token",
    { p_token: body.signing_token! },
  );

  if (sessionError || !sessionJson) {
    return jsonError(404, "token_not_found", "Enllaç de signatura no vàlid");
  }

  const session = sessionJson as {
    id: string;
    document_version_id: string;
    signing_group_id: string | null;
    status: string;
    expires_at: string;
  };

  if (session.status === "signed" || session.status === "cancelled") {
    return jsonError(409, "session_not_active", "La sessió de signatura ja no està activa");
  }

  if (new Date(session.expires_at) < new Date()) {
    return jsonError(410, "token_expired", "L'enllaç de signatura ha caducat");
  }

  if (session.signing_group_id) {
    const { data: sub } = await adminClient
      .from("signing_submissions")
      .select("staging_storage_path")
      .eq("native_group_id", session.signing_group_id)
      .eq("signing_provider", "native")
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    const stagingPath = sub?.staging_storage_path as string | null;
    if (stagingPath) {
      const { data: signed, error: signError } = await adminClient.storage
        .from(DOCUMENTS_BUCKET)
        .createSignedUrl(stagingPath, expiry);

      if (signError || !signed) {
        return jsonError(500, "storage_error", "No s'ha pogut generar la URL de descàrrega");
      }

      const downloadUrl = signed.signedUrl.replace(SUPABASE_URL, SUPABASE_PUBLIC_URL);
      const response: UrlResponse = { url: downloadUrl, storage_type: "native" };
      return new Response(JSON.stringify(response), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  if (session.document_version_id !== body.version_id) {
    return jsonError(403, "version_mismatch", "Versió no autoritzada per aquest enllaç");
  }

  const { data: version, error: versionError } = await adminClient
    .from("document_versions")
    .select("id, storage_type, file_path_or_url, document_id")
    .eq("id", body.version_id)
    .single();

  if (versionError || !version) {
    return jsonError(404, "version_not_found", "Versió no trobada");
  }

  return { version: version as VersionRow };
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
    const expiry = Math.min(
      body.expiry_seconds ?? DEFAULT_EXPIRY_SECONDS,
      MAX_EXPIRY_SECONDS,
    );

    if (body.signing_token) {
      const resolved = await resolveVersionViaSigningToken(body, expiry);
      if (resolved instanceof Response) return resolved;
      return buildSignedUrlResponse(resolved.version, expiry, null, body.source ?? "download");
    }

    // ── 1. Autenticar usuari via JWT ──────────────────────────────────────────
    const userClient = createUserClient(req);
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      return jsonError(401, "unauthorized", "Token invàlid o expirat");
    }

    // ── 2. Llegir la versió via userClient — RLS valida l'accés al tenant ─────
    // CRÍTIC: Fem servir userClient (no adminClient) per a aquesta consulta.
    // Si l'usuari no té accés al document via RLS, el registre no es retornarà.
    // api.document_versions té security_invoker = true i hereda les polítiques
    // de data.document_versions que comproven jwt_user_tenants().
    const { data: version, error: versionError } = await userClient
      .from("document_versions")
      .select("id, storage_type, file_path_or_url, document_id")
      .eq("id", body.version_id)
      .single();

    if (versionError || !version) {
      return jsonError(404, "version_not_found", "Versió no trobada o sense accés");
    }

    return buildSignedUrlResponse(version as VersionRow, expiry, user.id, body.source ?? "download");
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
// Fire-and-forget audit for required_permissions access
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
function fireAndForgetAudit(adminClient: any, userId: string, documentId: string, versionId: string, source: string): void {
  // Deliberately NOT awaited — errors must never block the signed-URL response.
  (async () => {
    try {
      const { data: doc } = await adminClient
        .schema("data")
        .from("documents")
        .select("required_permissions, tenant_id, site_id")
        .eq("id", documentId)
        .maybeSingle();

      if (!doc) return;

      const perms: string[] = Array.isArray(doc.required_permissions)
        ? (doc.required_permissions as string[])
        : [];

      if (perms.length === 0) return;

      await adminClient
        .schema("data")
        .from("audit_logs")
        .insert({
          tenant_id:   doc.tenant_id,
          user_id:     userId,
          action:      "DOCUMENT_PERMISSION_USED",
          entity_type: "document",
          entity_id:   documentId,
          payload: {
            required_permissions: perms,
            source,
            document_version_id:  versionId,
            site_id:              doc.site_id ?? null,
          },
        });
    } catch (auditErr) {
      log("warn", FEATURE, "audit fire-and-forget failed", {
        extra: { error: auditErr instanceof Error ? auditErr.message : String(auditErr) },
      });
    }
  })();
}
