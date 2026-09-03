import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { fetchAiConfigForTenant } from '../api/aiRpc'
import type { AiConfigForTenant, AiProvider, AiProviderStatus } from '../types/rpc'

export const AI_PROVIDER_LABELS: Record<AiProvider, string> = {
  openai: 'OpenAI',
  anthropic: 'Anthropic',
  gemini: 'Google Gemini',
  openrouter: 'OpenRouter',
}

export function useAiGenerationConfig(tenantId: string | null) {
  const query = useQuery<AiConfigForTenant | null>({
    queryKey: ['ai_config', tenantId],
    enabled: !!tenantId,
    queryFn: () => fetchAiConfigForTenant(tenantId!),
  })

  const providerMap = useMemo(() => {
    const map = new Map<AiProvider, AiProviderStatus>()
    for (const row of query.data?.providers ?? []) {
      map.set(row.provider, row)
    }
    return map
  }, [query.data?.providers])

  const defaultProvider = query.data?.default_provider ?? 'openai'

  function getProviderStatus(provider: AiProvider): AiProviderStatus | undefined {
    return providerMap.get(provider)
  }

  function resolveEffectiveProvider(override?: AiProvider): AiProvider {
    if (override && providerMap.get(override)?.configured) return override
    if (providerMap.get(defaultProvider)?.configured) return defaultProvider
    for (const p of ['openai', 'anthropic', 'gemini', 'openrouter'] as AiProvider[]) {
      if (providerMap.get(p)?.configured) return p
    }
    return override ?? defaultProvider
  }

  return {
    ...query,
    config: query.data,
    providerMap,
    defaultProvider,
    getProviderStatus,
    resolveEffectiveProvider,
  }
}
