import { useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Calculator, Plus, Search } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
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
  pickBestClone,
  setCalculatorStatus,
  type CalculatorCatalogRow,
  type CalculatorDefinitionRow,
} from '@/features/commercial/api/calculatorService'
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

  const clonedCatalogIds = useMemo(() => {
    const set = new Set<string>()
    for (const row of rows) {
      if (row.cloned_from_catalog_id) set.add(row.cloned_from_catalog_id)
    }
    return set
  }, [rows])

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

  async function handleClone(entry: CalculatorCatalogRow, forceNew = false) {
    if (!canEdit || busy) return
    if (!forceNew && clonedCatalogIds.has(entry.id)) {
      const existing = pickBestClone(rows, entry.id)
      if (existing) {
        navigate(`/catalog/calculators/${existing.id}`)
        return
      }
    }
    setBusy(true)
    let clonedId: string | null = null
    try {
      const title = resolveLocale(entry.title ?? undefined, 'ca') || entry.slug
      clonedId = await cloneCalculatorFromCatalog({
        catalogId: entry.id,
        name: title,
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
          await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
          navigate(`/catalog/calculators/${clonedId}?retryActivate=1`)
          return
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
      navigate(`/catalog/calculators/${clonedId}`)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('common:error', 'Error'),
      })
      if (clonedId) {
        await queryClient.invalidateQueries({ queryKey: ['calculator_definitions'] })
        navigate(`/catalog/calculators/${clonedId}`)
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
      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          size="sm"
          variant={tab === 'mine' ? 'secondary' : 'outline'}
          onClick={() => setTab('mine')}
        >
          {t('catalog.calculators.tab_mine', 'Les meves')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant={tab === 'library' ? 'secondary' : 'outline'}
          onClick={() => setTab('library')}
        >
          {t('catalog.calculators.tab_library', 'Biblioteca')}
        </Button>
      </div>

      {tab === 'library' ? (
        <section className="space-y-3 rounded-xl border border-border p-4">
          <div>
            <h2 className="text-base font-semibold">
              {t('catalog.calculators.library', 'Biblioteca de plataforma')}
            </h2>
            <p className="text-sm text-muted-foreground">
              {t(
                'catalog.calculators.library_help',
                'Calculadores llestes amb preus d’exemple. Clona-les, usa-les o adapta les tarifes.',
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
            <ul className="divide-y divide-border rounded-lg border border-border">
              {catalog.map((entry) => {
                const title = resolveLocale(entry.title ?? undefined, 'ca') || entry.slug
                const summary = resolveLocale(entry.summary ?? undefined, 'ca')
                const already = clonedCatalogIds.has(entry.id)
                return (
                  <li
                    key={entry.id}
                    className="flex flex-wrap items-center justify-between gap-2 px-3 py-3"
                  >
                    <div className="min-w-0">
                      <p className="font-medium">{title}</p>
                      {summary ? (
                        <p className="mt-0.5 text-sm text-muted-foreground">{summary}</p>
                      ) : null}
                      <div className="mt-1 flex flex-wrap gap-1">
                        {entry.crossArchetype ? (
                          <Badge variant="outline">
                            {t('catalog.calculators.cross_archetype', 'Altre arquetip')}
                          </Badge>
                        ) : null}
                        {already ? (
                          <Badge variant="outline">
                            {t('catalog.calculators.already_cloned', 'Ja la tens')}
                          </Badge>
                        ) : null}
                        {(entry.tags ?? []).map((tag) => (
                          <Badge key={tag} variant="secondary">
                            {tag}
                          </Badge>
                        ))}
                      </div>
                    </div>
                    <div className="flex flex-wrap gap-2">
                      {already ? (
                        <Button
                          type="button"
                          size="sm"
                          variant="outline"
                          disabled={busy}
                          onClick={() => void handleClone(entry, false)}
                        >
                          {t('catalog.calculators.open_clone', 'Obrir')}
                        </Button>
                      ) : null}
                      <Button
                        type="button"
                        size="sm"
                        variant={already ? 'outline' : 'default'}
                        disabled={busy}
                        onClick={() => void handleClone(entry, already)}
                      >
                        {already
                          ? t('catalog.calculators.clone_again', 'Nova còpia')
                          : t('catalog.calculators.clone', 'Clonar')}
                      </Button>
                    </div>
                  </li>
                )
              })}
            </ul>
          )}
        </section>
      ) : null}

      {tab === 'mine' ? (
        <>
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
                  {t('catalog.calculators.go_library', 'Veure biblioteca')}
                </Button>
                <Button type="button" disabled={busy} onClick={() => void handleCreate()}>
                  {t('catalog.calculators.create', 'Nova calculadora')}
                </Button>
              </div>
            </div>
          ) : (
            <ul className="divide-y divide-border rounded-xl border border-border">
              {filtered.map((row) => (
                <li
                  key={row.id}
                  className="flex flex-wrap items-start justify-between gap-3 px-4 py-3 hover:bg-muted/40"
                >
                  <Link to={`/catalog/calculators/${row.id}`} className="min-w-0 flex-1">
                    <p className="font-medium text-foreground">{row.name}</p>
                    {row.description ? (
                      <p className="mt-0.5 line-clamp-2 text-sm text-muted-foreground">
                        {row.description}
                      </p>
                    ) : null}
                    <div className="mt-2 flex flex-wrap gap-1.5">
                      <Badge variant="outline">{STATUS_LABEL[row.status].ca}</Badge>
                      {(row.tags ?? []).map((tag) => (
                        <Badge key={tag} variant="secondary">
                          {tag}
                        </Badge>
                      ))}
                    </div>
                  </Link>
                  <div className="flex flex-shrink-0 flex-wrap gap-2">
                    {row.status === 'active' ? (
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={busy}
                        onClick={() => void handleArchive(row)}
                      >
                        {t('catalog.calculators.archive', 'Arxivar')}
                      </Button>
                    ) : (
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={busy}
                        onClick={() => setPendingDelete(row)}
                      >
                        {t('catalog.calculators.delete', 'Eliminar')}
                      </Button>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          )}
        </>
      ) : null}

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
