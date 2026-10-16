import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  Calculator,
  ChevronRight,
  Copy,
  Plus,
  Search,
  Trash2,
} from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import {
  EMPTY_CALCULATOR_DEFINITION,
  activateClonedCalculator,
  cloneCalculatorFromCatalog,
  createCalculatorDefinition,
  deleteCalculatorDefinition,
  getCalculatorCatalogSettings,
  listCalculatorCatalog,
  listCalculators,
  listTenantCalculatorTags,
  setCalculatorStatus,
  type CalculatorCatalogRow,
  type CalculatorDefinitionRow,
} from '@/features/commercial/api/calculatorService'
import {
  calculatorAiCreatePath,
  createCalculatorForAi,
} from '@/features/commercial/api/calculatorCreateAi'
import { nextCalculatorCloneName } from '@/features/commercial/utils/calculatorCloneName'
import { resolveLocale } from '@pimed/price-calculator'

const STATUS_LABEL: Record<CalculatorDefinitionRow['status'], { ca: string }> = {
  draft: { ca: 'Esborrany' },
  incomplete: { ca: 'Incompleta' },
  active: { ca: 'Activa' },
  archived: { ca: 'Arxivada' },
}

type ListTab = 'mine' | 'library'
type StatusFilter = 'open' | 'archived' | 'all'

function isCalculatorHasRunsError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err ?? '')
  return msg.includes('calculator_has_runs')
}

export function CalculatorsListPage() {
  const { t } = useTranslation(['catalog', 'common'])
  const { activeTenant, activeRole } = useTenant()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { toast } = useToast()
  const canEdit = activeRole === 'owner' || activeRole === 'manager'
  const archetype = activeTenant?.archetype ?? 'generic'

  const [search, setSearch] = useState('')
  const [tagFilter, setTagFilter] = useState<string | null>(null)
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('open')
  const [busy, setBusy] = useState(false)
  const [tab, setTab] = useState<ListTab>('mine')
  const [pendingDelete, setPendingDelete] = useState<CalculatorDefinitionRow | null>(null)
  const [highlightedMineId, setHighlightedMineId] = useState<string | null>(null)
  const [highlightedCatalogId, setHighlightedCatalogId] = useState<string | null>(null)
  const highlightTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  function scheduleHighlightClear(
    clear: () => void,
  ) {
    if (highlightTimerRef.current) clearTimeout(highlightTimerRef.current)
    highlightTimerRef.current = setTimeout(clear, 4000)
  }

  function focusClonedRow(id: string) {
    setStatusFilter('open')
    setTab('mine')
    setHighlightedCatalogId(null)
    setHighlightedMineId(id)
    scheduleHighlightClear(() => setHighlightedMineId(null))
  }

  function focusCatalogRow(catalogId: string) {
    setTab('library')
    setHighlightedMineId(null)
    setHighlightedCatalogId(catalogId)
    scheduleHighlightClear(() => setHighlightedCatalogId(null))
  }

  useEffect(() => {
    return () => {
      if (highlightTimerRef.current) clearTimeout(highlightTimerRef.current)
    }
  }, [])

  const { data: rows = [], isLoading } = useQuery({
    queryKey: ['calculator_definitions', activeTenant?.id],
    queryFn: () => listCalculators({ status: 'all' }),
    enabled: !!activeTenant,
  })

  const { data: catalogSettings } = useQuery({
    queryKey: ['calculator_catalog_settings'],
    queryFn: getCalculatorCatalogSettings,
    enabled: !!activeTenant && canEdit,
  })
  const allowCross = catalogSettings?.show_cross_archetype_catalog === true

  const {
    data: catalog = [],
    isError: catalogError,
    error: catalogErr,
  } = useQuery({
    queryKey: ['calculator_catalog', activeTenant?.id, archetype, allowCross],
    queryFn: () => listCalculatorCatalog(archetype, { allowCrossArchetype: allowCross }),
    // Do not wait for settings RPC — default allowCross=false until settings resolve.
    enabled: !!activeTenant && canEdit,
  })

  const { data: tags = [] } = useQuery({
    queryKey: ['calculator_tags', activeTenant?.id],
    queryFn: listTenantCalculatorTags,
    enabled: !!activeTenant,
  })

  const cloneCountsByCatalogId = useMemo(() => {
    const map = new Map<string, number>()
    for (const row of rows) {
      if (!row.cloned_from_catalog_id || row.status === 'archived') continue
      map.set(row.cloned_from_catalog_id, (map.get(row.cloned_from_catalog_id) ?? 0) + 1)
    }
    return map
  }, [rows])

  const catalogTitleById = useMemo(() => {
    const map = new Map<string, string>()
    for (const entry of catalog) {
      map.set(entry.id, resolveLocale(entry.title ?? undefined, 'ca') || entry.slug)
    }
    return map
  }, [catalog])

  const openNames = useMemo(
    () => rows.filter((r) => r.status !== 'archived').map((r) => r.name),
    [rows],
  )

  const archivedCount = useMemo(
    () => rows.filter((r) => r.status === 'archived').length,
    [rows],
  )

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return rows.filter((row) => {
      if (statusFilter === 'open' && row.status === 'archived') return false
      if (statusFilter === 'archived' && row.status !== 'archived') return false
      if (tagFilter && !(row.tags ?? []).includes(tagFilter)) return false
      if (!q) return true
      return (
        row.name.toLowerCase().includes(q) ||
        (row.description ?? '').toLowerCase().includes(q) ||
        (row.tags ?? []).some((tag) => tag.includes(q))
      )
    })
  }, [rows, search, tagFilter, statusFilter])

  useEffect(() => {
    if (!highlightedMineId || tab !== 'mine') return
    const el = document.getElementById(`calculator-row-${highlightedMineId}`)
    el?.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
  }, [highlightedMineId, tab, filtered])

  useEffect(() => {
    if (!highlightedCatalogId || tab !== 'library') return
    const el = document.getElementById(`calculator-catalog-${highlightedCatalogId}`)
    el?.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
  }, [highlightedCatalogId, tab, catalog])

  const matchingOwnArchetype = useMemo(
    () => catalog.filter((c) => !c.crossArchetype),
    [catalog],
  )

  async function handleCreate() {
    if (!canEdit || busy) return
    setBusy(true)
    try {
      const id = await createCalculatorDefinition({
        name: t('catalog.calculators.new_name', 'Nova calculadora'),
        description: t(
          'catalog.calculators.new_help',
          'Afegeix tarifes, taules i línies amb l’assistent, o clona des de la biblioteca.',
        ),
        draftDefinition: EMPTY_CALCULATOR_DEFINITION,
        tags: [],
      })
      await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
      navigate(`/catalog/calculators/${id}`)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function handleCreateWithAi() {
    if (!canEdit || busy) return
    setBusy(true)
    try {
      const id = await createCalculatorForAi({
        name: t('catalog.calculators.new_name', 'Nova calculadora'),
        description: t(
          'catalog.calculators.new_help_ai',
          'Esborrany creat amb IA. Revisa tarifes i desa una prova abans d’activar.',
        ),
      })
      await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
      navigate(calculatorAiCreatePath(id))
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function handleClone(entry: CalculatorCatalogRow) {
    if (!canEdit || busy) return
    setBusy(true)
    let clonedId: string | null = null
    try {
      const title = resolveLocale(entry.title ?? undefined, 'ca') || entry.slug
      const name = nextCalculatorCloneName(title, openNames)
      clonedId = await cloneCalculatorFromCatalog({
        catalogId: entry.id,
        name,
      })
      const defaultCase = entry.default_case
      if (defaultCase?.params) {
        try {
          await activateClonedCalculator({
            definitionId: clonedId,
            definition: entry.definition,
            defaultCase,
          })
          toast({
            title: t(
              'catalog.calculators.clone_ready',
              'Clonada i activa. Ja disponible al flux ràpid.',
            ),
          })
        } catch (activateErr) {
          toast({
            variant: 'destructive',
            description:
              (activateErr instanceof Error ? activateErr.message : String(activateErr)) +
              ' — ' +
              t(
                'catalog.calculators.clone_activate_retry_hint',
                'Clon creat. Obre l’editor i usa «Reintentar activació».',
              ),
          })
        }
      } else {
        toast({
          title: t(
            'catalog.calculators.clone_incomplete',
            'Clonada. Omple tarifes i una prova abans d’activar.',
          ),
        })
      }
      await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
      focusClonedRow(clonedId)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
      if (clonedId) {
        await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
        focusClonedRow(clonedId)
      }
    } finally {
      setBusy(false)
    }
  }

  async function handleArchive(row: CalculatorDefinitionRow) {
    if (!canEdit || busy || row.status !== 'active') return
    setBusy(true)
    try {
      await setCalculatorStatus(row.id, 'archived')
      await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
      await queryClient.invalidateQueries({ queryKey: ['calculator_tags'] })
      setStatusFilter('archived')
      toast({
        title: t('catalog.calculators.archived_one', 'Calculadora arxivada'),
        description: t(
          'catalog.calculators.archived_hint',
          'La trobaràs a «Arxivades». Des d’allà pots eliminar-la si no té execucions.',
        ),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
    } finally {
      setBusy(false)
    }
  }

  async function confirmDelete() {
    const row = pendingDelete
    if (!row || !canEdit || busy || row.status === 'active') return
    setBusy(true)
    try {
      await deleteCalculatorDefinition(row.id)
      setPendingDelete(null)
      await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
      await queryClient.invalidateQueries({ queryKey: ['calculator_tags'] })
      toast({
        title: t('catalog.calculators.deleted_one', 'Calculadora eliminada'),
      })
    } catch (err) {
      if (isCalculatorHasRunsError(err)) {
        toast({
          variant: 'destructive',
          description: t(
            'catalog.calculators.delete_has_runs',
            'No es pot eliminar: té execucions. Només pots arxivar-la.',
          ),
        })
      } else {
        toast({
          variant: 'destructive',
          description: err instanceof Error ? err.message : t('common:error', 'Error'),
        })
      }
    } finally {
      setBusy(false)
    }
  }

  if (!canEdit) {
    return (
      <p className="text-sm text-muted-foreground">
        {t(
          'catalog.calculators.owner_only',
          'Només el propietari o el gestor poden editar calculadores.',
        )}
      </p>
    )
  }

  return (
    <div className="space-y-4">
      <Tabs
        value={tab}
        onValueChange={(value) => setTab(value as ListTab)}
      >
        <TabsList>
          <TabsTrigger value="mine">
            {t('catalog.calculators.tab_mine', 'Calculadores pròpies')}
          </TabsTrigger>
          <TabsTrigger value="library">
            {t('catalog.calculators.tab_library', 'Calculadores del sistema')}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="library" className="mt-4 space-y-3">
          <div>
            <p className="text-sm text-muted-foreground">
              {t(
                'catalog.calculators.library_help',
                'Les del sistema no s’apliquen al flux comercial: clona-les per usar-les i adaptar les tarifes.',
              )}
            </p>
          </div>
          {catalogError ? (
            <p className="text-sm text-destructive">
              {t(
                'catalog.calculators.library_load_error',
                'No s’ha pogut carregar la biblioteca. Torna-ho a provar.',
              )}
              {catalogErr instanceof Error && catalogErr.message ? (
                <span className="mt-1 block text-xs opacity-80">{catalogErr.message}</span>
              ) : null}
            </p>
          ) : catalog.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {!allowCross && matchingOwnArchetype.length === 0
                ? t(
                    'catalog.calculators.library_empty_archetype',
                    'Cap model assignat al teu arquetip. Contacta amb plataforma o amplia arquetips a admin.',
                  )
                : t('catalog.calculators.library_empty', 'No hi ha models per al teu arquetip.')}
            </p>
          ) : (
            <div className="space-y-3">
              {catalog.map((entry) => {
                const title = resolveLocale(entry.title ?? undefined, 'ca') || entry.slug
                const summary = resolveLocale(entry.summary ?? undefined, 'ca')
                const cloneCount = cloneCountsByCatalogId.get(entry.id) ?? 0
                const highlighted = highlightedCatalogId === entry.id
                return (
                  <div
                    key={entry.id}
                    id={`calculator-catalog-${entry.id}`}
                    className={`overflow-hidden rounded-xl border bg-card transition-colors hover:bg-accent/30 ${
                      highlighted ? 'ring-2 ring-primary bg-primary/5' : ''
                    }`}
                  >
                    <div className="flex items-center gap-3 px-4 py-3">
                      <Calculator className="h-4 w-4 shrink-0 text-muted-foreground" />
                      <div className="min-w-0 flex-1">
                        <p className="truncate text-sm font-medium">{title}</p>
                        {summary ? (
                          <p className="truncate text-xs text-muted-foreground">{summary}</p>
                        ) : null}
                        <div className="mt-1.5 flex flex-wrap gap-1">
                          <span className="rounded bg-indigo-100 px-2 py-0.5 text-[10px] font-semibold uppercase text-indigo-700">
                            {t('catalog.calculators.system_badge', 'Sistema')}
                          </span>
                          {entry.crossArchetype ? (
                            <span className="rounded bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
                              {t('catalog.calculators.cross_archetype', 'Altre arquetip')}
                            </span>
                          ) : null}
                          {cloneCount === 1 ? (
                            <button
                              type="button"
                              className="rounded bg-amber-100 px-2 py-0.5 text-[10px] font-medium text-amber-700 hover:bg-amber-200"
                              onClick={() => setTab('mine')}
                            >
                              {t('catalog.calculators.already_cloned', 'Ja la tens')}
                            </button>
                          ) : null}
                          {cloneCount > 1 ? (
                            <button
                              type="button"
                              className="rounded bg-amber-100 px-2 py-0.5 text-[10px] font-medium text-amber-700 hover:bg-amber-200"
                              onClick={() => setTab('mine')}
                            >
                              {t('catalog.calculators.clone_count', '{{n}} còpies', {
                                n: cloneCount,
                              })}
                            </button>
                          ) : null}
                          {(entry.tags ?? []).map((tag) => (
                            <span
                              key={tag}
                              className="rounded bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-700 dark:bg-slate-800 dark:text-slate-300"
                            >
                              {tag}
                            </span>
                          ))}
                        </div>
                      </div>
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        className="h-7 shrink-0 text-xs"
                        disabled={busy}
                        onClick={() => void handleClone(entry)}
                      >
                        <Copy className="mr-1 h-3.5 w-3.5" />
                        {t('catalog.calculators.clone', 'Clonar per personalitzar')}
                      </Button>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </TabsContent>

        <TabsContent value="mine" className="mt-4 space-y-3">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div className="relative min-w-0 flex-1">
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                className="pl-9"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder={t('catalog.calculators.search', 'Cerca per nom o tag…')}
              />
            </div>
            <div className="flex flex-wrap gap-2">
              <Button type="button" disabled={busy} onClick={() => void handleCreate()}>
                <Plus className="mr-1.5 h-4 w-4" />
                {t('catalog.calculators.create', 'Nova calculadora')}
              </Button>
              <Button
                type="button"
                variant="secondary"
                disabled={busy}
                onClick={() => void handleCreateWithAi()}
              >
                <Calculator className="mr-1.5 h-4 w-4" />
                {t(
                  'catalog.calculators.create_with_ai',
                  'Generar calculadora amb IA',
                )}
              </Button>
            </div>
          </div>

          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              size="sm"
              variant={statusFilter === 'open' ? 'secondary' : 'outline'}
              onClick={() => setStatusFilter('open')}
            >
              {t('catalog.calculators.filter_open', 'Actuals')}
            </Button>
            <Button
              type="button"
              size="sm"
              variant={statusFilter === 'archived' ? 'secondary' : 'outline'}
              onClick={() => setStatusFilter('archived')}
            >
              {t('catalog.calculators.filter_archived', 'Arxivades')}
              {archivedCount > 0 ? ` (${archivedCount})` : ''}
            </Button>
            <Button
              type="button"
              size="sm"
              variant={statusFilter === 'all' ? 'secondary' : 'outline'}
              onClick={() => setStatusFilter('all')}
            >
              {t('catalog.calculators.filter_all', 'Totes')}
            </Button>
          </div>

          {tags.length > 0 ? (
            <div className="flex flex-wrap gap-2">
              <Button
                type="button"
                size="sm"
                variant={tagFilter == null ? 'secondary' : 'outline'}
                onClick={() => setTagFilter(null)}
              >
                {t('catalog.calculators.all_tags', 'Tots els tags')}
              </Button>
              {tags.map((tag) => (
                <Button
                  key={tag}
                  type="button"
                  size="sm"
                  variant={tagFilter === tag ? 'secondary' : 'outline'}
                  onClick={() => setTagFilter(tag)}
                >
                  {tag}
                </Button>
              ))}
            </div>
          ) : null}

          {isLoading ? (
            <p className="text-sm text-muted-foreground">{t('common:loading', 'Carregant…')}</p>
          ) : filtered.length === 0 ? (
            <div className="flex flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-border py-12">
              <Calculator className="h-8 w-8 text-muted-foreground" />
              <p className="text-sm text-muted-foreground">
                {statusFilter === 'archived'
                  ? t('catalog.calculators.empty_archived', 'No hi ha calculadores arxivades.')
                  : archivedCount > 0
                    ? t(
                        'catalog.calculators.empty_but_archived',
                        'No hi ha calculadores actives. En tens {{n}} d’arxivades.',
                        { n: archivedCount },
                      )
                    : t('catalog.calculators.empty', 'Encara no hi ha calculadores.')}
              </p>
              <div className="flex flex-wrap justify-center gap-2">
                {archivedCount > 0 && statusFilter !== 'archived' ? (
                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => setStatusFilter('archived')}
                  >
                    {t('catalog.calculators.show_archived', 'Veure arxivades')}
                  </Button>
                ) : null}
                <Button type="button" variant="outline" onClick={() => setTab('library')}>
                  {t('catalog.calculators.go_library', 'Veure del sistema')}
                </Button>
                <Button type="button" disabled={busy} onClick={() => void handleCreate()}>
                  {t('catalog.calculators.create', 'Nova calculadora')}
                </Button>
                <Button
                  type="button"
                  variant="secondary"
                  disabled={busy}
                  onClick={() => void handleCreateWithAi()}
                >
                  {t(
                    'catalog.calculators.create_with_ai',
                    'Generar calculadora amb IA',
                  )}
                </Button>
              </div>
            </div>
          ) : (
            <div className="space-y-3">
              {filtered.map((row) => {
                const systemTitle = row.cloned_from_catalog_id
                  ? catalogTitleById.get(row.cloned_from_catalog_id)
                  : undefined
                const highlighted = highlightedMineId === row.id
                return (
                  <div
                    key={row.id}
                    id={`calculator-row-${row.id}`}
                    role="button"
                    tabIndex={0}
                    className={`cursor-pointer overflow-hidden rounded-xl border bg-card transition-colors hover:bg-accent/30 ${
                      highlighted
                        ? 'ring-2 ring-primary bg-primary/5'
                        : ''
                    }`}
                    onClick={() => navigate(`/catalog/calculators/${row.id}`)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') navigate(`/catalog/calculators/${row.id}`)
                    }}
                  >
                    <div className="flex items-center gap-3 px-4 py-3">
                      <Calculator className="h-4 w-4 shrink-0 text-muted-foreground" />
                      <div className="min-w-0 flex-1">
                        <p className="truncate text-sm font-medium">{row.name}</p>
                        {row.description ? (
                          <p className="truncate text-xs text-muted-foreground">
                            {row.description}
                          </p>
                        ) : null}
                        <div className="mt-1.5 flex flex-wrap gap-1">
                          <span className="rounded bg-amber-100 px-2 py-0.5 text-[10px] font-semibold uppercase text-amber-700">
                            {t('catalog.calculators.own_badge', 'Pròpia')}
                          </span>
                          <span className="rounded bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
                            {STATUS_LABEL[row.status].ca}
                          </span>
                          {row.cloned_from_catalog_id ? (
                            <button
                              type="button"
                              className="rounded bg-indigo-100 px-2 py-0.5 text-[10px] font-medium text-indigo-700 hover:bg-indigo-200"
                              onClick={(e) => {
                                e.stopPropagation()
                                focusCatalogRow(row.cloned_from_catalog_id!)
                              }}
                            >
                              {systemTitle
                                ? t(
                                    'catalog.calculators.from_system_named',
                                    'Del sistema: {{name}}',
                                    { name: systemTitle },
                                  )
                                : t('catalog.calculators.from_system', 'Del sistema')}
                            </button>
                          ) : null}
                          {(row.tags ?? []).map((tag) => (
                            <span
                              key={tag}
                              className="rounded bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-700 dark:bg-slate-800 dark:text-slate-300"
                            >
                              {tag}
                            </span>
                          ))}
                        </div>
                      </div>
                      {row.status === 'active' ? (
                        <Button
                          type="button"
                          variant="outline"
                          size="sm"
                          className="h-7 shrink-0 text-xs"
                          disabled={busy}
                          onClick={(e) => {
                            e.stopPropagation()
                            void handleArchive(row)
                          }}
                        >
                          {t('catalog.calculators.archive', 'Arxivar')}
                        </Button>
                      ) : (
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          className="h-7 shrink-0 text-destructive hover:text-destructive"
                          disabled={busy}
                          onClick={(e) => {
                            e.stopPropagation()
                            setPendingDelete(row)
                          }}
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </Button>
                      )}
                      <ChevronRight className="h-4 w-4 shrink-0 text-muted-foreground" />
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </TabsContent>
      </Tabs>

      <Dialog
        open={pendingDelete != null}
        onOpenChange={(open) => {
          if (!open && !busy) setPendingDelete(null)
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t('catalog.calculators.delete_title', 'Eliminar calculadora')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'catalog.calculators.delete_confirm',
                'Eliminar «{{name}}»? Aquesta acció no es pot desfer.',
                { name: pendingDelete?.name ?? '' },
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-0">
            <Button
              type="button"
              variant="outline"
              disabled={busy}
              onClick={() => setPendingDelete(null)}
            >
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={busy}
              onClick={() => void confirmDelete()}
            >
              {t('catalog.calculators.delete', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
