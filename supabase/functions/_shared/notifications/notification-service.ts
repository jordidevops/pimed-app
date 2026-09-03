import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { createOperationLogService } from "../observability/operation-log-service.ts";
import { captureException } from "../observability/system-error-tracker.ts";
import { isInfrastructureBug } from "../observability/helpers.ts";
import { resolveChannels, loadRoutingContext } from "./routing-resolver.ts";
import { resolveRecipientAddress } from "./recipient-resolver.ts";
import { renderNotification } from "./template-renderer.ts";
import { classifyNotificationError } from "./error-classifier.ts";
import { toError } from "./supabase-error.ts";
import { InAppAdapter } from "./adapters/in-app-adapter.ts";
import { OneSignalAdapter } from "./adapters/onesignal-adapter.ts";
import { ResendAdapter } from "./adapters/resend-adapter.ts";
import { TwilioSmsAdapter } from "./adapters/twilio-sms-adapter.ts";
import { TwilioWhatsAppAdapter } from "./adapters/twilio-whatsapp-adapter.ts";
import type {
  ChannelAdapter,
  NotificationChannel,
  NotificationSendInput,
  NotificationSendResult,
  PushConfig,
  TwilioCredentials,
} from "./types.ts";

const BILLABLE_CHANNELS = new Set<NotificationChannel>(["sms", "email"]);
const DIGEST_WINDOW_SECONDS = 300;

type DigestFlushRow = {
  tenant_id: string;
  event_code: string;
  recipient_id: string;
  recipient_kind: "tenant_member" | "contact";
  entity_type: string | null;
  entity_id: string | null;
  site_id: string | null;
  group_key: string;
  item_count: number;
  latest_payload: Record<string, unknown>;
  correlation_id: string;
};

type ClaimResult = {
  acquired: boolean;
  delivery_id: string | null;
};

export class NotificationService {
  private readonly operationLog;
  private readonly adapters: ChannelAdapter[];
  private readonly twilioCredentialsCache = new Map<string, TwilioCredentials | null>();
  private readonly pushConfigCache = new Map<string, PushConfig | null>();

  constructor(private readonly adminClient: SupabaseClient) {
    this.operationLog = createOperationLogService(adminClient);
    this.adapters = [
      new InAppAdapter(),
      new OneSignalAdapter(this.pushConfigCache),
      new ResendAdapter(),
      new TwilioSmsAdapter(this.twilioCredentialsCache),
      new TwilioWhatsAppAdapter(this.twilioCredentialsCache),
    ];
  }

  async enqueue(input: NotificationSendInput): Promise<{ queued: boolean; messageId?: string }> {
    const { data, error } = await this.adminClient.rpc("enqueue_notification", {
      payload: input,
    });
    if (error) throw toError(error);
    return { queued: true, messageId: String(data) };
  }

  async processDelivery(input: NotificationSendInput): Promise<NotificationSendResult> {
    const deliveries: NotificationSendResult["deliveries"] = [];
    let anySuccess = false;

    const address = await resolveRecipientAddress(this.adminClient, input);
    const routingCtx = await loadRoutingContext(this.adminClient, input);
    const locale = routingCtx.prefs?.locale ?? address.locale ?? "ca";
    const channels = await resolveChannels(this.adminClient, input, address);
    const rendered = renderNotification(input, routingCtx, locale);

    for (const channel of channels) {
      if (
        channel === "push"
        && routingCtx.eventMeta?.digestEligible
        && input.recipient.kind === "tenant_member"
        && !input.channelOverride?.length
      ) {
        await this.accumulateDigest(input);
        deliveries.push({ channel, status: "skipped", errorCode: "DIGEST_DEFERRED" });
        continue;
      }

      const adapter = this.adapters.find((a) => a.channel === channel);
      if (!adapter) {
        deliveries.push({ channel, status: "skipped", errorCode: "NO_ADAPTER" });
        continue;
      }

      const deliveryId = await this.claimDelivery(input, channel);
      if (!deliveryId) {
        deliveries.push({ channel, status: "skipped", errorCode: "ALREADY_CLAIMED" });
        continue;
      }

      if (BILLABLE_CHANNELS.has(channel)) {
        const allowed = await this.checkQuota(input, channel, deliveryId);
        if (!allowed) {
          deliveries.push({ channel, status: "cancelled", errorCode: "QUOTA_EXCEEDED" });
          continue;
        }
      }

      try {
        const result = await adapter.send({
          adminClient: this.adminClient,
          input,
          address,
          rendered,
          deliveryId,
        });

        await this.completeDelivery(deliveryId, input, channel, "sent", {
          provider: result.provider,
          providerMessageId: result.providerMessageId,
        });

        deliveries.push({ channel, status: "sent", provider: result.provider });
        anySuccess = true;
      } catch (err) {
        const classified = classifyNotificationError(err);
        let operationLogId: string | undefined;

        try {
          operationLogId = await this.operationLog.log({
            tenantId: input.tenantId,
            siteId: input.siteId,
            integrationType: channel === "sms" || channel === "whatsapp"
              ? "sms"
              : channel === "email"
              ? "email"
              : channel === "push"
              ? "push"
              : "other",
            operationCode: `notification.${channel}.send`,
            status: "failed",
            title: `Notificació ${input.eventType} (${channel})`,
            message: classified.errorMessage.slice(0, 500),
            errorCode: classified.errorCode,
            errorMessage: classified.errorMessage.slice(0, 1000),
            correlationId: input.correlationId,
            entityType: input.entityType,
            entityId: input.entityId,
            externalService: resultProviderForChannel(channel),
            isRetryable: !classified.isBusinessError,
          });
        } catch {
          // operation log no ha de trencar el flux
        }

        await this.completeDelivery(deliveryId, input, channel, "failed", {
          errorCode: classified.errorCode,
          errorMessage: classified.errorMessage,
          operationLogId,
        });

        if (!classified.isBusinessError && isInfrastructureBug(err)) {
          captureException(err, {
            feature: "notification-engine",
            extra: { channel, eventType: input.eventType, tenantId: input.tenantId },
          });
        }

        deliveries.push({
          channel,
          status: "failed",
          errorCode: classified.errorCode,
          operationLogId,
        });
      }
    }

    return { ok: anySuccess, deliveries };
  }

  async flushDigests(limit = 50): Promise<{ flushed: number; sent: number }> {
    const { data, error } = await this.adminClient.rpc("flush_notification_digests", {
      p_limit: limit,
    });
    if (error) throw toError(error);

    const rows = (data ?? []) as DigestFlushRow[];
    let sent = 0;

    for (const row of rows) {
      if (row.recipient_kind !== "tenant_member") continue;

      const result = await this.processDelivery({
        tenantId: row.tenant_id,
        siteId: row.site_id,
        eventType: row.event_code,
        recipient: { kind: "tenant_member", userId: row.recipient_id },
        payload: {
          ...row.latest_payload,
          digest_count: row.item_count,
        },
        correlationId: row.correlation_id,
        entityType: row.entity_type ?? undefined,
        entityId: row.entity_id ?? undefined,
        channelOverride: ["push"],
      });

      if (result.ok) sent += 1;
    }

    return { flushed: rows.length, sent };
  }

  private buildDigestGroupKey(input: NotificationSendInput): string {
    const recipientId = input.recipient.kind === "tenant_member"
      ? input.recipient.userId
      : input.recipient.kind === "contact"
      ? input.recipient.contactId
      : "raw";
    return `${input.eventType}:${input.entityId ?? ""}:${recipientId}`;
  }

  private async accumulateDigest(input: NotificationSendInput): Promise<void> {
    const recipientId = input.recipient.kind === "tenant_member"
      ? input.recipient.userId
      : input.recipient.kind === "contact"
      ? input.recipient.contactId
      : null;

    if (!recipientId) return;

    const { error } = await this.adminClient.rpc("accumulate_notification_digest", {
      p_tenant_id: input.tenantId,
      p_event_code: input.eventType,
      p_recipient_id: recipientId,
      p_recipient_kind: input.recipient.kind,
      p_entity_type: input.entityType ?? null,
      p_entity_id: input.entityId ?? null,
      p_site_id: input.siteId ?? null,
      p_group_key: this.buildDigestGroupKey(input),
      p_payload: input.payload,
      p_window_seconds: DIGEST_WINDOW_SECONDS,
    });

    if (error) throw toError(error);
  }

  private async claimDelivery(
    input: NotificationSendInput,
    channel: NotificationChannel,
  ): Promise<string | null> {
    const candidateId = crypto.randomUUID();

    const { data, error } = await this.adminClient.rpc("claim_notification_delivery", {
      p_tenant_id: input.tenantId,
      p_correlation_id: input.correlationId,
      p_channel: channel,
      p_delivery_id: candidateId,
    });

    if (error) throw toError(error);

    const row = (Array.isArray(data) ? data[0] : data) as ClaimResult | null;
    if (!row?.acquired || !row.delivery_id) return null;

    const deliveryId = row.delivery_id;
    await this.prepareDelivery(deliveryId, input, channel);
    return deliveryId;
  }

  private async prepareDelivery(
    deliveryId: string,
    input: NotificationSendInput,
    channel: NotificationChannel,
  ): Promise<void> {
    const { error } = await this.adminClient.rpc("prepare_notification_delivery_service", {
      p_delivery_id: deliveryId,
      p_tenant_id: input.tenantId,
      p_event_code: input.eventType,
      p_correlation_id: input.correlationId,
      p_recipient_kind: input.recipient.kind,
      p_recipient_id: input.recipient.kind === "tenant_member"
        ? input.recipient.userId
        : input.recipient.kind === "contact"
        ? input.recipient.contactId
        : null,
      p_channel: channel,
      p_entity_type: input.entityType ?? null,
      p_entity_id: input.entityId ?? null,
      p_payload_summary: {
        event_type: input.eventType,
        correlation_id: input.correlationId,
      },
    });

    if (error) throw toError(error);
  }

  private async completeDelivery(
    deliveryId: string,
    input: NotificationSendInput,
    channel: NotificationChannel,
    status: "sent" | "failed" | "cancelled",
    meta: {
      provider?: string;
      providerMessageId?: string;
      errorCode?: string;
      errorMessage?: string;
      operationLogId?: string;
    },
  ): Promise<void> {
    const { error } = await this.adminClient.rpc("complete_notification_delivery_service", {
      p_delivery_id: deliveryId,
      p_tenant_id: input.tenantId,
      p_correlation_id: input.correlationId,
      p_channel: channel,
      p_status: status,
      p_provider: meta.provider ?? null,
      p_provider_message_id: meta.providerMessageId ?? null,
      p_error_code: meta.errorCode ?? null,
      p_error_message: meta.errorMessage ?? null,
      p_operation_log_id: meta.operationLogId ?? null,
    });

    if (error) throw toError(error);
  }

  private async checkQuota(
    input: NotificationSendInput,
    channel: NotificationChannel,
    deliveryId: string,
  ): Promise<boolean> {
    const { data, error } = await this.adminClient.rpc("increment_notification_usage", {
      p_tenant_id: input.tenantId,
      p_channel: channel,
    });

    if (error) throw toError(error);
    if (data === true) return true;

    await this.completeDelivery(deliveryId, input, channel, "cancelled", {
      errorCode: "QUOTA_EXCEEDED",
      errorMessage: `Quota ${channel} exhaurida per al tenant`,
    });

    try {
      await this.operationLog.log({
        tenantId: input.tenantId,
        integrationType: channel === "sms" ? "sms" : "email",
        operationCode: `notification.${channel}.quota_exceeded`,
        status: "cancelled",
        title: `Quota ${channel} exhaurida`,
        message: `Notificació ${input.eventType} cancel·lada per límit de quota`,
        correlationId: input.correlationId,
        entityType: input.entityType,
        entityId: input.entityId,
      });
    } catch {
      // non-fatal
    }

    return false;
  }
}

function resultProviderForChannel(channel: NotificationChannel): string {
  switch (channel) {
    case "sms":
    case "whatsapp":
      return "twilio";
    case "email":
      return "resend";
    case "push":
      return "onesignal";
    default:
      return "internal";
  }
}
