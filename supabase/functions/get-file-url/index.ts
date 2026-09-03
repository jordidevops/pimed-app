import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient, createAdminClient } from "../_shared/supabase.ts";
import { S3Client, GetObjectCommand } from "npm:@aws-sdk/client-s3";
import { getSignedUrl as s3SignedUrl } from "npm:@aws-sdk/s3-request-presigner";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "get-file-url";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// In local dev SUPABASE_URL is http://kong:8000 (internal Docker).
// EXT_SUPABASE_URL overrides the base URL returned to the browser.
const SUPABASE_PUBLIC_URL = Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;

/** Signed URLs > 7 days are unsupported by S3/R2/GCS — use a share token instead. */
const MAX_DIRECT_EXPIRY_SECONDS = 604_800; // 7 days

/** Hard cap to prevent absurdly long-lived tokens (10 years). */
const MAX_EXPIRY_SECONDS = 315_360_000;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface RequestBody {
  file_id: string;
  expiry_seconds: number;
  download?: boolean;
}

interface StorageProvider {
  id: string;
  provider_type: string;
  endpoint_url: string | null;
  bucket_name: string | null;
  access_key: string | null;
  secret_key: string | null;
  region: string | null;
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
  return new Response(JSON.stringify({ error: code, message }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonError(405, "method_not_allowed", "Només POST");
  }

  try {
    let body: RequestBody;
    try {
      body = await req.json();
    } catch {
      throw new AppError(400, "invalid_json", "Body JSON no vàlid");
    }

    if (!body.file_id || typeof body.file_id !== "string") {
      throw new AppError(400, "missing_file_id", "file_id és obligatori");
    }
    if (typeof body.expiry_seconds !== "number" || body.expiry_seconds <= 0) {
      throw new AppError(
        400,
        "invalid_expiry",
        "expiry_seconds ha de ser un número positiu",
      );
    }

    const expiry = Math.min(body.expiry_seconds, MAX_EXPIRY_SECONDS);

    const userClient = createUserClient(req);
    const adminClient = createAdminClient();

    // 1. Authenticate — validate JWT
    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser();
    if (authError || !user) {
      throw new AppError(401, "unauthorized", "Token invàlid o expirat");
    }

    // 2. Fetch file node — RLS on api.file_nodes enforces tenant membership
    const { data: node, error: nodeError } = await userClient
      .from("file_nodes")
      .select("id, tenant_id, name, mime_type, storage_key, storage_provider_id")
      .eq("id", body.file_id)
      .eq("node_type", "file")
      .single();

    if (nodeError || !node) {
      throw new AppError(404, "file_not_found", "Fitxer no trobat o sense accés");
    }

    if (!node.storage_key) {
      throw new AppError(
        422,
        "no_storage_key",
        "El fitxer no té clau d'emmagatzematge",
      );
    }

    const downloadFileName = body.download ? (node.name as string) : undefined;

    // 3. Short expiry (≤ 7 days) → direct signed URL
    if (expiry <= MAX_DIRECT_EXPIRY_SECONDS) {
      const provider = await getStorageProvider(
        adminClient,
        node.tenant_id as string,
        (node.storage_provider_id as string | null) ?? null,
      );
      const url = provider
        ? await getByosSignedUrl(
          provider,
          node.storage_key as string,
          expiry,
          downloadFileName,
        )
        : await getSupabaseSignedUrl(
          node.storage_key as string,
          expiry,
          downloadFileName,
        );

      // Fire-and-forget egress log
      void (async () => {
        const { error: logError } = await adminClient.rpc("log_egress", {
          p_tenant_id: node.tenant_id as string,
          p_node_id: body.file_id,
          p_storage_provider_id: provider?.id ?? null,
          p_size_bytes: 0,
        });
        if (logError) {
          log("warn", FEATURE, "log_egress error", {
            tenantId: node.tenant_id as string,
            extra: { error: logError.message },
          });
        }
      })();

      return new Response(
        JSON.stringify({ type: "signed", url, expires_in: expiry }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // 4. Long expiry (> 7 days) → persistent share token
    const expiresAt = new Date(Date.now() + expiry * 1000).toISOString();
    const token = generateSecureToken();

    const { error: rpcError } = await adminClient.rpc("create_share_link", {
      p_node_id: body.file_id,
      p_created_by: user.id,
      p_expires_at: expiresAt,
      p_token: token,
    });

    if (rpcError) {
      log("error", FEATURE, "create_share_link RPC error", {
        extra: { error: rpcError.message },
      });
      throw new AppError(
        500,
        "share_link_failed",
        "No s'ha pogut crear l'enllaç compartit",
      );
    }

    // Fire-and-forget egress log for share token creation
    void (async () => {
      const { error: logError } = await adminClient.rpc("log_egress", {
        p_tenant_id: node.tenant_id as string,
        p_node_id: body.file_id,
        p_storage_provider_id: null,
        p_size_bytes: 0,
      });
      if (logError) {
        log("warn", FEATURE, "log_egress error", {
          tenantId: node.tenant_id as string,
          extra: { error: logError.message },
        });
      }
    })();

    const shareUrl =
      `${SUPABASE_PUBLIC_URL}/functions/v1/resolve-share?token=${token}`;

    return new Response(
      JSON.stringify({ type: "share", url: shareUrl, expires_at: expiresAt }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (e) {
    if (e instanceof AppError) {
      return jsonError(e.status, e.code, e.message);
    }
    const message = e instanceof Error ? e.message : String(e);
    log("error", FEATURE, "Unexpected error", { extra: { error: message } });
    captureException(e, { feature: FEATURE });
    return jsonError(500, "internal_error", "Error intern del servidor");
  }
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Generates a 32-byte (256-bit) cryptographically secure hex token. */
function generateSecureToken(): string {
  const buf = new Uint8Array(32);
  crypto.getRandomValues(buf);
  return Array.from(buf).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function getStorageProvider(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
  providerId?: string | null,
): Promise<StorageProvider | null> {
  // Explicit null means the file belongs to App Drive (Supabase bucket).
  if (providerId === null) {
    return null;
  }

  const params = providerId
    ? { p_provider_id: providerId }
    : { p_tenant_id: tenantId };

  const { data } = await adminClient.rpc("get_storage_provider_with_secret", params);
  if (!data || data.length === 0) return null;
  return data[0] as StorageProvider;
}

/**
 * Creates a signed GET URL via the Supabase Storage REST API.
 * Uses the internal SUPABASE_URL to reach kong in local Docker,
 * then rewrites the host with SUPABASE_PUBLIC_URL for the browser.
 */
async function getSupabaseSignedUrl(
  storageKey: string,
  expiresIn: number,
  downloadAs?: string,
): Promise<string> {
  const res = await fetch(
    `${SUPABASE_URL}/storage/v1/object/sign/tenant-files/${storageKey}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: SUPABASE_SERVICE_ROLE_KEY,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ expiresIn }),
    },
  );

  if (!res.ok) {
    const text = await res.text();
    log("error", FEATURE, "Storage sign error", {
      extra: { status: res.status, body: text.slice(0, 200) },
    });
    throw new AppError(502, "sign_url_failed", "No s'ha pogut generar la URL signada");
  }

  const { signedURL } = await res.json();
  // Storage may return a relative path OR an absolute URL with the internal
  // kong host. Always expose a browser-reachable URL.
  let url: string;
  const signed = signedURL as string;
  if (signed.startsWith("/")) {
    url = `${SUPABASE_PUBLIC_URL}/storage/v1${signed}`;
  } else {
    try {
      const parsed = new URL(signed);
      if (parsed.hostname === "kong" || parsed.hostname === "kong.local") {
        const pub = new URL(SUPABASE_PUBLIC_URL);
        parsed.protocol = pub.protocol;
        parsed.host = pub.host;
        url = parsed.toString();
      } else {
        url = signed;
      }
    } catch {
      url = signed.replace(/^https?:\/\/kong(?::\d+)?/i, SUPABASE_PUBLIC_URL);
    }
  }

  if (downloadAs) {
    url +=
      (url.includes("?") ? "&" : "?") +
      `download=${encodeURIComponent(downloadAs)}`;
  }

  return url;
}

/**
 * Creates a pre-signed GET URL for a BYOS S3/R2/GCS object.
 * The ResponseContentDisposition header forces download with the original filename.
 */
async function getByosSignedUrl(
  provider: StorageProvider,
  storageKey: string,
  expiresIn: number,
  downloadAs?: string,
): Promise<string> {
  if (!provider.access_key || !provider.secret_key) {
    throw new AppError(
      500,
      "byos_credentials_missing",
      "Credencials BYOS no configurades correctament",
    );
  }

  const s3 = new S3Client({
    region: provider.region ?? "auto",
    endpoint: provider.endpoint_url ?? undefined,
    credentials: {
      accessKeyId: provider.access_key,
      secretAccessKey: provider.secret_key,
    },
    // R2 and MinIO require path-style URLs
    forcePathStyle: provider.provider_type === "r2",
  });

  const cmd = new GetObjectCommand({
    Bucket: provider.bucket_name!,
    Key: storageKey,
    ...(downloadAs
      ? {
        ResponseContentDisposition: `attachment; filename="${
          downloadAs.replace(/"/g, '\\"')
        }"`,
      }
      : {}),
  });

  return s3SignedUrl(s3, cmd, { expiresIn });
}
