/**
 * process-webhook-queue — Worker PGMQ per a timeline webhooks.
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  QueueRunner,
  type TaskHandler,
  type TaskPayload,
} from "../_shared/queue-runtime.ts";
import { dispatchWebhook } from "../_shared/webhooks/webhook-dispatcher.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "process-webhook-queue";
const QUEUE_NAME = "webhook_dispatch_queue";
const BATCH_SIZE = 50;
const VISIBILITY_TIMEOUT_SEC = 120;
const APP_BASE_URL = Deno.env.get("TENANT_PORTAL_BASE_URL")
  ?? Deno.env.get("PUBLIC_APP_URL")
  ?? null;

initObservability({ feature: FEATURE });

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

type DispatchContext = {
  webhook_id: string;
  tenant_id: string;
  endpoint_url: string;
  secret: string;
  event_type: string;
  payload: Record<string, unknown>;
  attempts: number;
};

function createDispatchHandler(db: ReturnType<typeof createAdminClient>): TaskHandler {
  return async (payload: TaskPayload) => {
    const deliveryLogId = String(payload.delivery_log_id ?? "");
    const webhookId = String(payload.webhook_id ?? "");

    if (!deliveryLogId || !webhookId) {
      log("warn", FEATURE, "Invalid webhook payload", { extra: { payload } });
      return { success: false };
    }

    const { data, error } = await db.rpc("get_webhook_dispatch_context", {
      p_webhook_id: webhookId,
      p_delivery_log_id: deliveryLogId,
    });

    if (error) {
      log("error", FEATURE, "get_webhook_dispatch_context failed", {
        extra: { error: error.message, deliveryLogId, webhookId },
      });
      return { success: false, selfManaged: true };
    }

    const ctx = data as DispatchContext | null;
    if (!ctx?.endpoint_url || !ctx.secret) {
      await db.rpc("complete_webhook_delivery", {
        p_delivery_log_id: deliveryLogId,
        p_status: "failed",
        p_error_message: "WEBHOOK_CONTEXT_NOT_FOUND",
      });
      return { success: false };
    }

    const result = await dispatchWebhook({
      endpointUrl: ctx.endpoint_url,
      secret: ctx.secret,
      eventType: ctx.event_type,
      payload: (ctx.payload ?? {}) as Record<string, unknown>,
      appBaseUrl: APP_BASE_URL,
    });

    await db.rpc("complete_webhook_delivery", {
      p_delivery_log_id: deliveryLogId,
      p_status: result.ok ? "delivered" : "failed",
      p_response_status: result.responseStatus ?? null,
      p_response_body: result.responseBody ?? null,
      p_error_message: result.errorMessage ?? null,
    });

    if (result.ok) {
      return { success: true };
    }

    const attempts = Number(ctx.attempts ?? 0) + 1;
    const permanent = result.errorMessage === "SSRF_BLOCKED_URL"
      || result.errorMessage === "REDIRECT_NOT_ALLOWED";

    if (permanent || attempts >= 5) {
      return { success: false };
    }

    return { success: false, selfManaged: true };
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
      dispatch_webhook: createDispatchHandler(db),
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
