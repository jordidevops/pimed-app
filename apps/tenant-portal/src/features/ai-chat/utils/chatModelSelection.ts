import type { AiProviderStatus } from '@/features/ai/types/rpc'
import { effectiveEnabledModels } from '@/features/ai/utils/aiModels'

export function getChatAllowedModels(
  providerStatus: AiProviderStatus | undefined,
  userAllowed?: string[],
): string[] {
  if (!providerStatus) return []

  const tenantAllowed = effectiveEnabledModels(
    providerStatus.available_models ?? [],
    providerStatus.enabled_models ?? [],
  )

  if (!userAllowed?.length) return tenantAllowed

  const userSet = new Set(userAllowed)
  return tenantAllowed.filter((modelId) => userSet.has(modelId))
}

export function pickDefaultChatModel(
  providerStatus: AiProviderStatus | undefined,
  userAllowed?: string[],
): string {
  if (!providerStatus) return ''

  const allowed = getChatAllowedModels(providerStatus, userAllowed)
  if (allowed.includes(providerStatus.model)) return providerStatus.model
  if (allowed.length > 0) return allowed[0]
  return providerStatus.model
}
