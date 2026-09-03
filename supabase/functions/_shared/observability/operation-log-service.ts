import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { captureException } from "./system-error-tracker.ts";
import { sanitizeOperationMessage } from "./helpers.ts";

export type OperationLogStatus =
  | "pending"
  | "running"
  | "success"
  | "failed"
  | "dead_letter"
  | "cancelled"
  | "degraded";

export type OperationIntegrationType =
  | "email"
  | "sms"
  | "push"
  | "webhook_inbound"
  | "webhook_outbound"
  | "erp_sync"
  | "signing"
  | "pdf_generation"
  | "ai_generation"
  | "ai_chat"
  | "import"
  | "export"
  | "storage"
  | "geocoding"
  | "billing"
  | "other";

export type OperationLogInput = {
  tenantId: string;
  siteId?: string | null;
  integrationType: OperationIntegrationType;
  operationCode: string;
  status: OperationLogStatus;
  title: string;
  message?: string;
  errorCode?: string;
  errorMessage?: string;
  correlationId?: string;
  entityType?: string;
  entityId?: string;
  sourceJobTable?: string;
  sourceJobId?: string;
  payloadSummary?: Record<string, unknown>;
  durationMs?: number;
  durationThresholdMs?: number;
  externalService?: string;
  attemptCount?: number;
  maxAttempts?: number;
  isRetryable?: boolean;
  actorUserId?: string | null;
};

function resolveEffectiveStatus(input: OperationLogInput): OperationLogStatus {
  if (
    input.status === "success" &&
    input.durationMs != null &&
    input.durationThresholdMs != null &&
    input.durationMs > input.durationThresholdMs
  ) {
    return "degraded";
  }
  return input.status;
}

export class OperationLogService {
  constructor(private adminClient: SupabaseClient) {}

  async log(input: OperationLogInput): Promise<string> {
    const status = resolveEffectiveStatus(input);

    const { data, error } = await this.adminClient.rpc("log_tenant_operation", {
      p_tenant_id: input.tenantId,
      p_site_id: input.siteId ?? null,
      p_integration_type: input.integrationType,
      p_operation_code: input.operationCode,
      p_status: status,
      p_title: input.title,
      p_message: input.message ?? null,
      p_error_code: input.errorCode ?? null,
      p_error_message: sanitizeOperationMessage(input.errorMessage),
      p_entity_type: input.entityType ?? null,
      p_entity_id: input.entityId ?? null,
      p_correlation_id: input.correlationId ?? null,
      p_source_job_table: input.sourceJobTable ?? null,
      p_source_job_id: input.sourceJobId ?? null,
      p_payload_summary: input.payloadSummary ?? {},
      p_duration_ms: input.durationMs ?? null,
      p_duration_threshold_ms: input.durationThresholdMs ?? null,
      p_external_service: input.externalService ?? null,
      p_attempt_count: input.attemptCount ?? 0,
      p_max_attempts: input.maxAttempts ?? null,
      p_is_retryable: input.isRetryable ?? false,
      p_actor_user_id: input.actorUserId ?? null,
    });

    if (error) {
      captureException(error, {
        feature: "operation-log-service",
        tenantId: input.tenantId,
        correlationId: input.correlationId,
      });
      return "";
    }

    return String(data ?? "");
  }

  async logFailure(input: Omit<OperationLogInput, "status">): Promise<string> {
    return this.log({ ...input, status: "failed" });
  }

  async logSuccess(input: Omit<OperationLogInput, "status">): Promise<string> {
    return this.log({ ...input, status: "success" });
  }

  async logDeadLetter(input: Omit<OperationLogInput, "status">): Promise<string> {
    return this.log({ ...input, status: "dead_letter" });
  }
}

export function createOperationLogService(adminClient: SupabaseClient): OperationLogService {
  return new OperationLogService(adminClient);
}
