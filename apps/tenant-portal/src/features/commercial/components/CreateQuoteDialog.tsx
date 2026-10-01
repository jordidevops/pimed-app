import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Search } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useTenant } from '@/contexts/TenantContext'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import { getProjectsPage, getProjectsByClientId, type ProjectListItem } from '@/features/projects/api/projectsService'
import { issueCommercialDocument } from '../api/commercialFlowService'
import {
  loadQuotePickerCommercialHints,
  type QuotePickerCommercialHint,
} from '../utils/quotePickerCommercialHints'
import { QuoteFormalizationFields } from './QuoteFormalizationFields'
import {
  parseFormalizationModeDefault,
  type FormalizationMode,
} from '../utils/deviationApprovalThreshold'

interface CreateQuoteDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  onCreated: (documentId: string) => void
  /** When set (contact tab), only list this client's open orders. */
  clientId?: string | null
  clientName?: string | null
}

type CommercialFilter = 'all' | QuotePickerCommercialHint

const FILTER_CHIPS: CommercialFilter[] = [
  'all',
  'no_quote',
  'quote_open',
  'needs_prepare',
  'agreement_draft',
  'agreement_pending',
  'agreement_active',
]

function useDebouncedValue<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), delayMs)
    return () => window.clearTimeout(id)
  }, [value, delayMs])
  return debounced
}

function hintLabel(
  hint: QuotePickerCommercialHint,
  t: (key: string, fallback: string) => string,
): string {
  switch (hint) {
    case 'no_quote':
      return t('projects.quotes.create_hint_no_quote', 'Sense pressupost')
    case 'quote_open':
      return t('projects.quotes.create_hint_quote_open', 'Pressupost en curs')
    case 'needs_prepare':
      return t('projects.quotes.create_hint_needs_prepare', 'Pendent de preparar contracte')
    case 'agreement_draft':
      return t('projects.quotes.create_hint_agreement_draft', 'Acord en esborrany')
    case 'agreement_pending':
      return t('projects.quotes.create_hint_agreement_pending', 'Contracte pendent de firma')
    case 'agreement_active':
      return t('projects.quotes.create_hint_agreement_active', 'Contracte actiu')
    case 'other':
    default:
      return t('projects.quotes.create_hint_other', 'Altres')
  }
}

function filterChipLabel(
  filter: CommercialFilter,
  t: (key: string, fallback: string) => string,
): string {
  if (filter === 'all') return t('projects.quotes.create_filter_all', 'Totes')
  return hintLabel(filter, t)
}

function isOpenOrderStatus(status: string | null | undefined): boolean {
  return status !== 'completed' && status !== 'cancelled'
}

export function CreateQuoteDialog({
  open,
  onOpenChange,
  onCreated,
  clientId = null,
  clientName = null,
}: CreateQuoteDialogProps) {
  const { t } = useTranslation('projects')
  const { activeTenant } = useTenant()
  const isFieldService = useIsFieldService()
  const [q, setQ] = useState('')
  const debouncedQ = useDebouncedValue(q, 250)
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null)
  const [commercialFilter, setCommercialFilter] = useState<CommercialFilter>('no_quote')
  const [mode, setMode] = useState<FormalizationMode>('signed_quote')
  const [modeTouched, setModeTouched] = useState(false)
  const [templateId, setTemplateId] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const { data: effective } = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? '' },
    { enabled: open && !!activeTenant?.id },
  )
  const { data: templates = [] } = useDocumentTemplates(open ? activeTenant?.id : undefined)

  useEffect(() => {
    if (!open) {
      setQ('')
      setSelectedProjectId(null)
      setCommercialFilter('no_quote')
      setMode('signed_quote')
      setModeTouched(false)
      setTemplateId('')
      setBusy(false)
      setError(null)
      return
    }
    if (!modeTouched) setMode(parseFormalizationModeDefault(effective))
  }, [open, effective, modeTouched])

  const { data: globalPage, isLoading: globalLoading } = useQuery({
    queryKey: [
      'projects',
      'quote-create-picker',
      activeTenant?.id,
      debouncedQ,
      isFieldService,
    ],
    queryFn: () =>
      getProjectsPage(activeTenant!.id, {
        page: 1,
        pageSize: 20,
        q: debouncedQ,
        status: '',
        type: isFieldService ? 'work_order' : '',
        siteId: '',
        departmentId: '',
        plannedStartFrom: '',
        plannedStartTo: '',
        sortField: 'created_at',
        sortDirection: 'desc',
        openOnly: true,
      }),
    enabled: open && !!activeTenant?.id && !clientId,
  })

  const { data: clientProjects = [], isLoading: clientLoading } = useQuery({
    queryKey: ['projects', 'by-client', clientId, 'quote-picker'],
    queryFn: () => getProjectsByClientId(clientId!),
    enabled: open && !!clientId,
  })

  const items: ProjectListItem[] = useMemo(() => {
    if (!clientId) return globalPage?.items ?? []
    const qNorm = debouncedQ.trim().toLowerCase()
    return (clientProjects as ProjectListItem[])
      .filter((project) => {
        if (isFieldService && project.type !== 'work_order') return false
        if (!isOpenOrderStatus(project.status)) return false
        if (qNorm) {
          const hay = [project.name, project.description, clientName]
            .filter(Boolean)
            .join(' ')
            .toLowerCase()
          if (!hay.includes(qNorm)) return false
        }
        return true
      })
      .map((project) => ({
        ...project,
        client_display_name: project.client_display_name ?? clientName ?? null,
      }))
  }, [clientId, clientName, clientProjects, debouncedQ, globalPage?.items, isFieldService])

  const isLoading = clientId ? clientLoading : globalLoading
  const projectIds = useMemo(() => items.map((p) => p.id).filter(Boolean), [items])

  const { data: hints = new Map<string, QuotePickerCommercialHint>(), isLoading: hintsLoading } =
    useQuery({
      queryKey: ['projects', 'quote-create-hints', projectIds.join(',')],
      queryFn: () => loadQuotePickerCommercialHints(projectIds),
      enabled: open && projectIds.length > 0,
    })

  const filteredItems = useMemo(() => {
    if (commercialFilter === 'all') return items
    return items.filter((project) => (hints.get(project.id) ?? 'no_quote') === commercialFilter)
  }, [items, hints, commercialFilter])

  useEffect(() => {
    if (!selectedProjectId) return
    if (!filteredItems.some((p) => p.id === selectedProjectId)) {
      setSelectedProjectId(null)
    }
  }, [filteredItems, selectedProjectId])

  async function handleCreate() {
    if (!selectedProjectId || busy) return
    setBusy(true)
    setError(null)
    try {
      const documentId = await issueCommercialDocument({
        projectId: selectedProjectId,
        docType: 'quote',
        formalizationMode: mode,
        fullBodyTemplateId: templateId || null,
      })
      onCreated(documentId)
      onOpenChange(false)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setError(
        message.includes('project_client_required')
          ? t(
              'projects.quotes.create_needs_client',
              'Aquesta ordre no té client. Obre l’ordre i assigna’n un.',
            )
          : t(
              'projects.quotes.create_failed',
              'No s’ha pogut emetre el pressupost. Comprova que l’ordre tingui línies de preu.',
            ),
      )
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={(next) => !busy && onOpenChange(next)}>
      <DialogContent className="flex max-h-[90vh] max-w-md flex-col gap-0 overflow-hidden p-0">
        <div className="shrink-0 space-y-1 border-b border-border px-6 pb-4 pt-6 pr-12">
          <DialogHeader>
            <DialogTitle>
              {t('projects.quotes.create_title', 'Nou pressupost')}
            </DialogTitle>
            <DialogDescription>
              {clientId
                ? t(
                    'projects.quotes.create_help_client',
                    'Tria una ordre oberta d’aquest client. El pressupost s’emetrà amb les línies actuals.',
                  )
                : t(
                    'projects.quotes.create_help',
                    'Tria una ordre amb full de preus. El pressupost s’emetrà amb les línies actuals.',
                  )}
              {clientName ? ` (${clientName})` : ''}
            </DialogDescription>
          </DialogHeader>
        </div>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-6 py-4">
          <label className="relative block">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              className="pl-9"
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder={
                clientId
                  ? t(
                      'projects.quotes.create_search_placeholder_client',
                      'Cerca ordre d’aquest client…',
                    )
                  : t(
                      'projects.quotes.create_search_placeholder',
                      'Cerca per ordre, client o seu…',
                    )
              }
              aria-label={t(
                'projects.quotes.create_search_aria',
                'Cerca ordre per emetre pressupost',
              )}
            />
          </label>

          <div className="flex flex-wrap gap-1.5" role="group" aria-label={t(
            'projects.quotes.create_filter_aria',
            'Filtrar ordres per estat comercial',
          )}>
            {FILTER_CHIPS.map((filter) => {
              const active = commercialFilter === filter
              return (
                <button
                  key={filter}
                  type="button"
                  className={`rounded-full border px-2.5 py-1 text-xs font-medium transition-colors ${
                    active
                      ? 'border-foreground bg-foreground text-background'
                      : 'border-border bg-background text-muted-foreground hover:bg-muted/60'
                  }`}
                  onClick={() => setCommercialFilter(filter)}
                >
                  {filterChipLabel(filter, t)}
                </button>
              )
            })}
          </div>

          <ul className="max-h-64 overflow-y-auto divide-y divide-border rounded-lg border border-border">
            {(isLoading || (projectIds.length > 0 && hintsLoading)) && (
              <li className="px-3 py-4 text-sm text-muted-foreground">
                {t('projects.quotes.loading', 'Carregant…')}
              </li>
            )}
            {!isLoading && !hintsLoading && items.length === 0 && (
              <li className="px-3 py-4 text-sm text-muted-foreground">
                {t(
                  clientId
                    ? 'projects.quotes.create_empty_client'
                    : 'projects.quotes.create_empty',
                  clientId
                    ? 'Aquest client no té cap ordre oberta.'
                    : 'Cap ordre oberta no coincideix amb la cerca.',
                )}
              </li>
            )}
            {!isLoading && !hintsLoading && items.length > 0 && filteredItems.length === 0 && (
              <li className="px-3 py-4 text-sm text-muted-foreground">
                {t(
                  'projects.quotes.create_empty_filter',
                  'Cap ordre d’aquesta cerca coincideix amb el filtre comercial.',
                )}
              </li>
            )}
            {filteredItems.map((project) => {
              const selected = selectedProjectId === project.id
              const hint = hints.get(project.id) ?? 'no_quote'
              const subtitle = [
                project.client_display_name,
                project.contact_site_city,
              ]
                .filter(Boolean)
                .join(' · ')
              return (
                <li key={project.id}>
                  <button
                    type="button"
                    className={`w-full px-3 py-2.5 text-left transition-colors ${
                      selected ? 'bg-muted' : 'hover:bg-muted/60'
                    }`}
                    onClick={() => setSelectedProjectId(project.id)}
                  >
                    <div className="flex items-start justify-between gap-2">
                      <p className="text-sm font-medium text-foreground truncate">
                        {project.name || project.id}
                      </p>
                      <span className="shrink-0 rounded-full bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
                        {hintLabel(hint, t)}
                      </span>
                    </div>
                    {subtitle ? (
                      <p className="mt-0.5 text-xs text-muted-foreground truncate">
                        {subtitle}
                      </p>
                    ) : null}
                  </button>
                </li>
              )
            })}
          </ul>

          <QuoteFormalizationFields
            mode={mode}
            templateId={templateId}
            templates={templates}
            disabled={busy}
            onModeChange={(next) => {
              setModeTouched(true)
              setMode(next)
            }}
            onTemplateChange={setTemplateId}
          />

          {error ? (
            <p className="text-sm text-destructive" role="alert">
              {error}
            </p>
          ) : null}
        </div>

        <DialogFooter className="shrink-0 border-t border-border px-6 py-4">
          <Button
            type="button"
            variant="outline"
            disabled={busy}
            onClick={() => onOpenChange(false)}
          >
            {t('common.cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            disabled={busy || !selectedProjectId}
            onClick={() => void handleCreate()}
          >
            {busy
              ? t('projects.commercial.reissue_busy', 'Creant…')
              : t('projects.quotes.create_confirm', 'Emetre pressupost')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
