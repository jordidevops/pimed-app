/**
 * process-date-triggers
 *
 * Executa cada matí via pg_cron. Busca workflows amb trigger_event = 'SCHEDULED_DAILY'
 * per tots els tenants actius i emet events a workflow_trigger_queue.
 *
 * V1: només SCHEDULED_DAILY (sense filtres de data en camps de documents).
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "process-date-triggers";

initObservability();

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

  const db = createAdminClient();
  const runDate = new Date().toISOString().slice(0, 10);

  try {
    const { data: workflows, error: wfError } = await db
      .schema('data')
      .from('automation_workflows')
      .select('id, tenant_id, site_id, name')
      .eq('is_active', true)
      .eq('trigger_event', 'SCHEDULED_DAILY');

    if (wfError) {
      log('error', FEATURE, 'Failed to fetch SCHEDULED_DAILY workflows', {
        extra: { error: wfError.message },
      });
      return jsonResponse(500, { error: 'fetch_failed' });
    }

    if (!workflows || workflows.length === 0) {
      log('info', FEATURE, 'No SCHEDULED_DAILY workflows found', {
        extra: { run_date: runDate },
      });
      return jsonResponse(200, { emitted: 0, run_date: runDate });
    }

    let emitted = 0;
    const errors: string[] = [];

    for (const workflow of workflows as Array<{ id: string; tenant_id: string; site_id: string | null }>) {
      const idempotencyKey = `scheduled-daily-${workflow.id}-${runDate}`;

      const { error: enqueueError } = await db.rpc('pgmq_send', {
        p_queue: 'workflow_trigger_queue',
        p_message: {
          task: 'process_workflow_trigger',
          tenant_id: workflow.tenant_id,
          idempotency_key: idempotencyKey,
          event_type: 'SCHEDULED_DAILY',
          entity_type: null,
          entity_id: null,
          actor_user_id: null,
          site_id: workflow.site_id ?? null,
          payload: { run_date: runDate, workflow_id: workflow.id },
          enqueued_at: new Date().toISOString(),
        },
      });

      if (enqueueError) {
        errors.push(`workflow ${workflow.id}: ${enqueueError.message}`);
        log('warn', FEATURE, 'Failed to enqueue SCHEDULED_DAILY event', {
          tenantId: workflow.tenant_id,
          extra: { workflow_id: workflow.id, error: enqueueError.message },
        });
      } else {
        emitted++;
        log('info', FEATURE, 'SCHEDULED_DAILY event emitted', {
          tenantId: workflow.tenant_id,
          extra: { workflow_id: workflow.id, run_date: runDate },
        });
      }
    }

    const summary = { emitted, total: workflows.length, errors, run_date: runDate };
    log('info', FEATURE, 'Date triggers run complete', { extra: summary });

    return jsonResponse(200, summary);
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, { error: "internal_error" });
  }
});
