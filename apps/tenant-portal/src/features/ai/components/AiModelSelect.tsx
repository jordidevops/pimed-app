import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Input } from '@/components/ui/input'
import {
  AI_MODEL_SEARCH_THRESHOLD,
  filterAiModels,
  mergeAiModelIds,
  partitionAiModels,
} from '../utils/aiModels'

type AiModelSelectProps = {
  value: string
  onChange: (modelId: string) => void
  suggestedModels?: string[]
  availableModels?: string[]
  disabled?: boolean
  placeholder?: string
  selectClassName?: string
  allowFreeText?: boolean
}

export function AiModelSelect({
  value,
  onChange,
  suggestedModels = [],
  availableModels = [],
  disabled = false,
  placeholder,
  selectClassName = 'h-9 w-full rounded-md border bg-background px-3 text-sm',
  allowFreeText = true,
}: AiModelSelectProps) {
  const { t } = useTranslation('settings')
  const [query, setQuery] = useState('')

  const allModels = useMemo(
    () => mergeAiModelIds({
      suggested: suggestedModels,
      available: availableModels,
      current: value,
    }),
    [suggestedModels, availableModels, value],
  )

  const filtered = useMemo(
    () => filterAiModels(query, allModels),
    [query, allModels],
  )

  const { suggested, other } = useMemo(
    () => partitionAiModels(filtered, suggestedModels),
    [filtered, suggestedModels],
  )

  const showSearch = allModels.length > AI_MODEL_SEARCH_THRESHOLD
  const useSelect = allModels.length > 0

  if (!useSelect) {
    return (
      <Input
        value={value}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        className={selectClassName}
      />
    )
  }

  const inFiltered = value && filtered.includes(value)
  const selectValue = inFiltered ? value : (value || filtered[0] || '')

  return (
    <div className="space-y-1.5">
      {showSearch && (
        <Input
          value={query}
          disabled={disabled}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={t('ai.modelSearchPlaceholder', 'Cerca model...')}
          className="h-8 text-sm"
        />
      )}

      <select
        value={selectValue}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
        className={selectClassName}
      >
        {allowFreeText && value && !filtered.includes(value) && (
          <option value={value}>{value}</option>
        )}
        {suggested.length > 0 && (
          <optgroup label={t('ai.modelSuggestedGroup', 'Suggerits')}>
            {suggested.map((modelId) => (
              <option key={`s-${modelId}`} value={modelId}>{modelId}</option>
            ))}
          </optgroup>
        )}
        {other.length > 0 && (
          <optgroup label={
            suggested.length > 0
              ? t('ai.modelAllGroup', 'Tots els models')
              : t('ai.model', 'Model')
          }>
            {other.map((modelId) => (
              <option key={`o-${modelId}`} value={modelId}>{modelId}</option>
            ))}
          </optgroup>
        )}
        {filtered.length === 0 && (
          <option value="" disabled>
            {t('ai.modelSearchNoResults', 'Cap model coincideix amb la cerca')}
          </option>
        )}
      </select>

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
