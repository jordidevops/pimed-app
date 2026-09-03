import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { RefreshCw, Star } from 'lucide-react'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Checkbox } from '@/components/ui/checkbox'
import { cn } from '@/lib/utils'
import {
  AI_MODEL_SEARCH_THRESHOLD,
  effectiveEnabledModels,
  filterAiModels,
  mergeAiModelIds,
  partitionAiModels,
  pickDefaultAmongAllowed,
} from '../utils/aiModels'

type Props = {
  availableModels: string[]
  suggestedModels?: string[]
  enabledModels: string[]
  defaultModel: string
  disabled?: boolean
  placeholder?: string
  onEnabledChange: (enabledModels: string[]) => void
  onDefaultChange: (modelId: string) => void
  onRefresh?: () => void
  refreshing?: boolean
}

export function AiProviderModelsPanel({
  availableModels,
  suggestedModels = [],
  enabledModels,
  defaultModel,
  disabled,
  placeholder,
  onEnabledChange,
  onDefaultChange,
  onRefresh,
  refreshing,
}: Props) {
  const { t } = useTranslation('settings')
  const [query, setQuery] = useState('')

  const allModels = useMemo(
    () =>
      mergeAiModelIds({
        suggested: suggestedModels,
        available: availableModels,
        current: defaultModel,
      }),
    [suggestedModels, availableModels, defaultModel],
  )

  const allowedSet = useMemo(
    () => new Set(effectiveEnabledModels(availableModels, enabledModels)),
    [availableModels, enabledModels],
  )

  const allAllowed = enabledModels.length === 0 && availableModels.length > 0
  const filtered = useMemo(() => filterAiModels(query, allModels), [query, allModels])
  const { suggested, other } = useMemo(
    () => partitionAiModels(filtered, suggestedModels),
    [filtered, suggestedModels],
  )
  const showSearch = allModels.length > AI_MODEL_SEARCH_THRESHOLD

  function isAllowed(modelId: string): boolean {
    if (availableModels.length === 0) return true
    return allAllowed || allowedSet.has(modelId)
  }

  function toggleAllowed(modelId: string, checked: boolean) {
    if (availableModels.length === 0) return

    const base = allAllowed ? [...availableModels] : [...enabledModels]
    let next: string[]

    if (checked) {
      next = base.includes(modelId) ? base : [...base, modelId]
    } else {
      const remaining = base.filter((id) => id !== modelId)
      if (remaining.length === 0) return
      next = remaining
    }

    const nextEnabled = next.length === availableModels.length ? [] : next
    onEnabledChange(nextEnabled)

    if (!checked && modelId === defaultModel) {
      const nextDefault = pickDefaultAmongAllowed(
        defaultModel,
        availableModels,
        nextEnabled,
        placeholder ?? modelId,
      )
      if (nextDefault !== defaultModel) onDefaultChange(nextDefault)
    }
  }

  function setAsDefault(modelId: string) {
    if (!isAllowed(modelId)) {
      const base = allAllowed ? [...availableModels] : [...enabledModels]
      if (!base.includes(modelId)) base.push(modelId)
      const nextEnabled = base.length === availableModels.length ? [] : base
      onEnabledChange(nextEnabled)
    }
    onDefaultChange(modelId)
  }

  function allowAll() {
    onEnabledChange([])
  }

  if (availableModels.length === 0) {
    return (
      <div className="space-y-2">
        <p className="text-xs text-muted-foreground">
          {t(
            'ai.modelsPanelNoSync',
            'Encara no hi ha models sincronitzats. Pots indicar el model per defecte manualment o actualitzar la llista.',
          )}
        </p>
        <Input
          value={defaultModel}
          disabled={disabled}
          onChange={(e) => onDefaultChange(e.target.value)}
          placeholder={placeholder}
          className="h-9 text-sm"
        />
        {onRefresh && (
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={disabled || refreshing}
            onClick={onRefresh}
          >
            <RefreshCw className={cn('h-4 w-4 mr-2', refreshing && 'animate-spin')} />
            {refreshing
              ? t('ai.refreshingModels', 'Sincronitzant...')
              : t('ai.refreshModels', 'Actualitzar models')}
          </Button>
        )}
      </div>
    )
  }

  function renderRow(modelId: string) {
    const allowed = isAllowed(modelId)
    const isDefault = modelId === defaultModel
    const isSuggested = suggestedModels.includes(modelId)

    return (
      <div
        key={modelId}
        className={cn(
          'flex items-start gap-2 rounded-md px-2 py-1.5 text-sm',
          !allowed && 'opacity-60',
          isDefault && 'bg-indigo-50/80',
        )}
      >
        <Checkbox
          checked={allowed}
          disabled={disabled}
          onCheckedChange={(v) => toggleAllowed(modelId, v === true)}
          className="mt-0.5"
          aria-label={t('ai.modelAllowToggle', 'Permetre {{model}}', { model: modelId })}
        />
        <div className="flex-1 min-w-0">
          <p className="break-all leading-snug">{modelId}</p>
          <div className="flex flex-wrap gap-1 mt-1">
            {isSuggested && (
              <Badge variant="secondary" className="text-[10px] px-1.5 py-0">
                {t('ai.modelSuggestedBadge', 'Suggerit')}
              </Badge>
            )}
            {isDefault ? (
              <Badge className="text-[10px] px-1.5 py-0 bg-indigo-600 hover:bg-indigo-600">
                {t('ai.modelDefaultBadge', 'Per defecte')}
              </Badge>
            ) : (
              allowed && (
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  disabled={disabled}
                  className="h-6 px-1.5 text-[10px] text-muted-foreground"
                  onClick={() => setAsDefault(modelId)}
                >
                  <Star className="h-3 w-3 mr-1" />
                  {t('ai.modelSetDefault', 'Marcar per defecte')}
                </Button>
              )
            )}
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-muted-foreground">
          {allAllowed
            ? t('ai.enabledModelsAll', 'Tots els models disponibles estan permesos.')
            : t('ai.enabledModelsCount', '{{count}} de {{total}} models permesos', {
                count: allowedSet.size,
                total: availableModels.length,
              })}
        </p>
        <div className="flex items-center gap-2">
          {!allAllowed && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="h-7 text-xs"
              disabled={disabled}
              onClick={allowAll}
            >
              {t('ai.enabledModelsAllowAll', 'Permetre tots')}
            </Button>
          )}
          {onRefresh && (
            <Button
              type="button"
              variant="outline"
              size="sm"
              className="h-7 text-xs"
              disabled={disabled || refreshing}
              onClick={onRefresh}
            >
              <RefreshCw className={cn('h-3.5 w-3.5 mr-1.5', refreshing && 'animate-spin')} />
              {refreshing
                ? t('ai.refreshingModels', 'Sincronitzant...')
                : t('ai.refreshModels', 'Actualitzar')}
            </Button>
          )}
        </div>
      </div>

      {showSearch && (
        <Input
          value={query}
          disabled={disabled}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={t('ai.modelSearchPlaceholder', 'Cerca model...')}
          className="h-8 text-sm"
        />
      )}

      <div className="max-h-56 overflow-y-auto rounded-md border p-2 space-y-1">
        {filtered.length === 0 && (
          <p className="text-sm text-muted-foreground px-2 py-4 text-center">
            {t('ai.modelSearchNoResults', 'Cap model coincideix amb la cerca')}
          </p>
        )}
        {suggested.map(renderRow)}
        {other.map(renderRow)}
      </div>

      {showSearch && (
        <p className="text-[11px] text-muted-foreground">
          {filtered.length === allModels.length
            ? t('ai.modelsCount', '{{count}} models disponibles', { count: allModels.length })
            : t('ai.modelsFilteredCount', 'Mostrant {{shown}} de {{total}} models', {
                shown: filtered.length,
                total: allModels.length,
              })}
        </p>
      )}
    </div>
  )
}
