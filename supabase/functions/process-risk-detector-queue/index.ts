/**
 * process-risk-detector-queue — Worker PGMQ per incidents de Risk Detector.
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  QueueRunner,
  type TaskHandler,
  type TaskPayload,
} from "../_shared/queue-runtime.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "process-risk-detector-queue";
const QUEUE_NAME = "risk_detector_queue";
const BATCH_SIZE = 50;
const VISIBILITY_TIMEOUT_SEC = 120;

initObservability({ feature: FEATURE });

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function createProcessHandler(db: ReturnType<typeof createAdminClient>): TaskHandler {
  return async (payload: TaskPayload) => {
    const incidentId = String(payload.incident_id ?? "");
    if (!incidentId) {
      log("warn", FEATURE, "Invalid risk payload", { extra: { payload } });
      return { success: false };
    }

    const { data, error } = await db.rpc("process_risk_incident", {
      p_incident_id: incidentId,
    });

    if (error) {
      log("error", FEATURE, "process_risk_incident failed", {
        extra: { error: error.message, incidentId },
      });
      return { success: false, selfManaged: true };
    }

    const result = data as { ok?: boolean } | null;
    if (result?.ok === false) {
      return { success: true };
    }

    return { success: true };
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let batchSize = BATCH_SIZE;
  try {
    const body = await req.json();
    if (typeof body?.batch_size === "number" && body.batch_size > 0) {
      batchSize = Math.min(body.batch_size, 50);
    }
  } catch {
    // default
  }

  const db = createAdminClient();
  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    handlers: {
      process_risk_incident: createProcessHandler(db),
    },
    db,
    maxAttempts: 5,
    batchSize,
    visibilityTimeoutSec: VISIBILITY_TIMEOUT_SEC,
  });

  try {
    const summary = await runner.runBatch();
    log("info", FEATURE, "Batch complete", { extra: summary as Record<string, unknown> });
    return jsonResponse(200, summary);
  } catch (err) {
    log("error", FEATURE, "Unexpected batch error", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    if (isInfrastructureBug(err)) {
      captureException(err, { feature: FEATURE });
    }
    return jsonResponse(500, {
      error: { code: "internal_error", message: "An unexpected error occurred" },
    });
  }
});
