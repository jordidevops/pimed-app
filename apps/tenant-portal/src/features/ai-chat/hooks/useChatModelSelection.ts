import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { fetchAiUserAccess } from '@/features/ai/api/aiRpc'
import { aiUserAccessQueryKey } from '@/features/ai/api/aiQueryKeys'
import { useAiGenerationConfig } from '@/features/ai/hooks/useAiGenerationConfig'
import type { AiProvider } from '@/features/ai/types/rpc'
import type { AiConversationRow } from '@/features/ai-chat/api/chatApi'
import {
  getChatAllowedModels,
  pickDefaultChatModel,
} from '@/features/ai-chat/utils/chatModelSelection'

export type ChatModelSelection = {
  provider: AiProvider
  model: string
}

const PROVIDERS: AiProvider[] = ['openai', 'anthropic', 'gemini', 'openrouter']

export function useChatModelSelection(
  tenantId: string | null,
  activeConversationId: string | null,
  conversations: AiConversationRow[],
) {
  const {
    defaultProvider,
    getProviderStatus,
    resolveEffectiveProvider,
    providerMap,
    isLoading: configLoading,
  } = useAiGenerationConfig(tenantId)

  const { data: access, isLoading: accessLoading } = useQuery({
    queryKey: aiUserAccessQueryKey(tenantId!),
    enabled: !!tenantId,
    queryFn: () => fetchAiUserAccess(tenantId!),
  })

  const activeConversation = useMemo(
    () => conversations.find((c) => c.id === activeConversationId) ?? null,
    [conversations, activeConversationId],
  )

  const locked = !!activeConversation

  const [overrides, setOverrides] = useState<Partial<ChatModelSelection>>({})

  useEffect(() => {
    if (!activeConversationId) {
      setOverrides({})
    }
  }, [activeConversationId])

  const provider = locked
    ? (activeConversation!.provider as AiProvider)
    : resolveEffectiveProvider(overrides.provider ?? defaultProvider)

  const providerStatus = getProviderStatus(provider)
  const userAllowed = access?.allowed_models?.[provider]

  const modelOptions = useMemo(
    () => getChatAllowedModels(providerStatus, userAllowed),
    [providerStatus, userAllowed],
  )

  const suggestedModels = providerStatus?.suggested_models ?? []

  const model = locked
    ? activeConversation!.model
    : (overrides.model ?? pickDefaultChatModel(providerStatus, userAllowed))

  const configuredProviders = useMemo(
    () => PROVIDERS.filter((p) => providerMap.get(p)?.configured),
    [providerMap],
  )

  function setProvider(nextProvider: AiProvider) {
    const status = getProviderStatus(nextProvider)
    const allowed = access?.allowed_models?.[nextProvider]
    setOverrides({
      provider: nextProvider,
      model: pickDefaultChatModel(status, allowed),
    })
  }

  function setModel(nextModel: string) {
    setOverrides((prev) => ({
      ...prev,
      provider,
      model: nextModel,
    }))
  }

  return {
    provider,
    model,
    modelOptions,
    suggestedModels,
    locked,
    configuredProviders,
    defaultProvider,
    getProviderStatus,
    setProvider,
    setModel,
    isLoading: configLoading || accessLoading,
    providerStatus,
  }
}
