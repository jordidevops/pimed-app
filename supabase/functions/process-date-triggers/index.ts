// =============================================================================
// process-date-triggers — Processament de triggers per data
// =============================================================================

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "process-date-triggers";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorResponse(status: number, error: string, message?: string): Response {
  return jsonResponse({ error, message }, status);
}

function isAuthorized(req: Request): boolean {
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  return token === SERVICE_ROLE_KEY && SERVICE_ROLE_KEY !== "";
}

interface DateWorkflowRow {
  id: string;
  name: string;
  tenant_id: string;
  trigger_event: string;
  trigger_filters: {
    field_key?: string;
    days_ahead?: number;
  } | null;
}

interface ProcessResult {
  triggered: number;
  processed_workflows: number;
  skipped_workflows: number;
  message: string;
  details: Array<{
    workflow_id: string;
    workflow_name: string;
    status: string;
    triggered?: number;
  }>;
}

async function processDateTriggers(): Promise<ProcessResult> {
  const adminClient = createAdminClient();

  const { data: workflows, error } = await adminClient
    .schema("data" as "api")
    .from("automation_workflows" as never)
    .select("id, name, tenant_id, trigger_event, trigger_filters")
    .eq("is_active" as never, true)
    .in("trigger_event" as never, ["SCHEDULED_DAILY", "DATE_FIELD_REACHED"])
    .eq("is_blueprint" as never, false) as {
      data: DateWorkflowRow[] | null;
      error: { message: string } | null;
    };

  if (error) {
    throw error;
  }

  const workflowList = workflows ?? [];
  const details: ProcessResult["details"] = [];
  let totalTriggered = 0;
  let skipped = 0;

  const scheduledTenants = new Set<string>();

  for (const workflow of workflowList) {
    if (workflow.trigger_event === "SCHEDULED_DAILY") {
      if (scheduledTenants.has(workflow.tenant_id)) {
        details.push({
          workflow_id: workflow.id,
          workflow_name: workflow.name,
          status: "scheduled_via_tenant_batch",
        });
        continue;
      }

      const { error: schedErr } = await adminClient.rpc(
        "emit_scheduled_automation_trigger",
        { p_tenant_id: workflow.tenant_id, p_event_type: "SCHEDULED_DAILY" },
      );

      if (schedErr) {
        log("error", FEATURE, "emit_scheduled_automation_trigger failed", {
          extra: { tenant_id: workflow.tenant_id, error: schedErr.message },
        });
        skipped++;
        details.push({
          workflow_id: workflow.id,
          workflow_name: workflow.name,
          status: "error",
        });
        continue;
      }

      scheduledTenants.add(workflow.tenant_id);
      totalTriggered++;
      details.push({
        workflow_id: workflow.id,
        workflow_name: workflow.name,
        status: "scheduled_daily_emitted",
        triggered: 1,
      });
      continue;
    }

    const fieldKey = workflow.trigger_filters?.field_key;
    const daysAhead = workflow.trigger_filters?.days_ahead ?? 0;

    if (!fieldKey) {
      skipped++;
      details.push({
        workflow_id: workflow.id,
        workflow_name: workflow.name,
        status: "skipped_no_field_key",
      });
      continue;
    }

    const { data: count, error: dateErr } = await adminClient.rpc(
      "emit_date_field_triggers_for_tenant",
      {
        p_tenant_id: workflow.tenant_id,
        p_field_key: fieldKey,
        p_days_ahead: daysAhead,
      },
    );

    if (dateErr) {
      log("error", FEATURE, "emit_date_field_triggers_for_tenant failed", {
        extra: { workflow_id: workflow.id, error: dateErr.message },
      });
      skipped++;
      details.push({
        workflow_id: workflow.id,
        workflow_name: workflow.name,
        status: "error",
      });
      continue;
    }

    const triggered = typeof count === "number" ? count : 0;
    totalTriggered += triggered;
    details.push({
      workflow_id: workflow.id,
      workflow_name: workflow.name,
      status: "date_field_processed",
      triggered,
    });
  }

  const { error: timerErr } = await adminClient.rpc("process_automation_wait_timers");
  if (timerErr) {
    log("warn", FEATURE, "process_automation_wait_timers failed", {
      extra: { error: timerErr.message },
    });
  }

  return {
    triggered: totalTriggered,
    processed_workflows: workflowList.length - skipped,
    skipped_workflows: skipped,
    message: "date_triggers_processed",
    details,
  };
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Only POST is supported");
  }

  if (!isAuthorized(req)) {
    log("warn", FEATURE, "Unauthorized request rejected");
    return errorResponse(401, "unauthorized");
  }

  log("info", FEATURE, "Starting date trigger processing", {
    extra: { timestamp: new Date().toISOString() },
  });

  try {
    const result = await processDateTriggers();

    log("info", FEATURE, "Date trigger processing complete", {
      extra: {
        triggered: result.triggered,
        processed_workflows: result.processed_workflows,
        skipped_workflows: result.skipped_workflows,
      },
    });

    return jsonResponse(result);
  } catch (err) {
    captureException(err, {
      feature: FEATURE,
      tags: { cron: "true" },
      extra: { error: String(err) },
    });

    log("error", FEATURE, "Date trigger processing failed", {
      extra: { error: String(err) },
    });

    return errorResponse(500, "internal_error", String(err));
  }
});
