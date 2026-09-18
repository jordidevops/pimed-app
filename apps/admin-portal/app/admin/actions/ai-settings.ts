'use server'

import { revalidatePath } from 'next/cache'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'
import { createSupabaseServerClient } from '@/lib/supabase/server'

export type PlatformAiDefault = {
  provider: string
  suggested_models: string[]
  default_model: string
  billing_url: string
  system_prompt: string | null
  temperature: number
  max_tokens: number
  base_url: string | null
  has_key: boolean
  configured: boolean
  key_verified_at: string | null
  key_last_error: string | null
  available_models: string[]
  last_models_sync_at: string | null
  updated_at: string
}

export type AiModelCapabilityAdminRow = {
  provider: string
  model_id: string
  vision: boolean
  tools: boolean
  tools_with_vision: boolean
  streaming: boolean
  max_image_size_mb: number
  supported_image_mimes: string[]
  max_file_size_mb: number
  supported_file_mimes: string[]
  context_window: number | null
  deprecated_at: string | null
  needs_review: boolean
  source: string
  updated_at: string
}

export type TenantAiSummary = {
  tenant_id: string
  default_provider: string
  is_active: boolean
  rate_limit_per_hour: number
  rate_limit_per_day: number
  warn_threshold_pct: number
  hard_block_on_limit: boolean
  providers: Array<{
    provider: string
    has_key: boolean
    verified: boolean
    key_verified_at: string | null
    key_last_error: string | null
    model: string | null
    last_models_sync_at: string | null
  }>
  usage: {
    summary: {
      total_requests_30d: number
      total_tokens_30d: number
      blocked_requests_30d: number
    }
    top_users?: Array<{
      user_id: string
      email: string | null
      full_name: string | null
      requests: number
    }>
  }
}

async function assertAdmin(allowedRoles: ('admin' | 'support')[] = ['admin']) {
  const supabase = await createSupabaseServerClient()
  const { data: { user }, error } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')
  const role = user.app_metadata?.role as string | undefined
  if (!role || !allowedRoles.includes(role as 'admin' | 'support')) {
    throw new Error(`Forbidden: requires one of [${allowedRoles.join(', ')}]`)
  }
  return user
}

async function getAccessToken(): Promise<string> {
  const supabase = await createSupabaseServerClient()
  const { data: { session } } = await supabase.auth.getSession()
  if (!session?.access_token) throw new Error('Unauthenticated')
  return session.access_token
}

async function invokePlatformAiFunction<T>(
  functionName: string,
  init: RequestInit & { method?: string },
): Promise<T> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  if (!url) throw new Error('Missing NEXT_PUBLIC_SUPABASE_URL')

  const token = await getAccessToken()
  const res = await fetch(`${url}/functions/v1/${functionName}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  })

  const body = await res.json().catch(() => ({}))
  if (!res.ok) {
    const message = typeof body?.error?.message === 'string'
      ? body.error.message
      : typeof body?.message === 'string'
        ? body.message
        : `Edge function ${functionName} failed (${res.status})`
    throw new Error(message)
  }

  return body as T
}

export async function getPlatformAiDefaults(): Promise<PlatformAiDefault[]> {
  await assertAdmin(['admin', 'support'])
  const admin = createSupabaseAdminClient()
  const { data, error } = await admin.rpc('get_platform_ai_defaults')
  if (error) throw new Error(error.message)
  return (Array.isArray(data) ? data : []) as PlatformAiDefault[]
}

export async function upsertPlatformAiDefault(input: {
  provider: string
  suggested_models: string[]
  default_model: string
  billing_url: string
  system_prompt?: string | null
  temperature?: number
  max_tokens?: number
}) {
  await assertAdmin(['admin'])
  const admin = createSupabaseAdminClient()
  const { error } = await admin.rpc('upsert_platform_ai_defaults', {
    p_provider: input.provider,
    p_suggested_models: input.suggested_models,
    p_default_model: input.default_model,
    p_billing_url: input.billing_url,
    p_system_prompt: input.system_prompt ?? null,
    p_temperature: input.temperature ?? 0.2,
    p_max_tokens: input.max_tokens ?? 4096,
  })
  if (error) throw new Error(error.message)
  revalidatePath('/dashboard/settings/ai')
}

export type PlatformAiFeaturePrompt = {
  feature: string
  title: string
  instructions: string
  updated_at: string
}

export async function getPlatformAiFeaturePrompts(): Promise<PlatformAiFeaturePrompt[]> {
  await assertAdmin(['admin', 'support'])
  const admin = createSupabaseAdminClient()
  const { data, error } = await admin.rpc('get_platform_ai_feature_prompts')
  if (error) throw new Error(error.message)
  return (Array.isArray(data) ? data : []) as PlatformAiFeaturePrompt[]
}

export async function upsertPlatformAiFeaturePrompt(input: {
  feature: string
  title: string
  instructions: string
}) {
  await assertAdmin(['admin'])
  const admin = createSupabaseAdminClient()
  const { error } = await admin.rpc('upsert_platform_ai_feature_prompt', {
    p_feature: input.feature,
    p_title: input.title,
    p_instructions: input.instructions,
  })
  if (error) throw new Error(error.message)
  revalidatePath('/dashboard/settings/ai')
}

export async function savePlatformApiKey(input: {
  provider: string
  apiKey: string
  model?: string | null
  baseUrl?: string | null
}) {
  await assertAdmin(['admin'])
  await invokePlatformAiFunction('save-platform-api-key', {
    method: 'POST',
    body: JSON.stringify({
      provider: input.provider,
      apiKey: input.apiKey,
      model: input.model ?? null,
      baseUrl: input.baseUrl ?? null,
    }),
  })
  revalidatePath('/dashboard/settings/ai')
}

export async function deletePlatformApiKey(provider: string) {
  await assertAdmin(['admin'])
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  if (!url) throw new Error('Missing NEXT_PUBLIC_SUPABASE_URL')
  const token = await getAccessToken()
  const res = await fetch(
    `${url}/functions/v1/save-platform-api-key?provider=${encodeURIComponent(provider)}`,
    {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${token}` },
    },
  )
  const body = await res.json().catch(() => ({}))
  if (!res.ok) {
    throw new Error(body?.error?.message ?? `Delete failed (${res.status})`)
  }
  revalidatePath('/dashboard/settings/ai')
}

export async function refreshPlatformProviderModels(provider: string): Promise<string[]> {
  await assertAdmin(['admin', 'support'])
  const result = await invokePlatformAiFunction<{ models?: string[] }>('refresh-platform-ai-models', {
    method: 'POST',
    body: JSON.stringify({ provider }),
  })
  revalidatePath('/dashboard/settings/ai')
  return result.models ?? []
}

export async function getAiModelCapabilitiesAdmin(input?: {
  provider?: string | null
  onlyNeedsReview?: boolean
  includeDeprecated?: boolean
}): Promise<AiModelCapabilityAdminRow[]> {
  await assertAdmin(['admin', 'support'])
  const admin = createSupabaseAdminClient()
  const { data, error } = await admin.rpc('get_ai_model_capabilities_admin', {
    p_provider: input?.provider ?? null,
    p_only_needs_review: input?.onlyNeedsReview ?? false,
    p_include_deprecated: input?.includeDeprecated ?? true,
  })
  if (error) throw new Error(error.message)
  return (Array.isArray(data) ? data : []) as AiModelCapabilityAdminRow[]
}

export async function upsertAiModelCapabilityAdmin(input: {
  provider: string
  model_id: string
  vision: boolean
  tools: boolean
  tools_with_vision: boolean
  streaming: boolean
  max_image_size_mb: number
  supported_image_mimes: string[]
  max_file_size_mb: number
  supported_file_mimes: string[]
  context_window?: number | null
  deprecated: boolean
  needs_review: boolean
  source?: string | null
}) {
  await assertAdmin(['admin'])
  const admin = createSupabaseAdminClient()
  const { error } = await admin.rpc('upsert_ai_model_capability_admin', {
    p_provider: input.provider,
    p_model_id: input.model_id,
    p_vision: input.vision,
    p_tools: input.tools,
    p_tools_with_vision: input.tools_with_vision,
    p_streaming: input.streaming,
    p_max_image_size_mb: input.max_image_size_mb,
    p_supported_image_mimes: input.supported_image_mimes,
    p_max_file_size_mb: input.max_file_size_mb,
    p_supported_file_mimes: input.supported_file_mimes,
    p_context_window: input.context_window ?? null,
    p_deprecated: input.deprecated,
    p_needs_review: input.needs_review,
    p_source: input.source ?? null,
  })
  if (error) throw new Error(error.message)
  revalidatePath('/dashboard/settings/ai')
}

export async function getTenantAiSummary(tenantId: string): Promise<TenantAiSummary> {
  await assertAdmin(['admin', 'support'])
  const admin = createSupabaseAdminClient()
  const { data, error } = await admin.rpc('get_admin_tenant_ai_summary', {
    p_tenant_id: tenantId,
  })
  if (error) throw new Error(error.message)
  return data as TenantAiSummary
}

export async function updateTenantAiLimits(input: {
  tenantId: string
  rate_limit_per_hour?: number | null
  rate_limit_per_day?: number | null
  warn_threshold_pct?: number | null
  hard_block_on_limit?: boolean | null
  is_active?: boolean | null
}) {
  await assertAdmin(['admin'])
  const admin = createSupabaseAdminClient()
  const { error } = await admin.rpc('admin_update_tenant_ai_limits', {
    p_tenant_id: input.tenantId,
    p_rate_limit_per_hour: input.rate_limit_per_hour ?? null,
    p_rate_limit_per_day: input.rate_limit_per_day ?? null,
    p_warn_threshold_pct: input.warn_threshold_pct ?? null,
    p_hard_block_on_limit: input.hard_block_on_limit ?? null,
    p_is_active: input.is_active ?? null,
  })
  if (error) throw new Error(error.message)
  revalidatePath(`/dashboard/tenants/${input.tenantId}`)
}
