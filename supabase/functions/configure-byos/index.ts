import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  HeadBucketCommand,
  PutBucketCorsCommand,
  S3Client,
} from "npm:@aws-sdk/client-s3";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";

const FEATURE = "configure-byos";

type ProviderType = "s3" | "r2" | "gcs";

const VALID_PROVIDERS: ProviderType[] = ["s3", "r2", "gcs"];

interface RequestBody {
  tenant_id: string;
  provider_type: ProviderType;
  /** Required for r2 and gcs; optional for custom s3-compatible endpoints */
  endpoint_url?: string | null;
  region?: string | null;
  bucket_name: string;
  /** Public access key ID — stored in plaintext; optional when updating without credential change */
  access_key?: string | null;
  /** Secret access key — stored in Vault, never persisted in plaintext; optional when updating without credential change */
  secret_access_key?: string | null;
  /** If set, UPDATE the existing provider; if absent, INSERT a new one */
  provider_id?: string | null;
  /** Human-readable label for the drive */
  nickname?: string | null;
  /** Per-drive MIME type allow-list; null means use global defaults */
  allowed_mime_types?: string[] | null;
  /** Max file size in bytes for this drive */
  max_file_size_bytes?: number | null;
  /** Optional quota cap for this drive in bytes */
  quota_limit_bytes?: number | null;
}

// ---------------------------------------------------------------------------
// Error classes
// ---------------------------------------------------------------------------

class ValidationError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ValidationError";
  }
}

class CredentialError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CredentialError";
  }
}

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorResponse(
  status: number,
  code: string,
  message: string,
): Response {
  return jsonResponse(status, { error: { code, message } });
}

// ---------------------------------------------------------------------------
// Body parsing & validation
// ---------------------------------------------------------------------------

async function parseBody(req: Request): Promise<RequestBody> {
  let raw: Record<string, unknown>;
  try {
    raw = await req.json();
  } catch {
    throw new ValidationError("invalid_json", "Request body must be valid JSON");
  }

  const {
    tenant_id,
    provider_type,
    endpoint_url,
    region,
    bucket_name,
    access_key,
    secret_access_key,
    provider_id,
    nickname,
    allowed_mime_types,
    max_file_size_bytes,
    quota_limit_bytes,
  } = raw as Partial<RequestBody>;

  if (!tenant_id || typeof tenant_id !== "string") {
    throw new ValidationError("missing_field", "tenant_id is required");
  }
  if (!provider_type || !VALID_PROVIDERS.includes(provider_type)) {
    throw new ValidationError(
      "invalid_provider_type",
      `provider_type must be one of: ${VALID_PROVIDERS.join(", ")}`,
    );
  }
  if ((provider_type === "r2" || provider_type === "gcs") && !endpoint_url) {
    throw new ValidationError(
      "missing_field",
      `endpoint_url is required for provider_type '${provider_type}'`,
    );
  }
  if (!bucket_name || typeof bucket_name !== "string") {
    throw new ValidationError("missing_field", "bucket_name is required");
  }
  // Credentials are only required for new providers; edits may preserve existing creds
  const isEdit = typeof provider_id === "string" && provider_id.length > 0;
  if (!isEdit) {
    if (!access_key || typeof access_key !== "string") {
      throw new ValidationError("missing_field", "access_key is required");
    }
    if (!secret_access_key || typeof secret_access_key !== "string") {
      throw new ValidationError(
        "missing_field",
        "secret_access_key is required",
      );
    }
  }

  return {
    tenant_id,
    provider_type,
    endpoint_url: endpoint_url ?? null,
    region: region ?? null,
    bucket_name,
    access_key: typeof access_key === "string" && access_key.length > 0 ? access_key : null,
    secret_access_key: typeof secret_access_key === "string" && secret_access_key.length > 0 ? secret_access_key : null,
    provider_id: typeof provider_id === "string" ? provider_id : null,
    nickname: typeof nickname === "string" ? nickname : null,
    allowed_mime_types: Array.isArray(allowed_mime_types) ? allowed_mime_types as string[] : null,
    max_file_size_bytes: typeof max_file_size_bytes === "number" ? max_file_size_bytes : null,
    quota_limit_bytes: typeof quota_limit_bytes === "number" ? quota_limit_bytes : null,
  };
}

// ---------------------------------------------------------------------------
// S3 / R2 / GCS credential validation via HeadBucket
// ---------------------------------------------------------------------------

async function buildS3Client(body: RequestBody): Promise<S3Client> {
  const clientConfig: ConstructorParameters<typeof S3Client>[0] = {
    region: body.region ?? "us-east-1",
    credentials: {
      accessKeyId: body.access_key!,
      secretAccessKey: body.secret_access_key!,
    },
  };

  if (body.endpoint_url) {
    clientConfig.endpoint = body.endpoint_url;
    clientConfig.forcePathStyle = body.provider_type === "r2";
  }

  return new S3Client(clientConfig);
}

async function validateCredentials(body: RequestBody): Promise<void> {
  const s3 = await buildS3Client(body);

  try {
    await s3.send(new HeadBucketCommand({ Bucket: body.bucket_name }));
  } catch (err: unknown) {
    // AWS SDK v3 errors are objects; cast to access metadata fields
    const awsErr = err as {
      name?: string;
      Code?: string;
      $metadata?: { httpStatusCode?: number };
    };

    const code = awsErr?.name ?? awsErr?.Code ?? "UnknownError";
    const httpStatus = awsErr?.$metadata?.httpStatusCode ?? 0;

    if (
      code === "InvalidAccessKeyId" ||
      code === "SignatureDoesNotMatch" ||
      code === "ExpiredToken" ||
      code === "InvalidClientTokenId" ||
      httpStatus === 401
    ) {
      throw new CredentialError(
        `Invalid credentials: ${code}. Check your access_key and secret_access_key.`,
      );
    }

    if (httpStatus === 404 || code === "NoSuchBucket") {
      throw new CredentialError(
        `Bucket '${body.bucket_name}' does not exist or is not accessible with the provided credentials.`,
      );
    }

    if (httpStatus === 403) {
      throw new CredentialError(
        `Access denied to bucket '${body.bucket_name}'. ` +
          `Ensure the access key has at minimum s3:GetBucketLocation (or s3:HeadBucket) permission.`,
      );
    }

    // Network/DNS/timeout — surface the raw message
    const msg = err instanceof Error ? err.message : String(err);
    throw new CredentialError(
      `Could not connect to storage endpoint: ${msg}`,
    );
  }
}

// ---------------------------------------------------------------------------
// Automatic CORS configuration on the bucket
// This ensures the browser can PUT directly to the bucket via pre-signed URL.
// We allow all origins because pre-signed URL security relies on the signature.
// Failures are non-fatal: some S3-compatible providers don't support the API.
// ---------------------------------------------------------------------------

async function applyBucketCors(body: RequestBody): Promise<void> {
  const s3 = await buildS3Client(body);
  try {
    await s3.send(
      new PutBucketCorsCommand({
        Bucket: body.bucket_name,
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
    log("warn", FEATURE, "CORS setup failed (non-critical)", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
  }
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const url = new URL(req.url);

  // DELETE /configure-byos?provider_id=<uuid>&tenant_id=<uuid>
  if (req.method === "DELETE") {
    try {
      const providerId = url.searchParams.get("provider_id");
      const tenantId = url.searchParams.get("tenant_id");

      if (!providerId || !tenantId) {
        return errorResponse(400, "missing_field", "provider_id and tenant_id are required");
      }

      const userClient = createUserClient(req);
      const { data: { user }, error: authError } = await userClient.auth.getUser();
      if (authError || !user) {
        return errorResponse(401, "unauthorized", "Invalid or missing Authorization token");
      }

      const { data: membership } = await userClient
        .from("tenant_members")
        .select("role")
        .eq("tenant_id", tenantId)
        .eq("user_id", user.id)
        .eq("is_active", true)
        .maybeSingle();

      if (!membership || membership.role !== "owner") {
        return errorResponse(403, "forbidden", "Only tenant owners can delete storage providers");
      }

      const adminClient = createAdminClient();
      const { error: rpcError } = await adminClient.rpc("delete_storage_config", {
        p_provider_id: providerId,
        p_tenant_id: tenantId,
      });

      if (rpcError) {
        if (rpcError.message?.includes("provider_not_found")) {
          return errorResponse(404, "provider_not_found", "Provider not found");
        }
        if (rpcError.message?.includes("cannot_delete_default_provider")) {
          return errorResponse(400, "cannot_delete_default_provider", "Cannot delete the default Supabase provider");
        }
        log("error", FEATURE, "delete_storage_config RPC error", {
          tenantId,
          extra: { error: rpcError.message },
        });
        return errorResponse(500, "rpc_error", rpcError.message);
      }

      return jsonResponse(200, { message: "Storage provider deleted successfully" });
    } catch (err) {
      log("error", FEATURE, "Unexpected DELETE error", { extra: { error: String(err) } });
      captureException(err, { feature: FEATURE });
      return errorResponse(500, "internal_error", "An unexpected error occurred");
    }
  }

  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Only POST and DELETE are allowed");
  }

  try {
    // 1. Parse + validate body
    const body = await parseBody(req);

    // 2. Authenticate — verify JWT and get caller identity
    const userClient = createUserClient(req);
    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser();

    if (authError || !user) {
      return errorResponse(
        401,
        "unauthorized",
        "Invalid or missing Authorization token",
      );
    }

    // 3. Authorise — caller must be the tenant owner
    // RLS on tenant_members ensures the query only returns the current user's row
    const { data: membership, error: memberError } = await userClient
      .from("tenant_members")
      .select("role")
      .eq("tenant_id", body.tenant_id)
      .eq("user_id", user.id)
      .eq("is_active", true)
      .maybeSingle();

    if (memberError) {
      log("error", FEATURE, "Membership check error", {
        tenantId: body.tenant_id,
        extra: { error: memberError?.message },
      });
      return errorResponse(
        500,
        "internal_error",
        "Could not verify tenant membership",
      );
    }
    if (!membership || membership.role !== "owner") {
      return errorResponse(
        403,
        "forbidden",
        "Only tenant owners can configure storage providers",
      );
    }

    // 4. Validate credentials + set CORS only when new credentials are provided.
    //    Editing an existing provider without touching credentials skips this step —
    //    the credentials were already validated when the provider was first saved.
    const hasNewCredentials = !!(body.access_key && body.secret_access_key);
    if (hasNewCredentials || !body.provider_id) {
      await validateCredentials(body);
      await applyBucketCors(body);
    }

    // 5. Persist via privileged RPC (Step 3+4 per spec)
    //    The RPC stores the secret in Vault and upserts data.storage_providers
    const adminClient = createAdminClient();
    const { data: providerId, error: rpcError } = await adminClient.rpc(
      "save_storage_config",
      {
        p_tenant_id: body.tenant_id,
        p_provider_type: body.provider_type,
        p_endpoint_url: body.endpoint_url,
        p_region: body.region,
        p_bucket_name: body.bucket_name,
        p_access_key: body.access_key,
        p_secret_access_key: body.secret_access_key,
        p_provider_id: body.provider_id ?? null,
        p_nickname: body.nickname ?? null,
        p_allowed_mime_types: body.allowed_mime_types ?? null,
        p_max_file_size_bytes: body.max_file_size_bytes ?? null,
        p_quota_limit_bytes: body.quota_limit_bytes ?? null,
      },
    );

    if (rpcError) {
      log("error", FEATURE, "save_storage_config RPC error", {
        tenantId: body.tenant_id,
        extra: { error: rpcError.message },
      });
      await createOperationLogService(adminClient).log({
        tenantId: body.tenant_id,
        integrationType: "storage",
        operationCode: "save_byos_config",
        status: "failed",
        title: "No s'ha pogut desar la configuració d'emmagatzematge BYOS",
        message: rpcError.message.slice(0, 200),
        errorCode: "save_storage_config_failed",
        isRetryable: false,
      }).catch(() => undefined);
      return errorResponse(500, "rpc_error", rpcError.message);
    }

    return jsonResponse(201, {
      provider_id: providerId,
      message: "Storage provider configured and verified successfully",
    });
  } catch (err: unknown) {
    if (err instanceof ValidationError) {
      return errorResponse(400, err.code, err.message);
    }
    if (err instanceof CredentialError) {
      // Step 2 per spec: return 400 Bad Request with error details on failure
      return errorResponse(400, "credential_validation_failed", err.message);
    }
    log("error", FEATURE, "Unexpected error", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    captureException(err, { feature: FEATURE });
    return errorResponse(500, "internal_error", "An unexpected error occurred");
  }
});
