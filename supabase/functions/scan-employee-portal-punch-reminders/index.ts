/**
 * scan-employee-portal-punch-reminders
 *
 * WS-B1: avalua empleats amb subscripció push i encua recordatoris de fitxatge.
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/scan-employee-portal-punch-reminders \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
 *     -H "Content-Type: application/json" \
 *     -d '{}'
 */

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import {
  evaluatePunchReminder,
  localNowInTimezone,
  mapResolveWorkDayToScheduleInput,
  parsePunchReminderConfig,
  workDateInTimezone,
  type PunchReminderKind,
} from "../_shared/employee-portal/punch-reminder-eval.ts";
import type { PunchPresenceStatus, WorkSchedulePunchInput } from "../_shared/employee-portal/work-schedule-status.ts";

const FEATURE = "scan-employee-portal-punch-reminders";

const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";

interface CandidateRow {
  tenant_id: string;
  employee_id: string;
  tenant_settings: Record<string, unknown> | null;
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function readReminderSettings(tenantSettings: Record<string, unknown> | null) {
  const flat = tenantSettings?.attendance_punch_reminders;
  if (flat && typeof flat === "object") {
    return parsePunchReminderConfig(flat);
  }

  const attendance = tenantSettings?.attendance;
  const nested = attendance && typeof attendance === "object"
    ? (attendance as Record<string, unknown>).punch_reminders
    : undefined;
  return parsePunchReminderConfig(nested);
}

function isNonWorkingDayType(dayType: string, laborDayType: string | null): boolean {
  if (laborDayType === "work" || dayType === "working") return false;
  return true;
}

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

  const db = createAdminClient();
  const nowUtc = new Date();
  let scanned = 0;
  let enqueued = 0;
  let skipped = 0;
  let errors = 0;

  try {
    const { data: candidatesRaw, error: candidatesError } = await db.rpc(
      "list_employee_portal_punch_reminder_candidates",
    );

    if (candidatesError) {
      throw new Error(`list_employee_portal_punch_reminder_candidates: ${candidatesError.message}`);
    }

    const candidates = (Array.isArray(candidatesRaw) ? candidatesRaw : []) as CandidateRow[];

    for (const row of candidates) {
      scanned++;
      const config = readReminderSettings(row.tenant_settings);
      if (!config.enabled) {
        skipped++;
        continue;
      }

      try {
        const preliminaryDate = workDateInTimezone(nowUtc, "Europe/Madrid");
        const { data: resolveRaw, error: resolveError } = await db.rpc("resolve_work_day", {
          p_employee_id: row.employee_id,
          p_work_date: preliminaryDate,
        });

        if (resolveError) {
          errors++;
          log("warn", FEATURE, "resolve_work_day failed", {
            tenantId: row.tenant_id,
            correlationId: row.employee_id,
            extra: { error: resolveError.message },
          });
          continue;
        }

        const resolvePrelim = (resolveRaw ?? {}) as Record<string, unknown>;
        const timezone = String(resolvePrelim.site_timezone ?? "Europe/Madrid");
        const workDate = workDateInTimezone(nowUtc, timezone);
        const localNow = localNowInTimezone(nowUtc, timezone);

        const { data: resolveDayRaw, error: resolveDayError } = workDate === preliminaryDate
          ? { data: resolveRaw, error: null }
          : await db.rpc("resolve_work_day", {
            p_employee_id: row.employee_id,
            p_work_date: workDate,
          });

        if (resolveDayError) {
          errors++;
          log("warn", FEATURE, "resolve_work_day (work date) failed", {
            tenantId: row.tenant_id,
            correlationId: row.employee_id,
            extra: { error: resolveDayError.message },
          });
          continue;
        }

        const resolve = (resolveDayRaw ?? {}) as Record<string, unknown>;
        const scheduleInput = mapResolveWorkDayToScheduleInput(resolve);

        if (config.sendOnlyOnWorkdays && isNonWorkingDayType(scheduleInput.dayType, scheduleInput.laborDayType)) {
          skipped++;
          continue;
        }

        const { data: dayRaw, error: dayError } = await db.rpc(
          "employee_portal_get_day_punch_context",
          {
            p_employee_id: row.employee_id,
            p_tenant_id: row.tenant_id,
            p_work_date: workDate,
          },
        );

        if (dayError) {
          errors++;
          log("warn", FEATURE, "day punch context failed", {
            tenantId: row.tenant_id,
            correlationId: row.employee_id,
            extra: { error: dayError.message },
          });
          continue;
        }

        const day = (dayRaw ?? {}) as Record<string, unknown>;
        const punches = (Array.isArray(day.punches) ? day.punches : []) as WorkSchedulePunchInput[];
        const presenceStatus = String(day.current_status ?? "unknown") as PunchPresenceStatus;

        const reminderKind = evaluatePunchReminder({
          schedule: scheduleInput,
          punches,
          presenceStatus,
          now: localNow,
          config,
        });

        if (!reminderKind) {
          skipped++;
          continue;
        }

        const claimed = await claimAndEnqueue(
          db,
          row.tenant_id,
          row.employee_id,
          workDate,
          reminderKind,
          config.maxPerDay,
        );

        if (claimed) {
          enqueued++;
        } else {
          skipped++;
        }
      } catch (err) {
        errors++;
        const message = err instanceof Error ? err.message : "unknown_error";
        log("warn", FEATURE, "candidate scan failed", {
          tenantId: row.tenant_id,
          correlationId: row.employee_id,
          extra: { error: message },
        });
      }
    }

    log("info", FEATURE, "Scan complete", {
      extra: { scanned, enqueued, skipped, errors },
    });

    return jsonResponse(200, {
      ok: true,
      scanned,
      enqueued,
      skipped,
      errors,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown_error";
    log("error", FEATURE, "Scan failed", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, { error: { code: "scan_failed", message } });
  }
});

async function claimAndEnqueue(
  db: ReturnType<typeof createAdminClient>,
  tenantId: string,
  employeeId: string,
  workDate: string,
  reminderKind: PunchReminderKind,
  maxPerDay: number,
): Promise<boolean> {
  const { data: claimed, error: claimError } = await db.rpc(
    "try_claim_employee_portal_punch_reminder",
    {
      p_tenant_id: tenantId,
      p_employee_id: employeeId,
      p_work_date: workDate,
      p_reminder_kind: reminderKind,
      p_max_per_day: maxPerDay,
    },
  );

  if (claimError) {
    throw new Error(`try_claim_employee_portal_punch_reminder: ${claimError.message}`);
  }

  if (claimed !== true) {
    return false;
  }

  const { data: msgId, error: enqueueError } = await db.rpc(
    "enqueue_employee_portal_punch_reminder",
    {
      p_tenant_id: tenantId,
      p_employee_id: employeeId,
      p_work_date: workDate,
      p_reminder_kind: reminderKind,
    },
  );

  if (enqueueError || msgId == null) {
    await db.rpc("release_employee_portal_punch_reminder_claim", {
      p_employee_id: employeeId,
      p_work_date: workDate,
      p_reminder_kind: reminderKind,
    }).catch(() => undefined);

    throw new Error(
      enqueueError?.message ?? "enqueue_employee_portal_punch_reminder returned null",
    );
  }

  return true;
}
