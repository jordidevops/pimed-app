/**
 * resolve-share — Public Edge Function (no JWT required)
 *
 * Validates a share token created by get-file-url, then redirects (302) the
 * visitor to a freshly-generated, short-lived (5 min) signed URL of the file.
 *
 * Flow:
 *   1. Extract token from ?token= query param
 *   2. Call api.resolve_share_link(token) — SECURITY DEFINER RPC that:
 *      - Updates accessed_at (audit trail)
 *      - Returns file routing info + is_expired flag
 *   3. If expired → 410 Gone
 *   4. Determine storage backend (Supabase or BYOS)
 *   5. Generate a fresh 5-min signed URL
 *   6. 302 redirect → browser fetches/downloads the file
 */

import { createAdminClient } from "../_shared/supabase.ts";
import { S3Client, GetObjectCommand } from "npm:@aws-sdk/client-s3";
import { getSignedUrl as s3SignedUrl } from "npm:@aws-sdk/s3-request-presigner";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "resolve-share";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_PUBLIC_URL = Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;

/** The freshly-generated redirect URL expires after 5 minutes. */
const FRESH_URL_EXPIRY_SECONDS = 300;

// resolve-share is a GET endpoint — override the POST-only CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

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
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "GET") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  try {
    const url = new URL(req.url);
    const token = url.searchParams.get("token") ?? "";

    // Token must be exactly 64 hex characters (32 bytes)
    if (!/^[0-9a-f]{64}$/.test(token)) {
      return new Response("Invalid token format", { status: 400 });
    }

    const adminClient = createAdminClient();

    // Resolve token — the SECURITY DEFINER RPC touches accessed_at atomically
    const { data, error: rpcError } = await adminClient.rpc(
      "resolve_share_link",
      { p_token: token },
    );

    if (rpcError) {
      log("error", FEATURE, "resolve_share_link RPC error", {
        extra: { error: rpcError.message },
      });
      return new Response("Internal server error", { status: 500 });
    }

    if (!data || data.length === 0) {
      return new Response("Link not found", { status: 404 });
    }

    const link = data[0] as {
      node_id: string;
      storage_key: string | null;
      file_name: string;
      mime_type: string | null;
      tenant_id: string;
      is_expired: boolean;
    };

    if (link.is_expired) {
      return new Response("Link expired", {
        status: 410,
        headers: { "Content-Type": "text/plain" },
      });
    }

    if (!link.storage_key) {
      return new Response("File not available", { status: 404 });
    }

    // Look up storage provider for this tenant (null = Supabase default)
    const provider = await getStorageProvider(adminClient, link.tenant_id);

    // Generate a fresh short-lived signed URL
    const signedUrl = provider
      ? await getByosSignedUrl(
        provider,
        link.storage_key,
        FRESH_URL_EXPIRY_SECONDS,
      )
      : await getSupabaseSignedUrl(
        link.storage_key,
        FRESH_URL_EXPIRY_SECONDS,
      );

    // Log egress event (fire-and-forget — never block the redirect on a log failure)
    adminClient.rpc("log_egress", {
      p_tenant_id:           link.tenant_id,
      p_node_id:             link.node_id,
      p_storage_provider_id: provider?.id ?? null,
      p_size_bytes:          0,
    }).catch((err: unknown) => {
      log("warn", FEATURE, "log_egress error", {
        tenantId: link.tenant_id,
        extra: { error: err instanceof Error ? err.message : String(err) },
      });
    });

    // 302 redirect — the browser downloads / displays the file directly
    return new Response(null, {
      status: 302,
      headers: { Location: signedUrl },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    log("error", FEATURE, "Unhandled error", { extra: { error: message } });
    captureException(e, { feature: FEATURE });
    return new Response("Internal server error", { status: 500 });
  }
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function getStorageProvider(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
): Promise<StorageProvider | null> {
  const { data } = await adminClient.rpc("get_storage_provider_with_secret", {
    p_tenant_id: tenantId,
  });
  if (!data || data.length === 0) return null;
  return data[0] as StorageProvider;
}

async function getSupabaseSignedUrl(
  storageKey: string,
  expiresIn: number,
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
    throw new Error("Failed to generate signed URL");
  }

  const { signedURL } = await res.json();
  return (signedURL as string).startsWith("/")
    ? `${SUPABASE_PUBLIC_URL}/storage/v1${signedURL}`
    : (signedURL as string);
}

async function getByosSignedUrl(
  provider: StorageProvider,
  storageKey: string,
  expiresIn: number,
): Promise<string> {
  if (!provider.access_key || !provider.secret_key) {
    throw new Error("BYOS credentials not configured");
  }

  const s3 = new S3Client({
    region: provider.region ?? "auto",
    endpoint: provider.endpoint_url ?? undefined,
    credentials: {
      accessKeyId: provider.access_key,
      secretAccessKey: provider.secret_key,
    },
    forcePathStyle: provider.provider_type === "r2",
  });

  return s3SignedUrl(s3, new GetObjectCommand({
    Bucket: provider.bucket_name!,
    Key: storageKey,
  }), { expiresIn });
}
