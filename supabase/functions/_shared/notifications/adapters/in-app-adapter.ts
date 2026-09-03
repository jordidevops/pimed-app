import type { AdapterContext, ChannelAdapter } from "../types.ts";
import { toError } from "../supabase-error.ts";

export class InAppAdapter implements ChannelAdapter {
  channel = "in_app" as const;

  async send(ctx: AdapterContext) {
    if (ctx.input.recipient.kind !== "tenant_member") {
      throw new Error("in_app_only_for_tenant_members");
    }

    const { error } = await ctx.adminClient.rpc("insert_in_app_notification_service", {
      p_tenant_id: ctx.input.tenantId,
      p_user_id: ctx.input.recipient.userId,
      p_kind: ctx.input.eventType,
      p_title_i18n: ctx.rendered.titleI18n ?? { ca: ctx.rendered.title },
      p_body_i18n: ctx.rendered.bodyI18n ?? { ca: ctx.rendered.body },
      p_deep_link: ctx.rendered.deepLink ?? null,
      p_entity_type: ctx.input.entityType ?? null,
      p_entity_id: ctx.input.entityId ?? null,
      p_severity: "info",
    });

    if (error) throw toError(error);

    return { provider: "in_app", providerMessageId: ctx.deliveryId };
  }
}
