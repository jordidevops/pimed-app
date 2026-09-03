/**
 * process-workflow-triggers
 *
 * Llegeix events de 'workflow_trigger_queue' (alimentada per trigger a audit_logs)
 * i per cada event:
 *   1. Busca workflows actius del tenant que escolten aquest event_type
 *   2. Avalua trigger_filters (AND de tots els filters)
 *   3. Per cada workflow que coincideix: crea automation_run + step_runs + encua step 1
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { QueueRunner, type TaskHandler, type TaskPayload } from "../_shared/queue-runtime.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { buildWorkflowContext } from "../_shared/automation/context-builder.ts";
import type { AutomationWorkflow, StepDefinition, TriggerPayload } from "../_shared/automation/types.ts";

const FEATURE = "process-workflow-triggers";
const QUEUE_NAME = "workflow_trigger_queue";

initObservability();

function matchesTriggerFilters(
  filters: Record<string, unknown>,
  payload: Record<string, unknown>,
): boolean {
  for (const [key, expected] of Object.entries(filters)) {
    if (payload[key] !== expected) return false;
  }
  return true;
}

function createTriggerHandler(): TaskHandler {
  return async (rawPayload: TaskPayload, ctx) => {
    const payload = rawPayload as unknown as TriggerPayload;
    const { tenant_id, event_type, entity_type, entity_id, actor_user_id, site_id } = payload;
    const triggerPayload = (payload.payload as Record<string, unknown>) ?? {};
    const db = ctx.db;

    // 1. Find active workflows for this tenant and event
    const { data: workflows, error: wfError } = await db
      .schema('data')
      .from('automation_workflows')
      .select('id, tenant_id, site_id, name, trigger_event, trigger_filters, steps, is_active')
      .eq('tenant_id', tenant_id)
      .eq('is_active', true)
      .eq('trigger_event', event_type);

    if (wfError) {
      log('error', FEATURE, 'Failed to fetch workflows', {
        tenantId: tenant_id,
        extra: { error: wfError.message, event_type },
      });
      return { success: false };
    }

    if (!workflows || workflows.length === 0) {
      log('info', FEATURE, 'No matching workflows', {
        tenantId: tenant_id,
        extra: { event_type },
      });
      return { success: true };
    }

    // 2. Build workflow context once (shared across all matching workflows)
    const workflowContext = await buildWorkflowContext(db, {
      tenantId: tenant_id,
      siteId: site_id ?? null,
      eventType: event_type,
      entityType: entity_type ?? null,
      entityId: entity_id ?? null,
      actorUserId: actor_user_id ?? null,
      payload: triggerPayload,
    });

    for (const workflow of workflows as AutomationWorkflow[]) {
      // 3. Evaluate trigger_filters
      if (
        workflow.trigger_filters &&
        Object.keys(workflow.trigger_filters).length > 0 &&
        !matchesTriggerFilters(workflow.trigger_filters, triggerPayload)
      ) {
        log('info', FEATURE, 'Workflow filters did not match — skipping', {
          tenantId: tenant_id,
          extra: { workflow_id: workflow.id, event_type },
        });
        continue;
      }

      if (!workflow.steps || workflow.steps.length === 0) {
        log('warn', FEATURE, 'Workflow has no steps — skipping', {
          tenantId: tenant_id,
          extra: { workflow_id: workflow.id },
        });
        continue;
      }

      const firstStep = workflow.steps[0] as StepDefinition;

      // 4. Create automation_run
      const { data: run, error: runError } = await db
        .schema('data')
        .from('automation_runs')
        .insert({
          workflow_id: workflow.id,
          tenant_id,
          site_id: site_id ?? null,
          status: 'RUNNING',
          trigger_event: event_type,
          trigger_entity_type: entity_type ?? null,
          trigger_entity_id: entity_id ?? null,
          context: workflowContext,
          current_step_id: firstStep.id,
        })
        .select('id')
        .single();

      if (runError || !run) {
        log('error', FEATURE, 'automation_runs INSERT failed', {
          tenantId: tenant_id,
          extra: { workflow_id: workflow.id, error: runError?.message },
        });
        continue;
      }

      const runId = (run as { id: string }).id;

      // 5. Create all step_runs (PENDING) and collect IDs for enqueueing
      const stepRunIdMap = new Map<string, string>();
      for (const step of workflow.steps as StepDefinition[]) {
        const { data: stepRun, error: stepRunError } = await db
          .schema('data')
          .from('automation_step_runs')
          .insert({
            workflow_run_id: runId,
            step_id: step.id,
            step_name: step.name ?? null,
            step_type: step.type,
            status: 'PENDING',
          })
          .select('id')
          .single();

        if (stepRunError) {
          log('warn', FEATURE, 'automation_step_runs INSERT failed for step', {
            tenantId: tenant_id,
            extra: { run_id: runId, step_id: step.id, error: stepRunError.message },
          });
        } else if (stepRun) {
          stepRunIdMap.set(step.id, (stepRun as { id: string }).id);
        }
      }

      // 6. Enqueue first step to automation_queue
      const firstStepRunId = stepRunIdMap.get(firstStep.id) ?? null;
      const stepIdempotencyKey = `wf-step-${runId}-${firstStep.id}-0`;

      const { error: enqueueError } = await db.rpc('pgmq_send', {
        p_queue: 'automation_queue',
        p_message: {
          task: 'execute_step',
          tenant_id,
          idempotency_key: stepIdempotencyKey,
          workflow_run_id: runId,
          step_run_id: firstStepRunId,
          step_id: firstStep.id,
          step_type: firstStep.type,
          enqueued_at: new Date().toISOString(),
        },
      });

      if (enqueueError) {
        log('error', FEATURE, 'Failed to enqueue first step', {
          tenantId: tenant_id,
          extra: { run_id: runId, step_id: firstStep.id, error: enqueueError.message },
        });
        await db
          .schema('data')
          .from('automation_runs')
          .update({ status: 'FAILED', error: `Failed to enqueue first step: ${enqueueError.message}` })
          .eq('id', runId);
        continue;
      }

      log('info', FEATURE, 'Workflow run launched', {
        tenantId: tenant_id,
        extra: { workflow_id: workflow.id, run_id: runId, first_step: firstStep.id },
      });
    }

    return { success: true };
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const db = createAdminClient();

  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    handlers: { process_workflow_trigger: createTriggerHandler() },
    db,
    maxAttempts: 3,
    batchSize: 20,
    visibilityTimeoutSec: 60,
  });

  try {
    const summary = await runner.runBatch();
    log("info", FEATURE, "Batch complete", { extra: summary as Record<string, unknown> });
    return new Response(JSON.stringify(summary), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return new Response(JSON.stringify({ error: "internal_error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
