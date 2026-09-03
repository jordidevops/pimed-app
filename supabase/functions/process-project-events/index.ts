/**
 * process-project-events
 *
 * Worker per a la cua 'project_events'. Processa:
 *   - PROJECT_CREATED: crea notificacions in-app per als membres del projecte
 *     i materialitza l'event de calendari si té planned_start.
 *   - PROJECT_DATES_SET: crea o actualitza l'event de calendari quan planned_start
 *     es posa per primera vegada via update_project (no envia notificació).
 *
 * NOTA IMPORTANT: La cua és creada a 20260502000001 però els missatges legacy
 * no porten el camp `task`, sinó `event`. Per gestionar-ho s'usa
 * defaultTask: 'PROJECT_CREATED', que actua de fallback quan payload.task
 * és absent.
 *
 * Payload de PROJECT_CREATED (produit per api.create_project):
 *   {
 *     event:         'PROJECT_CREATED',   // camp legacy — NO és `task`
 *     project_id:    uuid,
 *     tenant_id:     uuid,
 *     name:          text,
 *     type:          text,
 *     planned_start: timestamptz | null,
 *     created_by:    uuid
 *   }
 *
 * Payload de PROJECT_DATES_SET (produit per api.update_project v3):
 *   {
 *     task:             'PROJECT_DATES_SET',
 *     project_id:       uuid,
 *     tenant_id:        uuid,
 *     idempotency_key:  'dates-set-<project_id>'
 *   }
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/process-project-events \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
 *     -H "Content-Type: application/json" -d "{}"
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  QueueRunner,
  type TaskHandler,
  type TaskPayload,
  type WorkerContext,
} from "../_shared/queue-runtime.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "process-project-events";

async function logProjectEventFailure(
  db: WorkerContext["db"],
  params: {
    tenantId: string;
    projectId: string;
    operationCode: string;
    title: string;
    message: string;
    err?: unknown;
  },
): Promise<void> {
  const operationLog = createOperationLogService(db);
  await operationLog.log({
    tenantId: params.tenantId,
    integrationType: "other",
    operationCode: params.operationCode,
    status: "failed",
    title: params.title,
    message: params.message.slice(0, 200),
    errorCode: "project_event_failed",
    errorMessage: params.message,
    correlationId: params.projectId,
    entityType: "project",
    entityId: params.projectId,
    isRetryable: true,
  });
  if (params.err && isInfrastructureBug(params.err)) {
    captureException(params.err, {
      feature: FEATURE,
      tenantId: params.tenantId,
      correlationId: params.projectId,
    });
  }
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ProjectCreatedPayload extends TaskPayload {
  project_id: string;
  name: string;
  type?: string;
  planned_start?: string | null;
  created_by: string;
}

interface ProjectDatesSetPayload extends TaskPayload {
  project_id: string;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const QUEUE_NAME = "project_events";
const BATCH_SIZE = 20;
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";

// ---------------------------------------------------------------------------
// Response helper
// ---------------------------------------------------------------------------

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Handler: PROJECT_CREATED
//
// Delega la lògica de BD a api.handle_project_created_event (SECURITY DEFINER)
// per garantir que tots els INSERTs (notifications + calendar_events + audit)
// s'executen amb els permisos correctes i de forma atòmica.
// ---------------------------------------------------------------------------
const projectCreatedHandler: TaskHandler = async (
  rawPayload: TaskPayload,
  ctx: WorkerContext,
): Promise<{ success: boolean }> => {
  const msg = rawPayload as ProjectCreatedPayload;

  if (!msg.project_id) {
    log("warn", FEATURE, "PROJECT_CREATED missing project_id — skipping", {
      tenantId: msg.tenant_id,
    });
    return { success: true };
  }

  log("info", FEATURE, "Processing PROJECT_CREATED", {
    tenantId: msg.tenant_id,
    correlationId: msg.project_id,
  });

  const { error } = await ctx.db.rpc("handle_project_created_event", {
    p_project_id:    msg.project_id,
    p_tenant_id:     msg.tenant_id,
    p_planned_start: msg.planned_start ?? null,
    p_project_name:  msg.name ?? "",
    p_created_by:    msg.created_by ?? null,
  });

  if (error) {
    await logProjectEventFailure(ctx.db, {
      tenantId: msg.tenant_id,
      projectId: msg.project_id,
      operationCode: "project_created",
      title: "Error processant creació de projecte",
      message: error.message,
      err: error,
    });
    throw new Error(error.message);
  }

  return { success: true };
};

// ---------------------------------------------------------------------------
// Handler: PROJECT_DATES_SET
//
// Cridat quan un projecte obté planned_start per primera vegada via update_project.
// Delega a api.handle_project_dates_set_event (SECURITY DEFINER) que fa upsert
// del calendar_event (INSERT si no existia, UPDATE si ja existia).
// No envia notificacions (la notificació de creació ja la va fer PROJECT_CREATED).
// ---------------------------------------------------------------------------
const projectDatesSetHandler: TaskHandler = async (
  rawPayload: TaskPayload,
  ctx: WorkerContext,
): Promise<{ success: boolean }> => {
  const msg = rawPayload as ProjectDatesSetPayload;

  if (!msg.project_id) {
    log("warn", FEATURE, "PROJECT_DATES_SET missing project_id — skipping", {
      tenantId: msg.tenant_id,
    });
    return { success: true };
  }

  log("info", FEATURE, "Processing PROJECT_DATES_SET", {
    tenantId: msg.tenant_id,
    correlationId: msg.project_id,
  });

  const { error } = await ctx.db.rpc("handle_project_dates_set_event", {
    p_project_id: msg.project_id,
    p_tenant_id:  msg.tenant_id ?? null,
  });

  if (error) {
    await logProjectEventFailure(ctx.db, {
      tenantId: msg.tenant_id ?? "",
      projectId: msg.project_id,
      operationCode: "project_dates_set",
      title: "Error actualitzant dates de projecte",
      message: error.message,
      err: error,
    });
    throw new Error(error.message);
  }

  return { success: true };
};

// ---------------------------------------------------------------------------
// Deno.serve entry point
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse(405, { error: { code: "method_not_allowed" } });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length)
    : "";
  if (!token || token !== SERVICE_ROLE_KEY) {
    log("error", FEATURE, "Unauthorized batch request");
    return new Response("Unauthorized", {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  }

  let batchSize = BATCH_SIZE;
  try {
    const body = await req.json();
    if (typeof body?.batch_size === "number") {
      batchSize = Math.max(1, Math.min(body.batch_size, 50));
    }
  } catch {
    // Body buit o no-JSON → usar default
  }

  const db = createAdminClient();

  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    handlers: {
      PROJECT_CREATED:   projectCreatedHandler,
      PROJECT_DATES_SET: projectDatesSetHandler,
    },
    db,
    // Missatges legacy produits per api.create_project no porten el camp `task`
    // (usen el camp `event`). defaultTask actua de fallback per aquests.
    defaultTask: "PROJECT_CREATED",
    maxAttempts: 3,
    batchSize,
    visibilityTimeoutSec: 60,
  });

  try {
    const summary = await runner.runBatch();
    log("info", FEATURE, "Batch complete", { extra: summary as Record<string, unknown> });
    return jsonResponse(200, summary);
  } catch (err) {
    log("error", FEATURE, "Unexpected batch error", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, {
      error: { code: "internal_error", message: "An unexpected error occurred" },
    });
  }
});
