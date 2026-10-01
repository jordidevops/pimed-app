import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Input } from '@/components/ui/input'

/** Show the search field once the list grows past a plain select. */
export const DOCUMENT_TEMPLATE_SEARCH_THRESHOLD = 6

export type DocumentTemplateOption = {
  id: string
  name: string | null
  is_platform_default?: boolean | null
}

type DocumentTemplateSelectProps = {
  templates: DocumentTemplateOption[]
  value: string
  onChange: (templateId: string) => void
  disabled?: boolean
  /** When set, allow an empty selection with this label (e.g. tenant default). */
  emptyOptionLabel?: string
  noTemplatesLabel?: string
  searchPlaceholder?: string
}

/** @deprecated Prefer DocumentTemplateSelect — kept as alias for agreement dialogs. */
export const AGREEMENT_TEMPLATE_SEARCH_THRESHOLD = DOCUMENT_TEMPLATE_SEARCH_THRESHOLD
export type AgreementTemplateOption = DocumentTemplateOption

export function DocumentTemplateSelect({
  templates,
  value,
  onChange,
  disabled = false,
  emptyOptionLabel,
  noTemplatesLabel,
  searchPlaceholder,
}: DocumentTemplateSelectProps) {
  const { t } = useTranslation('projects')
  const [query, setQuery] = useState('')
  const allowEmpty = emptyOptionLabel != null

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return templates
    return templates.filter((tpl) => (tpl.name ?? '').toLowerCase().includes(q))
  }, [templates, query])

  const showSearch = templates.length > DOCUMENT_TEMPLATE_SEARCH_THRESHOLD

  let selectValue = ''
  if (value && (filtered.some((tpl) => tpl.id === value) || templates.some((tpl) => tpl.id === value))) {
    selectValue = value
  } else if (!allowEmpty && filtered[0]?.id) {
    selectValue = filtered[0].id
  }

  if (templates.length === 0 && !allowEmpty) {
    return (
      <select
        className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
        value=""
        disabled
      >
        <option value="">
          {noTemplatesLabel
            ?? t('projects.commercial.prepare_agreement_no_template', 'No hi ha cap plantilla de contracte')}
        </option>
      </select>
    )
  }

  return (
    <div className="space-y-1.5">
      {showSearch ? (
        <Input
          type="search"
          value={query}
          disabled={disabled}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={
            searchPlaceholder
            ?? t('projects.commercial.prepare_agreement_template_search', 'Cerca plantilla per nom…')
          }
          className="h-8 text-sm"
        />
      ) : null}

      <select
        className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
        value={selectValue}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
      >
        {allowEmpty ? <option value="">{emptyOptionLabel}</option> : null}
        {value && !filtered.some((tpl) => tpl.id === value) && !allowEmpty ? (
          <option value={value}>
            {templates.find((tpl) => tpl.id === value)?.name
              ?? t('projects.commercial.prepare_agreement_template_selected', 'Plantilla seleccionada')}
          </option>
        ) : null}
        {filtered.map((tpl) => (
          <option key={tpl.id} value={tpl.id}>
            {tpl.name
              ?? t('projects.commercial.prepare_agreement_template_unnamed', 'Sense nom')}
            {tpl.is_platform_default
              ? ` (${t('projects.commercial.formalization_template_platform', 'plataforma')})`
              : ''}
          </option>
        ))}
        {filtered.length === 0 ? (
          <option value="" disabled>
            {t(
              'projects.commercial.prepare_agreement_template_no_match',
              'Cap plantilla coincideix amb la cerca',
            )}
          </option>
        ) : null}
      </select>

      {showSearch ? (
        <p className="text-[11px] text-muted-foreground">
          {filtered.length === templates.length
            ? t(
                'projects.commercial.prepare_agreement_template_count',
                '{{count}} plantilles disponibles',
                { count: templates.length },
              )
            : t(
                'projects.commercial.prepare_agreement_template_filtered',
                'Mostrant {{shown}} de {{total}}',
                { shown: filtered.length, total: templates.length },
              )}
        </p>
      ) : null}
    </div>
  )
}

export function AgreementTemplateSelect(props: DocumentTemplateSelectProps) {
  return <DocumentTemplateSelect {...props} />
}
