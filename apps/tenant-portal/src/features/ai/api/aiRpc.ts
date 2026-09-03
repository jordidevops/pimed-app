import { supabase } from '@/lib/supabase'
import type {
  AiConfigForTenant,
  AiModelCapabilitiesRow,
  AiUsageStats,
  AiUserAccess,
  AiUserPolicyRow,
  AiProvider,
  SetAiUserPolicyInput,
} from '../types/rpc'

function assertData<T>(data: T | null, error: { message: string } | null): T {
  if (error) throw new Error(error.message)
  if (data === null || data === undefined) throw new Error('Resposta buida')
  return data
}

export async function fetchAiConfigForTenant(tenantId: string): Promise<AiConfigForTenant> {
  const { data, error } = await supabase.rpc('get_ai_config_for_tenant', {
    p_tenant_id: tenantId,
  })
  return assertData(data, error) as AiConfigForTenant
}

export async function setTenantAiDefaultProvider(
  tenantId: string,
  provider: AiProvider,
): Promise<void> {
  const { error } = await supabase.rpc('set_tenant_ai_default_provider', {
    p_tenant_id: tenantId,
    p_provider: provider,
  })
  if (error) throw new Error(error.message)
}

export type SaveTenantAiGenerationSettingsInput = {
  tenantId: string
  provider: AiProvider
  systemPrompt?: string | null
  temperature?: number | null
  maxTokens?: number | null
  usePlatformDefaults?: boolean
}

export async function saveTenantAiProviderGenerationSettings(
  input: SaveTenantAiGenerationSettingsInput,
): Promise<void> {
  const { error } = await supabase.rpc('save_tenant_ai_provider_generation_settings', {
    p_tenant_id: input.tenantId,
    p_provider: input.provider,
    p_system_prompt: input.systemPrompt ?? undefined,
    p_temperature: input.temperature ?? undefined,
    p_max_tokens: input.maxTokens ?? undefined,
    p_use_platform_defaults: input.usePlatformDefaults ?? false,
  })
  if (error) throw new Error(error.message)
}

export async function fetchAiUserAccess(tenantId: string): Promise<AiUserAccess> {
  const { data, error } = await supabase.rpc('get_ai_user_access', {
    p_tenant_id: tenantId,
  })
  return assertData(data, error) as AiUserAccess
}

export async function fetchAiModelCapabilities(tenantId: string): Promise<AiModelCapabilitiesRow[]> {
  const { data, error } = await supabase.rpc('get_ai_model_capabilities', {
    p_tenant_id: tenantId,
  })
  return (assertData(data, error) ?? []) as AiModelCapabilitiesRow[]
}

export async function fetchAiUsageStats(tenantId: string): Promise<AiUsageStats> {
  const { data, error } = await supabase.rpc('get_ai_usage_stats', {
    p_tenant_id: tenantId,
  })
  return assertData(data, error) as AiUsageStats
}

export async function fetchAiUserPolicies(tenantId: string): Promise<AiUserPolicyRow[]> {
  const { data, error } = await supabase.rpc('get_tenant_ai_user_policies', {
    p_tenant_id: tenantId,
  })
  return (assertData(data, error) ?? []) as AiUserPolicyRow[]
}

export async function setAiUserPolicy(input: SetAiUserPolicyInput): Promise<void> {
  const { error } = await supabase.rpc('set_tenant_ai_user_policy', {
    p_tenant_id: input.tenantId,
    p_user_id: input.userId,
    p_policy: input.policy,
    p_custom_hourly_limit: input.customHourlyLimit ?? undefined,
    p_custom_daily_limit: input.customDailyLimit ?? undefined,
    p_notes: input.notes ?? undefined,
    p_ai_enabled: input.aiEnabled ?? undefined,
    p_allowed_models: input.allowedModels ?? {},
    p_custom_tokens_daily_limit: input.customTokensDailyLimit ?? undefined,
  })
  if (error) throw new Error(error.message)
}

export async function deleteAiUserPolicy(tenantId: string, userId: string): Promise<void> {
  const { error } = await supabase.rpc('delete_tenant_ai_user_policy', {
    p_tenant_id: tenantId,
    p_user_id: userId,
  })
  if (error) throw new Error(error.message)
}

export async function setTenantAiTokensDailyLimit(
  tenantId: string,
  rateLimitTokensPerDay: number,
): Promise<void> {
  const { error } = await supabase.rpc('set_tenant_ai_tokens_daily_limit', {
    p_tenant_id: tenantId,
    p_rate_limit_tokens_per_day: rateLimitTokensPerDay,
  })
  if (error) throw new Error(error.message)
}

export async function setAiAnalyticsCronEnabled(
  tenantId: string,
  enabled: boolean,
): Promise<void> {
  const { error } = await supabase.rpc('set_ai_analytics_cron_enabled', {
    p_tenant_id: tenantId,
    p_enabled: enabled,
  })
  if (error) throw new Error(error.message)
}
