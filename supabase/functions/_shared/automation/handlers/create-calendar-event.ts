/**
 * handlers/create-calendar-event.ts
 *
 * Crea un event de calendari via RPC service_role.
 */

import type { AdminClient } from "../../queue-runtime.ts";
import type { StepHandlerResult, WorkflowContext } from "../types.ts";
import { log } from "../../observability/structured-logger.ts";

const FEATURE = "handler:create-calendar-event";

export async function createCalendarEventHandler(
  db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const tenantId = context.tenant.id;
  const title = String(config.title ?? "").trim();
  const startsAt = String(config.starts_at ?? config.start_at ?? "").trim();

  if (!title) {
    log("warn", FEATURE, "Calendar event title is empty — skipping", { tenantId });
    return { success: true, output: { skipped: true, reason: "missing_title" } };
  }

  if (!startsAt) {
    log("warn", FEATURE, "Calendar event starts_at is empty — skipping", { tenantId });
    return { success: true, output: { skipped: true, reason: "missing_starts_at" } };
  }

  const durationMinutes = typeof config.duration_minutes === "number"
    ? config.duration_minutes
    : 60;

  const startDate = new Date(startsAt);
  const endAt = new Date(startDate.getTime() + durationMinutes * 60_000).toISOString();

  const entityType = context.trigger.entity_type ?? "automation";
  const entityId = context.trigger.entity_id ?? context.runtime?.workflow_run_id ?? tenantId;

  const { data, error } = await db.rpc("create_calendar_event_service", {
    p_tenant_id: tenantId,
    p_site_id: context.site?.id ?? null,
    p_title: title,
    p_start_at: startsAt,
    p_end_at: endAt,
    p_description: typeof config.description === "string" ? config.description : null,
    p_all_day: config.all_day === true,
    p_entity_type: entityType,
    p_entity_id: entityId,
  });

  if (error) {
    log("error", FEATURE, "create_calendar_event_service RPC failed", {
      tenantId,
      extra: { error: error.message, title, starts_at: startsAt },
    });
    return { success: false, error: error.message };
  }

  const eventId = (data as { event_id?: string } | null)?.event_id;

  log("info", FEATURE, "Calendar event created", {
    tenantId,
    extra: { event_id: eventId, title, starts_at: startsAt },
  });

  return { success: true, output: { event_id: eventId, title } };
}
