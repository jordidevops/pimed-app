/**
 * process-automation-queue
 *
 * Llegeix step_runs de 'automation_queue' i executa cada pas del workflow.
 * Usa QueueRunner + step-executor per despachar al handler correcte.
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { QueueRunner, type TaskHandler, type TaskPayload } from "../_shared/queue-runtime.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { executeStep } from "../_shared/automation/step-executor.ts";
import type { AutomationRun, AutomationWorkflow, StepDefinition } from "../_shared/automation/types.ts";

const FEATURE = "process-automation-queue";
const QUEUE_NAME = "automation_queue";

initObservability();

type StepPayload = {
  workflow_run_id: string;
  step_run_id?: string | null;
  step_id: string;
  step_type: string;
  tenant_id: string;
};

function createStepExecutorHandler(): TaskHandler {
  return async (rawPayload: TaskPayload, ctx) => {
    const payload = rawPayload as unknown as StepPayload;
    const { workflow_run_id, step_id, tenant_id } = payload;
    const db = ctx.db;

    if (!workflow_run_id || !step_id) {
      log('error', FEATURE, 'Invalid step payload: missing workflow_run_id or step_id', {
        tenantId: tenant_id,
        extra: { payload },
      });
      return { success: false };
    }

    // 1. Load automation_run
    const { data: runData, error: runError } = await db
      .schema('data')
      .from('automation_runs')
      .select('id, workflow_id, tenant_id, site_id, status, trigger_event, trigger_entity_type, trigger_entity_id, context, current_step_id, error')
      .eq('id', workflow_run_id)
      .single();

    if (runError || !runData) {
      log('error', FEATURE, 'Could not load automation_run', {
        tenantId: tenant_id,
        extra: { workflow_run_id, error: runError?.message },
      });
      return { success: false };
    }

    const run = runData as AutomationRun;

    if (run.status === 'CANCELLED' || run.status === 'COMPLETED' || run.status === 'FAILED') {
      log('info', FEATURE, 'Run already in terminal state — skipping step', {
        tenantId: tenant_id,
        extra: { workflow_run_id, status: run.status, step_id },
      });
      return { success: true };
    }

    // 2. Load workflow to get step definition
    const { data: wfData, error: wfError } = await db
      .schema('data')
      .from('automation_workflows')
      .select('id, tenant_id, site_id, name, trigger_event, trigger_filters, steps, is_active')
      .eq('id', run.workflow_id)
      .single();

    if (wfError || !wfData) {
      log('error', FEATURE, 'Could not load automation_workflow', {
        tenantId: tenant_id,
        extra: { workflow_id: run.workflow_id, error: wfError?.message },
      });
      return { success: false };
    }

    const workflow = wfData as AutomationWorkflow;
    const stepDef = workflow.steps.find((s: StepDefinition) => s.id === step_id);

    if (!stepDef) {
      log('error', FEATURE, 'Step definition not found in workflow', {
        tenantId: tenant_id,
        extra: { workflow_id: run.workflow_id, step_id },
      });
      return { success: false };
    }

    // 3. Resolve step_run_id: from payload or query
    let stepRunId: string | null = payload.step_run_id ?? null;

    if (!stepRunId) {
      const { data: stepRunData } = await db
        .schema('data')
        .from('automation_step_runs')
        .select('id')
        .eq('workflow_run_id', workflow_run_id)
        .eq('step_id', step_id)
        .order('created_at', { ascending: true })
        .limit(1)
        .maybeSingle();
      stepRunId = (stepRunData as { id: string } | null)?.id ?? null;
    }

    if (!stepRunId) {
      log('error', FEATURE, 'Could not find step_run for step', {
        tenantId: tenant_id,
        extra: { workflow_run_id, step_id },
      });
      return { success: false };
    }

    // 4. Get current attempt count and mark step as RUNNING
    const { data: currentStepRun } = await db
      .schema('data')
      .from('automation_step_runs')
      .select('attempt_number')
      .eq('id', stepRunId)
      .single();

    const attemptNumber = ((currentStepRun as { attempt_number: number } | null)?.attempt_number ?? 0) + 1;

    await db
      .schema('data')
      .from('automation_step_runs')
      .update({
        status: 'RUNNING',
        attempt_number: attemptNumber,
        started_at: new Date().toISOString(),
      })
      .eq('id', stepRunId);

    await db
      .schema('data')
      .from('automation_runs')
      .update({ status: 'RUNNING', current_step_id: step_id })
      .eq('id', workflow_run_id);

    // 5. Execute the step — pass apiDb (supports both api RPCs and data schema)
    const stepInput = { steps_output: (run.context as Record<string, unknown>).steps ?? {} };
    const result = await executeStep(db, stepDef, run, stepRunId, stepInput);

    const isWaiting = result.nextStatus === 'WAITING_HUMAN' || result.nextStatus === 'WAITING_TIMER';

    if (isWaiting) {
      await db
        .schema('data')
        .from('automation_step_runs')
        .update({
          status: result.nextStatus,
          output: result.output ?? {},
          attempt_number: attemptNumber,
        })
        .eq('id', stepRunId);

      await db
        .schema('data')
        .from('automation_runs')
        .update({ status: result.nextStatus, current_step_id: step_id })
        .eq('id', workflow_run_id);

      log('info', FEATURE, 'Step waiting', {
        tenantId: tenant_id,
        extra: { workflow_run_id, step_id, next_status: result.nextStatus },
      });

      return { success: true };
    }

    if (result.success) {
      await db
        .schema('data')
        .from('automation_step_runs')
        .update({
          status: 'COMPLETED',
          output: result.output ?? {},
          completed_at: new Date().toISOString(),
          attempt_number: attemptNumber,
        })
        .eq('id', stepRunId);

      // Determine next step
      const nextStepId = stepDef.on_success;
      let nextStep: StepDefinition | null = null;

      if (nextStepId && nextStepId !== 'END_OK' && nextStepId !== 'END_FAIL') {
        nextStep = workflow.steps.find((s: StepDefinition) => s.id === nextStepId) ?? null;
      } else if (!nextStepId) {
        const currentIdx = workflow.steps.findIndex((s: StepDefinition) => s.id === step_id);
        if (currentIdx >= 0 && currentIdx < workflow.steps.length - 1) {
          nextStep = workflow.steps[currentIdx + 1];
        }
      }

      if (nextStep) {
        // Update context with step output
        const updatedSteps = {
          ...((run.context.steps as Record<string, unknown>) ?? {}),
          [step_id]: result.output ?? {},
        };

        await db
          .schema('data')
          .from('automation_runs')
          .update({
            context: { ...run.context, steps: updatedSteps },
            current_step_id: nextStep.id,
          })
          .eq('id', workflow_run_id);

        // Find the next step's step_run_id
        const { data: nextStepRunData } = await db
          .schema('data')
          .from('automation_step_runs')
          .select('id')
          .eq('workflow_run_id', workflow_run_id)
          .eq('step_id', nextStep.id)
          .order('created_at', { ascending: true })
          .limit(1)
          .maybeSingle();

        const nextStepRunId = (nextStepRunData as { id: string } | null)?.id ?? null;
        const nextIdempotencyKey = `wf-step-${workflow_run_id}-${nextStep.id}-${attemptNumber}`;

        const { error: enqueueErr } = await db.rpc('pgmq_send', {
          p_queue: QUEUE_NAME,
          p_message: {
            task: 'execute_step',
            tenant_id,
            idempotency_key: nextIdempotencyKey,
            workflow_run_id,
            step_run_id: nextStepRunId,
            step_id: nextStep.id,
            step_type: nextStep.type,
            enqueued_at: new Date().toISOString(),
          },
        });

        if (enqueueErr) {
          log('error', FEATURE, 'Failed to enqueue next step', {
            tenantId: tenant_id,
            extra: { workflow_run_id, next_step_id: nextStep.id, error: enqueueErr.message },
          });
        }
      } else {
        await db
          .schema('data')
          .from('automation_runs')
          .update({
            status: 'COMPLETED',
            current_step_id: null,
            completed_at: new Date().toISOString(),
          })
          .eq('id', workflow_run_id);

        log('info', FEATURE, 'Workflow run completed', {
          tenantId: tenant_id,
          extra: { workflow_run_id, workflow_id: run.workflow_id },
        });
      }

      return { success: true };
    }

    // Step failed
    const errorMsg = result.error ?? 'Step handler returned success: false';

    if (ctx.readCount >= 3) {
      await db
        .schema('data')
        .from('automation_step_runs')
        .update({
          status: 'FAILED',
          output: {},
          error: errorMsg,
          attempt_number: attemptNumber,
          completed_at: new Date().toISOString(),
        })
        .eq('id', stepRunId);

      await db
        .schema('data')
        .from('automation_runs')
        .update({
          status: 'FAILED',
          current_step_id: step_id,
          error: errorMsg,
          completed_at: new Date().toISOString(),
        })
        .eq('id', workflow_run_id);

      // Enqueue on_failure step if defined
      const failureStepId = stepDef.on_failure;
      if (failureStepId && failureStepId !== 'END_FAIL') {
        const failureStep = workflow.steps.find((s: StepDefinition) => s.id === failureStepId);
        if (failureStep) {
          const { data: failStepRun } = await db
            .schema('data')
            .from('automation_step_runs')
            .select('id')
            .eq('workflow_run_id', workflow_run_id)
            .eq('step_id', failureStep.id)
            .maybeSingle();

          const failIdempotencyKey = `wf-fail-${workflow_run_id}-${failureStep.id}-${attemptNumber}`;
          await db.rpc('pgmq_send', {
            p_queue: QUEUE_NAME,
            p_message: {
              task: 'execute_step',
              tenant_id,
              idempotency_key: failIdempotencyKey,
              workflow_run_id,
              step_run_id: (failStepRun as { id: string } | null)?.id ?? null,
              step_id: failureStep.id,
              step_type: failureStep.type,
              enqueued_at: new Date().toISOString(),
            },
          });
        }
      }

      log('error', FEATURE, 'Step permanently failed after max retries', {
        tenantId: tenant_id,
        extra: { workflow_run_id, step_id, error: errorMsg },
      });

      return { success: false };
    }

    // Retriable failure
    await db
      .schema('data')
      .from('automation_step_runs')
      .update({
        status: 'FAILED',
        error: errorMsg,
        attempt_number: attemptNumber,
      })
      .eq('id', stepRunId);

    log('warn', FEATURE, 'Step failed — will retry', {
      tenantId: tenant_id,
      extra: { workflow_run_id, step_id, attempt: attemptNumber, error: errorMsg },
    });

    return { success: false };
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const db = createAdminClient();

  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    handlers: { execute_step: createStepExecutorHandler() },
    db,
    maxAttempts: 3,
    batchSize: 10,
    visibilityTimeoutSec: 180,
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
