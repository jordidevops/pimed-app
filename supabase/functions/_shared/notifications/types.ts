export type NotificationChannel = "in_app" | "push" | "email" | "sms" | "whatsapp";

export type NotificationEventCode =
  | "INVOICE_GENERATED"
  | "QUOTE_SENT"
  | "TASK_ASSIGNED"
  | "MENTION_CREATED"
  | "INTERVENTION_DISPATCHED"
  | "SIGNING_REMINDER"
  | "DLQ_ERROR"
  | "LEAD_RECEIVED"
  | "NOTIFICATION_TEST"
  | string;

export type NotificationRecipient =
  | { kind: "tenant_member"; userId: string }
  | { kind: "contact"; contactId: string }
  | { kind: "raw_address"; email?: string; phoneE164?: string };

export type NotificationSendInput = {
  tenantId: string;
  siteId?: string | null;
  eventType: NotificationEventCode;
  recipient: NotificationRecipient;
  payload: Record<string, unknown>;
  correlationId: string;
  entityType?: string;
  entityId?: string;
  actorUserId?: string | null;
  channelOverride?: NotificationChannel[];
};

export type NotificationSendResult = {
  ok: boolean;
  deliveries: Array<{
    channel: NotificationChannel;
    status: "sent" | "skipped" | "failed" | "cancelled";
    provider?: string;
    errorCode?: string;
    operationLogId?: string;
  }>;
};

export type ResolvedAddress = {
  email?: string;
  phoneE164?: string;
  locale?: string;
  displayName?: string;
};

export type RenderedNotification = {
  title: string;
  body: string;
  bodyHtml?: string;
  smsBody?: string;
  deepLink?: string;
  titleI18n?: Record<string, string>;
  bodyI18n?: Record<string, string>;
};

export type AdapterResult = {
  provider: string;
  providerMessageId?: string;
};

export type AdapterContext = {
  adminClient: import("npm:@supabase/supabase-js@2").SupabaseClient;
  input: NotificationSendInput;
  address: ResolvedAddress;
  rendered: RenderedNotification;
  deliveryId: string;
};

export type ChannelAdapter = {
  channel: NotificationChannel;
  send(ctx: AdapterContext): Promise<AdapterResult>;
};

export type TwilioCredentials = {
  account_sid: string;
  auth_token: string;
  sms_from_number?: string | null;
  whatsapp_from_number?: string | null;
  messaging_service_sid?: string | null;
};

export type PushConfig = {
  appId: string;
  restApiKey: string;
  source: "platform" | "tenant";
};

export type RoutingContext = {
  prefs: {
    channelsEnabled?: NotificationChannel[];
    preferredChannel?: NotificationChannel;
    quietHours?: Record<string, unknown>;
    locale?: string;
  } | null;
  eventMeta: {
    defaultChannels?: NotificationChannel[];
    requiresLegal?: boolean;
    entityType?: string;
    deepLinkTemplate?: string;
    digestEligible?: boolean;
  } | null;
  optedOutChannels?: string[];
  twilioEnabled?: boolean;
};
