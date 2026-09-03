import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { fetchAiModelCapabilities } from '@/features/ai/api/aiRpc'
import type { AiProvider } from '@/features/ai/types/rpc'
import {
  buildCapabilitiesIndex,
  resolveModelCapabilitiesFromIndex,
} from '@/features/ai-chat/utils/modelCapabilities'

export function useAiModelCapabilities(tenantId: string | null) {
  const query = useQuery({
    queryKey: ['ai_model_capabilities', tenantId],
    enabled: !!tenantId,
    queryFn: () => fetchAiModelCapabilities(tenantId!),
    staleTime: 5 * 60 * 1000,
  })

  const index = useMemo(
    () => buildCapabilitiesIndex(query.data ?? []),
    [query.data],
  )

  function getCapabilities(provider: AiProvider, modelId: string) {
    return resolveModelCapabilitiesFromIndex(index, provider, modelId)
  }

  return {
    ...query,
    getCapabilities,
  }
}
