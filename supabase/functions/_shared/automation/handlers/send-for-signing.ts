/**
 * handlers/send-for-signing.ts
 *
 * Envia un document a firma nativa i espera el resultat via trigger d'audit.
 */

import type { AdminClient } from "../../queue-runtime.ts";
import type { StepHandlerResult, WorkflowContext } from "../types.ts";
import { log } from "../../observability/structured-logger.ts";

const FEATURE = "handler:send-for-signing";

export async function sendForSigningHandler(
  db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const tenantId = context.tenant.id;
  const documentId = String(config.document_id ?? "").trim();
  const stepRunId = context.runtime?.step_run_id;
  const workflowRunId = context.runtime?.workflow_run_id;

  if (!documentId) {
    log("warn", FEATURE, "Missing document_id — skipping", { tenantId });
    return { success: true, output: { skipped: true, reason: "missing_document_id" } };
  }

  if (!stepRunId || !workflowRunId) {
    return { success: false, error: "missing_runtime_context" };
  }

  const signers = Array.isArray(config.signers) ? config.signers : [];

  const { data, error } = await db.rpc("automation_send_for_signing_service", {
    p_tenant_id: tenantId,
    p_document_id: documentId,
    p_signers: signers,
    p_workflow_run_id: workflowRunId,
    p_step_run_id: stepRunId,
  });

  if (error) {
    log("error", FEATURE, "automation_send_for_signing_service failed", {
      tenantId,
      extra: { error: error.message, document_id: documentId },
    });
    return { success: false, error: error.message };
  }

  const result = data as {
    submission_id?: string;
    session_id?: string;
    document_id?: string;
  } | null;

  log("info", FEATURE, "Document sent for signing", {
    tenantId,
    extra: {
      document_id: documentId,
      submission_id: result?.submission_id,
    },
  });

  return {
    success: true,
    waitingTimer: true,
    output: {
      submission_id: result?.submission_id,
      session_id: result?.session_id,
      document_id: documentId,
    },
  };
}
