import { useCallback, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { getFunctionErrorMessage, getResponseErrorMessage } from '@/lib/functionErrors'
import {
  isTransientAiInvokeError,
  sanitizeAiErrorMessage,
} from '@/features/ai/utils/sanitizeAiErrorMessage'
import type { AiGenerateMessage, AiGenerateOverrides, AiGenerateResult } from '../components/AIGenerateAction'

type UseAiGenerateOptions = {
  tenantId: string | null
  feature: string
  responseFormat?: 'text' | 'json'
}

async function invokeGenerateAiContent(params: {
  tenantId: string
  feature: string
  responseFormat: 'text' | 'json'
  messages: AiGenerateMessage[]
  overrides?: AiGenerateOverrides
}): Promise<AiGenerateResult> {
  const { data, error } = await supabase.functions.invoke('generate-ai-content', {
    headers: { 'x-tenant-id': params.tenantId },
    body: {
      feature: params.feature,
      messages: params.messages,
      responseFormat: params.responseFormat,
      model: params.overrides?.model,
      temperature: params.overrides?.temperature,
      maxTokens: params.overrides?.maxTokens,
      provider: params.overrides?.provider,
    },
  })

  if (error) {
    const detailed = await getFunctionErrorMessage(error)
    throw new Error(sanitizeAiErrorMessage(detailed ?? error.message))
  }

  const responseError = getResponseErrorMessage(data)
  if (responseError) throw new Error(sanitizeAiErrorMessage(responseError))

  return data as AiGenerateResult
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
      try {
        const result = await invokeGenerateAiContent({
          tenantId,
          feature,
          responseFormat,
          messages,
          overrides,
        })
        setLastWarnings(result.warnings ?? null)
        return result
      } catch (firstErr) {
        const raw = firstErr instanceof Error ? firstErr.message : String(firstErr)
        if (!isTransientAiInvokeError(raw)) throw firstErr
        // Un reintent: Kong/upstream a vegades tallen connexions llargues de forma intermitent.
        await new Promise((r) => setTimeout(r, 600))
        const result = await invokeGenerateAiContent({
          tenantId,
          feature,
          responseFormat,
          messages,
          overrides,
        })
        setLastWarnings(result.warnings ?? null)
        return result
      }
    } finally {
      setGenerating(false)
    }
  }, [tenantId, feature, responseFormat])

  return { generate, generating, lastWarnings }
}
