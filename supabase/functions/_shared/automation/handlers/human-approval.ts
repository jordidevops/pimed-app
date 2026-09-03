/**
 * handlers/human-approval.ts
 *
 * Crea una aprovació pendent i notifica el responsable.
 * El workflow queda en WAITING_HUMAN fins que l'aprovació es resol externament
 * (via UI o webhook) i es reprèn el workflow manualment.
 *
 * Config esperada:
 * {
 *   "assigned_to_role": "manager",
 *   "assigned_to_user_id": null,
 *   "context_preview_fields": ["entity.full_name", "entity.email"],
 *   "due_hours": 24
 * }
 *
 * RPCs:
 *   - api.create_automation_pending_approval_service({ p_step_run_id, p_run_id,
 *       p_tenant_id, p_assigned_to_role, p_assigned_to_user_id, p_due_hours,
 *       p_context_preview })
 *     → { approval_id: string }
 *   - api.enqueue_notification({ payload: { ... } })
 */

import type { AdminClient } from "../../queue-runtime.ts";
import type { StepHandlerResult, WorkflowContext } from "../types.ts";
import { log } from "../../observability/structured-logger.ts";

const FEATURE = "handler:human-approval";

function buildContextPreview(
  fields: string[],
  context: WorkflowContext,
): Record<string, unknown> {
  const preview: Record<string, unknown> = {};
  const entity = context.entity ?? {};

  for (const field of fields) {
    if (field.startsWith("entity.")) {
      const key = field.slice("entity.".length);
      preview[key] = (entity as Record<string, unknown>)[key] ?? null;
    } else if (field.startsWith("trigger.")) {
      const key = field.slice("trigger.".length);
      preview[key] = (context.trigger as unknown as Record<string, unknown>)[key] ?? null;
    }
  }

  return preview;
}

export async function humanApprovalHandler(
  db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const tenantId = context.tenant.id;
  const assignedToRole = typeof config.assigned_to_role === "string"
    ? config.assigned_to_role
    : null;
  const assignedToUserId = typeof config.assigned_to_user_id === "string" && config.assigned_to_user_id
    ? config.assigned_to_user_id
    : null;
  const dueHours = typeof config.due_hours === "number" ? config.due_hours : 24;
  const previewFields = Array.isArray(config.context_preview_fields)
    ? config.context_preview_fields.map(String)
    : [];

  if (!assignedToRole && !assignedToUserId) {
    log("warn", FEATURE, "No assigned_to_role nor assigned_to_user_id — skipping", {
      tenantId,
    });
    return { success: true, output: { skipped: true, reason: "missing_assignee" } };
  }

  const contextPreview = buildContextPreview(previewFields, context);
  const stepRunId = context.runtime?.step_run_id;
  const workflowRunId = context.runtime?.workflow_run_id;

  if (!stepRunId || !workflowRunId) {
    log("error", FEATURE, "Missing runtime context (step_run_id, workflow_run_id)", {
      tenantId,
    });
    return { success: false, error: "missing_runtime_context" };
  }

  // 1. Crear l'aprovació pendent
  const { data: approvalData, error: approvalError } = await db.rpc(
    "create_automation_pending_approval_service",
    {
      p_step_run_id: stepRunId,
      p_workflow_run_id: workflowRunId,
      p_tenant_id: tenantId,
      p_site_id: context.site?.id ?? null,
      p_assigned_to_role: assignedToRole,
      p_assigned_to_user_id: assignedToUserId,
      p_due_hours: dueHours,
      p_context_preview: contextPreview,
    },
  );

  if (approvalError) {
    log("error", FEATURE, "create_automation_pending_approval_service failed", {
      tenantId,
      extra: { error: approvalError.message },
    });
    return { success: false, error: approvalError.message };
  }

  const approvalId = (approvalData as { approval_id?: string } | null)?.approval_id;

  // 2. Notificar el responsable via notification queue
  const notifRecipient = assignedToUserId
    ? { kind: "user", userId: assignedToUserId }
    : { kind: "role", role: assignedToRole };

  const { error: notifError } = await db.rpc("enqueue_notification", {
    payload: {
      tenantId,
      siteId: context.site?.id ?? null,
      eventType: "AUTOMATION_APPROVAL_REQUIRED",
      correlationId: `approval:${approvalId}`,
      recipient: notifRecipient,
      payload: {
        approval_id: approvalId,
        due_hours: dueHours,
        context_preview: contextPreview,
        entity_type: context.trigger.entity_type,
        entity_id: context.trigger.entity_id,
      },
    },
  });

  if (notifError) {
    // La notificació és opcional — no bloquejem el flow si falla
    log("warn", FEATURE, "enqueue_notification failed for approval", {
      tenantId,
      extra: { error: notifError.message, approval_id: approvalId },
    });
  }

  log("info", FEATURE, "Human approval created", {
    tenantId,
    extra: { approval_id: approvalId, due_hours: dueHours },
  });

  // Retornem waitingHuman: true → el workflow queda en WAITING_HUMAN
  return {
    success: true,
    waitingHuman: true,
    output: { approval_id: approvalId, due_hours: dueHours },
  };
}
