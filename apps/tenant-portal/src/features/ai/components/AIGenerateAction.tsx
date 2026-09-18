import { useState } from 'react'
import { Link } from 'react-router-dom'
import { AlertTriangle, Loader2, Sparkles } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { supabase } from '@/lib/supabase'
import { getFunctionErrorMessage, getResponseErrorMessage } from '@/lib/functionErrors'
import { sanitizeAiErrorMessage } from '@/features/ai/utils/sanitizeAiErrorMessage'
import { fetchAiUserAccess } from '@/features/ai/api/aiRpc'
import { aiUserAccessQueryKey } from '@/features/ai/api/aiQueryKeys'
import type { AiUserAccess } from '@/features/ai/types/rpc'
import {
  AiGenerationSettingsPopover,
  type AiGenerateOverrides,
} from '@/features/ai/components/AiGenerationSettingsPopover'

export type AiGenerateMessage = {
  role: 'system' | 'user' | 'assistant'
  content: string
}

export type { AiGenerateOverrides }

export type AiGenerateResult = {
  content: string
  usage?: {
    promptTokens: number | null
    completionTokens: number | null
    totalTokens: number | null
  }
  provider?: string
  model?: string
  warnings?: {
    near_limit?: boolean
    warn_only_user?: boolean
  } | null
}

type AIGenerateActionProps = {
  feature: string
  messages: AiGenerateMessage[]
  responseFormat?: 'text' | 'json'
  overrides?: AiGenerateOverrides
  disabled?: boolean
  label?: string
  className?: string
  onSuccess?: (result: AiGenerateResult) => void
  onError?: (message: string) => void
}

export function AIGenerateAction({
  feature,
  messages,
  responseFormat = 'text',
  overrides: initialOverrides,
  disabled = false,
  label,
  className,
  onSuccess,
  onError,
}: AIGenerateActionProps) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? null

  const [generating, setGenerating] = useState(false)
  const [overrides, setOverrides] = useState<AiGenerateOverrides>(initialOverrides ?? {})
  const [nearLimitWarning, setNearLimitWarning] = useState(false)
  const [warnOnlyBanner, setWarnOnlyBanner] = useState(false)

  const { data: access, isPending: accessPending } = useQuery<AiUserAccess | null>({
    queryKey: aiUserAccessQueryKey(tenantId!),
    enabled: !!tenantId,
    queryFn: () => fetchAiUserAccess(tenantId!),
  })

  const notConfigured = !accessPending && !access?.configured
  const isBlocked = access?.blocked ?? false

  async function handleGenerate() {
    if (!tenantId || generating || disabled || accessPending || notConfigured || isBlocked) return

    setGenerating(true)
    setNearLimitWarning(false)
    try {
      const { data, error } = await supabase.functions.invoke('generate-ai-content', {
        headers: { 'x-tenant-id': tenantId },
        body: {
          feature,
          messages,
          responseFormat,
          model: overrides.model || undefined,
          temperature: overrides.temperature,
          maxTokens: overrides.maxTokens,
          provider: overrides.provider,
        },
      })

      if (error) {
        const detailed = await getFunctionErrorMessage(error)
        const message = sanitizeAiErrorMessage(detailed ?? error.message)
        onError?.(message)
        toast({ variant: 'destructive', description: message })
        return
      }

      const responseError = getResponseErrorMessage(data)
      if (responseError) {
        const message = sanitizeAiErrorMessage(responseError)
        onError?.(message)
        toast({ variant: 'destructive', description: message })
        return
      }

      const result = data as AiGenerateResult
      if (result.warnings?.near_limit) setNearLimitWarning(true)
      if (result.warnings?.warn_only_user || access?.warn_only) setWarnOnlyBanner(true)

      onSuccess?.(result)
    } catch (err) {
      const message = sanitizeAiErrorMessage(err instanceof Error ? err.message : String(err))
      onError?.(message)
      toast({ variant: 'destructive', description: message })
    } finally {
      setGenerating(false)
    }
  }

  return (
    <div className={className}>
      {notConfigured && (
        <p className="text-sm text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 mb-2">
          {t('ai.notConfiguredLink', 'Configura una clau verificada a')}{' '}
          <Link to="/settings/ai" className="underline font-medium">
            {t('tabs.ai', 'IA')}
          </Link>
          .
        </p>
      )}

      {isBlocked && (
        <p className="text-sm text-red-800 bg-red-50 border border-red-200 rounded-lg px-3 py-2 mb-2">
          {t('ai.userBlocked', 'El propietari ha bloquejat l\'ús de la IA per al teu compte.')}
        </p>
      )}

      {(warnOnlyBanner || access?.warn_only) && !isBlocked && (
        <p className="text-sm text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 mb-2 flex items-start gap-2">
          <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
          <span>{t('ai.warnOnlyUser', 'Pots generar, però el propietari ha marcat el teu compte amb avís d\'ús.')}</span>
        </p>
      )}

      {nearLimitWarning && (
        <p className="text-sm text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 mb-2 flex items-start gap-2">
          <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
          <span>{t('ai.nearLimitWarning', 'Estàs aprop del límit d\'ús IA del tenant.')}</span>
        </p>
      )}

      <div className="flex items-center gap-2 flex-wrap">
        <Button
          type="button"
          onClick={() => void handleGenerate()}
          disabled={disabled || generating || accessPending || notConfigured || isBlocked}
        >
          {generating ? (
            <Loader2 className="h-4 w-4 animate-spin mr-2" />
          ) : (
            <Sparkles className="h-4 w-4 mr-2" />
          )}
          {label ?? t('ai.generate', 'Generar amb IA')}
        </Button>
        <AiGenerationSettingsPopover
          value={overrides}
          onChange={setOverrides}
          disabled={disabled || generating || isBlocked}
        />
      </div>
    </div>
  )
}
