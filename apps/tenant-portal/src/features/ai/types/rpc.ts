/** Typed shapes for AI RPCs (mirror api.* functions). */

export type AiProvider = 'openai' | 'anthropic' | 'gemini' | 'openrouter'

export type AiUserPolicy = 'allow' | 'warn_only' | 'block'

export type AiProviderStatus = {
  provider: AiProvider
  configured: boolean
  has_key?: boolean
  verified?: boolean
  key_verified_at?: string | null
  key_last_error?: string | null
  model: string
  base_url: string
  available_models?: string[]
  enabled_models?: string[]
  last_models_sync_at?: string | null
  suggested_models?: string[]
  billing_url?: string
  system_prompt?: string | null
  temperature?: number
  max_tokens?: number
  platform_system_prompt?: string | null
  platform_temperature?: number
  platform_max_tokens?: number
  system_prompt_override?: string | null
  temperature_override?: number | null
  max_tokens_override?: number | null
}

export type AiConfigForTenant = {
  default_provider: AiProvider
  is_active: boolean
  configured: boolean
  system_prompt?: string | null
  temperature?: number
  max_tokens?: number
  default_models?: Record<string, unknown>
  rate_limit_per_hour?: number
  rate_limit_per_day?: number
  rate_limit_tokens_per_day?: number
  analytics_cron_enabled?: boolean
  warn_threshold_pct?: number
  hard_block_on_limit?: boolean
  providers: AiProviderStatus[]
}

export type AiUserAccess = {
  configured: boolean
  policy: AiUserPolicy
  custom_hourly_limit: number | null
  custom_daily_limit: number | null
  blocked: boolean
  warn_only: boolean
  allowed_models?: Partial<Record<AiProvider, string[]>>
}

export type AiModelCapabilitiesRow = {
  provider: AiProvider
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
}

export type AiUserPolicyRow = {
  user_id: string
  email: string
  full_name: string | null
  role: string
  policy: AiUserPolicy
  custom_hourly_limit: number | null
  custom_daily_limit: number | null
  custom_tokens_daily_limit: number | null
  ai_enabled: boolean | null
  allowed_models: Partial<Record<AiProvider, string[]>>
  notes: string | null
  updated_at: string | null
}

export type AiUsageStats = {
  summary: {
    hour_count: number
    day_count: number
    hour_limit: number
    day_limit: number
    tokens_today: number
    tokens_day_limit: number
    warn_threshold_pct: number
    total_requests_30d: number
    total_tokens_30d: number
    blocked_requests_30d: number
  }
  daily: Array<{
    date: string
    requests: number
    tokens: number
    blocked: number
    provider: string
  }>
  by_provider: Array<{
    provider: string
    requests: number
    tokens: number
    blocked: number
  }>
  top_users?: Array<{
    user_id: string
    email: string | null
    full_name: string | null
    requests: number
    tokens: number
    blocked: number
  }>
}

export type SetAiUserPolicyInput = {
  tenantId: string
  userId: string
  policy: AiUserPolicy
  customHourlyLimit?: number | null
  customDailyLimit?: number | null
  customTokensDailyLimit?: number | null
  aiEnabled?: boolean | null
  allowedModels?: Partial<Record<AiProvider, string[]>>
  notes?: string | null
}
