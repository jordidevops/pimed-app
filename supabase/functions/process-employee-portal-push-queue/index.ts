/**
 * process-employee-portal-push-queue
 *
 * Envia notificacions Web Push als empleats quan canvia el torn (shift_slots).
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/process-employee-portal-push-queue \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
 *     -H "Content-Type: application/json" \
 *     -d '{"batch_size": 10}'
 */

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  QueueRunner,
  type TaskHandler,
  type TaskPayload,
  type WorkerContext,
} from "../_shared/queue-runtime.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import {
  buildShiftPushNotification,
  type ShiftPushEvent,
  type ShiftSlotPushContext,
} from "../_shared/employee-portal/shift-push-content.ts";
import {
  buildPlanningPushNotification,
  type PlanningPushEvent,
  type PlanningPushPayload,
} from "../_shared/employee-portal/planning-push-content.ts";
import {
  buildPunchReminderNotification,
} from "../_shared/employee-portal/punch-reminder-content.ts";
import type { PunchReminderKind } from "../_shared/employee-portal/punch-reminder-eval.ts";
import {
  isWebPushConfigured,
  sendWebPushNotification,
} from "../_shared/employee-portal/web-push-sender.ts";

const FEATURE = "process-employee-portal-push-queue";
const QUEUE_NAME = "employee_portal_push_queue";
const DEFAULT_BATCH_SIZE = 20;
const MAX_BATCH_SIZE = 50;

const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";

interface ShiftPushPayload extends TaskPayload {
  employee_id: string;
  slot_id: string;
  event: ShiftPushEvent;
}

interface PlanningPushMsg extends TaskPayload {
  employee_id: string;
  event: PlanningPushEvent;
  payload?: PlanningPushPayload;
  urgent?: boolean;
}

interface PunchReminderPayload extends TaskPayload {
  employee_id: string;
  work_date: string;
  reminder_kind: PunchReminderKind;
}

interface PushSubscriptionRow {
  id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const shiftPushHandler: TaskHandler = async (
  rawPayload: TaskPayload,
  ctx: WorkerContext,
): Promise<{ success: boolean }> => {
  const msg = rawPayload as ShiftPushPayload;
  const { tenant_id, employee_id, slot_id, event } = msg;

  if (!tenant_id || !employee_id || !slot_id || !event) {
    log("error", FEATURE, "Missing required fields", { extra: { msg } });
    return { success: false };
  }

  if (!isWebPushConfigured()) {
    log("warn", FEATURE, "VAPID not configured — skipping push delivery", {
      tenantId: tenant_id,
      correlationId: slot_id,
    });
    return { success: true };
  }

  const db = ctx.db;

  const { data: contextRaw, error: contextError } = await db.rpc(
    "get_shift_slot_push_context",
    { p_slot_id: slot_id },
  );

  if (contextError) {
    throw new Error(`get_shift_slot_push_context: ${contextError.message}`);
  }

  if (!contextRaw) {
    log("warn", FEATURE, "Slot not found — skipping", {
      tenantId: tenant_id,
      correlationId: slot_id,
    });
    return { success: true };
  }

  const slotContext = contextRaw as ShiftSlotPushContext;
  const notification = buildShiftPushNotification(event, slotContext);

  return deliverPushToEmployee(
    db,
    tenant_id,
    employee_id,
    `${employee_id}:${slot_id}`,
    notification,
  );
};

async function deliverPushToEmployee(
  db: WorkerContext["db"],
  tenantId: string,
  employeeId: string,
  correlationId: string,
  notification: { title: string; body: string; url: string; tag: string },
): Promise<{ success: boolean }> {
  const { data: subsRaw, error: subsError } = await db.rpc(
    "list_employee_portal_push_subscriptions",
    { p_employee_id: employeeId, p_tenant_id: tenantId },
  );

  if (subsError) {
    throw new Error(`list_employee_portal_push_subscriptions: ${subsError.message}`);
  }

  const subscriptions = (Array.isArray(subsRaw) ? subsRaw : []) as PushSubscriptionRow[];

  if (subscriptions.length === 0) {
    log("info", FEATURE, "No push subscriptions for employee", {
      tenantId,
      correlationId: employeeId,
    });
    return { success: true };
  }

  let sent = 0;
  let failed = 0;

  for (const sub of subscriptions) {
    const result = await sendWebPushNotification(
      { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
      notification,
    );

    if (result.ok) {
      sent++;
      continue;
    }

    failed++;
    if (result.gone) {
      await db.rpc("delete_employee_portal_push_subscription", {
        p_endpoint: sub.endpoint,
      }).catch(() => undefined);
    }
  }

  log("info", FEATURE, "Push delivered", {
    tenantId,
    correlationId,
    extra: { sent, failed, total: subscriptions.length },
  });

  return { success: sent > 0 || failed === 0 };
}

const punchReminderHandler: TaskHandler = async (
  rawPayload: TaskPayload,
  ctx: WorkerContext,
): Promise<{ success: boolean }> => {
  const msg = rawPayload as PunchReminderPayload;
  const { tenant_id, employee_id, work_date, reminder_kind } = msg;

  if (!tenant_id || !employee_id || !work_date || !reminder_kind) {
    log("error", FEATURE, "Missing punch reminder fields", { extra: { msg } });
    return { success: false };
  }

  if (!isWebPushConfigured()) {
    log("warn", FEATURE, "VAPID not configured — skipping push delivery", {
      tenantId: tenant_id,
      correlationId: employee_id,
    });
    return { success: true };
  }

  const notification = buildPunchReminderNotification(reminder_kind, work_date);

  return deliverPushToEmployee(
    ctx.db,
    tenant_id,
    employee_id,
    `${employee_id}:${work_date}:${reminder_kind}`,
    notification,
  );
};

const planningPushHandler: TaskHandler = async (
  rawPayload: TaskPayload,
  ctx: WorkerContext,
): Promise<{ success: boolean }> => {
  const msg = rawPayload as PlanningPushMsg;
  const { tenant_id, employee_id, event, payload } = msg;

  if (!tenant_id || !employee_id || !event) {
    log("error", FEATURE, "Missing planning push fields", { extra: { msg } });
    return { success: false };
  }

  if (!isWebPushConfigured()) {
    log("warn", FEATURE, "VAPID not configured — skipping planning push", {
      tenantId: tenant_id,
      correlationId: employee_id,
    });
    return { success: true };
  }

  const notification = buildPlanningPushNotification(event, payload ?? {});

  return deliverPushToEmployee(
    ctx.db,
    tenant_id,
    employee_id,
    `${employee_id}:${event}:${payload?.entity_id ?? "x"}`,
    notification,
  );
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
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice("Bearer ".length) : "";
  if (!token || token !== SERVICE_ROLE_KEY) {
    return new Response("Unauthorized", {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  }

  let batchSize = DEFAULT_BATCH_SIZE;
  try {
    const body = await req.json();
    if (typeof body?.batch_size === "number") {
      batchSize = Math.max(1, Math.min(body.batch_size, MAX_BATCH_SIZE));
    }
  } catch {
    /* empty body ok */
  }

  const db = createAdminClient();
  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    db,
    batchSize,
    visibilityTimeoutSec: 120,
    maxAttempts: 3,
    defaultTask: "shift_push",
    handlers: {
      shift_push: shiftPushHandler,
      punch_reminder: punchReminderHandler,
      planning_push: planningPushHandler,
    },
  });

  try {
    const summary = await runner.runBatch();
    return jsonResponse(200, { ok: true, queue: QUEUE_NAME, summary });
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown_error";
    log("error", FEATURE, "Worker failed", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, { error: { code: "worker_failed", message } });
  }
});
