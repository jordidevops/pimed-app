/**
 * ai-cron-analytics
 *
 * Worker S7: analítica proactiva pilot (employee_health_scan).
 * Cridat per pg_cron via data.invoke_ai_cron_analytics_worker().
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/ai-cron-analytics \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
 *     -H "Content-Type: application/json" -d '{}'
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { applyOverrides } from "../_shared/ai/providers.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { loadTenantAiRuntimeConfig } from "../_shared/ai/run.ts";
import {
  AiGovernanceError,
  prepareAiExecution,
  toHttpGovernanceError,
} from "../_shared/ai/governance.ts";
import { logAiUsage } from "../_shared/ai/usage.ts";
import { runToolLoop } from "../_shared/ai/tools/executor.ts";
import { listProviderSchemas } from "../_shared/ai/tools/registry.ts";
import { resolveMemberAiContext } from "../_shared/ai/tools/permissions.ts";
import { buildCronAnalyticsSystemPrompt } from "../_shared/ai/tools/system-prompt-cron.ts";
import type { AiMessage } from "../_shared/ai/types.ts";
import type { ToolExecutionContext } from "../_shared/ai/tools/types.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "ai-cron-analytics";

const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";

type ScheduledJobRow = {
  id: string;
  tenantId: string;
  siteId: string | null;
  notifyUserId: string;
  jobKey: string;
  config: Record<string, unknown>;
};

type JobRunResult = {
  jobId: string;
  tenantId: string;
  jobKey: string;
  status: "success" | "skipped" | "error";
  alertCreated?: boolean;
  summary?: string;
  error?: string;
};

function extractBearerToken(req: Request): string | null {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return null;
  return auth.slice("Bearer ".length).trim();
}

async function runScheduledJob(
  adminClient: ReturnType<typeof createAdminClient>,
  job: ScheduledJobRow,
): Promise<JobRunResult> {
  const startedAt = Date.now();

  try {
    const prepared = await prepareAiExecution(adminClient, {
      tenantId: job.tenantId,
      userId: job.notifyUserId,
      siteId: job.siteId,
      feature: "cron_analytics",
      estimatedTokens: 2048,
    });

    const runtime = await loadTenantAiRuntimeConfig(
      adminClient,
      job.tenantId,
      prepared.provider,
    );
    const config = applyOverrides(runtime, {
      provider: prepared.provider,
      model: prepared.model,
    });

    const { data: snapshot, error: snapshotError } = await adminClient.rpc(
      "aggregate_tenant_ai_analytics_snapshot_service",
      {
        p_tenant_id: job.tenantId,
        p_site_id: job.siteId,
      },
    );
    if (snapshotError) throw new Error(snapshotError.message);

    const memberCtx = await resolveMemberAiContext(
      adminClient,
      job.tenantId,
      job.notifyUserId,
    );

    const ctx: ToolExecutionContext = {
      tenantId: job.tenantId,
      siteId: job.siteId,
      userId: job.notifyUserId,
      role: memberCtx.role,
      permissions: memberCtx.permissions,
      feature: "cron_analytics",
      provider: config.provider,
      metadata: { jobId: job.id, jobKey: job.jobKey },
    };

    const tools = listProviderSchemas(ctx);
    const systemPrompt = buildCronAnalyticsSystemPrompt(
      (snapshot ?? {}) as Record<string, unknown>,
      tools,
    );

    const messages: AiMessage[] = [
      { role: "system", content: systemPrompt },
      {
        role: "user",
        content: "Analitza el snapshot i actua segons les regles del sistema.",
      },
    ];

    const turn = await runToolLoop({
      adminClient,
      ctx,
      config,
      messages,
      temperature: Math.min(config.temperature, 0.3),
      maxTokens: Math.min(config.maxTokens, 4096),
    });

    const alertCreated = turn.toolTrace.some(
      (entry) => entry.name.includes("propose_create_alert") && entry.ok,
    );

    await logAiUsage({
      adminClient,
      tenantId: job.tenantId,
      userId: job.notifyUserId,
      feature: "cron_analytics",
      provider: config.provider,
      model: config.model,
      requestStatus: "success",
      latencyMs: Date.now() - startedAt,
    });

    const summary = {
      alertCreated,
      toolTrace: turn.toolTrace,
      contentPreview: turn.content.slice(0, 500),
    };

    await adminClient.rpc("touch_ai_scheduled_job_run_service", {
      p_job_id: job.id,
      p_status: alertCreated ? "alert_created" : "ok",
      p_summary: summary,
    });

    return {
      jobId: job.id,
      tenantId: job.tenantId,
      jobKey: job.jobKey,
      status: "success",
      alertCreated,
      summary: turn.content.slice(0, 280),
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);

    await adminClient.rpc("touch_ai_scheduled_job_run_service", {
      p_job_id: job.id,
      p_status: "error",
      p_summary: { error: message },
    }).catch(() => undefined);

    await logAiUsage({
      adminClient,
      tenantId: job.tenantId,
      userId: job.notifyUserId,
      feature: "cron_analytics",
      provider: "openai",
      model: "unknown",
      requestStatus: "error",
      errorCode: message.slice(0, 120),
      latencyMs: Date.now() - startedAt,
    }).catch(() => undefined);

    const operationLog = createOperationLogService(adminClient);
    await operationLog.log({
      tenantId: job.tenantId,
      siteId: job.siteId,
      integrationType: "ai_generation",
      operationCode: "cron_analytics",
      status: "failed",
      title: "Error en analítica proactiva IA",
      message: message.slice(0, 200),
      errorCode: "cron_job_failed",
      errorMessage: message,
      correlationId: job.id,
      externalService: "ai_provider",
      isRetryable: true,
      payloadSummary: { jobKey: job.jobKey },
    }).catch(() => undefined);

    if (isInfrastructureBug(err)) {
      captureException(err, { feature: FEATURE, tenantId: job.tenantId, correlationId: job.id });
    }

    log("error", FEATURE, "Scheduled job failed", {
      tenantId: job.tenantId,
      correlationId: job.id,
      extra: { jobKey: job.jobKey, error: message },
    });

    return {
      jobId: job.id,
      tenantId: job.tenantId,
      jobKey: job.jobKey,
      status: "error",
      error: message,
    };
  }
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Només POST");
  }

  const token = extractBearerToken(req);
  if (!SERVICE_ROLE_KEY || !token || token !== SERVICE_ROLE_KEY) {
    return errorResponse(401, "unauthorized", "Service role requerit");
  }

  try {
    const adminClient = createAdminClient();
    const body = await req.json().catch(() => ({})) as { limit?: number };

    const { data: dueJobs, error: listError } = await adminClient.rpc(
      "list_due_ai_scheduled_jobs_service",
      { p_limit: body.limit ?? 10 },
    );
    if (listError) throw new Error(listError.message);

    const jobs = (dueJobs ?? []) as ScheduledJobRow[];
    const results: JobRunResult[] = [];

    for (const job of jobs) {
      results.push(await runScheduledJob(adminClient, job));
    }

    return jsonResponse({
      processed: results.length,
      results,
    });
  } catch (err) {
    if (err instanceof AiGovernanceError) {
      return toHttpGovernanceError(err);
    }
    const message = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "Worker fatal error", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return errorResponse(500, "internal_error", message);
  }
});
