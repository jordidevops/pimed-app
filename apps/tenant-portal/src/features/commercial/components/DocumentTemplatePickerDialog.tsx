import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Search } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { DocumentTemplatePreviewPane } from './DocumentTemplatePreviewPane'

export type DocumentTemplatePickerItem = {
  id: string
  name: string | null
  is_platform_default?: boolean | null
  template_type?: string | null
  default_block_mapping?: Record<string, string> | null
}

type DocumentTemplatePickerDialogProps = {
  open: boolean
  onOpenChange: (open: boolean) => void
  templates: DocumentTemplatePickerItem[]
  value: string
  onSelect: (templateId: string) => void
  allowEmpty?: boolean
  emptyOptionLabel?: string
  title?: string
  description?: string
  searchPlaceholder?: string
  /** When highlight is the empty option, preview this resolved template id. */
  emptyPreviewTemplateId?: string | null
  emptyPreviewMessage?: string
  /**
   * When the empty option has no resolved template, show QT-D1 system-default
   * sample preview for this doc type.
   */
  emptySystemDefaultDocType?: 'quote' | 'delivery_note' | null
}

export function DocumentTemplatePickerDialog({
  open,
  onOpenChange,
  templates,
  value,
  onSelect,
  allowEmpty = false,
  emptyOptionLabel,
  title,
  description,
  searchPlaceholder,
  emptyPreviewTemplateId = null,
  emptyPreviewMessage,
  emptySystemDefaultDocType = null,
}: DocumentTemplatePickerDialogProps) {
  const { t } = useTranslation(['projects', 'common'])
  const [query, setQuery] = useState('')
  const [highlightId, setHighlightId] = useState(value)

  useEffect(() => {
    if (!open) return
    setQuery('')
    setHighlightId(value)
  }, [open, value])

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return templates
    return templates.filter((tpl) => (tpl.name ?? '').toLowerCase().includes(q))
  }, [templates, query])

  const highlight = useMemo(
    () => templates.find((tpl) => tpl.id === highlightId) ?? null,
    [templates, highlightId],
  )

  const previewTemplateId =
    highlightId || (allowEmpty ? emptyPreviewTemplateId ?? '' : '')
  const previewTemplate =
    templates.find((tpl) => tpl.id === previewTemplateId) ?? null
  const previewingEmptyDefault = allowEmpty && !highlightId

  function confirm(id: string) {
    onSelect(id)
    onOpenChange(false)
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="flex max-h-[90vh] w-full max-w-4xl flex-col gap-0 overflow-hidden p-0">
        <DialogHeader className="shrink-0 space-y-1 border-b border-border px-6 py-4 text-left">
          <DialogTitle>
            {title ?? t('projects.commercial.template_picker_title', 'Triar plantilla')}
          </DialogTitle>
          <DialogDescription>
            {description
              ?? t(
                'projects.commercial.template_picker_help',
                'Cerca per nom i revisa la vista prèvia abans de seleccionar.',
              )}
          </DialogDescription>
        </DialogHeader>

        <div className="grid min-h-[min(70vh,40rem)] flex-1 gap-0 overflow-hidden md:grid-cols-[minmax(0,18rem)_minmax(0,1fr)]">
          <div className="flex min-h-0 flex-col overflow-hidden border-b border-border md:border-b-0 md:border-r">
            <div className="shrink-0 space-y-2 border-b border-border px-4 py-3">
              <div className="relative">
                <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  autoFocus
                  type="search"
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder={
                    searchPlaceholder
                    ?? t(
                      'projects.commercial.prepare_agreement_template_search',
                      'Cerca plantilla per nom…',
                    )
                  }
                  className="h-9 pl-8"
                />
              </div>
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
            </div>

            <ul className="min-h-0 flex-1 overflow-y-auto p-2">
              {allowEmpty ? (
                <li>
                  <button
                    type="button"
                    className={`w-full rounded-md px-3 py-2 text-left text-sm transition-colors ${
                      highlightId === ''
                        ? 'bg-muted font-medium'
                        : 'hover:bg-muted/60'
                    }`}
                    onClick={() => setHighlightId('')}
                    onDoubleClick={() => confirm('')}
                  >
                    {emptyOptionLabel
                      ?? t(
                        'projects.commercial.formalization_template_default',
                        'La plantilla activa del tenant',
                      )}
                  </button>
                </li>
              ) : null}
              {filtered.length === 0 ? (
                <li className="px-3 py-6 text-center text-sm text-muted-foreground">
                  {t(
                    'projects.commercial.prepare_agreement_template_no_match',
                    'Cap plantilla coincideix amb la cerca',
                  )}
                </li>
              ) : (
                filtered.map((tpl) => {
                  const active = tpl.id === highlightId
                  return (
                    <li key={tpl.id}>
                      <button
                        type="button"
                        className={`w-full rounded-md px-3 py-2 text-left text-sm transition-colors ${
                          active ? 'bg-muted font-medium' : 'hover:bg-muted/60'
                        }`}
                        onClick={() => setHighlightId(tpl.id)}
                        onDoubleClick={() => confirm(tpl.id)}
                      >
                        <span className="block truncate">
                          {tpl.name
                            ?? t(
                              'projects.commercial.prepare_agreement_template_unnamed',
                              'Sense nom',
                            )}
                        </span>
                        <span className="mt-0.5 flex flex-wrap gap-1.5 text-[10px] text-muted-foreground">
                          {tpl.template_type ? (
                            <span className="uppercase">{tpl.template_type}</span>
                          ) : null}
                          {tpl.is_platform_default ? (
                            <span>
                              {t(
                                'projects.commercial.formalization_template_platform',
                                'plataforma',
                              )}
                            </span>
                          ) : null}
                        </span>
                      </button>
                    </li>
                  )
                })
              )}
            </ul>
          </div>

          <div className="flex min-h-0 flex-col overflow-hidden px-4 py-3">
            <p className="mb-2 shrink-0 text-xs font-medium text-muted-foreground">
              {t('projects.commercial.template_preview_label', 'Vista prèvia')}
              {previewingEmptyDefault && previewTemplate?.name
                ? `: ${previewTemplate.name}`
                : ''}
            </p>
            {previewTemplateId || (previewingEmptyDefault && emptySystemDefaultDocType) ? (
              <div className="flex min-h-0 flex-1 flex-col gap-2">
                {previewingEmptyDefault && previewTemplateId ? (
                  <p className="shrink-0 text-[11px] text-muted-foreground">
                    {emptyPreviewMessage
                      ?? t(
                        'projects.commercial.template_preview_tenant_default_resolved',
                        'Aquesta és la plantilla activa del tenant que s’usarà si no en tries cap altra.',
                      )}
                  </p>
                ) : null}
                <DocumentTemplatePreviewPane
                  templateId={previewTemplateId || null}
                  templateType={
                    highlight?.template_type ?? previewTemplate?.template_type
                  }
                  blockMapping={
                    highlight?.default_block_mapping
                    ?? previewTemplate?.default_block_mapping
                  }
                  systemDefaultDocType={
                    previewingEmptyDefault && !previewTemplateId
                      ? emptySystemDefaultDocType
                      : null
                  }
                  className="min-h-0 flex-1"
                />
              </div>
            ) : (
              <p className="rounded-lg border border-dashed border-border px-3 py-8 text-center text-xs text-muted-foreground">
                {allowEmpty
                  ? emptyPreviewMessage
                    ?? t(
                      'projects.commercial.template_preview_tenant_default_none',
                      'No hi ha plantilla activa resoluble (format per defecte del sistema).',
                    )
                  : t(
                      'projects.commercial.template_preview_none',
                      'Selecciona una plantilla per veure’n la vista prèvia.',
                    )}
              </p>
            )}
          </div>
        </div>

        <DialogFooter className="shrink-0 border-t border-border px-6 py-4">
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            {t('common:cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            onClick={() => confirm(highlightId)}
            disabled={!allowEmpty && !highlightId}
          >
            {t('projects.commercial.template_picker_confirm', 'Seleccionar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
