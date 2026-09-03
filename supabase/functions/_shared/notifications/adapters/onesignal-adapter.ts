import type { AdapterContext, ChannelAdapter, PushConfig } from "../types.ts";
import { toError } from "../supabase-error.ts";

const ADAPTER_TIMEOUT_MS = 25_000;

export class OneSignalAdapter implements ChannelAdapter {
  channel = "push" as const;

  constructor(private readonly pushConfigCache: Map<string, PushConfig | null>) {}

  async send(ctx: AdapterContext) {
    if (ctx.input.recipient.kind !== "tenant_member") {
      throw new Error("push_only_for_tenant_members");
    }

    const config = await this.resolvePushConfig(ctx.adminClient, ctx.input.tenantId);
    if (!config) throw new Error("ONESIGNAL_NOT_CONFIGURED");

    const res = await fetch("https://api.onesignal.com/notifications", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Basic ${config.restApiKey}`,
      },
      body: JSON.stringify({
        app_id: config.appId,
        include_aliases: { external_id: [ctx.input.recipient.userId] },
        target_channel: "push",
        headings: { en: ctx.rendered.title, ca: ctx.rendered.title },
        contents: { en: ctx.rendered.body, ca: ctx.rendered.body },
        url: ctx.rendered.deepLink,
        data: {
          event_type: ctx.input.eventType,
          correlation_id: ctx.input.correlationId,
        },
      }),
      signal: AbortSignal.timeout(ADAPTER_TIMEOUT_MS),
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(`OneSignal ${res.status}: ${text.slice(0, 500)}`);
    }

    const json = await res.json() as { id?: string };
    return { provider: config.source === "tenant" ? "onesignal_byo" : "onesignal", providerMessageId: json.id };
  }

  private async resolvePushConfig(
    adminClient: AdapterContext["adminClient"],
    tenantId: string,
  ): Promise<PushConfig | null> {
    if (this.pushConfigCache.has(tenantId)) {
      return this.pushConfigCache.get(tenantId) ?? null;
    }

    const { data: tenantCfg, error: tenantErr } = await adminClient.rpc(
      "get_tenant_push_config_service",
      { p_tenant_id: tenantId },
    );

    if (!tenantErr && tenantCfg && typeof tenantCfg === "object") {
      const cfg = tenantCfg as { appId: string; restApiKey: string; source?: string };
      if (cfg.appId && cfg.restApiKey) {
        const push: PushConfig = {
          appId: cfg.appId,
          restApiKey: cfg.restApiKey,
          source: "tenant",
        };
        this.pushConfigCache.set(tenantId, push);
        return push;
      }
    }

    const appId = Deno.env.get("ONESIGNAL_APP_ID");
    const restApiKey = Deno.env.get("ONESIGNAL_REST_API_KEY");
    if (!appId || !restApiKey) {
      this.pushConfigCache.set(tenantId, null);
      return null;
    }

    const cfg: PushConfig = { appId, restApiKey, source: "platform" };
    this.pushConfigCache.set(tenantId, cfg);
    return cfg;
  }
}
