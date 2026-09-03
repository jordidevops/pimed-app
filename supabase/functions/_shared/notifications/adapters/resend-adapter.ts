import type { AdapterContext, ChannelAdapter } from "../types.ts";
import { toError } from "../supabase-error.ts";

const URGENT_EVENTS = new Set(["INTERVENTION_DISPATCHED", "SIGNING_REMINDER"]);

export class ResendAdapter implements ChannelAdapter {
  channel = "email" as const;

  async send(ctx: AdapterContext) {
    if (!ctx.address.email) throw new Error("email_address_missing");

    const isUrgent = URGENT_EVENTS.has(ctx.input.eventType);
    const emailEventType = ctx.input.payload.email_event_type as string | undefined;
    const templateVariables = ctx.input.payload.template_variables as Record<string, unknown> | undefined;

    const payload: Record<string, unknown> = emailEventType
      ? {
        tenant_id: ctx.input.tenantId,
        site_id: ctx.input.siteId ?? null,
        event_type: emailEventType,
        to: [ctx.address.email],
        idempotency_key: `${ctx.input.correlationId}:email`,
        template_variables: templateVariables ?? {},
        priority: isUrgent ? 100 : 0,
        metadata: {
          event_type: ctx.input.eventType,
          source: "notification_engine",
          delivery_id: ctx.deliveryId,
        },
      }
      : {
        tenant_id: ctx.input.tenantId,
        site_id: ctx.input.siteId ?? null,
        to: [ctx.address.email],
        subject: ctx.rendered.title,
        html_body: ctx.rendered.bodyHtml ?? ctx.rendered.body,
        text_body: ctx.rendered.body,
        idempotency_key: `${ctx.input.correlationId}:email`,
        priority: isUrgent ? 100 : 0,
        metadata: {
          event_type: ctx.input.eventType,
          source: "notification_engine",
          delivery_id: ctx.deliveryId,
        },
      };

    const { error } = await ctx.adminClient.rpc("enqueue_email", { payload });

    if (error) throw toError(error);

    return {
      provider: "resend",
      providerMessageId: `${ctx.input.correlationId}:email`,
    };
  }
}
