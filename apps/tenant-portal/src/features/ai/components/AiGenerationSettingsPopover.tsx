import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Loader2, Settings2 } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { AiModelSelect } from '@/features/ai/components/AiModelSelect'
import { useTenant } from '@/contexts/TenantContext'
import { useAiGenerationConfig, AI_PROVIDER_LABELS } from '../hooks/useAiGenerationConfig'
import { fetchAiUserAccess } from '../api/aiRpc'
import { aiUserAccessQueryKey } from '../api/aiQueryKeys'
import type { AiProvider } from '../types/rpc'

export type AiGenerateOverrides = {
  model?: string
  temperature?: number
  maxTokens?: number
  provider?: AiProvider
}

const PROVIDERS: AiProvider[] = ['openai', 'anthropic', 'gemini', 'openrouter']

type AiGenerationSettingsPopoverProps = {
  value: AiGenerateOverrides
  onChange: (next: AiGenerateOverrides) => void
  disabled?: boolean
  className?: string
  align?: 'start' | 'center' | 'end'
}

export function AiGenerationSettingsPopover({
  value,
  onChange,
  disabled = false,
  className,
  align = 'end',
}: AiGenerationSettingsPopoverProps) {
  const { t } = useTranslation('settings')
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? null
  const [open, setOpen] = useState(false)

  const {
    defaultProvider,
    getProviderStatus,
    resolveEffectiveProvider,
    isLoading,
  } = useAiGenerationConfig(tenantId)

  const { data: access } = useQuery({
    queryKey: aiUserAccessQueryKey(tenantId!),
    enabled: !!tenantId,
    queryFn: () => fetchAiUserAccess(tenantId!),
  })

  const selectedProvider = value.provider ?? defaultProvider
  const effectiveProvider = resolveEffectiveProvider(selectedProvider)
  const providerStatus = getProviderStatus(effectiveProvider)
  const effectiveModel = value.model ?? providerStatus?.model ?? ''

  const summary = useMemo(() => {
    const providerLabel = AI_PROVIDER_LABELS[effectiveProvider]
    const modelLabel = effectiveModel || t('ai.overrideModelPlaceholder', 'Per defecte del tenant')
    return `${providerLabel} · ${modelLabel}`
  }, [effectiveProvider, effectiveModel, t])

  const notConfigured = !access?.configured
  const availableModels = providerStatus?.available_models ?? []
  const suggestedModels = providerStatus?.suggested_models ?? []

  const modelOptions = useMemo(() => {
    const ids = new Set<string>()
    if (effectiveModel) ids.add(effectiveModel)
    for (const id of availableModels) ids.add(id)
    for (const id of suggestedModels) ids.add(id)
    return [...ids]
  }, [availableModels, suggestedModels, effectiveModel])

  const hasModelCatalog = modelOptions.length > 0

  function update(patch: Partial<AiGenerateOverrides>) {
    onChange({ ...value, ...patch })
  }

  function handleProviderChange(provider: AiProvider) {
    const status = getProviderStatus(provider)
    onChange({
      provider,
      model: status?.model,
      temperature: undefined,
      maxTokens: undefined,
    })
  }

  return (
    <Popover open={open} onOpenChange={setOpen} modal={false}>
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="outline"
          size="icon"
          disabled={disabled}
          className={className}
          title={isLoading ? t('ai.loading', 'Carregant...') : summary}
          aria-label={t('ai.generationSettingsTitle', 'Configuració de generació IA')}
        >
          <Settings2 className="h-4 w-4" />
        </Button>
      </PopoverTrigger>
      <PopoverContent
        align={align}
        className="z-[100] w-80 sm:w-96 space-y-3"
        onOpenAutoFocus={(e) => e.preventDefault()}
      >
        <div>
          <p className="text-sm font-medium">{t('ai.generationSettingsTitle', 'Configuració de generació IA')}</p>
          <p className="text-xs text-muted-foreground mt-0.5">
            {t('ai.generationSettingsHint', 'Aquests valors s\'apliquen només a aquesta acció. Els defaults del tenant es configuren a')}
            {' '}
            <Link to="/settings/ai" className="underline" onClick={() => setOpen(false)}>
              {t('tabs.ai', 'IA')}
            </Link>
            .
          </p>
        </div>

        {notConfigured && (
          <p className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-2.5 py-2">
            {t('ai.notConfiguredLink', 'Configura una clau verificada a')}{' '}
            <Link to="/settings/ai" className="underline font-medium" onClick={() => setOpen(false)}>
              {t('tabs.ai', 'IA')}
            </Link>
            .
          </p>
        )}

        <label className="space-y-1 block">
          <span className="text-xs text-muted-foreground">{t('ai.provider', 'Proveïdor')}</span>
          <select
            value={selectedProvider}
            disabled={disabled || notConfigured}
            onChange={(e) => handleProviderChange(e.target.value as AiProvider)}
            className="h-8 w-full rounded-md border bg-background px-2 text-sm"
          >
            {PROVIDERS.map((provider) => {
              const configured = getProviderStatus(provider)?.configured ?? false
              return (
                <option key={provider} value={provider} disabled={!configured && provider !== effectiveProvider}>
                  {AI_PROVIDER_LABELS[provider]}
                  {configured ? ' ✓' : ''}
                  {provider === defaultProvider ? ` (${t('ai.defaultBadge', 'Per defecte')})` : ''}
                </option>
              )
            })}
          </select>
        </label>

        <label className="space-y-1 block">
          <span className="text-xs text-muted-foreground">{t('ai.model', 'Model')}</span>
          {effectiveProvider === 'openrouter' && (
            <p className="text-[11px] text-muted-foreground leading-snug">
              {t('ai.openrouterOneKeyHint', 'OpenRouter: una clau, molts models (format proveïdor/model).')}
            </p>
          )}
          {hasModelCatalog ? (
            <AiModelSelect
              value={value.model ?? providerStatus?.model ?? ''}
              onChange={(model) => update({ model: model || undefined })}
              suggestedModels={suggestedModels}
              availableModels={availableModels}
              disabled={disabled || notConfigured}
              placeholder={t('ai.overrideModelPlaceholder', 'Per defecte del tenant')}
              selectClassName="h-8 w-full rounded-md border bg-background px-2 text-sm"
            />
          ) : (
            <Input
              value={value.model ?? providerStatus?.model ?? ''}
              disabled={disabled || notConfigured}
              onChange={(e) => update({ model: e.target.value || undefined })}
              placeholder={t('ai.overrideModelPlaceholder', 'Per defecte del tenant')}
              className="h-8 text-sm"
            />
          )}
        </label>

        <div className="grid grid-cols-2 gap-2">
          <label className="space-y-1">
            <span className="text-xs text-muted-foreground">{t('ai.temperature', 'Temperatura')}</span>
            <Input
              type="number"
              min={0}
              max={1}
              step={0.1}
              disabled={disabled || notConfigured}
              value={value.temperature ?? providerStatus?.temperature ?? ''}
              onChange={(e) => update({
                temperature: e.target.value === '' ? undefined : Number(e.target.value),
              })}
              className="h-8 text-sm"
            />
          </label>
          <label className="space-y-1">
            <span className="text-xs text-muted-foreground">{t('ai.maxTokens', 'Màx. tokens')}</span>
            <Input
              type="number"
              min={1}
              disabled={disabled || notConfigured}
              value={value.maxTokens ?? providerStatus?.max_tokens ?? ''}
              onChange={(e) => update({
                maxTokens: e.target.value === '' ? undefined : Number(e.target.value),
              })}
              className="h-8 text-sm"
            />
          </label>
        </div>

        {providerStatus && (
          <p className="text-[11px] text-muted-foreground leading-snug">
            {t('ai.sessionOverrideNote', 'Sense override, s\'usen temperatura {{temp}} i {{tokens}} tokens del tenant.', {
              temp: providerStatus.temperature ?? 0.2,
              tokens: providerStatus.max_tokens ?? 4096,
            })}
          </p>
        )}

        {isLoading && (
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <Loader2 className="h-3.5 w-3.5 animate-spin" />
            {t('ai.loading', 'Carregant...')}
          </div>
        )}
      </PopoverContent>
    </Popover>
  )
}
