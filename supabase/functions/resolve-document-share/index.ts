import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "resolve-document-share";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_PUBLIC_URL = Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;
const DOCUMENTS_BUCKET = "documents";

// Signed URL lifetime after resolution (not the share link expiry)
const SIGNED_URL_TTL_SECONDS = 300; // 5 minutes

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function errorResponse(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Validates a 64-character lowercase hex token (256-bit random)
const HEX_64_RE = /^[0-9a-f]{64}$/;

// ---------------------------------------------------------------------------
// Main handler (no JWT required — verify_jwt = false in config.toml)
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  // Only GET is supported
  if (req.method !== "GET") {
    return errorResponse(405, "Method not allowed");
  }

  const url = new URL(req.url);
  const token = url.searchParams.get("token");

  if (!token || !HEX_64_RE.test(token)) {
    return errorResponse(400, "Invalid or missing token");
  }

  try {
    const adminClient = createAdminClient();

    // ── 1. Resolve the token (SECURITY DEFINER RPC) ───────────────────────────
    // resolve_document_share_link updates counters atomically and returns version info.
    const { data, error: rpcError } = await adminClient.rpc(
      "resolve_document_share_link",
      { p_token: token },
    );

    if (rpcError) {
      log("error", FEATURE, "resolve_document_share_link error", {
        extra: { error: rpcError.message },
      });
      return errorResponse(500, "Internal server error");
    }

    // Empty result = token not found in DB
    if (!data || data.length === 0) {
      return errorResponse(404, "Share link not found");
    }

    const row = data[0] as {
      storage_path: string | null;
      document_id: string | null;
      version_id: string | null;
      tenant_id: string | null;
      title: string | null;
      is_expired: boolean;
      is_revoked: boolean;
    };

    // ── 2. Check validity ─────────────────────────────────────────────────────
    if (row.is_revoked) {
      return errorResponse(410, "Share link has been revoked");
    }
    if (row.is_expired) {
      return errorResponse(410, "Share link has expired");
    }

    if (!row.storage_path) {
      log("error", FEATURE, "Missing storage_path for token");
      return errorResponse(500, "Internal server error");
    }

    // ── 3. Generate a short-lived signed URL for the document ─────────────────
    const { data: signed, error: signError } = await adminClient.storage
      .from(DOCUMENTS_BUCKET)
      .createSignedUrl(row.storage_path, SIGNED_URL_TTL_SECONDS);

    if (signError || !signed) {
      log("error", FEATURE, "Storage createSignedUrl error", {
        tenantId: row.tenant_id ?? undefined,
        extra: { error: signError?.message },
      });
      return errorResponse(500, "Could not generate download URL");
    }

    const downloadUrl = signed.signedUrl.replace(SUPABASE_URL, SUPABASE_PUBLIC_URL);

    // ── 4. Fire-and-forget egress / audit log ─────────────────────────────────
    (async () => {
      try {
        if (row.tenant_id) {
          await adminClient.schema("data").from("audit_logs").insert({
            tenant_id:   row.tenant_id,
            user_id:     null,        // anonymous access
            action:      "DOCUMENT_SHARE_LINK_ACCESSED",
            entity_type: "document_share_link",
            entity_id:   row.document_id,
            payload: {
              version_id:   row.version_id,
              document_id:  row.document_id,
              title:        row.title,
            },
          });
        }
      } catch (e) {
        log("warn", FEATURE, "audit fire-and-forget failed", {
          extra: { error: e instanceof Error ? e.message : String(e) },
        });
      }
    })();

    // ── 5. Redirect to signed URL ─────────────────────────────────────────────
    return new Response(null, {
      status: 302,
      headers: { Location: downloadUrl },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "Unexpected error", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return errorResponse(500, "Internal server error");
  }
});
