/**
 * export-recruitment-applications
 *
 * REC-4 P0: prepare CSV server-side (no PII in browser RPC), upload with
 * service_role, return short-lived signed URL only.
 *
 * POST body: { job_posting_id: uuid, ack_warning: true }
 * Headers: Authorization (JWT), x-tenant-id
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  initObservability,
  captureException,
} from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "export-recruitment-applications";
const TTL_SECONDS = 900;

initObservability({ feature: FEATURE });

type ExportRequest = {
  job_posting_id?: string;
  ack_warning?: boolean;
};

type PrepareResult = {
  package_id: string;
  storage_path: string;
  filename: string;
  row_count: number;
  excluded_count: number;
  signed_url_ttl_seconds?: number;
};

type ClaimResult = {
  package_id: string;
  storage_path: string;
  filename: string;
  csv_text: string;
  row_count: number;
  excluded_count: number;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: { code: "method_not_allowed" } }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: { code: "unauthorized" } }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  let body: ExportRequest;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: { code: "invalid_json" } }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const jobPostingId = body.job_posting_id?.trim();
  if (!jobPostingId) {
    return new Response(JSON.stringify({ error: { code: "missing_job_posting_id" } }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (!body.ack_warning) {
    return new Response(JSON.stringify({ error: { code: "ack_required" } }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const userDb = createUserClient(req);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data: prepRaw, error: prepErr } = await (userDb as any).rpc(
      "export_job_posting_applications_csv",
      {
        p_job_posting_id: jobPostingId,
        p_ack_warning: true,
      },
    );

    if (prepErr) {
      const message = prepErr.message ?? "prepare_failed";
      const status = message.includes("forbidden")
        ? 403
        : message.includes("ack_required")
        ? 400
        : message.includes("not_found")
        ? 404
        : 400;
      log("warn", FEATURE, "Prepare export failed", {
        extra: { message, jobPostingId },
      });
      return new Response(
        JSON.stringify({ error: { code: "prepare_failed", message } }),
        {
          status,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const prep = prepRaw as PrepareResult;
    if (!prep?.package_id || !prep.storage_path) {
      return new Response(JSON.stringify({ error: { code: "prepare_invalid" } }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Guard: prepare must never leak csv_text to this path's client response
    if (
      prepRaw &&
      typeof prepRaw === "object" &&
      "csv_text" in (prepRaw as Record<string, unknown>)
    ) {
      log("error", FEATURE, "Prepare RPC leaked csv_text — aborting", {
        extra: { packageId: prep.package_id },
      });
      return new Response(JSON.stringify({ error: { code: "internal_error" } }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const admin = createAdminClient();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data: claimRaw, error: claimErr } = await (admin as any).rpc(
      "claim_recruitment_export_package",
      { p_package_id: prep.package_id },
    );

    if (claimErr || !claimRaw) {
      log("error", FEATURE, "Claim export package failed", {
        extra: {
          message: claimErr?.message,
          packageId: prep.package_id,
        },
      });
      return new Response(JSON.stringify({ error: { code: "claim_failed" } }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const claim = claimRaw as ClaimResult;
    const bytes = new TextEncoder().encode(claim.csv_text ?? "");

    const { error: upErr } = await admin.storage
      .from("recruitment-exports")
      .upload(claim.storage_path, bytes, {
        contentType: "text/csv;charset=utf-8",
        upsert: true,
      });

    if (upErr) {
      log("error", FEATURE, "Storage upload failed", {
        extra: { message: upErr.message, path: claim.storage_path },
      });
      // Still clear csv blob
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      await (admin as any).rpc("finalize_recruitment_export", {
        p_package_id: prep.package_id,
        p_uploaded: false,
      });
      return new Response(JSON.stringify({ error: { code: "upload_failed" } }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const ttl = prep.signed_url_ttl_seconds || TTL_SECONDS;
    const { data: signed, error: signErr } = await admin.storage
      .from("recruitment-exports")
      .createSignedUrl(claim.storage_path, ttl);

    if (signErr || !signed?.signedUrl) {
      log("error", FEATURE, "Signed URL failed", {
        extra: { message: signErr?.message },
      });
      return new Response(JSON.stringify({ error: { code: "signed_url_failed" } }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (admin as any).rpc("finalize_recruitment_export", {
      p_package_id: prep.package_id,
      p_uploaded: true,
    });

    log("info", FEATURE, "Export ready", {
      extra: {
        jobPostingId,
        rowCount: claim.row_count,
        excludedCount: claim.excluded_count,
      },
    });

    return new Response(
      JSON.stringify({
        signed_url: signed.signedUrl,
        filename: claim.filename,
        row_count: claim.row_count,
        excluded_count: claim.excluded_count,
        expires_in: ttl,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  } catch (err) {
    log("error", FEATURE, "Unexpected export error", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    captureException(err, { feature: FEATURE });
    return new Response(JSON.stringify({ error: { code: "internal_error" } }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
