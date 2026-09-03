/**
 * step-executor.ts
 *
 * Dispatcher de handlers per tipus de step.
 * Rep el step_definition, el step_run i el workflow_run ja hidratats,
 * i delega l'execució al handler corresponent.
 */

import type { AdminClient } from "../queue-runtime.ts";
import type {
  AutomationRunStatus,
  AutomationStepStatus,
  StepDefinition,
  StepHandlerResult,
  StepType,
  WorkflowContext,
} from "./types.ts";
import { resolveConfigValues } from "./template-engine.ts";
import { log } from "../observability/structured-logger.ts";

import { sendEmailHandler } from "./handlers/send-email.ts";
import { sendNotificationHandler } from "./handlers/send-notification.ts";
import { createTaskHandler } from "./handlers/create-task.ts";
import { createCalendarEventHandler } from "./handlers/create-calendar-event.ts";
import { generateDocumentHandler } from "./handlers/generate-document.ts";
import { sendForSigningHandler } from "./handlers/send-for-signing.ts";
import { humanApprovalHandler } from "./handlers/human-approval.ts";
import { conditionHandler } from "./handlers/condition.ts";
import { updateFieldHandler } from "./handlers/update-field.ts";
import { waitHandler } from "./handlers/wait.ts";

const FEATURE = "step-executor";

// ---------------------------------------------------------------------------
// Row types — representació de les files de BD rebudes via RPC
// ---------------------------------------------------------------------------

export interface AutomationStepRunRow {
  id: string;
  run_id: string;
  step_id: string;
  step_type: StepType;
  status: AutomationStepStatus;
  /** Número d'intents acumulats (comença en 1) */
  attempt_count: number;
  started_at: string | null;
  completed_at: string | null;
  output: Record<string, unknown> | null;
  error: string | null;
}

export interface AutomationRunRow {
  id: string;
  workflow_id: string;
  tenant_id: string;
  status: AutomationRunStatus;
  trigger_event: string;
  started_at: string | null;
  completed_at: string | null;
  error: string | null;
}

// ---------------------------------------------------------------------------
// Tipus dels handlers individuals
// ---------------------------------------------------------------------------

export type StepHandler = (
  db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
) => Promise<StepHandlerResult>;

// ---------------------------------------------------------------------------
// Registre de handlers
// ---------------------------------------------------------------------------

const HANDLERS: Record<StepType, StepHandler> = {
  SEND_EMAIL: sendEmailHandler,
  SEND_NOTIFICATION: sendNotificationHandler,
  CREATE_TASK: createTaskHandler,
  CREATE_CALENDAR_EVENT: createCalendarEventHandler,
  GENERATE_DOCUMENT: generateDocumentHandler,
  SEND_FOR_SIGNING: sendForSigningHandler,
  HUMAN_APPROVAL: humanApprovalHandler,
  CONDITION: conditionHandler,
  UPDATE_FIELD: updateFieldHandler,
  WAIT: waitHandler,
};

// ---------------------------------------------------------------------------
// executeStep — punt d'entrada públic
// ---------------------------------------------------------------------------

/**
 * Executa el handler corresponent al tipus de step.
 *
 * El context passat ja ha de tenir integrats els outputs dels steps anteriors
 * (context.steps.*) — responsabilitat del caller (process-automation-queue).
 *
 * Retorna sempre un StepHandlerResult; mai llança (errors atrapats internament).
 */
export async function executeStep(
  db: AdminClient,
  stepDef: StepDefinition,
  stepRun: AutomationStepRunRow,
  workflowRun: AutomationRunRow,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const handler = HANDLERS[stepDef.type];

  if (!handler) {
    log("warn", FEATURE, "Unknown step type", {
      tenantId: workflowRun.tenant_id,
      extra: { step_type: stepDef.type, step_id: stepDef.id },
    });
    return { success: false, error: `Unknown step type: ${stepDef.type}` };
  }

  // Resoldre templates al config amb el context actual
  const resolvedConfig = resolveConfigValues(stepDef.config, context as unknown as Record<string, unknown>);

  log("info", FEATURE, `Dispatching step`, {
    tenantId: workflowRun.tenant_id,
    correlationId: stepRun.id,
    extra: {
      step_id: stepDef.id,
      step_type: stepDef.type,
      attempt: stepRun.attempt_count,
    },
  });

  try {
    const result = await handler(db, resolvedConfig, context);

    log("info", FEATURE, "Step handler returned", {
      tenantId: workflowRun.tenant_id,
      correlationId: stepRun.id,
      extra: {
        step_id: stepDef.id,
        success: result.success,
        waitingHuman: result.waitingHuman ?? false,
      },
    });

    return result;
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "Step handler threw unhandled error", {
      tenantId: workflowRun.tenant_id,
      correlationId: stepRun.id,
      extra: { step_id: stepDef.id, step_type: stepDef.type, error: errorMsg },
    });
    return { success: false, error: errorMsg };
  }
}
