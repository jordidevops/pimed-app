/**
 * process-reminders-queue
 *
 * Worker per a la cua 'reminders_queue'. Materialitza recordatoris de calendari:
 * llegeix l'event de calendari, calcula el moment d'enviament i encua l'email
 * a email_send_queue amb scheduled_at (PGMQ delay natiu).
 *
 * SIMPLICITAT CLAU: No cal set_vt ni deferral complex. pgmq.send() amb delay
 * manté el missatge invisible a email_send_queue fins al moment exacte.
 *
 * Payload esperat a reminders_queue:
 *   {
 *     task:              'materialize_reminder',  // injectat per api.create_calendar_event_with_reminders
 *     tenant_id:         uuid,
 *     site_id?:          uuid | null,
 *     actor_user_id:     uuid,                    // qui crea l'event (fallback destinatari)
 *     entity_type:       'calendar_event',
 *     entity_id:         uuid,                    // calendar_event.id
 *     idempotency_key:   'rem-<event_id>-<offset_minutes>',
 *     payload: {
 *       offset_minutes:  number,                  // minuts abans de start_at
 *       channel:         'email' | 'push' | ...   // v1: només 'email'
 *     },
 *     enqueued_at:       timestamptz
 *   }
 *
 * TODO: Quan existeixi data.communications, inserir un registre outbound
 *       ABANS d'encuar l'email, per traçabilitat.
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/process-reminders-queue \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
 *     -H "Content-Type: application/json" -d "{}"
 * 
 *    -d '{"batch_size": 20}' // fins a 20 recordatoris
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
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "process-reminders-queue";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ReminderPayload extends TaskPayload {
  actor_user_id: string;
  entity_id: string;   // calendar_event.id
  payload?: {
    offset_minutes: number;
    channel?: string;
  };
}

interface CalendarEventRow {
  id: string;
  tenant_id: string;
  site_id: string | null;
  title: string;
  start_at: string;
  end_at: string | null;
  all_day: boolean;
  owner_id: string | null;
  entity_type: string | null;
  entity_id: string | null;
}

interface ProfileRow {
  id: string;
  email: string;
  full_name: string | null;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const QUEUE_NAME = "reminders_queue";
const BATCH_SIZE = 20;
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";

// ---------------------------------------------------------------------------
// Response helper
// ---------------------------------------------------------------------------

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Formatadors
// ---------------------------------------------------------------------------

function formatDateCat(isoDate: string): string {
  try {
    return new Date(isoDate).toLocaleString("ca-ES", {
      weekday: "long",
      day: "numeric",
      month: "long",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return isoDate;
  }
}

function buildReminderHtml(
  eventTitle: string,
  startAt: string,
  offsetMinutes: number,
  recipientName: string | null,
): string {
  const formattedDate = formatDateCat(startAt);
  const greeting = recipientName ? `Hola, ${recipientName}!` : "Hola!";
  const offsetText = offsetMinutes >= 60
    ? `${Math.round(offsetMinutes / 60)} hora${Math.round(offsetMinutes / 60) !== 1 ? "s" : ""}`
    : `${offsetMinutes} minut${offsetMinutes !== 1 ? "s" : ""}`;

  return `
<p>${greeting}</p>
<p>Et recordem que tens un event programat en <strong>${offsetText}</strong>:</p>
<table style="border-left:4px solid #4F46E5;padding:12px 16px;background:#F5F5FF;border-radius:4px;width:100%;max-width:480px;">
  <tr><td><strong style="font-size:18px;">${eventTitle}</strong></td></tr>
  <tr><td style="color:#555;margin-top:4px;">${formattedDate}</td></tr>
</table>
`.trim();
}

// ---------------------------------------------------------------------------
// Resolució del destinatari del recordatori
// ---------------------------------------------------------------------------

async function resolveReminderRecipientId(
  adminClient: ReturnType<typeof createAdminClient>,
  event: CalendarEventRow,
  fallbackUserId: string | null | undefined,
): Promise<string | null> {
  if (event.entity_type === "task" && event.entity_id) {
    const { data: taskRow, error } = await adminClient
      .schema("data")
      .from("tasks")
      .select("assignee_id")
      .eq("id", event.entity_id)
      .eq("tenant_id", event.tenant_id)
      .maybeSingle();

    if (error) {
      log("warn", FEATURE, "Task lookup for reminder failed — using owner fallback", {
        tenantId: event.tenant_id,
        correlationId: event.id,
        extra: { taskId: event.entity_id, error: error.message },
      });
    } else if (taskRow?.assignee_id) {
      return taskRow.assignee_id as string;
    }
  }

  return event.owner_id ?? fallbackUserId ?? null;
}

// ---------------------------------------------------------------------------
// Handler: materialize_reminder
// ---------------------------------------------------------------------------

const materializeReminderHandler: TaskHandler = async (
  rawPayload: TaskPayload,
  ctx: WorkerContext,
): Promise<{ success: boolean; selfManaged?: boolean }> => {
  const msg = rawPayload as ReminderPayload;
  const adminClient = ctx.db;
  const operationLog = createOperationLogService(adminClient);

  // 1. Obtenir l'event de calendari
  //    Via api.calendar_events (security_invoker view) — el client és service_role.
  const { data: eventData, error: eventErr } = await adminClient
    .from("calendar_events")
    .select("id, tenant_id, site_id, title, start_at, end_at, all_day, owner_id, entity_type, entity_id")
    .eq("id", msg.entity_id)
    .single();

  if (eventErr || !eventData) {
    log("warn", FEATURE, "Calendar event not found — skipping", {
      tenantId: msg.tenant_id,
      correlationId: msg.entity_id,
      extra: { error: eventErr?.message },
    });
    // L'event ha estat eliminat → no hi ha res a enviar. Estat terminal.
    return { success: true };
  }

  const event = eventData as CalendarEventRow;

  // 2. Verificar que el tenant_id coincideix (seguretat multi-tenant)
  if (event.tenant_id !== msg.tenant_id) {
    log("error", FEATURE, "Tenant mismatch — discarding message", {
      tenantId: msg.tenant_id,
      correlationId: msg.entity_id,
      extra: { eventTenantId: event.tenant_id },
    });
    return { success: true }; // Terminal: descart silenciós per seguretat
  }

  // 3. Destinatari: assignee de la tasca si n'hi ha; sinó owner/creador de l'event
  const recipientId = await resolveReminderRecipientId(adminClient, event, msg.actor_user_id);
  if (!recipientId) {
    log("warn", FEATURE, "No recipient — skipping", {
      tenantId: msg.tenant_id,
      correlationId: msg.entity_id,
    });
    return { success: true };
  }

  const { data: profileData, error: profileErr } = await adminClient
    .from("profiles")
    .select("id, email, full_name")
    .eq("id", recipientId)
    .single();

  if (profileErr || !profileData) {
    log("warn", FEATURE, "Profile not found — skipping", {
      tenantId: msg.tenant_id,
      correlationId: msg.entity_id,
      extra: { recipientId, error: profileErr?.message },
    });
    return { success: true };
  }

  const profile = profileData as ProfileRow;

  // 4. Calcular el moment d'enviament
  const offsetMinutes = msg.payload?.offset_minutes ?? 30;
  const startAt = new Date(event.start_at);
  const sendAt = new Date(startAt.getTime() - offsetMinutes * 60 * 1000);

  // 5. Encuar l'email a email_send_queue amb scheduled_at
  //    api.enqueue_email() amb scheduled_at usa pgmq.send() amb delay natiu.
  //    Si sendAt ja ha passat, scheduled_at = null → enviament immediat.
  const isInFuture = sendAt.getTime() > Date.now() + 5_000; // marge de 5s
  const scheduledAt = isInFuture ? sendAt.toISOString() : null;

  const emailIdempotencyKey = `reminder-email-${msg.entity_id}-${offsetMinutes}`;
  const htmlBody = buildReminderHtml(
    event.title,
    event.start_at,
    offsetMinutes,
    profile.full_name,
  );
  const subject = `Recordatori: ${event.title}`;

  const { error: enqueueErr } = await adminClient.rpc("enqueue_email", {
    payload: {
      tenant_id:        event.tenant_id,
      site_id:          event.site_id,
      idempotency_key:  emailIdempotencyKey,
      to:               [profile.email],
      subject:          subject,
      html_body:        htmlBody,
      // Fallback text: versió plana sense HTML
      text_body:        `${subject}\n\nData: ${formatDateCat(event.start_at)}`,
      // Intentem usar la plantilla 'calendar_reminder' si existeix al tenant;
      // si no existeix, enqueue_email usa l'html_body/text_body inline com a fallback.
      event_type:       "calendar_reminder",
      template_variables: {
        event_title:    event.title,
        start_at:       event.start_at,
        offset_minutes: String(offsetMinutes),
      },
      email_type:       "transactional",
      locale:           "ca",
      ...(scheduledAt && { scheduled_at: scheduledAt }),
      metadata: {
        source:        "reminders_queue",
        calendar_event_id: event.id,
        reminder_msg_id:   ctx.msgId,
      },
    },
  });

  if (enqueueErr) {
    const errMsg = enqueueErr.message;
    log("error", FEATURE, "enqueue_email failed", {
      tenantId: event.tenant_id,
      correlationId: msg.entity_id,
      extra: { error: errMsg },
    });

    await operationLog.log({
      tenantId: event.tenant_id,
      siteId: event.site_id,
      integrationType: "email",
      operationCode: "materialize_calendar_reminder",
      status: "failed",
      title: "No s'ha pogut encuar el recordatori de calendari",
      message: errMsg.slice(0, 200),
      errorCode: "enqueue_failed",
      errorMessage: errMsg,
      correlationId: msg.entity_id,
      entityType: "calendar_event",
      entityId: msg.entity_id,
      externalService: "email_queue",
      isRetryable: true,
      payloadSummary: { event_title: event.title.slice(0, 80) },
    });

    if (isInfrastructureBug(enqueueErr)) {
      captureException(enqueueErr, {
        feature: FEATURE,
        tenantId: event.tenant_id,
        correlationId: msg.entity_id,
      });
    }

    throw new Error(`enqueue_email: ${errMsg}`);
  }

  log("info", FEATURE, "Reminder email enqueued", {
    tenantId: event.tenant_id,
    correlationId: msg.entity_id,
    extra: { offsetMinutes, scheduledAt: scheduledAt ?? "immediate" },
  });

  return { success: true };
};

// ---------------------------------------------------------------------------
// Edge Function entry point
// ---------------------------------------------------------------------------

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
    log("error", FEATURE, "Unauthorized batch request");
    return new Response("Unauthorized", {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  }

  let batchSize = BATCH_SIZE;
  try {
    const body = await req.json();
    if (typeof body?.batch_size === "number") {
      batchSize = Math.max(1, Math.min(body.batch_size, 50));
    }
  } catch {
    // Body buit o no-JSON → usar default
  }

  const db = createAdminClient();

  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    handlers: {
      materialize_reminder: materializeReminderHandler,
    },
    db,
    maxAttempts: 3,
    batchSize,
    visibilityTimeoutSec: 60,
  });

  try {
    const summary = await runner.runBatch();
    log("info", FEATURE, "Batch complete", { extra: summary as Record<string, unknown> });
    return jsonResponse(200, summary);
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
