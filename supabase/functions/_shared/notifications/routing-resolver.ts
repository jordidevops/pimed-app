import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { toError } from "./supabase-error.ts";
import type {
  NotificationChannel,
  NotificationSendInput,
  RoutingContext,
} from "./types.ts";

const VALID_CHANNELS = new Set<NotificationChannel>([
  "in_app",
  "push",
  "email",
  "sms",
  "whatsapp",
]);

function normalizeChannels(value: unknown): NotificationChannel[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.filter((ch): ch is NotificationChannel =>
    typeof ch === "string" && VALID_CHANNELS.has(ch as NotificationChannel)
  );
}

function dedupe(channels: NotificationChannel[]): NotificationChannel[] {
  return [...new Set(channels)];
}

function isChannelAllowedForRecipient(
  channel: NotificationChannel,
  kind: NotificationSendInput["recipient"]["kind"],
): boolean {
  if (kind === "tenant_member") return ["in_app", "push", "email"].includes(channel);
  return ["email", "sms", "whatsapp"].includes(channel);
}

export async function resolveChannels(
  adminClient: SupabaseClient,
  input: NotificationSendInput,
  address: { email?: string; phoneE164?: string },
): Promise<NotificationChannel[]> {
  if (input.channelOverride?.length) return input.channelOverride;

  const routingCtx = await loadRoutingContext(adminClient, input);
  const { prefs, eventMeta, twilioEnabled } = routingCtx;
  const optedOut = new Set<string>((routingCtx.optedOutChannels ?? []) as string[]);

  const enabled = normalizeChannels(prefs?.channelsEnabled);
  const defaults = normalizeChannels(eventMeta?.defaultChannels);

  let channels: NotificationChannel[] = enabled?.length
    ? enabled
    : (defaults?.length ? defaults : ["in_app"]);

  channels = channels.filter((ch) => isChannelAllowedForRecipient(ch, input.recipient.kind));

  const available = channels.filter((ch) => {
    if (optedOut.has(ch)) return false;
    if (ch === "email") return !!address.email;
    if (ch === "sms") return !!address.phoneE164 && !!twilioEnabled;
    if (ch === "whatsapp") return !!address.phoneE164 && !!twilioEnabled;
    return true;
  });

  if (input.recipient.kind === "contact" && prefs?.preferredChannel) {
    const pref = prefs.preferredChannel;
    if (available.includes(pref)) {
      return dedupe([pref, ...available.filter((c) => c !== pref)]);
    }
  }

  if (eventMeta?.requiresLegal && address.email && !available.includes("email")) {
    available.push("email");
  }

  return dedupe(available);
}

export async function loadRoutingContext(
  adminClient: SupabaseClient,
  input: NotificationSendInput,
): Promise<RoutingContext> {
  const recipientId = input.recipient.kind === "tenant_member"
    ? input.recipient.userId
    : input.recipient.kind === "contact"
    ? input.recipient.contactId
    : null;

  const { data, error } = await adminClient.rpc("resolve_notification_routing_context", {
    p_tenant_id: input.tenantId,
    p_event_code: input.eventType,
    p_recipient_id: recipientId,
    p_recipient_kind: input.recipient.kind,
  });

  if (error) throw toError(error);

  const ctx = (data ?? {
    prefs: null,
    eventMeta: null,
    twilioEnabled: false,
    optedOutChannels: [],
  }) as RoutingContext;

  if (ctx.prefs) {
    ctx.prefs = {
      ...ctx.prefs,
      channelsEnabled: normalizeChannels(ctx.prefs.channelsEnabled),
      preferredChannel: ctx.prefs.preferredChannel,
    };
  }

  if (ctx.eventMeta) {
    ctx.eventMeta = {
      ...ctx.eventMeta,
      defaultChannels: normalizeChannels(ctx.eventMeta.defaultChannels),
    };
  }

  return ctx;
}
