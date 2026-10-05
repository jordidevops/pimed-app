import { useEffect, useMemo, useState } from 'react'
import { Link, useLocation, useNavigate, useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  CalendarDays,
  ChevronLeft,
  ChevronRight,
  ClipboardPlus,
  PanelRightOpen,
  Search,
  X,
} from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'
import { PageShell } from '@/components/layout/PageShell'
import { UnderlineTabs } from '@/components/layout/UnderlineTabs'
import { CalendarGrid, type CalendarGridEvent } from '@/features/calendar'
import {
  addDays,
  dateKey,
  startOfDay,
  startOfWeekMonday,
  toUiLocale,
} from '@/features/calendar/calendarDateUtils'
import { ProjectForm } from '@/features/projects/components/ProjectForm'
import { getProjectStatusLabel, getProjectStatusVariant } from '@/features/projects/projectStatus'
import { useTenant } from '@/contexts/TenantContext'
import { useAuth } from '@/contexts/AuthContext'
import { useMembers } from '@/hooks/useMembers'
import { useIsLargeScreen } from '@/hooks/useIsLargeScreen'
import { withReturnTo } from '@/lib/navigationReturn'
import { cn } from '@/lib/utils'
import { useFieldVisits } from '../hooks/useFieldVisits'
import type { FieldVisit } from '../api/fieldVisitsService'
import { rangeForView, startOfMonthAnchor } from '../utils/agendaRange'
import {
  defaultAgendaViewForWidth,
  formatAnchorDate,
  hasActiveAgendaFilters,
  parseAgendaUrlState,
  parseAnchorDate,
  readStoredAgendaView,
  serializeAgendaUrlState,
  storeAgendaView,
  type AgendaScope,
  type AgendaUrlState,
  type AgendaView,
} from '../utils/agendaUrlState'

function memberInitials(name: string): string {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase() ?? '')
    .join('')
}

function visitSubtitle(visit: FieldVisit): string {
  const parts = [visit.client_display_name, visit.contact_site_city].filter(Boolean)
  return parts.join(' · ')
}

function visitToGridEvent(visit: FieldVisit): CalendarGridEvent {
  const memberNames = visit.members.slice(0, 2).map((m) => memberInitials(m.display_name))
  if (visit.members.length > 2) memberNames.push(`+${visit.members.length - 2}`)
  const badges = [
    ...memberNames,
    visit.service_mode === 'assessment' ? 'Avaluació' : null,
  ].filter(Boolean) as string[]

  return {
    id: visit.id,
    start: visit.planned_start ?? '',
    end: visit.planned_end,
    title: visit.name,
    subtitle: visitSubtitle(visit),
    tone: visit.type === 'maintenance' ? 'maintenance' : 'work_order',
    badges,
    dimmed: visit.status === 'completed' || visit.status === 'cancelled',
  }
}

function FiltersPanel({
  state,
  isManager,
  profiles,
  onChange,
  onClear,
}: {
  state: AgendaUrlState
  isManager: boolean
  profiles: { id: string; full_name: string | null; email: string | null }[]
  onChange: (patch: Partial<AgendaUrlState>) => void
  onClear: () => void
}) {
  const { t } = useTranslation('field-service')
  const selectableProfiles = profiles.filter((p) => Boolean(p.id))

  return (
    <div className="space-y-4">
      <div className="space-y-2">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('agenda.filters.type', 'Tipus')}
        </p>
        <div className="flex flex-wrap gap-2">
          {(
            [
              ['work_order', t('agenda.filters.work_order', 'Ordre de servei')],
              ['maintenance', t('agenda.filters.maintenance', 'Manteniment')],
            ] as const
          ).map(([value, label]) => {
            const active = state.types.includes(value)
            return (
              <Button
                key={value}
                type="button"
                size="sm"
                variant={active ? 'default' : 'outline'}
                onClick={() => {
                  const next = active
                    ? state.types.filter((x) => x !== value)
                    : [...state.types, value]
                  onChange({ types: next.length ? next : ['work_order', 'maintenance'] })
                }}
              >
                {label}
              </Button>
            )
          })}
        </div>
      </div>

      <div className="space-y-2">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('agenda.filters.status', 'Estat')}
        </p>
        <div className="flex flex-wrap gap-2">
          {(
            [
              ['draft', t('status.draft', 'Esborrany')],
              ['active', t('status.active', 'Activa')],
              ['in_progress', t('status.in_progress', 'En curs')],
              ['on_hold', t('status.on_hold', 'En espera')],
            ] as const
          ).map(([value, label]) => {
            const active = state.statuses.includes(value)
            return (
              <Button
                key={value}
                type="button"
                size="sm"
                variant={active ? 'default' : 'outline'}
                onClick={() => {
                  const next = active
                    ? state.statuses.filter((x) => x !== value)
                    : [...state.statuses, value]
                  onChange({ statuses: next })
                }}
              >
                {label}
              </Button>
            )
          })}
        </div>
      </div>

      {isManager && (
        <div className="space-y-2">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            {t('agenda.filters.technician', 'Tècnic')}
          </p>
          <select
            multiple
            className="h-40 w-full rounded-md border border-input bg-background px-2 py-1 text-sm"
            value={state.memberIds}
            onChange={(e) => {
              const selected = Array.from(e.target.selectedOptions).map((o) => o.value)
              onChange({ memberIds: selected })
            }}
          >
            {selectableProfiles.map((p) => (
              <option key={p.id} value={p.id}>
                {p.full_name || p.email || p.id}
              </option>
            ))}
          </select>
          <p className="text-[11px] text-muted-foreground">
            {t('agenda.filters.technician_help', 'Mantén Ctrl/Cmd per seleccionar-ne més d’un.')}
          </p>
        </div>
      )}

      {hasActiveAgendaFilters(state) && (
        <Button type="button" variant="ghost" size="sm" onClick={onClear}>
          <X className="mr-1 h-4 w-4" />
          {t('agenda.filters.clear', 'Netejar filtres')}
        </Button>
      )}
    </div>
  )
}

export function FieldAgendaPage() {
  const { t, i18n } = useTranslation(['field-service', 'projects'])
  const navigate = useNavigate()
  const location = useLocation()
  const [searchParams, setSearchParams] = useSearchParams()
  const { activeTenant, activeRole } = useTenant()
  const { user } = useAuth()
  const isManager = activeRole === 'owner' || activeRole === 'manager'
  const uiLocale = toUiLocale(i18n.resolvedLanguage)
  const { data: membersRaw = [] } = useMembers(activeTenant?.id ?? null, user?.id, 'active', {
    enabled: isManager,
  })
  const profiles = useMemo(() => {
    const byUser = new Map<string, { id: string; full_name: string | null; email: string | null }>()
    for (const m of membersRaw) {
      if (!m.user_id || byUser.has(m.user_id)) continue
      byUser.set(m.user_id, {
        id: m.user_id,
        full_name: m.full_name,
        email: m.email,
      })
    }
    return [...byUser.values()]
  }, [membersRaw])

  const defaultView = useMemo(() => {
    const stored = readStoredAgendaView()
    if (stored) return stored
    if (typeof window === 'undefined') return 'list' as AgendaView
    return defaultAgendaViewForWidth(window.innerWidth)
  }, [])
  const defaultScope: AgendaScope = isManager ? 'all' : 'mine'
  const defaults = useMemo(
    () => ({ defaultView, defaultScope }),
    [defaultView, defaultScope],
  )

  const state = useMemo(
    () => parseAgendaUrlState(searchParams, defaults),
    [searchParams, defaults],
  )

  const anchor = useMemo(
    () => parseAnchorDate(state.anchor, startOfDay(new Date())),
    [state.anchor],
  )

  function patchState(patch: Partial<AgendaUrlState>) {
    const next = { ...state, ...patch }
    if (!isManager) {
      next.scope = 'mine'
      next.memberIds = []
      next.tray = false
    }
    if (patch.view) storeAgendaView(patch.view)
    const params = serializeAgendaUrlState(next, defaults)
    setSearchParams(params, { replace: true })
  }

  useEffect(() => {
    if (!searchParams.get('view') && defaultView !== 'list') {
      // Persist default desktop week into URL once for shareable links
      if (defaultView === 'week' || defaultView === 'month') {
        const params = serializeAgendaUrlState({ ...state, view: defaultView }, defaults)
        setSearchParams(params, { replace: true })
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only on mount for default view
  }, [])

  // Members cannot use company-wide scope or the unscheduled tray.
  useEffect(() => {
    if (isManager) return
    if (state.scope === 'all' || state.tray || state.memberIds.length > 0) {
      patchState({ scope: 'mine', memberIds: [], tray: false })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- canonicalize when role/URL drifts
  }, [isManager, state.scope, state.tray, state.memberIds.length])

  const range = rangeForView(state.view, anchor)
  const { data: visits = [], isLoading, isFetching } = useFieldVisits({
    from: range.from,
    to: range.to,
    types: state.types,
    statuses: state.statuses.length ? state.statuses : null,
    memberIds: state.scope === 'all' && state.memberIds.length ? state.memberIds : null,
    mineOnly: state.scope === 'mine',
    openOnly: true,
    // Month grid spans ~6 weeks; avoid truncating mid-window.
    limit: state.view === 'month' ? 1000 : 500,
  })

  const { data: unscheduled = [] } = useFieldVisits({
    unscheduled: true,
    types: state.types,
    openOnly: true,
    enabled: isManager,
  })

  const [createOpen, setCreateOpen] = useState(false)
  const [createDay, setCreateDay] = useState<string | null>(null)
  const [panelOpen, setPanelOpen] = useState(false)
  const isLarge = useIsLargeScreen()
  const returnTo = `${location.pathname}${location.search}`

  const clearFilters = () =>
    patchState({ types: ['work_order', 'maintenance'], statuses: [], memberIds: [] })

  const openCreate = (day?: Date | string | null) => {
    const value =
      typeof day === 'string'
        ? day
        : formatAnchorDate(day ? startOfDay(day) : startOfDay(new Date()))
    setCreateDay(value)
    setCreateOpen(true)
  }

  const trayVisible = isManager && (isLarge || panelOpen)

  function setAgendaView(next: AgendaView) {
    if (next === 'month') {
      // Keep the visible month stable (day 1) so grid/range stay aligned.
      patchState({
        view: next,
        anchor: formatAnchorDate(startOfMonthAnchor(anchor)),
      })
      return
    }
    if (next === 'week') {
      patchState({
        view: next,
        anchor: formatAnchorDate(startOfWeekMonday(anchor)),
      })
      return
    }
    patchState({ view: next })
  }

  const groupedList = useMemo(() => {
    const map = new Map<string, FieldVisit[]>()
    for (const visit of visits) {
      const key = visit.planned_start ? dateKey(visit.planned_start) : '—'
      const list = map.get(key) ?? []
      list.push(visit)
      map.set(key, list)
    }
    return [...map.entries()].sort(([a], [b]) => a.localeCompare(b))
  }, [visits])

  const gridEvents = useMemo(() => visits.filter((v) => v.planned_start).map(visitToGridEvent), [visits])

  function openVisit(id: string, focusPlanned = false) {
    const base = focusPlanned
      ? `/field/orders/${id}?tab=prepare&focus=planned_start`
      : `/field/orders/${id}`
    navigate(withReturnTo(base, returnTo))
  }

  function formatDayLabel(key: string): string {
    if (key === '—') return key
    const [y, m, d] = key.split('-').map(Number)
    return new Date(y, m - 1, d).toLocaleDateString(uiLocale, {
      weekday: 'short',
      day: 'numeric',
      month: 'short',
    })
  }

  function formatTime(iso: string | null | undefined): string {
    if (!iso) return ''
    const d = new Date(iso)
    if (d.getHours() === 0 && d.getMinutes() === 0) return ''
    return d.toLocaleTimeString(uiLocale, { hour: '2-digit', minute: '2-digit' })
  }

  const viewTabs = (
    <UnderlineTabs
      activeKey={state.view}
      aria-label={t('field-service:agenda.view.label', 'Vista')}
      items={(
        [
          ['list', t('field-service:agenda.view.list', 'Llista')],
          ['day', t('field-service:agenda.view.day', 'Dia')],
          ['week', t('field-service:agenda.view.week', 'Setmana')],
          ['month', t('field-service:agenda.view.month', 'Mes')],
        ] as const
      ).map(([value, label]) => ({
        key: value,
        label,
        onSelect: () => setAgendaView(value),
      }))}
    />
  )

  const shellActions = (
    <Button
      type="button"
      variant="outline"
      size="sm"
      className="lg:hidden"
      onClick={() => setPanelOpen(true)}
    >
      <PanelRightOpen className="mr-1 h-4 w-4" />
      {t('field-service:agenda.filters.open', 'Filtres')}
      {(hasActiveAgendaFilters(state) || (isManager && unscheduled.length > 0)) && (
        <Badge className="ml-2" variant="secondary">
          !
        </Badge>
      )}
    </Button>
  )

  function renderToolsPanel(unscheduledId: string) {
    return (
      <div className="space-y-5">
        <Button type="button" className="w-full" onClick={() => openCreate()}>
          <ClipboardPlus className="mr-1.5 h-4 w-4" />
          {t('field-service:orders.new', 'Nova ordre')}
        </Button>

        {isManager && (
          <div className="space-y-2">
            <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              {t('field-service:agenda.scope.label', 'Àmbit')}
            </p>
            <div className="inline-flex w-full rounded-lg border border-border p-0.5">
              <button
                type="button"
                className={cn(
                  'flex-1 rounded-md px-2.5 py-1.5 text-xs font-medium',
                  state.scope === 'mine' ? 'bg-accent text-foreground' : 'text-muted-foreground',
                )}
                onClick={() => patchState({ scope: 'mine', memberIds: [] })}
              >
                {t('field-service:agenda.scope.mine', 'Les meves')}
              </button>
              <button
                type="button"
                className={cn(
                  'flex-1 rounded-md px-2.5 py-1.5 text-xs font-medium',
                  state.scope === 'all' ? 'bg-accent text-foreground' : 'text-muted-foreground',
                )}
                onClick={() => patchState({ scope: 'all' })}
              >
                {t('field-service:agenda.scope.all', 'Totes')}
              </button>
            </div>
          </div>
        )}

        <FiltersPanel
          state={state}
          isManager={isManager}
          profiles={profiles}
          onChange={patchState}
          onClear={clearFilters}
        />

        {isManager && (
          <section id={unscheduledId} className="space-y-3 border-t border-border pt-4">
            <div className="flex items-center justify-between gap-2">
              <h3 className="text-sm font-semibold">
                {t('field-service:agenda.unscheduled.title', 'Sense planificar')}
              </h3>
              <Badge variant="secondary">{unscheduled.length}</Badge>
            </div>
            {unscheduled.length === 0 ? (
              <p className="text-xs text-muted-foreground">
                {t('field-service:agenda.unscheduled.empty', 'No hi ha ordres sense data')}
              </p>
            ) : (
              <ul className="space-y-2">
                {unscheduled.slice(0, 30).map((visit) => (
                  <li key={visit.id} className="rounded-xl border border-border p-3">
                    <p className="truncate text-sm font-medium">{visit.name}</p>
                    <p className="truncate text-xs text-muted-foreground">{visitSubtitle(visit)}</p>
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      className="mt-2"
                      onClick={() => openVisit(visit.id, true)}
                    >
                      {t('field-service:agenda.unscheduled.plan', 'Planificar')}
                    </Button>
                  </li>
                ))}
              </ul>
            )}
          </section>
        )}
      </div>
    )
  }

  const emptyNotice = (
    <AgendaEmptyNotice
      filtered={hasActiveAgendaFilters(state)}
      trayVisible={trayVisible}
      onClear={clearFilters}
    />
  )

  const dayNav = (
    <div className="flex flex-wrap items-center gap-2">
      <Button
        type="button"
        variant="outline"
        size="sm"
        onClick={() => patchState({ anchor: formatAnchorDate(startOfDay(new Date())) })}
      >
        {t('field-service:agenda.today', 'Avui')}
      </Button>
      <div className="flex items-center gap-1">
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8"
          onClick={() => patchState({ anchor: formatAnchorDate(addDays(anchor, -1)) })}
          aria-label={t('field-service:agenda.prev_day', 'Dia anterior')}
        >
          <ChevronLeft className="h-4 w-4" />
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8"
          onClick={() => patchState({ anchor: formatAnchorDate(addDays(anchor, 1)) })}
          aria-label={t('field-service:agenda.next_day', 'Dia següent')}
        >
          <ChevronRight className="h-4 w-4" />
        </Button>
      </div>
      <p className="text-sm font-semibold capitalize">
        {formatDayLabel(formatAnchorDate(anchor))}
      </p>
      <div className="flex min-h-5 min-w-0 flex-1 items-center sm:justify-end">
        {visits.length === 0 ? emptyNotice : null}
      </div>
    </div>
  )

  const showInitialSpinner = isLoading && visits.length === 0

  const agendaBody = showInitialSpinner ? (
    <div className="flex h-64 items-center justify-center">
      <div className="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent" />
    </div>
  ) : state.view === 'list' ? (
    <div className="space-y-3">
      {dayNav}
      {groupedList.length === 0 ? (
        <EmptyAgenda filtered={hasActiveAgendaFilters(state)} onClear={clearFilters} />
      ) : (
        <div className="space-y-5">
          {groupedList.map(([day, dayVisits]) => (
            <section key={day} className="space-y-2">
              <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                {formatDayLabel(day)}
              </h2>
              <VisitDayList visits={dayVisits} formatTime={formatTime} onOpen={openVisit} />
            </section>
          ))}
        </div>
      )}
    </div>
  ) : state.view === 'day' ? (
    <div className="space-y-3">
      {dayNav}
      {visits.length === 0 ? null : (
        <VisitDayList visits={visits} formatTime={formatTime} onOpen={openVisit} />
      )}
    </div>
  ) : (
    <div className={cn('space-y-3', isFetching && 'opacity-90')}>
      <CalendarGrid
        view={state.view === 'month' ? 'month' : 'week'}
        anchor={anchor}
        onAnchorChange={(next) => patchState({ anchor: formatAnchorDate(next) })}
        events={gridEvents}
        onEventClick={(event) => openVisit(event.id)}
        onSelectDay={(day) => {
          patchState({ view: 'day', anchor: formatAnchorDate(day) })
        }}
        onDayAction={
          isManager
            ? (day) => {
                openCreate(day)
              }
            : undefined
        }
        monthCellMode="cards"
        monthMaxCards={2}
        allDayLabel={t('field-service:agenda.all_day', 'Tot el dia')}
        notice={visits.length === 0 ? emptyNotice : null}
      />
    </div>
  )

  return (
    <>
      <PageShell
        flush
        className="pb-24 lg:pb-6"
        title={t('field-service:agenda.title', 'Agenda')}
        subtitle={t('field-service:agenda.subtitle', 'Visites planificades')}
        icon={<CalendarDays className="h-5 w-5" aria-hidden />}
        actions={shellActions}
        tabs={viewTabs}
      >
        <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem] xl:grid-cols-[minmax(0,1fr)_22.5rem]">
          <div className="min-w-0">{agendaBody}</div>
          <aside
            className={cn(
              'hidden lg:block',
              'sticky top-[calc(var(--app-sticky-chrome,0px)+1rem)] self-start',
              'max-h-[calc(100dvh-var(--app-sticky-chrome,0px)-2rem)] overflow-y-auto',
              'rounded-2xl border border-border bg-card p-4',
            )}
          >
            <h2 className="mb-4 text-sm font-semibold">
              {t('field-service:agenda.panel.title', 'Eines')}
            </h2>
            {renderToolsPanel('agenda-unscheduled-desktop')}
          </aside>
        </div>
      </PageShell>

      <Sheet open={!isLarge && panelOpen} onOpenChange={setPanelOpen}>
        <SheetContent side="right" className="flex w-full flex-col gap-0 p-0 sm:max-w-md">
          <SheetHeader className="border-b border-border px-4 py-3 text-left">
            <SheetTitle>{t('field-service:agenda.panel.title', 'Eines')}</SheetTitle>
          </SheetHeader>
          <div className="min-h-0 flex-1 overflow-y-auto p-4">
            {renderToolsPanel('agenda-unscheduled-mobile')}
          </div>
        </SheetContent>
      </Sheet>

      <ProjectForm
        open={createOpen}
        onClose={() => {
          setCreateOpen(false)
          setCreateDay(null)
        }}
        initialType="work_order"
        initialPlannedStart={createDay}
      />
    </>
  )
}

function VisitDayList({
  visits,
  formatTime,
  onOpen,
}: {
  visits: FieldVisit[]
  formatTime: (iso: string | null | undefined) => string
  onOpen: (id: string) => void
}) {
  const { t } = useTranslation(['field-service', 'projects'])
  return (
    <ul className="space-y-2">
      {visits.map((visit) => (
        <li key={visit.id}>
          <button
            type="button"
            onClick={() => onOpen(visit.id)}
            className="flex w-full items-center justify-between rounded-xl border border-border bg-card px-4 py-3 min-h-12 text-left hover:bg-accent/30"
          >
            <div className="min-w-0 space-y-0.5">
              <p className="truncate font-medium">{visit.name}</p>
              <p className="text-xs text-muted-foreground">
                {[formatTime(visit.planned_start), visitSubtitle(visit)].filter(Boolean).join(' · ')}
              </p>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <Badge variant={getProjectStatusVariant(visit.status)}>
                {getProjectStatusLabel(t, visit.status, { fieldService: true })}
              </Badge>
              <ChevronRight className="h-4 w-4 text-muted-foreground" />
            </div>
          </button>
        </li>
      ))}
    </ul>
  )
}

/** Inline notice beside day/week/month chrome — fixed slot, no layout jump. */
function AgendaEmptyNotice({
  filtered,
  trayVisible,
  onClear,
}: {
  filtered: boolean
  trayVisible: boolean
  onClear: () => void
}) {
  const { t } = useTranslation('field-service')
  if (filtered) {
    return (
      <span className="inline-flex flex-wrap items-center gap-x-2 gap-y-1">
        <span>{t('agenda.empty.filtered', 'Cap visita amb aquests filtres')}</span>
        <button
          type="button"
          className="text-primary underline-offset-2 hover:underline"
          onClick={onClear}
        >
          {t('agenda.filters.clear', 'Netejar filtres')}
        </button>
      </span>
    )
  }
  return (
    <span>
      {t('agenda.empty.none', 'Cap visita planificada')}
      {trayVisible
        ? ` · ${t('agenda.empty.tray_hint', 'Pots planificar des de la safata')}`
        : null}
    </span>
  )
}

/** Full empty state for list view only. */
function EmptyAgenda({
  filtered,
  onClear,
}: {
  filtered: boolean
  onClear: () => void
}) {
  const { t } = useTranslation('field-service')
  return (
    <div className="rounded-2xl border border-dashed border-border py-12 text-center">
      <CalendarDays className="mx-auto mb-2 h-8 w-8 text-muted-foreground/50" />
      <p className="text-sm text-muted-foreground">
        {filtered
          ? t('agenda.empty.filtered', 'Cap visita amb aquests filtres')
          : t('agenda.empty.none', 'Cap visita planificada')}
      </p>
      <div className="mt-3 flex flex-wrap items-center justify-center gap-3">
        {filtered ? (
          <Button type="button" variant="outline" size="sm" onClick={onClear}>
            <Search className="mr-1 h-4 w-4" />
            {t('agenda.filters.clear', 'Netejar filtres')}
          </Button>
        ) : (
          <Link to="/field/orders" className="text-sm text-primary">
            {t('agenda.empty.orders', 'Veure ordres')}
          </Link>
        )}
      </div>
    </div>
  )
}
