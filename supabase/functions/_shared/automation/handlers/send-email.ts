/**
 * handlers/send-email.ts
 *
 * Envia un correu electrònic via la cua email_send_queue.
 */

import type { AdminClient } from "../../queue-runtime.ts";
import type { StepHandlerResult, WorkflowContext } from "../types.ts";
import { log } from "../../observability/structured-logger.ts";

const FEATURE = "handler:send-email";

interface EmailAttachment {
  filename: string;
  storage_path?: string;
  storage_object_id?: string;
}

function resolveDocumentRoleRecipients(
  context: WorkflowContext,
  roleKey: string,
): string[] {
  const roles = context.roles as Record<string, { email?: string }> | undefined;
  if (!roles) return [];

  const entry = roles[roleKey];
  if (entry?.email && entry.email.includes("@")) {
    return [entry.email];
  }

  return [];
}

function normalizeAttachments(
  raw: unknown,
  context: WorkflowContext,
): { filename: string; storage_path: string }[] {
  if (!Array.isArray(raw)) return [];

  const out: { filename: string; storage_path: string }[] = [];

  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const att = item as EmailAttachment;
    const filename = String(att.filename ?? "attachment.pdf");

    let storagePath = att.storage_path;
    if (!storagePath && att.storage_object_id) {
      const doc = context.document as { storage_path?: string } | undefined;
      if (doc?.storage_path) {
        storagePath = doc.storage_path;
      }
      const stepOutputs = Object.values(context.steps);
      for (const step of stepOutputs) {
        if (typeof step.storage_path === "string") {
          storagePath = step.storage_path;
          break;
        }
      }
    }

    if (storagePath) {
      out.push({ filename, storage_path: storagePath });
    }
  }

  return out;
}

export async function sendEmailHandler(
  db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const tenantId = context.tenant.id;
  const recipientSource = String(config.recipient_source ?? "fixed");
  let recipients: string[] = [];

  if (recipientSource === "document_role") {
    const roleKey = String(config.role_key ?? "signer");
    recipients = resolveDocumentRoleRecipients(context, roleKey);
  } else {
    const rawRecipients = config.recipients;
    if (Array.isArray(rawRecipients)) {
      recipients = rawRecipients
        .map((r) => String(r).trim())
        .filter((r) => r.length > 0 && r.includes("@"));
    }
  }

  if (recipients.length === 0) {
    log("warn", FEATURE, "No valid recipients resolved — skipping", {
      tenantId,
      extra: { recipient_source: recipientSource },
    });
    return {
      success: true,
      output: { skipped: true, reason: "no_valid_recipients" },
    };
  }

  const emailPayload: Record<string, unknown> = {
    tenantId,
    siteId: context.site?.id ?? null,
    recipients,
    priority: typeof config.priority === "number" ? config.priority : 0,
  };

  if (typeof config.event_type === "string" && config.event_type) {
    emailPayload.eventType = config.event_type;
    emailPayload.templateVariables = (config.template_variables as Record<string, unknown>) ?? {};
  } else {
    emailPayload.subject = String(config.subject ?? "");
    emailPayload.body = String(config.body_template ?? "");
    emailPayload.templateVariables = (config.template_variables as Record<string, unknown>) ?? {};
  }

  const attachments = normalizeAttachments(config.attachments, context);
  if (attachments.length > 0) {
    emailPayload.attachments = attachments;
  }

  emailPayload.correlationId = `automation:email:${tenantId}:${Date.now()}`;

  const { error } = await db.rpc("enqueue_email", { payload: emailPayload });

  if (error) {
    log("error", FEATURE, "enqueue_email RPC failed", {
      tenantId,
      extra: { error: error.message, recipients },
    });
    return { success: false, error: error.message };
  }

  log("info", FEATURE, "Email enqueued", {
    tenantId,
    extra: { recipients, event_type: config.event_type ?? "raw" },
  });

  return { success: true, output: { enqueued: true, recipients } };
}
