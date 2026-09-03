/**
 * process-automation-queue
 *
 * Llegeix steps de automation_queue i executa el handler corresponent.
 * Cada step és independent: llegeix l'automation_step_run, executa l'handler,
 * actualitza l'estat, i encua el step següent (si n'hi ha).
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/process-automation-queue \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
 *     -H "Content-Type: application/json" \
 *     -d '{"batch_size": 10}'
 *
 * RPCs SECURITY DEFINER necessàries (implementades a la migració SQL):
 *   - api.get_automation_execution_context({ p_step_run_id })
 *       → { step_run, workflow_run, step_definition, context }
 *   - api.start_automation_step_run({ p_step_run_id })
 *   - api.complete_automation_step_run({ p_step_run_id, p_status, p_output, p_error })
 *   - api.complete_automation_run({ p_run_id, p_status, p_error })
 *   - api.enqueue_automation_step({ p_tenant_id, p_run_id, p_step_run_id, p_step_id, p_step_type, p_attempt_number })
 */

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  QueueRunner,
  type TaskHandler,
  type TaskPayload,
} from "../_shared/queue-runtime.ts";
import {
  captureException,
  initObservability,
} from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";
import { executeStep } from "../_shared/automation/step-executor.ts";
import type {
  AutomationStepPayload,
  AutomationRunStatus,
  AutomationStepStatus,
  StepDefinition,
  StepHandlerResult,
  WorkflowContext,
} from "../_shared/automation/types.ts";
import type {
  AutomationRunRow,
  AutomationStepRunRow,
} from "../_shared/automation/step-executor.ts";

const FEATURE = "process-automation-queue";
const QUEUE_NAME = "automation_queue";
const BATCH_SIZE = 20;
const VISIBILITY_TIMEOUT_SEC = 120;

initObservability({ feature: FEATURE });

// ---------------------------------------------------------------------------
// Tipus retornats per get_automation_execution_context
// ---------------------------------------------------------------------------

interface ExecutionContext {
  step_run: AutomationStepRunRow;
  workflow_run: AutomationRunRow;
  step_definition: StepDefinition;
  /** Context del workflow amb outputs dels steps anteriors ja integrats */
  context: WorkflowContext;
  /** Refs a tots els step_runs del run (per trobar el next step_run_id) */
  all_step_runs: Array<{ step_id: string; step_run_id: string; step_type: string }>;
}

// ---------------------------------------------------------------------------
// Lògica de determinació del proper step
// ---------------------------------------------------------------------------

type NextAction =
  | { type: "COMPLETED" }
  | { type: "FAILED"; error: string }
  | { type: "WAITING_HUMAN" }
  | { type: "WAITING_TIMER" }
  | { type: "ENQUEUE_NEXT"; stepRunId: string; stepId: string; stepType: string };

function resolveNextAction(
  result: StepHandlerResult,
  stepDef: StepDefinition,
  allStepRuns: ExecutionContext["all_step_runs"],
): NextAction {
  if (result.waitingHuman) {
    return { type: "WAITING_HUMAN" };
  }

  if (result.waitingTimer) {
    return { type: "WAITING_TIMER" };
  }

  // Determinar el step_id destí
  let nextStepId: string | undefined;

  if (result.nextStepId) {
    // El handler sobreescriu el routing (ex: CONDITION)
    nextStepId = result.nextStepId;
  } else if (result.success) {
    nextStepId = stepDef.on_success ?? "END_OK";
  } else {
    nextStepId = stepDef.on_failure ?? "END_FAIL";
  }

  // Terminals
  if (nextStepId === "END_OK" || nextStepId == null) {
    return { type: "COMPLETED" };
  }

  if (nextStepId === "END_FAIL") {
    return {
      type: "FAILED",
      error: result.error ?? "Step ended with END_FAIL",
    };
  }

  // Buscar el step_run corresponent al next step_id
  const nextRef = allStepRuns.find((r) => r.step_id === nextStepId);
  if (!nextRef) {
    return {
      type: "FAILED",
      error: `next_step_id '${nextStepId}' not found in step_runs`,
    };
  }

  return {
    type: "ENQUEUE_NEXT",
    stepRunId: nextRef.step_run_id,
    stepId: nextRef.step_id,
    stepType: nextRef.step_type,
  };
}

// ---------------------------------------------------------------------------
// Handler principal
// ---------------------------------------------------------------------------

function createStepHandler(
  db: ReturnType<typeof createAdminClient>,
): TaskHandler {
  return async (rawPayload: TaskPayload) => {
    const payload = rawPayload as unknown as AutomationStepPayload;
    const { tenant_id, step_run_id, workflow_run_id, step_id, attempt_number } =
      payload;

    log("info", FEATURE, "Executing automation step", {
      tenantId: tenant_id,
      correlationId: step_run_id,
      extra: { workflow_run_id, step_id, attempt_number },
    });

    // 1. Llegir context complet del step (step_run + run + step_def + context)
    const { data: ctxData, error: ctxError } = await db.rpc(
      "get_automation_execution_context",
      { p_step_run_id: step_run_id },
    );

    if (ctxError || !ctxData) {
      log("error", FEATURE, "Failed to fetch execution context", {
        tenantId: tenant_id,
        correlationId: step_run_id,
        extra: { error: ctxError?.message ?? "no data" },
      });
      captureException(ctxError ?? new Error("no execution context"), {
        feature: FEATURE,
        tenantId: tenant_id,
      });
      return { success: false };
    }

    const execCtx = ctxData as ExecutionContext;
    const { step_run, workflow_run, step_definition, context, all_step_runs } =
      execCtx;

    // Protecció: si el step_run ja no és PENDING (ja processat per duplicat)
    if (step_run.status !== "PENDING") {
      log("info", FEATURE, "Step already processed — idempotent skip", {
        tenantId: tenant_id,
        correlationId: step_run_id,
        extra: { status: step_run.status },
      });
      return { success: true };
    }

    // 2. Marcar step_run com a RUNNING
    const { error: startError } = await db.rpc("start_automation_step_run", {
      p_step_run_id: step_run_id,
    });

    if (startError) {
      log("warn", FEATURE, "Failed to mark step as RUNNING", {
        tenantId: tenant_id,
        correlationId: step_run_id,
        extra: { error: startError.message },
      });
      // No fatal — continuem intentant executar el step
    }

    // 3. Executar el handler del step
    // Injectem el runtime al context perquè els handlers que ho necessitin
    // (ex: HUMAN_APPROVAL) tinguin accés al step_run_id i workflow_run_id.
    const enrichedContext = {
      ...context,
      runtime: {
        step_run_id: step_run_id,
        workflow_run_id: workflow_run.id,
        step_id: step_run.step_id,
        tenant_id: tenant_id,
      },
    };

    let result: StepHandlerResult;
    try {
      result = await executeStep(db, step_definition, step_run, workflow_run, enrichedContext);
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      log("error", FEATURE, "Step execution threw unexpected error", {
        tenantId: tenant_id,
        correlationId: step_run_id,
        extra: { step_id, step_type: step_definition.type, error: errorMsg },
      });

      if (isInfrastructureBug(err)) {
        captureException(err, { feature: FEATURE, tenantId: tenant_id });
      }

      // Marcar el step_run com a FAILED
      await safeCompleteStepRun(db, step_run_id, "FAILED", undefined, errorMsg);

      // Comprovar si hi ha més reintents disponibles
      const maxRetries = step_definition.retry_max ?? 3;
      if ((step_run.attempt_count ?? 1) < maxRetries) {
        return { success: false, selfManaged: true };
      }

      // Sense més reintents: marcar el run com a FAILED
      await safeCompleteRun(db, workflow_run.id, "FAILED", errorMsg);
      return { success: false };
    }

    // 4. Processar el resultat
    const stepStatus: AutomationStepStatus = result.waitingHuman
      ? "WAITING_HUMAN"
      : result.waitingTimer
      ? "WAITING_TIMER"
      : result.success
      ? "COMPLETED"
      : "FAILED";

    await safeCompleteStepRun(
      db,
      step_run_id,
      stepStatus,
      result.output,
      result.error,
    );

    if (result.waitingTimer) {
      const waitUntil = typeof result.output?.wait_until === "string"
        ? result.output.wait_until
        : null;

      const { error: waitErr } = await db.rpc("schedule_automation_wait", {
        p_run_id: workflow_run.id,
        p_step_run_id: step_run_id,
        p_wait_until: waitUntil,
      });

      if (waitErr) {
        log("error", FEATURE, "schedule_automation_wait failed", {
          tenantId: tenant_id,
          correlationId: step_run_id,
          extra: { error: waitErr.message },
        });
        captureException(waitErr, { feature: FEATURE, tenantId: tenant_id });
      }
    }

    // 5. Determinar l'acció següent
    const nextAction = resolveNextAction(result, step_definition, all_step_runs);

    switch (nextAction.type) {
      case "COMPLETED": {
        log("info", FEATURE, "Workflow completed successfully", {
          tenantId: tenant_id,
          extra: { workflow_run_id, step_id },
        });
        await safeCompleteRun(db, workflow_run.id, "COMPLETED");
        break;
      }

      case "FAILED": {
        log("warn", FEATURE, "Workflow ended with FAILED", {
          tenantId: tenant_id,
          extra: { workflow_run_id, step_id, error: nextAction.error },
        });
        await safeCompleteRun(db, workflow_run.id, "FAILED", nextAction.error);
        break;
      }

      case "WAITING_HUMAN": {
        log("info", FEATURE, "Workflow waiting for human approval", {
          tenantId: tenant_id,
          extra: { workflow_run_id, step_id },
        });
        await safeUpdateRunStatus(db, workflow_run.id, "WAITING_HUMAN");
        break;
      }

      case "WAITING_TIMER": {
        log("info", FEATURE, "Workflow waiting for timer or async event", {
          tenantId: tenant_id,
          extra: { workflow_run_id, step_id },
        });
        break;
      }

      case "ENQUEUE_NEXT": {
        const { error: enqErr } = await db.rpc("enqueue_automation_step", {
          p_tenant_id: tenant_id,
          p_run_id: workflow_run_id,
          p_step_run_id: nextAction.stepRunId,
          p_step_id: nextAction.stepId,
          p_step_type: nextAction.stepType,
          p_attempt_number: 1,
        });

        if (enqErr) {
          log("error", FEATURE, "Failed to enqueue next step", {
            tenantId: tenant_id,
            correlationId: step_run_id,
            extra: { next_step_id: nextAction.stepId, error: enqErr.message },
          });
          captureException(enqErr, { feature: FEATURE, tenantId: tenant_id });
          // El run queda en estat inconsistent — NO retornem failure per no re-executar
          // aquest step; loguem i continuem. El monitoring alertarà.
        } else {
          log("info", FEATURE, "Next step enqueued", {
            tenantId: tenant_id,
            extra: { next_step_id: nextAction.stepId },
          });
        }
        break;
      }
    }

    return { success: true };
  };
}

// ---------------------------------------------------------------------------
// Helpers d'actualització de BD (fire-and-log, no bloquejen el resultat)
// ---------------------------------------------------------------------------

async function safeCompleteStepRun(
  db: ReturnType<typeof createAdminClient>,
  stepRunId: string,
  status: AutomationStepStatus,
  output?: Record<string, unknown>,
  error?: string,
): Promise<void> {
  const { error: dbError } = await db.rpc("complete_automation_step_run", {
    p_step_run_id: stepRunId,
    p_status: status,
    p_output: output ?? null,
    p_error: error ?? null,
  });

  if (dbError) {
    log("warn", FEATURE, "complete_automation_step_run failed", {
      extra: { step_run_id: stepRunId, status, error: dbError.message },
    });
  }
}

async function safeCompleteRun(
  db: ReturnType<typeof createAdminClient>,
  runId: string,
  status: AutomationRunStatus,
  error?: string,
): Promise<void> {
  const { error: dbError } = await db.rpc("complete_automation_run", {
    p_run_id: runId,
    p_status: status,
    p_error: error ?? null,
  });

  if (dbError) {
    log("warn", FEATURE, "complete_automation_run failed", {
      extra: { run_id: runId, status, error: dbError.message },
    });
  }
}

async function safeUpdateRunStatus(
  db: ReturnType<typeof createAdminClient>,
  runId: string,
  status: AutomationRunStatus,
): Promise<void> {
  const { error: dbError } = await db.rpc("update_automation_run_status", {
    p_run_id: runId,
    p_status: status,
  });

  if (dbError) {
    log("warn", FEATURE, "update_automation_run_status failed", {
      extra: { run_id: runId, status, error: dbError.message },
    });
  }
}

// ---------------------------------------------------------------------------
// Entrada Deno.serve
// ---------------------------------------------------------------------------

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
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
    // body buit o no JSON → default
  }

  const db = createAdminClient();
  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    handlers: {
      execute_step: createStepHandler(db),
    },
    db,
    maxAttempts: 3,
    batchSize,
    visibilityTimeoutSec: VISIBILITY_TIMEOUT_SEC,
  });

  try {
    const summary = await runner.runBatch();
    log("info", FEATURE, "Batch complete", {
      extra: summary as Record<string, unknown>,
    });
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
