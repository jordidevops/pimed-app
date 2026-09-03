/**
 * handlers/generate-document.ts
 *
 * Encua un job PDF amb metadata d'automatització.
 * El step queda en WAITING_TIMER fins que el trigger de document_pdf_jobs
 * completa el pas via api.automation_resume_step_service.
 */

import type { AdminClient } from "../../queue-runtime.ts";
import type { StepHandlerResult, WorkflowContext } from "../types.ts";
import { log } from "../../observability/structured-logger.ts";

const FEATURE = "handler:generate-document";

export async function generateDocumentHandler(
  db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const tenantId = context.tenant.id;
  const templateId = String(config.template_id ?? "").trim();
  const stepRunId = context.runtime?.step_run_id;
  const workflowRunId = context.runtime?.workflow_run_id;

  if (!templateId) {
    log("warn", FEATURE, "Missing template_id — skipping", { tenantId });
    return { success: true, output: { skipped: true, reason: "missing_template_id" } };
  }

  if (!stepRunId || !workflowRunId) {
    return { success: false, error: "missing_runtime_context" };
  }

  const locale = typeof config.locale === "string" ? config.locale : "ca";
  const folderId = typeof config.folder_id === "string" ? config.folder_id : null;
  const variables = (config.context_override as Record<string, unknown>) ??
    (config.variables as Record<string, unknown>) ?? {};

  const { data, error } = await db.rpc("automation_start_generate_document", {
    p_tenant_id: tenantId,
    p_template_id: templateId,
    p_locale: locale,
    p_folder_id: folderId,
    p_entity_type: context.trigger.entity_type ?? null,
    p_entity_id: context.trigger.entity_id ?? null,
    p_workflow_run_id: workflowRunId,
    p_step_run_id: stepRunId,
    p_variables: variables,
  });

  if (error) {
    log("error", FEATURE, "automation_start_generate_document failed", {
      tenantId,
      extra: { error: error.message, template_id: templateId },
    });
    return { success: false, error: error.message };
  }

  const jobId = (data as { job_id?: string } | null)?.job_id;

  log("info", FEATURE, "PDF generation job queued", {
    tenantId,
    extra: { job_id: jobId, template_id: templateId },
  });

  return {
    success: true,
    waitingTimer: true,
    output: {
      job_id: jobId,
      template_id: templateId,
      status: "queued",
    },
  };
}
