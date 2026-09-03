import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import { HeadObjectCommand, S3Client } from "npm:@aws-sdk/client-s3";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "confirm-upload";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface RequestBody {
  file_id: string;
}

interface PendingFile {
  id: string;
  tenant_id: string;
  storage_key: string;
  storage_provider_id: string | null;
  processing_status: string;
}

interface StorageProvider {
  id: string;
  provider_type: string;
  endpoint_url: string | null;
  bucket_name: string;
  access_key: string;
  secret_key: string;
  region: string | null;
}

interface ConfirmResponse {
  node_id: string;
  size_bytes: number;
  processing_status: "done";
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/** Default Supabase Storage bucket for all non-BYOS tenants */
const DEFAULT_BUCKET = "tenant-files";

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
// Body parsing & validation
// ---------------------------------------------------------------------------

async function parseBody(req: Request): Promise<RequestBody> {
  let raw: Record<string, unknown>;
  try {
    raw = await req.json();
  } catch {
    throw new AppError(400, "invalid_json", "Request body must be valid JSON");
  }

  const { file_id } = raw as Partial<RequestBody>;

  if (!file_id || typeof file_id !== "string") {
    throw new AppError(400, "missing_field", "file_id is required");
  }

  // Basic UUID format guard
  const UUID_RE =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!UUID_RE.test(file_id)) {
    throw new AppError(400, "invalid_field", "file_id must be a valid UUID");
  }

  return { file_id };
}

// ---------------------------------------------------------------------------
// BYOS verification — HeadObjectCommand via AWS SDK v3
// ---------------------------------------------------------------------------

async function verifyByosObject(
  provider: StorageProvider,
  storageKey: string,
): Promise<number> {
  const clientConfig: ConstructorParameters<typeof S3Client>[0] = {
    region: provider.region ?? "us-east-1",
    credentials: {
      accessKeyId: provider.access_key,
      secretAccessKey: provider.secret_key,
    },
  };

  if (provider.endpoint_url) {
    clientConfig.endpoint = provider.endpoint_url;
    clientConfig.forcePathStyle = provider.provider_type === "r2";
  }

  const s3 = new S3Client(clientConfig);

  try {
    const response = await s3.send(
      new HeadObjectCommand({
        Bucket: provider.bucket_name,
        Key: storageKey,
      }),
    );

    // ContentLength may be undefined for 0-byte objects; treat those as 0
    return response.ContentLength ?? 0;
  } catch (err: unknown) {
    const awsErr = err as {
      name?: string;
      $metadata?: { httpStatusCode?: number };
    };

    const httpStatus = awsErr?.$metadata?.httpStatusCode ?? 0;

    if (httpStatus === 404 || awsErr?.name === "NoSuchKey") {
      throw new AppError(
        404,
        "object_not_found",
        `File '${storageKey}' was not found in bucket '${provider.bucket_name}'. ` +
          "The upload may not have completed.",
      );
    }

    if (httpStatus === 403) {
      throw new AppError(
        502,
        "storage_access_denied",
        "Access denied when verifying the object in the external bucket. " +
          "Check the storage provider credentials.",
      );
    }

    const msg = err instanceof Error ? err.message : String(err);
    throw new AppError(
      502,
      "storage_unreachable",
      `Could not connect to storage endpoint: ${msg}`,
    );
  }
}

// ---------------------------------------------------------------------------
// Supabase Storage (default) verification — HEAD request via Storage REST API
// ---------------------------------------------------------------------------

async function verifySupabaseObject(storageKey: string): Promise<number> {
  const url =
    `${SUPABASE_URL}/storage/v1/object/${DEFAULT_BUCKET}/${storageKey}`;

  const response = await fetch(url, {
    method: "HEAD",
    headers: {
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    },
  });

  if (response.status === 404) {
    throw new AppError(
      404,
      "object_not_found",
      `File '${storageKey}' was not found in Supabase Storage. ` +
        "The upload may not have completed.",
    );
  }

  if (!response.ok) {
    throw new AppError(
      502,
      "storage_error",
      `Supabase Storage returned HTTP ${response.status} while verifying object.`,
    );
  }

  const contentLength = response.headers.get("Content-Length");
  return contentLength ? parseInt(contentLength, 10) : 0;
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
    return jsonError(405, "method_not_allowed", "Only POST is allowed");
  }

  try {
    // 1. Parse + validate body
    const body = await parseBody(req);

    // 2. Task 1: Authenticate via user JWT
    const userClient = createUserClient(req);
    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser();

    if (authError || !user) {
      return jsonError(
        401,
        "unauthorized",
        "Invalid or missing Authorization token",
      );
    }

    const adminClient = createAdminClient();

    // 3. Task 2: Fetch pending file details via privileged RPC.
    //    The RPC validates that the user is a member of the tenant that owns
    //    the file, preventing access to files belonging to other tenants.
    const { data: fileRows, error: fileError } = await adminClient.rpc(
      "get_pending_file",
      {
        p_file_id: body.file_id,
        p_user_id: user.id,
      },
    );

    if (fileError) {
      log("error", FEATURE, "get_pending_file RPC error", {
        extra: { error: fileError.message },
      });
      return jsonError(500, "rpc_error", fileError.message);
    }

    if (!fileRows || fileRows.length === 0) {
      // Intentionally vague: don't reveal whether the file exists at all
      return jsonError(
        404,
        "file_not_found",
        "File not found, not in pending status, or you do not have access to it",
      );
    }

    const file = fileRows[0] as PendingFile;

    // 4. Task 3 + 4 + 5 + 6: Verify the object in storage and get its actual size
    let actualSizeBytes: number;

    if (file.storage_provider_id) {
      // BYOS path: get provider credentials from Vault then check S3/R2/GCS
      const { data: providerRows, error: providerError } =
        await adminClient.rpc("get_storage_provider_with_secret", {
          p_tenant_id: file.tenant_id,
        });

      if (providerError || !providerRows || providerRows.length === 0) {
        log("error", FEATURE, "get_storage_provider_with_secret error", {
          tenantId: file.tenant_id,
          extra: { error: providerError?.message },
        });
        return jsonError(
          500,
          "provider_not_found",
          "Could not retrieve storage provider configuration",
        );
      }

      const provider = providerRows[0] as StorageProvider;
      // Task 4 + 5 + 6: HeadObject → ContentLength or throw 404/502
      actualSizeBytes = await verifyByosObject(provider, file.storage_key);
    } else {
      // Default Supabase Storage path
      // Task 4 + 5 + 6: HEAD request → Content-Length or throw 404/502
      actualSizeBytes = await verifySupabaseObject(file.storage_key);
    }

    // 5. Task 7: Mark the file as done and update size_bytes in the database.
    //    The existing update_file_nodes_storage_usage trigger automatically
    //    moves reserved_bytes → committed_bytes on the pending → done transition.
    const { data: markedId, error: markError } = await adminClient.rpc(
      "mark_file_as_done",
      {
        p_file_id: body.file_id,
        p_actual_size: actualSizeBytes,
      },
    );

    if (markError) {
      log("error", FEATURE, "mark_file_as_done RPC error", {
        tenantId: file.tenant_id,
        extra: { error: markError.message },
      });

      if (markError.message?.includes("file_not_found_or_not_pending")) {
        return jsonError(
          409,
          "already_processed",
          "This file has already been confirmed or was cancelled",
        );
      }
      return jsonError(500, "rpc_error", markError.message);
    }

    const successResponse: ConfirmResponse = {
      node_id: markedId as string,
      size_bytes: actualSizeBytes,
      processing_status: "done",
    };

    return new Response(JSON.stringify(successResponse), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err: unknown) {
    if (err instanceof AppError) {
      return jsonError(err.status, err.code, err.message);
    }
    const message = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "Unexpected error", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return jsonError(500, "internal_error", "An unexpected error occurred");
  }
});
