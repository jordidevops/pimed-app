import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient, createAdminClient } from "../_shared/supabase.ts";
import { S3Client, PutObjectCommand, PutBucketCorsCommand } from "npm:@aws-sdk/client-s3";
import { getSignedUrl } from "npm:@aws-sdk/s3-request-presigner";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "request-upload";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface RequestBody {
  tenant_id: string;
  parent_id?: string | null;
  file_name: string;
  mime_type?: string;
  size_bytes: number;
  metadata?: Record<string, unknown>;
  /**
   * Drive routing semantics:
   * - undefined: legacy behavior (backend may resolve tenant default BYOS)
   * - null: explicit App Drive (Supabase internal storage)
   * - string: explicit BYOS drive id
   */
  storage_provider_id?: string | null;
}

interface UploadResponse {
  upload_url: string;
  method: "PUT";
  node_id: string;
  storage_key: string;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const UPLOAD_EXPIRY_MINUTES = 30;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// En local dev SUPABASE_URL és http://kong:8000 (intern Docker).
// EXT_SUPABASE_URL sobreescriu l'URL base de les signed URLs retornades al browser.
// En producció no cal definir-la: SUPABASE_URL ja és pública.
const SUPABASE_PUBLIC_URL = Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  initObservability();

  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return error(405, "method_not_allowed", "Només POST");
  }

  try {
    // 1. Parse & validate body
    const body = await parseBody(req);

    // 2. Create clients
    const userClient = createUserClient(req);
    const adminClient = createAdminClient();

    // 3. Authenticate — get user from JWT
    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser();
    if (authError || !user) {
      return error(401, "unauthorized", "Token invàlid o expirat");
    }

    // 4. Kill Switch + Quota check (single query via adminClient)
    await checkKillSwitchAndQuota(adminClient, body.tenant_id, body.size_bytes);

    // 5. Verify membership via userClient (RLS does this implicitly)
    const { data: membership, error: memberError } = await userClient
      .from("tenant_members")
      .select("role")
      .eq("tenant_id", body.tenant_id)
      .eq("user_id", user.id)
      .eq("is_active", true)
      .single();

    if (memberError || !membership) {
      return error(403, "not_a_member", "No ets membre d'aquest tenant");
    }

    if (membership.role === "viewer") {
      return error(403, "forbidden", "Els viewers no poden pujar fitxers");
    }

    // 6. Generate storage_key and compute upload_expires_at
    const nodeId = crypto.randomUUID();
    const storageKey = `${body.tenant_id}/${nodeId}/${sanitizeFileName(body.file_name)}`;
    const uploadExpiresAt = new Date(
      Date.now() + UPLOAD_EXPIRY_MINUTES * 60 * 1000
    ).toISOString();

    // 7. Check if tenant has a BYOS provider (or use specific drive)
    const provider = await getStorageProvider(adminClient, body.tenant_id, body.storage_provider_id);

    // 7a. Per-drive validations
    if (provider) {
      if (provider.is_locked) {
        return error(403, "drive_locked", "Aquesta unitat està bloquejada. No s'hi poden pujar fitxers.");
      }

      if (provider.max_file_size_bytes != null && body.size_bytes > provider.max_file_size_bytes) {
        return error(
          413,
          "file_too_large",
          `El fitxer supera la mida màxima d'aquesta unitat (${formatBytes(provider.max_file_size_bytes)})`
        );
      }

      if (provider.allowed_mime_types != null && provider.allowed_mime_types.length > 0 && body.mime_type) {
        if (!provider.allowed_mime_types.includes(body.mime_type)) {
          return error(415, "mime_type_not_allowed", `Tipus de fitxer no permès en aquesta unitat: ${body.mime_type}`);
        }
      }
    } else {
      // 7b. Internal bucket — check per-tenant admin limits (file size + MIME type)
      await checkInternalLimits(adminClient, body.tenant_id, body.size_bytes, body.mime_type);
    }

    // 8. INSERT file_node (pending) via RPC — bypasses RLS and the api.file_nodes
    //    view INSERT rule to set all required columns directly on data.file_nodes
    const { error: insertError } = await adminClient
      .rpc("create_pending_upload", {
        p_id: nodeId,
        p_tenant_id: body.tenant_id,
        p_parent_id: body.parent_id ?? null,
        p_created_by: user.id,
        p_name: body.file_name,
        p_storage_provider_id: provider?.id ?? null,
        p_storage_key: storageKey,
        p_mime_type: body.mime_type ?? null,
        p_size_bytes: body.size_bytes,
        p_upload_expires_at: uploadExpiresAt,
        p_metadata: body.metadata ?? null,
      });

    if (insertError) {
      // Handle known DB errors
      if (insertError.message?.includes("pending_upload_limit_exceeded")) {
        return error(429, "pending_upload_limit_exceeded", "Massa uploads pendents (màx 50)");
      }
      if (insertError.code === "23505") {
        return error(409, "duplicate_name", "Ja existeix un node amb aquest nom a la mateixa carpeta");
      }
      log("error", FEATURE, "INSERT error", {
        tenantId: body.tenant_id,
        extra: { error: insertError.message },
      });
      return error(500, "insert_failed", "No s'ha pogut crear el node");
    }

    // 9. Generate pre-signed upload URL
    //    For BYOS providers: ensure CORS is configured on the bucket first (non-fatal).
    //    This self-heals buckets that were configured before automatic CORS was introduced.
    if (provider) {
      await ensureBucketCors(provider);
    }
    const uploadUrl = provider
      ? await generateByosUrl(provider, storageKey, body.mime_type)
      : await generateSupabaseUrl(storageKey);

    // 10. Return response
    const response: UploadResponse = {
      upload_url: uploadUrl,
      method: "PUT",
      node_id: nodeId,
      storage_key: storageKey,
    };

    return new Response(JSON.stringify(response), {
      status: 201,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    if (e instanceof AppError) {
      return error(e.status, e.code, e.message);
    }
    const message = e instanceof Error ? e.message : String(e);
    log("error", FEATURE, "Unexpected error", { extra: { error: message } });
    captureException(e, { feature: FEATURE });
    return error(500, "internal_error", "Error intern del servidor");
  }
});

// ---------------------------------------------------------------------------
// Parse & Validate
// ---------------------------------------------------------------------------

function parseBody(req: Request): Promise<RequestBody> {
  return req.json().then((body: Record<string, unknown>) => {
    if (!body.tenant_id || typeof body.tenant_id !== "string") {
      throw new AppError(400, "invalid_tenant_id", "tenant_id és obligatori");
    }
    if (!body.file_name || typeof body.file_name !== "string") {
      throw new AppError(400, "invalid_file_name", "file_name és obligatori");
    }
    if (typeof body.size_bytes !== "number" || body.size_bytes <= 0) {
      throw new AppError(400, "invalid_size", "size_bytes ha de ser un número positiu");
    }

    const hasStorageProviderId = Object.prototype.hasOwnProperty.call(body, "storage_provider_id");
    const rawStorageProviderId = body.storage_provider_id;
    const storageProviderId = !hasStorageProviderId
      ? undefined
      : typeof rawStorageProviderId === "string"
        ? rawStorageProviderId
        : null;

    return {
      tenant_id: body.tenant_id,
      parent_id: typeof body.parent_id === "string" ? body.parent_id : null,
      file_name: body.file_name,
      mime_type: typeof body.mime_type === "string" ? body.mime_type : undefined,
      size_bytes: body.size_bytes,
      metadata: typeof body.metadata === "object" && body.metadata !== null
        ? body.metadata as Record<string, unknown>
        : undefined,
      storage_provider_id: storageProviderId,
    };
  });
}

// ---------------------------------------------------------------------------
// Kill Switch + Quota (single query)
// ---------------------------------------------------------------------------

async function checkKillSwitchAndQuota(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
  sizeBytes: number
) {
  // Single SQL query via adminClient — bypasses RLS
  const { data, error: queryError } = await adminClient
    .rpc("check_upload_eligibility", {
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
    throw new AppError(403, "storage_blocked", result.storage_blocked_reason ?? "Storage bloquejat per l'administrador");
  }

  if (result.quota_exceeded) {
    throw new AppError(
      413,
      "quota_exceeded",
      `Quota superada: ${formatBytes(result.current_bytes)} / ${formatBytes(result.max_bytes)} usats`
    );
  }
}

// ---------------------------------------------------------------------------
// Storage Provider (via RPC that joins with vault)
// ---------------------------------------------------------------------------

interface StorageProvider {
  id: string;
  provider_type: string;
  endpoint_url: string | null;
  bucket_name: string | null;
  access_key: string | null;
  secret_key: string | null;
  region: string | null;
  allowed_mime_types: string[] | null;
  max_file_size_bytes: number | null;
  is_locked: boolean;
}

async function getStorageProvider(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
  providerId?: string | null
): Promise<StorageProvider | null> {
  // Explicit null means "use App Drive" (no BYOS) from the UI selector.
  if (providerId === null) {
    return null;
  }

  const params = providerId
    ? { p_provider_id: providerId }
    : { p_tenant_id: tenantId };

  const { data } = await adminClient
    .rpc("get_storage_provider_with_secret", params);

  if (!data || data.length === 0) return null;
  return data[0] as StorageProvider;
}

// ---------------------------------------------------------------------------
// Internal bucket limits (admin-controlled per-tenant overrides)
// ---------------------------------------------------------------------------

async function checkInternalLimits(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
  sizeBytes: number,
  mimeType?: string | null
) {
  const { data, error: queryError } = await adminClient
    .rpc("get_internal_limits", { p_tenant_id: tenantId });

  if (queryError) {
    log("warn", FEATURE, "get_internal_limits error (non-fatal)", {
      tenantId,
      extra: { error: queryError.message },
    });
    return; // Non-fatal: let the upload proceed if limits cannot be read
  }

  if (!data || data.length === 0) return; // No custom limits set

  const limits = data[0] as {
    internal_max_file_mb: number | null;
    internal_allowed_mimes: string[];
  };

  if (limits.internal_max_file_mb != null) {
    const maxBytes = limits.internal_max_file_mb * 1024 * 1024;
    if (sizeBytes > maxBytes) {
      throw new AppError(
        413,
        "file_too_large",
        `El fitxer supera la mida màxima del bucket intern (${formatBytes(maxBytes)})`
      );
    }
  }

  if (limits.internal_allowed_mimes.length > 0 && mimeType) {
    if (!limits.internal_allowed_mimes.includes(mimeType)) {
      throw new AppError(
        415,
        "mime_type_not_allowed",
        `Tipus de fitxer no permès al bucket intern: ${mimeType}`
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Pre-signed URL: Supabase Storage
// ---------------------------------------------------------------------------

async function generateSupabaseUrl(storageKey: string): Promise<string> {
  // Use the REST API directly with service_role key to create a signed upload URL.
  // supabase-js .storage.from().createSignedUploadUrl() returns a token-based URL.
  const res = await fetch(
    `${SUPABASE_URL}/storage/v1/object/upload/sign/tenant-files/${storageKey}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    }
  );

  if (!res.ok) {
    const body = await res.text();
    log("error", FEATURE, "Supabase Storage sign error", {
      extra: { status: res.status, body: body.slice(0, 200) },
    });
    throw new AppError(502, "storage_sign_failed", "No s'ha pogut generar la URL de pujada");
  }

  const { url } = await res.json();

  // The returned URL is relative ("/object/upload/sign/...?token=...")
  // Use SUPABASE_PUBLIC_URL so the browser can reach it (in local dev, SUPABASE_URL is kong:8000).
  return `${SUPABASE_PUBLIC_URL}/storage/v1${url}`;
}

// ---------------------------------------------------------------------------
// Pre-signed URL: BYOS (S3 / R2 / GCS)
// ---------------------------------------------------------------------------

function buildByosS3Client(provider: StorageProvider): S3Client {
  return new S3Client({
    region: provider.region ?? "auto",
    endpoint: provider.endpoint_url ?? undefined,
    credentials: {
      accessKeyId: provider.access_key,
      secretAccessKey: provider.secret_key,
    },
    // R2 / MinIO compatibility
    forcePathStyle: provider.provider_type === "r2",
    // Disable automatic CRC32 checksum injection.
    // When enabled, the SDK adds x-amz-checksum-crc32 / x-amz-sdk-checksum-algorithm
    // headers to the signed URL query string, which the browser must then send as
    // request headers. This triggers a CORS preflight that fails on most
    // S3-compatible providers unless their CORS policy explicitly lists those headers.
    // Setting "when_required" only computes checksums for operations that mandate them.
    requestChecksumCalculation: "when_required",
  });
}

/** Apply CORS policy to the bucket so browsers can PUT via pre-signed URL.
 *  Non-fatal: logs a warning if the provider doesn't support PutBucketCors. */
async function ensureBucketCors(provider: StorageProvider): Promise<void> {
  if (!provider.bucket_name || !provider.access_key || !provider.secret_key) return;
  const s3 = buildByosS3Client(provider);
  try {
    await s3.send(
      new PutBucketCorsCommand({
        Bucket: provider.bucket_name,
        CORSConfiguration: {
          CORSRules: [
            {
              AllowedOrigins: ["*"],
              AllowedMethods: ["GET", "PUT", "HEAD", "DELETE"],
              AllowedHeaders: ["*"],
              ExposeHeaders: ["ETag", "Content-Length"],
              MaxAgeSeconds: 3600,
            },
          ],
        },
      }),
    );
  } catch (err) {
    log("warn", FEATURE, "ensureBucketCors: could not set CORS policy (non-fatal)", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
  }
}

async function generateByosUrl(
  provider: StorageProvider,
  storageKey: string,
  mimeType?: string | null
): Promise<string> {
  if (!provider.access_key || !provider.secret_key) {
    throw new AppError(
      500,
      "byos_credentials_missing",
      "Credencials BYOS no configurades correctament"
    );
  }

  const s3Client = buildByosS3Client(provider);

  const command = new PutObjectCommand({
    Bucket: provider.bucket_name!,
    Key: storageKey,
    ContentType: mimeType ?? "application/octet-stream",
  });

  const url = await getSignedUrl(s3Client, command, {
    expiresIn: UPLOAD_EXPIRY_MINUTES * 60,
    // Do not add unsigned payload headers; let the browser send the raw bytes.
    unhoistableHeaders: new Set([]),
  });

  return url;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class AppError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string
  ) {
    super(message);
  }
}

function error(status: number, code: string, message: string): Response {
  return new Response(JSON.stringify({ error: code, message }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function sanitizeFileName(name: string): string {
  // Remove path traversal, null bytes, and control characters
  return name
    .replace(/[/\\]/g, "_")
    .replace(/\0/g, "")
    .replace(/[\x00-\x1f\x7f]/g, "")
    .trim();
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}
