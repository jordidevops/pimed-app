/**
 * handlers/create-task.ts
 *
 * Crea una tasca assignada a un usuari o rol.
 *
 * Config esperada:
 * {
 *   "title": "Seguiment lead: {{ context.entity.company_name }}",
 *   "description": "",
 *   "assignee_role": "owner",    // mutualment exclusiu amb assignee_user_id
 *   "assignee_user_id": "uuid",  // mutualment exclusiu amb assignee_role
 *   "project_id": null,
 *   "due_date_offset_days": 3
 * }
 *
 * RPC: api.create_automation_task_service({ p_tenant_id, p_site_id, p_title,
 *       p_description, p_assignee_role, p_assignee_user_id, p_project_id,
 *       p_due_date_offset_days })
 *   → { task_id: string }
 */

import type { AdminClient } from "../../queue-runtime.ts";
import type { StepHandlerResult, WorkflowContext } from "../types.ts";
import { log } from "../../observability/structured-logger.ts";

const FEATURE = "handler:create-task";

export async function createTaskHandler(
  db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const tenantId = context.tenant.id;
  const title = String(config.title ?? "").trim();

  if (!title) {
    log("warn", FEATURE, "Task title is empty — skipping", { tenantId });
    return { success: true, output: { skipped: true, reason: "missing_title" } };
  }

  const dueDateOffsetDays = typeof config.due_date_offset_days === "number"
    ? config.due_date_offset_days
    : null;

  const { data, error } = await db.rpc("create_automation_task_service", {
    p_tenant_id: tenantId,
    p_site_id: context.site?.id ?? null,
    p_title: title,
    p_description: String(config.description ?? ""),
    p_assignee_role: typeof config.assignee_role === "string" ? config.assignee_role : null,
    p_assignee_user_id: typeof config.assignee_user_id === "string" ? config.assignee_user_id : null,
    p_project_id: typeof config.project_id === "string" ? config.project_id : null,
    p_due_date_offset_days: dueDateOffsetDays,
    p_entity_type: context.trigger.entity_type ?? null,
    p_entity_id: context.trigger.entity_id ?? null,
  });

  if (error) {
    log("error", FEATURE, "create_automation_task_service RPC failed", {
      tenantId,
      extra: { error: error.message, title },
    });
    return { success: false, error: error.message };
  }

  const taskId = (data as { task_id?: string } | null)?.task_id;

  log("info", FEATURE, "Task created", {
    tenantId,
    extra: { task_id: taskId, title },
  });

  return { success: true, output: { task_id: taskId, title } };
}
