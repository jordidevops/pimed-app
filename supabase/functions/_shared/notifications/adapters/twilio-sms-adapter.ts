import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AdapterContext, ChannelAdapter, TwilioCredentials } from "../types.ts";

function buildStatusCallbackUrl(): string | null {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!supabaseUrl) return null;
  return `${supabaseUrl}/functions/v1/twilio-status-callback`;
}

const ADAPTER_TIMEOUT_MS = 25_000;

export class TwilioSmsAdapter implements ChannelAdapter {
  channel = "sms" as const;

  constructor(private readonly credentialsCache: Map<string, TwilioCredentials | null>) {}

  async send(ctx: AdapterContext) {
    const creds = await this.getCredentials(ctx.adminClient, ctx.input.tenantId);
    if (!creds) throw new Error("TWILIO_NOT_CONFIGURED");
    if (!ctx.address.phoneE164) throw new Error("phone_missing");

    const from = creds.sms_from_number ?? creds.messaging_service_sid;
    if (!from) throw new Error("TWILIO_FROM_NOT_CONFIGURED");

    const auth = btoa(`${creds.account_sid}:${creds.auth_token}`);
    const statusCallbackUrl = buildStatusCallbackUrl();
    const bodyParams: Record<string, string> = {
      To: ctx.address.phoneE164,
      From: from,
      Body: ctx.rendered.smsBody ?? ctx.rendered.body,
    };
    if (statusCallbackUrl) {
      bodyParams.StatusCallback = statusCallbackUrl;
    }
    const body = new URLSearchParams(bodyParams);

    const res = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${creds.account_sid}/Messages.json`,
      {
        method: "POST",
        headers: { Authorization: `Basic ${auth}` },
        body,
        signal: AbortSignal.timeout(ADAPTER_TIMEOUT_MS),
      },
    );

    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Twilio SMS ${res.status}: ${text.slice(0, 500)}`);
    }

    const json = await res.json() as { sid?: string };
    return { provider: "twilio_sms", providerMessageId: json.sid };
  }

  private async getCredentials(client: SupabaseClient, tenantId: string) {
    if (this.credentialsCache.has(tenantId)) {
      return this.credentialsCache.get(tenantId) ?? null;
    }
    const { data } = await client.rpc("get_tenant_twilio_credentials_service", {
      p_tenant_id: tenantId,
    });
    const creds = (data ?? null) as TwilioCredentials | null;
    this.credentialsCache.set(tenantId, creds);
    return creds;
  }
}
