/**
 * handlers/wait.ts
 *
 * Pausa el workflow fins a wait_until (pg_cron reprendrà el pas).
 */

import type { AdminClient } from "../../queue-runtime.ts";
import type { StepHandlerResult, WorkflowContext } from "../types.ts";
import { log } from "../../observability/structured-logger.ts";

const FEATURE = "handler:wait";

export async function waitHandler(
  _db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const tenantId = context.tenant.id;
  const durationMinutes = typeof config.duration_minutes === "number"
    ? config.duration_minutes
    : 0;

  if (durationMinutes <= 0) {
    return { success: true, output: { waited: false, reason: "zero_duration" } };
  }

  const waitUntil = new Date(Date.now() + durationMinutes * 60_000).toISOString();

  log("info", FEATURE, "Scheduling wait timer", {
    tenantId,
    extra: { duration_minutes: durationMinutes, wait_until: waitUntil },
  });

  return {
    success: true,
    waitingTimer: true,
    output: {
      wait_until: waitUntil,
      duration_minutes: durationMinutes,
    },
  };
}
