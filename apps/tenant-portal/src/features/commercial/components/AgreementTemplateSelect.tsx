import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Search } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  DocumentTemplatePickerDialog,
  type DocumentTemplatePickerItem,
} from './DocumentTemplatePickerDialog'

/** @deprecated Prefer always opening the picker; kept for callers. */
export const DOCUMENT_TEMPLATE_SEARCH_THRESHOLD = 0
export const AGREEMENT_TEMPLATE_SEARCH_THRESHOLD = DOCUMENT_TEMPLATE_SEARCH_THRESHOLD

export type DocumentTemplateOption = DocumentTemplatePickerItem
export type AgreementTemplateOption = DocumentTemplateOption

type DocumentTemplateSelectProps = {
  templates: DocumentTemplateOption[]
  value: string
  onChange: (templateId: string) => void
  disabled?: boolean
  /** When set, allow an empty selection with this label (e.g. tenant default). */
  emptyOptionLabel?: string
  noTemplatesLabel?: string
  searchPlaceholder?: string
  pickerTitle?: string
  pickerDescription?: string
  /** Resolved template used when value is empty (tenant active / fallback). */
  emptyPreviewTemplateId?: string | null
  emptyPreviewMessage?: string
  emptySystemDefaultDocType?: 'quote' | 'delivery_note' | null
}

export function DocumentTemplateSelect({
  templates,
  value,
  onChange,
  disabled = false,
  emptyOptionLabel,
  noTemplatesLabel,
  searchPlaceholder,
  pickerTitle,
  pickerDescription,
  emptyPreviewTemplateId,
  emptyPreviewMessage,
  emptySystemDefaultDocType,
}: DocumentTemplateSelectProps) {
  const { t } = useTranslation('projects')
  const [pickerOpen, setPickerOpen] = useState(false)
  const allowEmpty = emptyOptionLabel != null

  const selected = useMemo(
    () => templates.find((tpl) => tpl.id === value) ?? null,
    [templates, value],
  )

  const selectedLabel = selected
    ? `${selected.name
        ?? t('projects.commercial.prepare_agreement_template_unnamed', 'Sense nom')}${
        selected.is_platform_default
          ? ` (${t('projects.commercial.formalization_template_platform', 'plataforma')})`
          : ''
      }`
    : allowEmpty
      ? emptyOptionLabel
      : t('projects.commercial.template_picker_none_selected', 'Cap plantilla seleccionada')

  if (templates.length === 0 && !allowEmpty) {
    return (
      <select
        className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
        value=""
        disabled
      >
        <option value="">
          {noTemplatesLabel
            ?? t(
              'projects.commercial.prepare_agreement_no_template',
              'No hi ha cap plantilla de contracte',
            )}
        </option>
      </select>
    )
  }

  return (
    <div className="space-y-1.5">
      <Button
        type="button"
        variant="outline"
        disabled={disabled}
        onClick={() => setPickerOpen(true)}
        className="flex h-9 w-full items-center justify-between gap-2 px-3 font-normal"
      >
        <span className="min-w-0 flex-1 truncate text-left">{selectedLabel}</span>
        <span className="inline-flex shrink-0 items-center gap-1 text-muted-foreground">
          <Search className="h-3.5 w-3.5" />
          {t('projects.commercial.template_picker_browse', 'Cercar')}
        </span>
      </Button>

      <DocumentTemplatePickerDialog
        open={pickerOpen}
        onOpenChange={setPickerOpen}
        templates={templates}
        value={value}
        onSelect={onChange}
        allowEmpty={allowEmpty}
        emptyOptionLabel={emptyOptionLabel}
        title={pickerTitle}
        description={pickerDescription}
        searchPlaceholder={searchPlaceholder}
        emptyPreviewTemplateId={emptyPreviewTemplateId}
        emptyPreviewMessage={emptyPreviewMessage}
        emptySystemDefaultDocType={emptySystemDefaultDocType}
      />
    </div>
  )
}

export function AgreementTemplateSelect(props: DocumentTemplateSelectProps) {
  return <DocumentTemplateSelect {...props} />
}
