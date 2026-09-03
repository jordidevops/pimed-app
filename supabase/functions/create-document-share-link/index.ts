import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient, createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "create-document-share-link";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const FUNCTIONS_BASE_PUBLIC =
  Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;

// Max share link lifetime: 30 days
const MAX_EXPIRY_SECONDS = 30 * 24 * 3600;
const DEFAULT_EXPIRY_SECONDS = 24 * 3600; // 24 h

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface RequestBody {
  tenant_id: string;
  document_id: string;
  document_version_id: string;
  /** Duration in seconds. Default 86400 (24 h). Max 30 days. */
  expiry_seconds?: number;
}

interface ShareLinkResponse {
  id: string;
  token: string;
  expires_at: string;
  /** Full public URL to give to third parties. */
  share_url: string;
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
  if (!raw.tenant_id || typeof raw.tenant_id !== "string") {
    throw new AppError(400, "missing_tenant_id", "tenant_id és obligatori");
  }
  if (!raw.document_id || typeof raw.document_id !== "string") {
    throw new AppError(400, "missing_document_id", "document_id és obligatori");
  }
  if (!raw.document_version_id || typeof raw.document_version_id !== "string") {
    throw new AppError(400, "missing_version_id", "document_version_id és obligatori");
  }
  const expiry = raw.expiry_seconds != null ? Number(raw.expiry_seconds) : undefined;
  if (expiry !== undefined && (isNaN(expiry) || expiry <= 0)) {
    throw new AppError(400, "invalid_expiry", "expiry_seconds ha de ser un número positiu");
  }
  return {
    tenant_id:           raw.tenant_id as string,
    document_id:         raw.document_id as string,
    document_version_id: raw.document_version_id as string,
    expiry_seconds:      expiry,
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

    // ── 1. Authenticate ───────────────────────────────────────────────────────
    const userClient = createUserClient(req);
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      return jsonError(401, "unauthorized", "Token invàlid o expirat");
    }

    // ── 2. Validate tenant context (header vs body) ───────────────────────────
    const headerTenantId = req.headers.get("x-tenant-id");
    if (headerTenantId && headerTenantId !== body.tenant_id) {
      return jsonError(403, "tenant_mismatch", "tenant_id no coincideix amb el context actiu");
    }

    // ── 3. Call SECURITY DEFINER RPC (validates role + document ownership) ─────
    const expirySeconds = Math.min(
      body.expiry_seconds ?? DEFAULT_EXPIRY_SECONDS,
      MAX_EXPIRY_SECONDS,
    );

    // We use userClient so auth.uid() is set correctly inside the SECURITY DEFINER RPC.
    const { data, error: rpcError } = await userClient.rpc(
      "create_document_share_link",
      {
        p_tenant_id:           body.tenant_id,
        p_document_id:         body.document_id,
        p_document_version_id: body.document_version_id,
        p_expiry_seconds:      expirySeconds,
      },
    );

    if (rpcError) {
      // Map known exception messages to HTTP responses
      if (rpcError.message?.includes("insufficient_permissions")) {
        return jsonError(403, "insufficient_permissions", "Cal rol owner o manager per crear links de compartició");
      }
      if (rpcError.message?.includes("document_not_found")) {
        return jsonError(404, "document_not_found", "Document no trobat");
      }
      if (rpcError.message?.includes("version_not_found_or_not_native")) {
        return jsonError(422, "version_not_native", "Els links de compartició requereixen una versió en emmagatzematge natiu");
      }
      if (rpcError.message?.includes("tenant_mismatch")) {
        return jsonError(403, "tenant_mismatch", "Context de tenant incorrecte");
      }
      log("error", FEATURE, "create_document_share_link RPC error", {
        tenantId: body.tenant_id,
        extra: { error: rpcError.message },
      });
      return jsonError(500, "rpc_error", "No s'ha pogut crear el link de compartició");
    }

    if (!data || data.length === 0) {
      return jsonError(500, "empty_result", "RPC ha retornat resultat buit");
    }

    const link = data[0] as { id: string; token: string; expires_at: string };

    // ── 4. Construct the public resolver URL ──────────────────────────────────
    const shareUrl = `${FUNCTIONS_BASE_PUBLIC}/functions/v1/resolve-document-share?token=${link.token}`;

    const response: ShareLinkResponse = {
      id:         link.id,
      token:      link.token,
      expires_at: link.expires_at,
      share_url:  shareUrl,
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
