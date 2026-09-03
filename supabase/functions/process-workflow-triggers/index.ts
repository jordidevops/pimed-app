/**
 * process-workflow-triggers
 *
 * Llegeix events de workflow_trigger_queue i, per cada event:
 *   1. Busca automation_workflows actius del tenant per al trigger_event
 *   2. Avalua trigger_filters (template_id, site_id, etc.)
 *   3. Per cada workflow que coincideix: crea automation_run + automation_step_runs
 *   4. Encua el primer step a automation_queue
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/process-workflow-triggers \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
 *     -H "Content-Type: application/json" \
 *     -d '{"batch_size": 10}'
 *
 * RPCs SECURITY DEFINER necessàries (implementades a la migració SQL):
 *   - api.get_active_automation_workflows({ p_tenant_id, p_event_type })
 *   - api.create_automation_run_service({ p_workflow_id, p_tenant_id, p_trigger_event, p_context })
 *   - api.create_automation_step_runs_service({ p_run_id, p_steps })
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
import { buildWorkflowContext } from "../_shared/automation/context-builder.ts";
import type {
  StepDefinition,
  WorkflowTriggerPayload,
} from "../_shared/automation/types.ts";

const FEATURE = "process-workflow-triggers";
const QUEUE_NAME = "workflow_trigger_queue";
const BATCH_SIZE = 20;
const VISIBILITY_TIMEOUT_SEC = 60;

initObservability({ feature: FEATURE });

// ---------------------------------------------------------------------------
// Types retornades per les RPCs
// ---------------------------------------------------------------------------

interface ActiveWorkflow {
  id: string;
  trigger_filters: Record<string, unknown> | null;
  steps: StepDefinition[];
}

interface StepRunRef {
  step_id: string;
  step_run_id: string;
  step_type: string;
}

// ---------------------------------------------------------------------------
// Avaluació de trigger_filters
// ---------------------------------------------------------------------------

/**
 * Comprova si els filtres d'un workflow coincideixen amb l'event rebut.
 * Suporta: template_id (del payload), site_id (del trigger).
 */
function matchesTriggerFilters(
  filters: Record<string, unknown> | null,
  payload: Record<string, unknown>,
  siteId: string | null,
): boolean {
  if (!filters) return true;

  if (typeof filters.template_id === "string") {
    if (payload.template_id !== filters.template_id) return false;
  }

  if (typeof filters.site_id === "string") {
    if (siteId !== filters.site_id) return false;
  }

  // Generic equality for any other filter key (e.g. {"to":"active"} on lifecycle)
  for (const [key, expected] of Object.entries(filters)) {
    if (key === "template_id" || key === "site_id") continue;
    if (payload[key] !== expected) return false;
  }

  return true;
}

// ---------------------------------------------------------------------------
// Handler principal
// ---------------------------------------------------------------------------

function createTriggerHandler(
  db: ReturnType<typeof createAdminClient>,
): TaskHandler {
  return async (rawPayload: TaskPayload) => {
    const payload = rawPayload as unknown as WorkflowTriggerPayload;
    const { tenant_id, event_type, entity_type, entity_id, actor_user_id, site_id, payload: triggerPayload, audit_log_id } =
      payload;

    log("info", FEATURE, "Processing workflow trigger", {
      tenantId: tenant_id,
      extra: { event_type, entity_type, entity_id, audit_log_id },
    });

    // 1. Buscar workflows actius per tenant + event_type
    const { data: workflowsData, error: workflowsError } = await db.rpc(
      "get_active_automation_workflows",
      { p_tenant_id: tenant_id, p_event_type: event_type },
    );

    if (workflowsError) {
      log("error", FEATURE, "Failed to fetch active workflows", {
        tenantId: tenant_id,
        extra: { error: workflowsError.message, event_type },
      });
      captureException(workflowsError, { feature: FEATURE, tenantId: tenant_id });
      return { success: false };
    }

    const workflows = (workflowsData as ActiveWorkflow[]) ?? [];

    if (workflows.length === 0) {
      log("info", FEATURE, "No active workflows for event", {
        tenantId: tenant_id,
        extra: { event_type },
      });
      return { success: true };
    }

    // 2. Construir el context del workflow
    let workflowContext;
    try {
      workflowContext = await buildWorkflowContext(db, {
        tenantId: tenant_id,
        siteId: site_id ?? null,
        eventType: event_type,
        entityType: entity_type ?? null,
        entityId: entity_id ?? null,
        actorUserId: actor_user_id ?? null,
        payload: triggerPayload ?? {},
      });
    } catch (err) {
      log("error", FEATURE, "Failed to build workflow context", {
        tenantId: tenant_id,
        extra: { error: err instanceof Error ? err.message : String(err) },
      });
      captureException(err, { feature: FEATURE, tenantId: tenant_id });
      return { success: false };
    }

    let anyFailed = false;

    // 3. Processar cada workflow coincident
    for (const workflow of workflows) {
      // Avaluar filtres
      if (!matchesTriggerFilters(workflow.trigger_filters, triggerPayload ?? {}, site_id ?? null)) {
        log("info", FEATURE, "Workflow filters not matched — skipping", {
          tenantId: tenant_id,
          extra: { workflow_id: workflow.id, event_type },
        });
        continue;
      }

      if (!workflow.steps || workflow.steps.length === 0) {
        log("warn", FEATURE, "Workflow has no steps — skipping", {
          tenantId: tenant_id,
          extra: { workflow_id: workflow.id },
        });
        continue;
      }

      try {
        await instantiateWorkflow(db, {
          tenantId: tenant_id,
          workflow,
          context: workflowContext,
          triggerEvent: event_type,
        });
      } catch (err) {
        // Fallada aïllada per workflow: continuem amb el següent
        log("error", FEATURE, "Failed to instantiate workflow — skipping", {
          tenantId: tenant_id,
          extra: {
            workflow_id: workflow.id,
            error: err instanceof Error ? err.message : String(err),
          },
        });
        if (isInfrastructureBug(err)) {
          captureException(err, { feature: FEATURE, tenantId: tenant_id });
        }
        anyFailed = true;
      }
    }

    // Si algun workflow ha fallat, retornem success: false per permetre retry
    // del missatge sencer (QueueRunner gestionarà el backoff).
    if (anyFailed) {
      return { success: false };
    }

    return { success: true };
  };
}

// ---------------------------------------------------------------------------
// Instanciació d'un workflow: crea run + step_runs + encua primer step
// ---------------------------------------------------------------------------

async function instantiateWorkflow(
  db: ReturnType<typeof createAdminClient>,
  params: {
    tenantId: string;
    workflow: ActiveWorkflow;
    context: unknown;
    triggerEvent: string;
  },
): Promise<void> {
  const { tenantId, workflow, context, triggerEvent } = params;

  // 3a. Crear automation_run
  const { data: runData, error: runError } = await db.rpc(
    "create_automation_run_service",
    {
      p_workflow_id: workflow.id,
      p_tenant_id: tenantId,
      p_trigger_event: triggerEvent,
      p_context: context,
    },
  );

  if (runError || !runData) {
    throw new Error(
      `create_automation_run_service failed: ${runError?.message ?? "no data"}`,
    );
  }

  const runId = (runData as { run_id: string }).run_id;

  // 3b. Crear tots els automation_step_runs (un per step, status PENDING)
  const { data: stepRunsData, error: stepRunsError } = await db.rpc(
    "create_automation_step_runs_service",
    {
      p_run_id: runId,
      p_steps: workflow.steps,
    },
  );

  if (stepRunsError || !stepRunsData) {
    throw new Error(
      `create_automation_step_runs_service failed: ${stepRunsError?.message ?? "no data"}`,
    );
  }

  const stepRuns = stepRunsData as StepRunRef[];

  if (stepRuns.length === 0) {
    throw new Error("No step_runs created — steps array may be malformed");
  }

  // 3c. Encuar el primer step (ordre preservat per l'array)
  const firstStep = stepRuns[0];
  const firstStepDef = workflow.steps[0];

  const { error: enqueueError } = await db.rpc("enqueue_automation_step", {
    p_tenant_id: tenantId,
    p_run_id: runId,
    p_step_run_id: firstStep.step_run_id,
    p_step_id: firstStep.step_id,
    p_step_type: firstStepDef.type,
    p_attempt_number: 1,
  });

  if (enqueueError) {
    throw new Error(`enqueue_automation_step failed: ${enqueueError.message}`);
  }

  log("info", FEATURE, "Workflow instantiated successfully", {
    tenantId,
    extra: {
      workflow_id: workflow.id,
      run_id: runId,
      first_step_id: firstStep.step_id,
      total_steps: stepRuns.length,
    },
  });
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
      process_workflow_trigger: createTriggerHandler(db),
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
