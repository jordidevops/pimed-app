/**
 * handlers/send-notification.ts
 *
 * Envia una notificació in-app/push/sms via la cua notification_dispatch_queue.
 *
 * Config esperada:
 * {
 *   "recipient_source": "fixed" | "role",
 *   "user_id": "{{ context.trigger.actor_user_id }}",  // si recipient_source=fixed
 *   "role": "owner",                                    // si recipient_source=role
 *   "event_type": "TASK_ASSIGNED",
 *   "payload": {}
 * }
 *
 * RPC: api.enqueue_notification({ payload: { tenantId, eventType, correlationId, recipient, payload } })
 */

import type { AdminClient } from "../../queue-runtime.ts";
import type { StepHandlerResult, WorkflowContext } from "../types.ts";
import { log } from "../../observability/structured-logger.ts";

const FEATURE = "handler:send-notification";

export async function sendNotificationHandler(
  db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const tenantId = context.tenant.id;
  const eventType = String(config.event_type ?? "");

  if (!eventType) {
    log("warn", FEATURE, "Missing event_type — skipping", { tenantId });
    return { success: true, output: { skipped: true, reason: "missing_event_type" } };
  }

  // Resolució del destinatari
  const recipientSource = String(config.recipient_source ?? "fixed");
  let recipient: Record<string, unknown>;

  if (recipientSource === "role") {
    const role = String(config.role ?? "");
    if (!role) {
      log("warn", FEATURE, "recipient_source=role but role is empty — skipping", { tenantId });
      return { success: true, output: { skipped: true, reason: "missing_role" } };
    }
    recipient = { kind: "role", role };
  } else {
    // Fixed: espera user_id
    const userId = String(config.user_id ?? "");
    if (!userId) {
      log("warn", FEATURE, "recipient_source=fixed but user_id is empty — skipping", { tenantId });
      return { success: true, output: { skipped: true, reason: "missing_user_id" } };
    }
    recipient = { kind: "user", userId };
  }

  const correlationId = `automation:notif:${tenantId}:${Date.now()}`;

  const notificationPayload: Record<string, unknown> = {
    tenantId,
    siteId: context.site?.id ?? null,
    eventType,
    correlationId,
    recipient,
    payload: (config.payload as Record<string, unknown>) ?? {},
    entityType: context.trigger.entity_type ?? undefined,
    entityId: context.trigger.entity_id ?? undefined,
    actorUserId: context.trigger.actor_user_id ?? null,
  };

  const { error } = await db.rpc("enqueue_notification", {
    payload: notificationPayload,
  });

  if (error) {
    log("error", FEATURE, "enqueue_notification RPC failed", {
      tenantId,
      extra: { error: error.message, event_type: eventType },
    });
    return { success: false, error: error.message };
  }

  log("info", FEATURE, "Notification enqueued", {
    tenantId,
    extra: { event_type: eventType, recipient_source: recipientSource },
  });

  return { success: true, output: { enqueued: true, eventType, recipient } };
}
