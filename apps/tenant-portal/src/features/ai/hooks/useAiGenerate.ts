import { useCallback, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { getFunctionErrorMessage, getResponseErrorMessage } from '@/lib/functionErrors'
import type { AiGenerateMessage, AiGenerateOverrides, AiGenerateResult } from '../components/AIGenerateAction'

type UseAiGenerateOptions = {
  tenantId: string | null
  feature: string
  responseFormat?: 'text' | 'json'
}

export function useAiGenerate({ tenantId, feature, responseFormat = 'text' }: UseAiGenerateOptions) {
  const [generating, setGenerating] = useState(false)
  const [lastWarnings, setLastWarnings] = useState<AiGenerateResult['warnings']>(null)

  const generate = useCallback(async (
    messages: AiGenerateMessage[],
    overrides?: AiGenerateOverrides,
  ): Promise<AiGenerateResult> => {
    if (!tenantId) throw new Error('No tenant actiu')

    setGenerating(true)
    setLastWarnings(null)
    try {
      const { data, error } = await supabase.functions.invoke('generate-ai-content', {
        headers: { 'x-tenant-id': tenantId },
        body: {
          feature,
          messages,
          responseFormat,
          model: overrides?.model,
          temperature: overrides?.temperature,
          maxTokens: overrides?.maxTokens,
          provider: overrides?.provider,
        },
      })

      if (error) {
        const detailed = await getFunctionErrorMessage(error)
        throw new Error(detailed ?? error.message)
      }

      const responseError = getResponseErrorMessage(data)
      if (responseError) throw new Error(responseError)

      const result = data as AiGenerateResult
      setLastWarnings(result.warnings ?? null)
      return result
    } finally {
      setGenerating(false)
    }
  }, [tenantId, feature, responseFormat])

  return { generate, generating, lastWarnings }
}
