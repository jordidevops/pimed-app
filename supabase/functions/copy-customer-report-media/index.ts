/**
 * copy-customer-report-media
 *
 * Copies server-authored jobs from the private CIR media ledger. The caller
 * supplies only a draft id; source and destination coordinates are never read
 * from a browser-visible manifest.
 *
 * Auth: caller JWT (tenant-portal). Storage I/O uses service_role.
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "copy-customer-report-media";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

type CopyJob = {
  job_id: string;
  tenant_id: string;
  source_bucket: "tenant-files";
  source_object_key: string;
  destination_bucket: "customer-report-media";
  destination_object_key: string;
  content_type: string;
  expected_size_bytes: number;
};

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: { code: "method_not_allowed" } }, 405);
  }

  try {
    const body = await req.json().catch(() => ({}));
    const draftId =
      typeof body?.draft_id === "string"
        ? body.draft_id
        : typeof body?.p_draft_id === "string"
          ? body.p_draft_id
          : null;
    if (!draftId) {
      return json({ error: { code: "draft_id_required" } }, 400);
    }

    const user = createUserClient(req) as any;
    const { data: authorization, error: authorizationError } = await user.rpc(
      "authorize_customer_intervention_report_media_copy",
      { p_draft_id: draftId },
    );
    if (authorizationError || !authorization) {
      return json({ error: { code: "draft_not_copyable" } }, 404);
    }

    const admin = createAdminClient() as any;
    let draftMarkedFailed = false;
    const markDraftFailed = async (reason: string) => {
      if (draftMarkedFailed) return;
      draftMarkedFailed = true;
      try {
        await admin.rpc("fail_customer_intervention_report_media_prepare", {
          p_draft_id: draftId,
          p_failure_reason: reason,
        });
      } catch (failErr) {
        captureException(failErr, { feature: FEATURE });
      }
    };

    const { data: claimed, error: claimError } = await admin.rpc(
      "claim_customer_intervention_report_media_copy_jobs",
      { p_draft_id: draftId },
    );
    if (claimError) {
      captureException(claimError, { feature: FEATURE });
      await markDraftFailed(claimError.message ?? "copy_jobs_claim_failed");
      return json({ error: { code: "copy_jobs_claim_failed" } }, 500);
    }
    const jobs = Array.isArray(claimed) ? (claimed as CopyJob[]) : [];

    try {
      for (const job of jobs) {
        const { data: blob, error: dlErr } = await admin.storage
          .from(job.source_bucket)
          .download(job.source_object_key);
        if (dlErr || !blob) {
          log("error", FEATURE, "source download failed", {
            tenantId: job.tenant_id,
            extra: { jobId: job.job_id, error: dlErr?.message },
          });
          await admin.rpc("mark_customer_intervention_report_media_copy_job", {
            p_job_id: job.job_id,
            p_succeeded: false,
            p_copied_size_bytes: null,
            p_failure_reason: dlErr?.message ?? "source_download_failed",
          });
          await markDraftFailed(dlErr?.message ?? "source_download_failed");
          return json({
            error: {
              code: "source_download_failed",
              message: dlErr?.message ?? "download_failed",
            },
          }, 502);
        }

        const { error: upErr } = await admin.storage
          .from(job.destination_bucket)
          .upload(job.destination_object_key, blob, {
            contentType: job.content_type || blob.type || "application/octet-stream",
            upsert: true,
          });
        if (upErr) {
          log("error", FEATURE, "dest upload failed", {
            tenantId: job.tenant_id,
            extra: { jobId: job.job_id, error: upErr.message },
          });
          await admin.rpc("mark_customer_intervention_report_media_copy_job", {
            p_job_id: job.job_id,
            p_succeeded: false,
            p_copied_size_bytes: blob.size,
            p_failure_reason: upErr.message,
          });
          await markDraftFailed(upErr.message);
          return json({
            error: {
              code: "dest_upload_failed",
              message: upErr.message,
            },
          }, 502);
        }

        const { error: markError } = await admin.rpc(
          "mark_customer_intervention_report_media_copy_job",
          {
            p_job_id: job.job_id,
            p_succeeded: true,
            p_copied_size_bytes: blob.size,
            p_failure_reason: null,
          },
        );
        if (markError) {
          captureException(markError, { feature: FEATURE });
          await markDraftFailed(markError.message ?? "copy_job_completion_failed");
          return json({
            error: { code: "copy_job_completion_failed", message: markError.message },
          }, 500);
        }
      }

      const { data: completed, error: completeErr } = await admin.rpc(
        "complete_customer_intervention_report_media_prepare",
        {
          p_draft_id: draftId,
        },
      );
      if (completeErr) {
        captureException(completeErr, { feature: FEATURE });
        await markDraftFailed(completeErr.message ?? "complete_failed");
        return json({ error: { code: "complete_failed", message: completeErr.message } }, 500);
      }

      log("info", FEATURE, "media copy completed", {
        tenantId: (authorization as { tenant_id?: string }).tenant_id,
        extra: { draft_id: draftId, copied: jobs.length },
      });

      return json({
        ok: true,
        status: "ready",
        copied: jobs.length,
        result: completed,
      });
    } catch (innerErr) {
      await markDraftFailed(
        innerErr instanceof Error ? innerErr.message : "media_prepare_failed",
      );
      throw innerErr;
    }
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return json({ error: { code: "internal_error" } }, 500);
  }
});
