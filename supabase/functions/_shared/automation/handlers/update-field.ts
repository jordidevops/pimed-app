/**
 * handlers/update-field.ts
 *
 * Actualitza un camp d'una entitat via RPC amb whitelist.
 */

import type { AdminClient } from "../../queue-runtime.ts";
import type { StepHandlerResult, WorkflowContext } from "../types.ts";
import { log } from "../../observability/structured-logger.ts";

const FEATURE = "handler:update-field";

export async function updateFieldHandler(
  db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const tenantId = context.tenant.id;
  const entityType = String(config.entity_type ?? context.trigger.entity_type ?? "").trim();
  const entityId = String(config.entity_id ?? context.trigger.entity_id ?? "").trim();
  const field = String(config.field ?? "").trim();
  const value = String(config.value ?? "");

  if (!entityType || !entityId || !field) {
    log("warn", FEATURE, "Missing entity_type, entity_id or field — skipping", {
      tenantId,
      extra: { entity_type: entityType, entity_id: entityId, field },
    });
    return { success: true, output: { skipped: true, reason: "missing_params" } };
  }

  const { data, error } = await db.rpc("update_entity_field_service", {
    p_tenant_id: tenantId,
    p_entity_type: entityType,
    p_entity_id: entityId,
    p_field: field,
    p_value: value,
  });

  if (error) {
    log("error", FEATURE, "update_entity_field_service failed", {
      tenantId,
      extra: { error: error.message, entity_type: entityType, field },
    });
    return { success: false, error: error.message };
  }

  log("info", FEATURE, "Entity field updated", {
    tenantId,
    extra: { entity_type: entityType, entity_id: entityId, field },
  });

  return {
    success: true,
    output: {
      updated: true,
      ...(data as Record<string, unknown> ?? {}),
    },
  };
}
