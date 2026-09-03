/**
 * process-attendance-queue
 *
 * Worker per a la cua 'attendance_recompute_queue'. Delega tota la lògica de
 * recomputació a api.recompute_attendance_worker (SECURITY DEFINER, SQL).
 *
 * Catch-up: accepta max_batches per processar diversos lots en una invocació
 * quan hi ha backlog (veure data.attendance_recompute_max_batches).
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/process-attendance-queue \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
 *     -H "Content-Type: application/json" \
 *     -d '{"batch_size": 50, "max_batches": 5, "catch_up": true}'
 */

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  QueueRunner,
  type TaskHandler,
  type TaskPayload,
  type WorkerContext,
  type BatchSummary,
} from "../_shared/queue-runtime.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "process-attendance-queue";

interface RecomputePayload extends TaskPayload {
  employee_id: string;
  work_date: string;
  tenant_id: string;
}

const QUEUE_NAME = "attendance_recompute_queue";
const DEFAULT_BATCH_SIZE = 50;
const MAX_BATCH_SIZE = 50;
const DEFAULT_MAX_BATCHES = 1;
const MAX_BATCHES_CAP = 10;
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function aggregateSummaries(batches: BatchSummary[]) {
  return batches.reduce(
    (acc, s) => ({
      total: acc.total + s.total,
      succeeded: acc.succeeded + s.succeeded,
      skipped: acc.skipped + s.skipped,
      retried: acc.retried + s.retried,
      dlqed: acc.dlqed + s.dlqed,
      errors: [...acc.errors, ...s.errors],
    }),
    { total: 0, succeeded: 0, skipped: 0, retried: 0, dlqed: 0, errors: [] as string[] },
  );
}

const recomputeAttendanceDayHandler: TaskHandler = async (
  rawPayload: TaskPayload,
  ctx: WorkerContext,
): Promise<{ success: boolean }> => {
  const msg = rawPayload as RecomputePayload;
  const db = ctx.db;
  const operationLog = createOperationLogService(db);

  const { employee_id, work_date, tenant_id } = msg;

  if (!employee_id || !work_date || !tenant_id) {
    log("error", FEATURE, "Missing required fields", {
      tenantId: tenant_id,
      correlationId: `${employee_id}:${work_date}`,
    });
    return { success: false };
  }

  const started = performance.now();
  const { data: result, error } = await db.rpc("recompute_attendance_worker", {
    p_employee_id: employee_id,
    p_work_date: work_date,
    p_tenant_id: tenant_id,
  });
  const durationMs = Math.round(performance.now() - started);

  if (error) {
    log("error", FEATURE, "recompute_attendance_worker failed", {
      tenantId: tenant_id,
      correlationId: `${employee_id}:${work_date}`,
      durationMs,
      extra: { error: error.message },
    });

    await operationLog.log({
      tenantId: tenant_id,
      integrationType: "other",
      operationCode: "recompute_attendance_day",
      status: "failed",
      title: "Error recomputant assistència",
      message: error.message.slice(0, 200),
      errorCode: "recompute_failed",
      errorMessage: error.message,
      correlationId: `${employee_id}:${work_date}`,
      entityType: "employee",
      entityId: employee_id,
      isRetryable: true,
      payloadSummary: { work_date, duration_ms: durationMs },
    });

    if (isInfrastructureBug(error)) {
      captureException(error, { feature: FEATURE, tenantId: tenant_id, correlationId: employee_id });
    }

    throw new Error(`recompute_attendance_worker: ${error.message}`);
  }

  if (result?.skipped || result?.skipped_entry) {
    log("info", FEATURE, "Recompute skipped", {
      tenantId: tenant_id,
      correlationId: `${employee_id}:${work_date}`,
      durationMs,
      extra: { reason: result.reason },
    });
    return { success: true };
  }

  log("info", FEATURE, "Recomputed attendance", {
    tenantId: tenant_id,
    correlationId: `${employee_id}:${work_date}`,
    durationMs,
    extra: {
      punch_count: result?.punch_count,
      net_minutes: result?.net_minutes,
      status: result?.entry_status,
    },
  });

  return { success: true };
};

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse(405, { error: { code: "method_not_allowed" } });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length)
    : "";
  if (!token || token !== SERVICE_ROLE_KEY) {
    return new Response("Unauthorized", {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  }

  let batchSize = DEFAULT_BATCH_SIZE;
  let maxBatches = DEFAULT_MAX_BATCHES;
  let catchUp = false;

  try {
    const body = await req.json();
    if (typeof body?.batch_size === "number") {
      batchSize = Math.max(1, Math.min(body.batch_size, MAX_BATCH_SIZE));
    }
    if (typeof body?.max_batches === "number") {
      maxBatches = Math.max(1, Math.min(body.max_batches, MAX_BATCHES_CAP));
    }
    if (body?.catch_up === true) {
      catchUp = true;
    }
  } catch {
    // Body buit → defaults
  }

  const runStarted = performance.now();
  const db = createAdminClient();

  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    handlers: {
      recompute_attendance_day: recomputeAttendanceDayHandler,
    },
    db,
    maxAttempts: 3,
    batchSize,
    visibilityTimeoutSec: catchUp ? 120 : 90,
  });

  const batches: BatchSummary[] = [];

  try {
    for (let i = 0; i < maxBatches; i++) {
      const summary = await runner.runBatch();
      batches.push(summary);
      if (summary.total === 0) break;
    }

    const totals = aggregateSummaries(batches);
    const durationMs = Math.round(performance.now() - runStarted);

    let queueHealth: Record<string, unknown> | null = null;
    try {
      const { data } = await db.rpc("get_attendance_queue_health");
      if (data && typeof data === "object") {
        queueHealth = data as Record<string, unknown>;
      }
    } catch {
      // Health RPC opcional (migració pendent en entorns antics)
    }

    const response = {
      queue_name: QUEUE_NAME,
      catch_up: catchUp,
      batch_size: batchSize,
      max_batches: maxBatches,
      batches_run: batches.length,
      duration_ms: durationMs,
      ...totals,
      batches,
      queue_health: queueHealth,
      recompute_per_sec:
        durationMs > 0 ? Math.round((totals.succeeded / durationMs) * 1000 * 100) / 100 : 0,
    };

    log("info", FEATURE, "Run complete", {
      extra: {
        batches_run: batches.length,
        succeeded: totals.succeeded,
        duration_ms: durationMs,
        queue_length: queueHealth?.queue_length,
      },
    });

    return jsonResponse(200, response);
  } catch (err) {
    log("error", FEATURE, "Unexpected batch error", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, {
      error: { code: "internal_error", message: "An unexpected error occurred" },
    });
  }
});
