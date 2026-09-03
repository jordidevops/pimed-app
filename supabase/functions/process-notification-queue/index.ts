/**
 * process-notification-queue
 *
 * Worker per a la cua 'notification_dispatch_queue'.
 * Usa QueueRunner amb preprocessBatch per fairness multi-tenant.
 *
 * Payload (després de api.enqueue_notification):
 *   {
 *     task: 'dispatch_notification',
 *     tenant_id: uuid,
 *     tenantId: uuid,
 *     eventType: string,
 *     correlationId: string,
 *     idempotency_key: string,
 *     recipient: { kind, userId|contactId|email|phoneE164 },
 *     payload: { ... },
 *     ...
 *   }
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/process-notification-queue \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
 *     -H "Content-Type: application/json" \
 *     -d '{"batch_size": 10}'
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  QueueRunner,
  type PreprocessBatch,
  type QueueMessage,
  type TaskHandler,
  type TaskPayload,
} from "../_shared/queue-runtime.ts";
import { NotificationService } from "../_shared/notifications/notification-service.ts";
import type { NotificationRecipient, NotificationSendInput } from "../_shared/notifications/types.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";
import { toError } from "../_shared/notifications/supabase-error.ts";

const FEATURE = "process-notification-queue";
const QUEUE_NAME = "notification_dispatch_queue";
const BATCH_SIZE = 50;
const MAX_PER_TENANT = 10;
const VISIBILITY_TIMEOUT_SEC = 120;

initObservability({ feature: FEATURE });

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeChannelOverride(value: unknown): NotificationSendInput["channelOverride"] {
  if (!Array.isArray(value)) return undefined;
  return value.filter((ch): ch is NotificationSendInput["channelOverride"][number] =>
    typeof ch === "string" && ["in_app", "push", "email", "sms", "whatsapp"].includes(ch)
  );
}

function payloadToNotificationInput(payload: TaskPayload): NotificationSendInput {
  const tenantId = String(payload.tenantId ?? payload.tenant_id ?? "");
  const recipient = payload.recipient as NotificationRecipient | undefined;

  if (!tenantId || !payload.eventType || !recipient || !payload.correlationId) {
    throw new Error("INVALID_NOTIFICATION_PAYLOAD");
  }

  return {
    tenantId,
    siteId: (payload.siteId as string | null | undefined) ?? null,
    eventType: String(payload.eventType),
    recipient,
    payload: (payload.payload ?? {}) as Record<string, unknown>,
    correlationId: String(payload.correlationId ?? payload.idempotency_key),
    entityType: payload.entityType as string | undefined,
    entityId: payload.entityId as string | undefined,
    actorUserId: (payload.actorUserId as string | null | undefined) ?? null,
    channelOverride: normalizeChannelOverride(payload.channelOverride),
  };
}

function createFairnessPreprocess(maxPerTenant: number): PreprocessBatch {
  return async (messages, ctx) => {
    const byTenant = new Map<string, QueueMessage[]>();

    for (const msg of messages) {
      const tenantId = String(msg.message?.tenant_id ?? msg.message?.tenantId ?? "");
      if (!byTenant.has(tenantId)) byTenant.set(tenantId, []);
      byTenant.get(tenantId)!.push(msg);
    }

    const toProcess: QueueMessage[] = [];

    for (const [, tenantMsgs] of byTenant) {
      toProcess.push(...tenantMsgs.slice(0, maxPerTenant));

      for (const excess of tenantMsgs.slice(maxPerTenant)) {
        const { error } = await ctx.db.rpc("set_queue_message_vt", {
          p_queue: ctx.queueName,
          p_msg_id: excess.msg_id,
          p_vt_seconds: 0,
        });
        if (error) {
          log("warn", FEATURE, "set_queue_message_vt failed for fairness deferral", {
            extra: { msg_id: excess.msg_id, error: error.message },
          });
        }
      }
    }

    return toProcess;
  };
}

function createDispatchHandler(service: NotificationService): TaskHandler {
  return async (payload) => {
    try {
      const input = payloadToNotificationInput(payload);
      await service.processDelivery(input);
      return { success: true };
    } catch (err) {
      const error = toError(err);
      const message = error.message;

      if (message === "INVALID_NOTIFICATION_PAYLOAD") {
        log("warn", FEATURE, "Invalid notification payload — DLQ candidate", {
          extra: { payload },
        });
        return { success: false };
      }

      log("error", FEATURE, "Infrastructure error processing notification", {
        extra: { error: message },
      });

      const isPermanentDataError = message === "INVALID_NOTIFICATION_PAYLOAD"
        || message.startsWith("23503:")
        || message.includes("PGRST205");

      if (isPermanentDataError) {
        return { success: false };
      }

      if (isInfrastructureBug(message)) {
        captureException(err, { feature: FEATURE });
      }

      return { success: false, selfManaged: true };
    }
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
    // body buit → default
  }

  const db = createAdminClient();
  const service = new NotificationService(db);

  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    handlers: {
      dispatch_notification: createDispatchHandler(service),
    },
    db,
    maxAttempts: 3,
    batchSize,
    visibilityTimeoutSec: VISIBILITY_TIMEOUT_SEC,
    preprocessBatch: createFairnessPreprocess(MAX_PER_TENANT),
  });

  try {
    const summary = await runner.runBatch();
    const digestSummary = await service.flushDigests(batchSize);
    log("info", FEATURE, "Batch complete", {
      extra: { ...summary as Record<string, unknown>, digest: digestSummary },
    });
    return jsonResponse(200, { ...summary, digest: digestSummary });
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
