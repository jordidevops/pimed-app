import { supabase } from '../../../lib/supabase'

export type NotificationChannel = 'in_app' | 'push' | 'email' | 'sms' | 'whatsapp'

export type NotificationPreferenceEvent = {
  event_code: string
  description: string | null
  default_channels: NotificationChannel[]
  channels_enabled: NotificationChannel[]
  has_custom: boolean
}

export type NotificationPreferencesResponse = {
  tenant_id: string
  user_id: string
  locale: string
  events: NotificationPreferenceEvent[]
}

const MEMBER_CHANNELS: NotificationChannel[] = ['in_app', 'push', 'email']

export function memberChannels(channels: NotificationChannel[]): NotificationChannel[] {
  return MEMBER_CHANNELS.filter((c) => channels.includes(c))
}

export async function fetchMyNotificationPreferences(): Promise<NotificationPreferencesResponse> {
  const { data, error } = await supabase.rpc('get_my_notification_preferences')
  if (error) throw error
  return data as NotificationPreferencesResponse
}

export async function saveNotificationPreference(
  eventCode: string,
  channels: NotificationChannel[],
): Promise<void> {
  const { error } = await supabase.rpc('upsert_my_notification_preference', {
    p_event_code: eventCode,
    p_channels_enabled: channels,
  })
  if (error) throw error
}

export async function sendTestNotification(
  channels: NotificationChannel[] = ['in_app', 'push', 'email'],
): Promise<void> {
  const { error } = await supabase.rpc('send_test_notification', {
    p_channels: channels,
  })
  if (error) throw error
}

export type TwilioConfigStatus = {
  configured: boolean
  account_sid?: string
  sms_from_number?: string | null
  whatsapp_from_number?: string | null
  is_enabled?: boolean
  is_verified?: boolean
  last_error_code?: string | null
}

export async function fetchTwilioConfig(): Promise<TwilioConfigStatus> {
  const { data, error } = await supabase.rpc('get_tenant_twilio_config')
  if (error) throw error
  return data as TwilioConfigStatus
}

export async function saveTwilioConfig(
  tenantId: string,
  params: {
    accountSid: string
    authToken: string
    smsFromNumber?: string
    whatsappFromNumber?: string
  },
): Promise<void> {
  const { error } = await supabase.rpc('upsert_tenant_twilio_config', {
    p_tenant_id: tenantId,
    p_account_sid: params.accountSid,
    p_auth_token: params.authToken,
    p_sms_from_number: params.smsFromNumber ?? undefined,
    p_whatsapp_from_number: params.whatsappFromNumber ?? undefined,
  })
  if (error) throw error
}

export type PushConfigStatus = {
  configured: boolean
  platform_fallback?: boolean
  onesignal_app_id?: string
  is_enabled?: boolean
  has_rest_key?: boolean
}

export async function fetchPushConfig(): Promise<PushConfigStatus> {
  const { data, error } = await supabase.rpc('get_tenant_push_config')
  if (error) throw error
  return data as PushConfigStatus
}

export async function savePushConfig(params: {
  appId: string
  restApiKey: string
  isEnabled?: boolean
}): Promise<void> {
  const { error } = await supabase.rpc('upsert_tenant_push_config', {
    p_onesignal_app_id: params.appId,
    p_rest_api_key: params.restApiKey,
    p_is_enabled: params.isEnabled ?? true,
  })
  if (error) throw error
}

export async function sendTestSms(phoneE164: string): Promise<void> {
  const { error } = await supabase.rpc('send_test_sms', {
    p_phone_e164: phoneE164,
  })
  if (error) throw error
}
