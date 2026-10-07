/**
 * reconcile-docuseal-signed-artifacts
 *
 * CF-28 F8/F9: retry attaching signed PDFs for commercial DocuSeal bridges.
 * Auth: Bearer must be SUPABASE_SERVICE_ROLE_KEY (verify_jwt=true + check).
 * Throughput: concurrency 5 + soft time budget (~22s); one pass per invoke.
 */
import { createAdminClient } from "../_shared/supabase.ts";
import { attachSignedDocumentFromUrl } from "../_shared/docuseal-attach-signed.ts";
import {
  initObservability,
  captureException,
} from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "reconcile-docuseal-signed-artifacts";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 100;
const CONCURRENCY = 5;
const SOFT_BUDGET_MS = 22_000;

initObservability(FEATURE);

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function requireServiceRole(req: Request): Response | null {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!SERVICE_ROLE_KEY || !token || token !== SERVICE_ROLE_KEY) {
    return jsonResponse(401, { error: "unauthorized" });
  }
  return null;
}

async function mapPool<T, R>(
  items: T[],
  concurrency: number,
  shouldStop: () => boolean,
  worker: (item: T) => Promise<R>,
): Promise<R[]> {
  const results: R[] = [];
  let idx = 0;
  async function runOne(): Promise<void> {
    while (!shouldStop()) {
      const i = idx;
      idx += 1;
      if (i >= items.length) return;
      results[i] = await worker(items[i]!);
    }
  }
  const n = Math.min(concurrency, Math.max(items.length, 1));
  await Promise.all(Array.from({ length: n }, () => runOne()));
  return results;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  const denied = requireServiceRole(req);
  if (denied) return denied;

  const admin = createAdminClient();
  const wallStart = Date.now();
  const startedAt = new Date(wallStart).toISOString();
  let limit = DEFAULT_LIMIT;
  try {
    const body = (await req.json().catch(() => ({}))) as { limit?: number };
    if (typeof body.limit === "number" && Number.isFinite(body.limit)) {
      limit = Math.max(1, Math.min(MAX_LIMIT, Math.floor(body.limit)));
    }
  } catch {
    /* defaults */
  }

  const { data: rowsRaw, error: listErr } = await admin.rpc(
    "list_signing_submissions_needing_artifact_reconcile",
    { p_limit: limit },
  );

  if (listErr) {
    log("error", FEATURE, "list failed", { extra: { error: listErr.message } });
    captureException(listErr, { feature: FEATURE });
    await admin.rpc("record_signing_ops_job_run", {
      p_job_name: FEATURE,
      p_ok: false,
      p_error: listErr.message,
      p_started_at: startedAt,
      p_duration_ms: Date.now() - wallStart,
    });
    return jsonResponse(500, { error: "list_failed" });
  }

  const rows = Array.isArray(rowsRaw)
    ? (rowsRaw as Array<Record<string, unknown>>)
    : [];

  let attempted = 0;
  let attached = 0;
  let skipped = 0;
  let timedOut = false;

  const shouldStop = () => {
    if (Date.now() - wallStart >= SOFT_BUDGET_MS) {
      timedOut = true;
      return true;
    }
    return false;
  };

  await mapPool(rows, CONCURRENCY, shouldStop, async (row) => {
    if (shouldStop()) {
      skipped += 1;
      return;
    }
    const submissionId =
      typeof row.submission_id === "string" ? row.submission_id : null;
    const tenantId = typeof row.tenant_id === "string" ? row.tenant_id : null;
    const signedUrl =
      typeof row.artifact_signed_url === "string"
        ? row.artifact_signed_url.trim()
        : "";
    if (!submissionId || !tenantId || !signedUrl) {
      skipped += 1;
      if (!signedUrl && submissionId) {
        log("warn", FEATURE, "missing artifact_retry_url", {
          correlationId: submissionId,
          tenantId: tenantId ?? undefined,
        });
      }
      return;
    }

    attempted += 1;
    try {
      const result = await attachSignedDocumentFromUrl({
        adminClient: admin,
        submissionId,
        tenantId,
        documentUrl: signedUrl,
        documentName: `signed-document-${submissionId}`,
      });
      if (result.ok) attached += 1;
    } catch (err) {
      log("error", FEATURE, "reconcile item failed", {
        correlationId: submissionId,
        tenantId,
        extra: { error: err instanceof Error ? err.message : String(err) },
      });
      captureException(err, {
        feature: FEATURE,
        tenantId,
        correlationId: submissionId,
      });
    }
  });

  let backlogHint: number | null = null;
  try {
    const { data: n } = await admin.rpc(
      "count_signing_submissions_needing_artifact_reconcile",
      { p_cap: 500 },
    );
    if (typeof n === "number") backlogHint = n;
  } catch {
    /* optional */
  }

  const durationMs = Date.now() - wallStart;
  const detail = {
    concurrency: CONCURRENCY,
    soft_budget_ms: SOFT_BUDGET_MS,
    timed_out: timedOut,
    backlog_hint: backlogHint,
  };

  await admin.rpc("record_signing_ops_job_run", {
    p_job_name: FEATURE,
    p_ok: true,
    p_listed: rows.length,
    p_attempted: attempted,
    p_attached: attached,
    p_skipped: skipped,
    p_started_at: startedAt,
    p_duration_ms: durationMs,
    p_detail: detail,
  });

  log("info", FEATURE, "reconcile batch done", {
    extra: {
      listed: rows.length,
      attempted,
      attached,
      skipped,
      duration_ms: durationMs,
      timed_out: timedOut,
      backlog_hint: backlogHint,
    },
  });

  return jsonResponse(200, {
    ok: true,
    listed: rows.length,
    attempted,
    attached,
    skipped,
    duration_ms: durationMs,
    timed_out: timedOut,
    backlog_hint: backlogHint,
  });
});
