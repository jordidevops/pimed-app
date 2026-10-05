import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import {
  CalendarRange,
  ChevronLeft,
  ChevronRight,
  PanelRightOpen,
  Plus,
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
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useMyEmployee } from '@/features/attendance/api/useMyEmployee'
import { usePermission } from '@/hooks/usePermission'
import { useIsLargeScreen } from '@/hooks/useIsLargeScreen'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { useDebounce } from '@/hooks/useDebounce'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'
import {
  eventSearchAnchorDate,
  isSearchQueryActive,
  matchCalendarEvents,
} from './matchCalendarEvents'
import { collectTaskEntityIds, filterMyCalendarEvents } from './mineCalendarEvents'
import { useTaskAssignees } from './useTaskAssignees'
import { CalendarGrid, type CalendarGridEvent } from './CalendarGrid'
import { CalendarTimeGrid } from './CalendarTimeGrid'
import { CalendarRegistry } from './CalendarRegistry'
import { CreateEventForm } from './CreateEventForm'
import { EventDetailSheet } from './EventDetailSheet'
import { useCalendarEvents } from './useCalendarEvents'
import { projectEventsOntoDays, toProjectableResolvedEvents } from './projectEventsOntoDays'
import {
  addDays,
  dateKey,
  endOfDay,
  endOfWeek,
  getMonthGridDays,
  startOfDay,
  startOfWeek,
  toUiLocale,
} from './calendarDateUtils'
import type { CalendarResolvedEvent } from './calendar.types'
import {
  formatCalendarDate,
  nextListSpan,
  parseCalendarDate,
  parseCompanyCalendarUrlState,
  readStoredCompanyCalendarView,
  resolveDefaultCompanyCalendarView,
  serializeCompanyCalendarUrlState,
  storeCompanyCalendarView,
  type CompanyCalendarUrlState,
  type CompanyCalendarView,
} from './companyCalendarUrlState'

function rangeForCompanyView(
  view: CompanyCalendarView,
  anchor: Date,
  span: number,
  weekStartsOn: number,
): { rangeStart: Date; rangeEnd: Date } {
  const day = startOfDay(anchor)
  if (view === 'list') {
    // Inclusive last day — use endOfDay so timed events that day are not cut off at midnight.
    return { rangeStart: day, rangeEnd: endOfDay(addDays(day, span - 1)) }
  }
  if (view === 'day') {
    return { rangeStart: day, rangeEnd: endOfDay(day) }
  }
  if (view === 'week') {
    const weekStart = startOfWeek(day, weekStartsOn)
    return { rangeStart: weekStart, rangeEnd: endOfWeek(day, weekStartsOn) }
  }
  const monthDays = getMonthGridDays(day, weekStartsOn)
  const last = monthDays[monthDays.length - 1] ?? endOfWeek(day, weekStartsOn)
  return {
    rangeStart: monthDays[0] ?? startOfWeek(day, weekStartsOn),
    rangeEnd: endOfDay(last),
  }
}

function startOfMonthAnchor(anchor: Date): Date {
  return startOfDay(new Date(anchor.getFullYear(), anchor.getMonth(), 1))
}

/** Wider window for search results (±180 days from today). */
const SEARCH_HALF_WINDOW_DAYS = 180

function eventToGridEvent(event: CalendarResolvedEvent): CalendarGridEvent | null {
  if (!event.id || !event.start_at) return null
  return {
    id: event.id,
    start: event.start_at,
    end: event.end_at,
    title: event.title ?? '',
    subtitle: event.resolvedLabel,
    color: event.resolvedColor,
    allDay: event.all_day,
    dimmed: event.addonUnavailable,
  }
}

function EventListRow({
  event,
  formatTime,
  onOpen,
}: {
  event: CalendarResolvedEvent
  formatTime: (iso: string | null | undefined, allDay: boolean | null | undefined) => string
  onOpen: (event: CalendarResolvedEvent, canEdit: boolean) => void
}) {
  const { t } = useTranslation('calendar')
  const eventSiteCtx = event.site_id ?? undefined
  const canEdit = usePermission(event.editPermission, eventSiteCtx)
  const title = event.title ?? t('calendar.untitled', '(Sense títol)')
  const time = formatTime(event.start_at, event.all_day)

  return (
    <li>
      <button
        type="button"
        onClick={() => onOpen(event, canEdit)}
        className={cn(
          'flex w-full items-center gap-3 rounded-xl border border-border bg-card px-4 py-3 min-h-12 text-left hover:bg-accent/30',
          event.addonUnavailable && 'opacity-60',
        )}
      >
        <span
          className="h-2.5 w-2.5 shrink-0 rounded-full"
          style={{ backgroundColor: event.resolvedColor || '#6366f1' }}
          aria-hidden
        />
        <div className="min-w-0 flex-1 space-y-0.5">
          <p className="truncate font-medium">{title}</p>
          <p className="truncate text-xs text-muted-foreground">
            {[time, t(`calendar.entity.${event.entity_type}`, event.resolvedLabel)]
              .filter(Boolean)
              .join(' · ')}
          </p>
        </div>
        <ChevronRight className="h-4 w-4 shrink-0 text-muted-foreground" />
      </button>
    </li>
  )
}

export function CompanyCalendarPage() {
  const { t, i18n } = useTranslation('calendar')
  const { user } = useAuth()
  const canView = usePermission('calendar.view')
  const canCreate = usePermission('calendar.edit')
  const { selectedSiteId, sites, activeTenant } = useTenant()
  const { data: myEmployee } = useMyEmployee()
  const { weekStartsOn } = useCalendarDisplaySettings()
  const { data: effective = {} } = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? null, siteId: selectedSiteId },
    { enabled: !!activeTenant?.id },
  )
  const [searchParams, setSearchParams] = useSearchParams()
  const isLarge = useIsLargeScreen()
  const queryClient = useQueryClient()
  const uiLocale = toUiLocale(i18n.resolvedLanguage)

  const defaultSite = selectedSiteId ?? 'all'
  const defaultView = useMemo(() => {
    const stored = readStoredCompanyCalendarView()
    const width = typeof window === 'undefined' ? 1024 : window.innerWidth
    return resolveDefaultCompanyCalendarView({
      width,
      settingsView: String(effective.default_calendar_view ?? ''),
      stored,
    })
  }, [effective.default_calendar_view])

  const defaults = useMemo(
    () => ({ defaultView, defaultSite }),
    [defaultView, defaultSite],
  )

  const state = useMemo(
    () => parseCompanyCalendarUrlState(searchParams, defaults),
    [searchParams, defaults],
  )

  const anchor = useMemo(
    () => parseCalendarDate(state.date, startOfDay(new Date())),
    [state.date],
  )

  function patchState(patch: Partial<CompanyCalendarUrlState>) {
    const next = { ...state, ...patch }
    if (patch.view) storeCompanyCalendarView(patch.view)
    setSearchParams(serializeCompanyCalendarUrlState(next, defaults), { replace: true })
  }

  useEffect(() => {
    if (!searchParams.get('view') && defaultView !== 'list') {
      if (defaultView === 'week' || defaultView === 'month' || defaultView === 'day') {
        setSearchParams(
          serializeCompanyCalendarUrlState({ ...state, view: defaultView }, defaults),
          { replace: true },
        )
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- seed default view once
  }, [])

  const { rangeStart, rangeEnd } = useMemo(
    () => rangeForCompanyView(state.view, anchor, state.span, weekStartsOn),
    [state.view, state.span, anchor, weekStartsOn],
  )

  const querySiteId = state.site === 'all' ? null : state.site

  const { data: events = [], isLoading, isFetching } = useCalendarEvents({
    rangeStart,
    rangeEnd,
    siteId: querySiteId,
  })

  const searchActive = isSearchQueryActive(state.q)
  const searchRange = useMemo(() => {
    const today = startOfDay(new Date())
    return {
      rangeStart: addDays(today, -SEARCH_HALF_WINDOW_DAYS),
      rangeEnd: endOfDay(addDays(today, SEARCH_HALF_WINDOW_DAYS)),
    }
  }, [])

  const { data: searchPool = [], isFetching: searchFetching } = useCalendarEvents({
    rangeStart: searchRange.rangeStart,
    rangeEnd: searchRange.rangeEnd,
    siteId: querySiteId,
    enabled: searchActive,
  })

  const availableTypes = useMemo(() => {
    const fromRegistry = CalendarRegistry.getEntityTypes()
    const fromData = events.map((e) => e.entity_type).filter(Boolean) as string[]
    return [...new Set([...fromRegistry, ...fromData])].sort()
  }, [events])

  const typedViewEvents = useMemo(() => {
    if (state.types.length === 0) return events
    const set = new Set(state.types)
    return events.filter((e) => e.entity_type && set.has(e.entity_type))
  }, [events, state.types])

  const typedSearchPool = useMemo(() => {
    if (state.types.length === 0) return searchPool
    return searchPool.filter((e) => e.entity_type && state.types.includes(e.entity_type))
  }, [searchPool, state.types])

  const taskIdsForMine = useMemo(() => {
    if (!state.mine) return []
    return collectTaskEntityIds([
      ...typedViewEvents,
      ...(searchActive ? typedSearchPool : []),
    ])
  }, [state.mine, typedViewEvents, searchActive, typedSearchPool])

  const { data: taskAssigneeById } = useTaskAssignees(taskIdsForMine, state.mine)

  const mineCtx = useMemo(
    () => ({
      userId: user?.id,
      myEmployeeId: myEmployee?.id ?? null,
      taskAssigneeById: taskAssigneeById ?? new Map<string, string | null>(),
    }),
    [user?.id, myEmployee?.id, taskAssigneeById],
  )

  const filteredEvents = useMemo(() => {
    if (!state.mine) return typedViewEvents
    return filterMyCalendarEvents(typedViewEvents, mineCtx)
  }, [typedViewEvents, state.mine, mineCtx])

  const searchResults = useMemo(() => {
    if (!searchActive) return []
    const scoped = state.mine
      ? filterMyCalendarEvents(typedSearchPool, mineCtx)
      : typedSearchPool
    return matchCalendarEvents(scoped, state.q).slice(0, 40)
  }, [searchActive, typedSearchPool, state.mine, state.q, mineCtx])

  const eventsByDay = useMemo(() => {
    return projectEventsOntoDays(
      toProjectableResolvedEvents(filteredEvents),
      rangeStart,
      rangeEnd,
    )
  }, [filteredEvents, rangeStart, rangeEnd])

  const listDays = useMemo(() => {
    return [...eventsByDay.entries()]
      .filter(([, list]) => list.length > 0)
      .sort(([a], [b]) => a.localeCompare(b))
  }, [eventsByDay])

  const gridEvents = useMemo(
    () =>
      filteredEvents
        .map(eventToGridEvent)
        .filter((e): e is CalendarGridEvent => e != null),
    [filteredEvents],
  )

  const [panelOpen, setPanelOpen] = useState(false)
  const [activeEvent, setActiveEvent] = useState<CalendarResolvedEvent | null>(null)
  const [activeCanEdit, setActiveCanEdit] = useState(false)
  const [createOpen, setCreateOpen] = useState(false)
  const [createDate, setCreateDate] = useState<Date>(() => startOfDay(new Date()))
  const [createAllDay, setCreateAllDay] = useState(false)
  const [editEvent, setEditEvent] = useState<CalendarResolvedEvent | null>(null)
  const [searchDraft, setSearchDraft] = useState(state.q)
  const debouncedSearch = useDebounce(searchDraft, 300)

  useEffect(() => {
    setSearchDraft(state.q)
  }, [state.q])

  useEffect(() => {
    const next = debouncedSearch.trim()
    if (next === state.q) return
    patchState({ q: next })
    // eslint-disable-next-line react-hooks/exhaustive-deps -- sync draft → URL
  }, [debouncedSearch])

  useEffect(() => {
    if (!state.create) return
    setCreateDate(anchor)
    setCreateAllDay(false)
    setCreateOpen(true)
    patchState({ create: false })
    // eslint-disable-next-line react-hooks/exhaustive-deps -- open once when create=1
  }, [state.create])

  const deleteMutation = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc('delete_manual_calendar_event' as never, {
        p_id: id,
      } as never)
      if (error) throw error
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['calendar_events'] })
      setActiveEvent(null)
    },
  })

  const filtersActive =
    state.types.length > 0 ||
    state.site !== defaultSite ||
    searchActive ||
    state.mine

  function selectSearchResult(event: CalendarResolvedEvent) {
    const date = eventSearchAnchorDate(event)
    patchState({
      date: date ?? state.date,
      view: 'day',
    })
    openDetail(event, false)
  }

  function setCalendarView(next: CompanyCalendarView) {
    if (next === 'month') {
      patchState({ view: next, date: formatCalendarDate(startOfMonthAnchor(anchor)) })
      return
    }
    if (next === 'week') {
      patchState({
        view: next,
        date: formatCalendarDate(startOfWeek(anchor, weekStartsOn)),
      })
      return
    }
    patchState({ view: next })
  }

  function openCreate(at?: Date, opts?: { allDay?: boolean }) {
    setEditEvent(null)
    setCreateDate(at ?? anchor)
    setCreateAllDay(Boolean(opts?.allDay))
    setCreateOpen(true)
  }

  function openEdit(event: CalendarResolvedEvent) {
    setEditEvent(event)
    setActiveEvent(null)
    setCreateOpen(true)
  }

  function openDetail(event: CalendarResolvedEvent, canEdit: boolean) {
    setActiveEvent(event)
    setActiveCanEdit(canEdit)
  }

  function formatDayLabel(key: string): string {
    const [y, m, d] = key.split('-').map(Number)
    return new Date(y, m - 1, d).toLocaleDateString(uiLocale, {
      weekday: 'short',
      day: 'numeric',
      month: 'short',
    })
  }

  function formatTime(
    iso: string | null | undefined,
    allDay: boolean | null | undefined,
  ): string {
    if (!iso) return ''
    if (allDay) return t('calendar.all_day', 'Tot el dia')
    const d = new Date(iso)
    return d.toLocaleTimeString(uiLocale, { hour: '2-digit', minute: '2-digit' })
  }

  function clearFilters() {
    setSearchDraft('')
    patchState({ types: [], site: defaultSite, q: '', mine: false })
  }

  if (!canView) {
    return (
      <div className="mx-auto max-w-lg px-4 py-12 text-center">
        <p className="text-sm text-muted-foreground">
          {t(
            'calendar.page.forbidden',
            'No tens permís per veure el calendari d’empresa.',
          )}
        </p>
      </div>
    )
  }

  const viewTabs = (
    <UnderlineTabs
      activeKey={state.view}
      aria-label={t('calendar.page.viewLabel', 'Vista')}
      items={(
        [
          ['list', t('calendar.page.views.list', 'Llista')],
          ['day', t('calendar.page.views.day', 'Dia')],
          ['week', t('calendar.page.views.week', 'Setmana')],
          ['month', t('calendar.page.views.month', 'Mes')],
        ] as const
      ).map(([value, label]) => ({
        key: value,
        label,
        onSelect: () => setCalendarView(value),
      }))}
    />
  )

  const shellActions = (
    <div className="flex items-center gap-2">
      {canCreate ? (
        <Button type="button" size="sm" onClick={() => openCreate()}>
          <Plus className="mr-1 h-4 w-4" />
          {t('calendar.actions.create', 'Nou event')}
        </Button>
      ) : null}
      <Button
        type="button"
        variant="outline"
        size="sm"
        className="lg:hidden"
        onClick={() => setPanelOpen(true)}
      >
        <PanelRightOpen className="mr-1 h-4 w-4" />
        {t('calendar.page.filtersOpen', 'Filtres')}
        {filtersActive ? (
          <Badge className="ml-2" variant="secondary">
            !
          </Badge>
        ) : null}
      </Button>
    </div>
  )

  const searchField = (
    <div className="relative">
      <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
      <input
        type="search"
        value={searchDraft}
        onChange={(e) => setSearchDraft(e.target.value)}
        placeholder={t('calendar.page.searchPlaceholder', 'Cerca events…')}
        className="h-10 w-full rounded-md border border-input bg-background py-2 pl-9 pr-9 text-sm"
        data-testid="company-calendar-search"
        aria-label={t('calendar.page.searchPlaceholder', 'Cerca events…')}
      />
      {searchDraft ? (
        <button
          type="button"
          className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-1 text-muted-foreground hover:bg-muted"
          onClick={() => {
            setSearchDraft('')
            patchState({ q: '' })
          }}
          aria-label={t('calendar.page.searchClear', 'Netejar cerca')}
        >
          <X className="h-3.5 w-3.5" />
        </button>
      ) : null}
    </div>
  )

  const searchResultsPanel =
    searchActive ? (
      <div
        className="rounded-xl border border-border bg-card p-3"
        data-testid="company-calendar-search-results"
      >
        <div className="mb-2 flex items-center justify-between gap-2">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            {t('calendar.page.searchResults', 'Resultats')}
          </p>
          {searchFetching ? (
            <span className="text-[11px] text-muted-foreground">
              {t('calendar.loading', 'Carregant events…')}
            </span>
          ) : (
            <span className="text-[11px] text-muted-foreground">
              {t('calendar.page.searchCount', '{{count}} trobats', {
                count: searchResults.length,
              })}
            </span>
          )}
        </div>
        {searchResults.length === 0 && !searchFetching ? (
          <p className="py-4 text-center text-sm text-muted-foreground">
            {t('calendar.page.searchEmpty', 'Cap event coincideix amb la cerca')}
          </p>
        ) : (
          <ul className="max-h-64 space-y-1 overflow-y-auto">
            {searchResults.map((event) => {
              const title = event.title ?? t('calendar.untitled', '(Sense títol)')
              const day = eventSearchAnchorDate(event)
              return (
                <li key={event.id}>
                  <button
                    type="button"
                    onClick={() => selectSearchResult(event)}
                    className="flex w-full items-center gap-2 rounded-lg px-2 py-2 text-left text-sm hover:bg-accent/40"
                  >
                    <span
                      className="h-2 w-2 shrink-0 rounded-full"
                      style={{ backgroundColor: event.resolvedColor || '#6366f1' }}
                      aria-hidden
                    />
                    <span className="min-w-0 flex-1 truncate font-medium">{title}</span>
                    <span className="shrink-0 text-xs text-muted-foreground">
                      {day ? formatDayLabel(day) : ''}
                    </span>
                  </button>
                </li>
              )
            })}
          </ul>
        )}
        <p className="mt-2 text-[11px] text-muted-foreground">
          {t(
            'calendar.page.searchScopeHint',
            'Cerca dins els darrers i propers 6 mesos (amb els filtres actius).',
          )}
        </p>
      </div>
    ) : null

  const filtersPanel = (
    <div className="space-y-4">
      <div className="space-y-2 lg:hidden">{searchField}</div>
      <div className="space-y-2">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('calendar.page.filters.mineLabel', 'Personal')}
        </p>
        <Button
          type="button"
          size="sm"
          variant={state.mine ? 'default' : 'outline'}
          onClick={() => patchState({ mine: !state.mine })}
          data-testid="company-calendar-mine-toggle"
          aria-pressed={state.mine}
        >
          {t('calendar.page.filters.mine', 'Els meus')}
        </Button>
        <p className="text-[11px] text-muted-foreground">
          {t(
            'calendar.page.filters.mineHint',
            'Manuals teus, tasques assignades i els teus torns. Sense projectes d’empresa.',
          )}
        </p>
      </div>
      <div className="space-y-2">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('calendar.page.filters.type', 'Tipus')}
        </p>
        <div className="flex flex-wrap gap-2">
          <Button
            type="button"
            size="sm"
            variant={state.types.length === 0 ? 'default' : 'outline'}
            onClick={() => patchState({ types: [] })}
          >
            {t('calendar.page.filters.allTypes', 'Tots')}
          </Button>
          {availableTypes.map((type) => {
            const active = state.types.includes(type)
            return (
              <Button
                key={type}
                type="button"
                size="sm"
                variant={active ? 'default' : 'outline'}
                onClick={() => {
                  const next = active
                    ? state.types.filter((x) => x !== type)
                    : [...state.types, type]
                  patchState({ types: next })
                }}
              >
                {t(`calendar.entity.${type}`, type)}
              </Button>
            )
          })}
        </div>
      </div>

      <div className="space-y-2">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('calendar.page.filters.site', 'Àmbit')}
        </p>
        <select
          className="h-10 w-full rounded-md border border-input bg-background px-3 text-sm"
          value={state.site}
          onChange={(e) => patchState({ site: e.target.value })}
        >
          <option value="all">{t('calendar.page.filters.siteAll', 'Tots els centres')}</option>
          {sites.map((site) => (
            <option key={site.id} value={site.id}>
              {site.name}
            </option>
          ))}
        </select>
      </div>

      {filtersActive ? (
        <Button type="button" variant="ghost" size="sm" onClick={clearFilters}>
          <X className="mr-1 h-4 w-4" />
          {t('calendar.page.filters.clear', 'Netejar filtres')}
        </Button>
      ) : null}
    </div>
  )

  const dayNav = (
    <div className="flex flex-wrap items-center gap-2">
      <Button
        type="button"
        variant="outline"
        size="sm"
        onClick={() => patchState({ date: formatCalendarDate(startOfDay(new Date())) })}
      >
        {t('calendar.today', 'Avui')}
      </Button>
      <div className="flex items-center gap-1">
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8"
          onClick={() =>
            patchState({
              date: formatCalendarDate(
                addDays(anchor, state.view === 'list' ? -state.span : -1),
              ),
            })
          }
          aria-label={t('calendar.prev', 'Anterior')}
        >
          <ChevronLeft className="h-4 w-4" />
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8"
          onClick={() =>
            patchState({
              date: formatCalendarDate(
                addDays(anchor, state.view === 'list' ? state.span : 1),
              ),
            })
          }
          aria-label={t('calendar.next', 'Següent')}
        >
          <ChevronRight className="h-4 w-4" />
        </Button>
      </div>
      <p className="text-sm font-semibold capitalize">
        {state.view === 'list'
          ? t('calendar.page.listRange', '{{from}} – {{to}}', {
              from: formatDayLabel(formatCalendarDate(rangeStart)),
              to: formatDayLabel(formatCalendarDate(rangeEnd)),
            })
          : formatDayLabel(formatCalendarDate(anchor))}
      </p>
    </div>
  )

  const emptyNotice = (
    <span className="text-sm text-muted-foreground">
      {filtersActive
        ? t('calendar.page.emptyFiltered', 'Cap event amb aquests filtres')
        : t('calendar.empty', 'Sense events aquest mes')}
    </span>
  )

  const showInitialSpinner = isLoading && filteredEvents.length === 0

  const moreSpan = nextListSpan(state.span)

  const body = showInitialSpinner ? (
    <div className="flex h-64 items-center justify-center">
      <div className="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent" />
    </div>
  ) : state.view === 'list' ? (
    <div className="space-y-3">
      {dayNav}
      {listDays.length === 0 ? (
        <div className="rounded-2xl border border-dashed border-border py-12 text-center">
          <CalendarRange className="mx-auto mb-2 h-8 w-8 text-muted-foreground/50" />
          <p className="text-sm text-muted-foreground">
            {filtersActive
              ? t('calendar.page.emptyFiltered', 'Cap event amb aquests filtres')
              : t('calendar.page.emptyList', 'No hi ha events en aquest període')}
          </p>
          {filtersActive ? (
            <Button type="button" variant="outline" size="sm" className="mt-3" onClick={clearFilters}>
              <Search className="mr-1 h-4 w-4" />
              {t('calendar.page.filters.clear', 'Netejar filtres')}
            </Button>
          ) : null}
        </div>
      ) : (
        <div className="space-y-5">
          {listDays.map(([day, dayEventsList]) => (
            <section key={day} className="space-y-2">
              <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                {formatDayLabel(day)}
              </h2>
              <ul className="space-y-2">
                {dayEventsList.map((event) => (
                  <EventListRow
                    key={`${day}-${event.id}`}
                    event={event}
                    formatTime={formatTime}
                    onOpen={openDetail}
                  />
                ))}
              </ul>
            </section>
          ))}
          {moreSpan ? (
            <div className="flex justify-center pt-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => patchState({ span: moreSpan })}
              >
                {t('calendar.page.moreDays', 'Més 14 dies')}
              </Button>
            </div>
          ) : null}
        </div>
      )}
    </div>
  ) : state.view === 'day' || state.view === 'week' ? (
    <div className={cn('space-y-3', isFetching && 'opacity-90')}>
      <CalendarTimeGrid
        view={state.view}
        anchor={anchor}
        onAnchorChange={(next) => patchState({ date: formatCalendarDate(next) })}
        events={gridEvents}
        weekStartsOn={weekStartsOn}
        onEventClick={(gridEvent) => {
          const full = filteredEvents.find((e) => e.id === gridEvent.id)
          if (full) openDetail(full, false)
        }}
        onSelectDay={(day) => {
          if (state.view === 'week') {
            patchState({ view: 'day', date: formatCalendarDate(day) })
          } else {
            patchState({ date: formatCalendarDate(day) })
          }
        }}
        onSlotClick={
          canCreate
            ? (start) => openCreate(start, { allDay: false })
            : undefined
        }
        onAllDayClick={
          canCreate
            ? (day) => openCreate(startOfDay(day), { allDay: true })
            : undefined
        }
        allDayLabel={t('calendar.all_day', 'Tot el dia')}
        notice={filteredEvents.length === 0 ? emptyNotice : null}
      />
    </div>
  ) : (
    <div className={cn('space-y-3', isFetching && 'opacity-90')}>
      <CalendarGrid
        view="month"
        anchor={anchor}
        onAnchorChange={(next) => patchState({ date: formatCalendarDate(next) })}
        events={gridEvents}
        weekStartsOn={weekStartsOn}
        onEventClick={(gridEvent) => {
          const full = filteredEvents.find((e) => e.id === gridEvent.id)
          if (full) openDetail(full, false)
        }}
        onSelectDay={(day) => {
          patchState({ view: 'day', date: formatCalendarDate(day) })
        }}
        onDayAction={canCreate ? (day) => openCreate(startOfDay(day), { allDay: true }) : undefined}
        monthCellMode="cards"
        monthMaxCards={2}
        allDayLabel={t('calendar.all_day', 'Tot el dia')}
        notice={filteredEvents.length === 0 ? emptyNotice : null}
      />
    </div>
  )

  return (
    <>
      <PageShell
        flush
        className="pb-24 lg:pb-6"
        icon={<CalendarRange className="h-5 w-5" aria-hidden />}
        title={t('calendar.page.title', 'Calendari')}
        subtitle={t('calendar.page.subtitle', 'Events de l’empresa')}
        actions={shellActions}
        tabs={viewTabs}
        toolbar={
          <div className="hidden items-center gap-2 lg:flex">
            <div className="min-w-0 flex-1">{searchField}</div>
            <Button
              type="button"
              size="sm"
              variant={state.mine ? 'default' : 'outline'}
              onClick={() => patchState({ mine: !state.mine })}
              aria-pressed={state.mine}
            >
              {t('calendar.page.filters.mine', 'Els meus')}
            </Button>
          </div>
        }
      >
        <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem] xl:grid-cols-[minmax(0,1fr)_22.5rem]">
          <div className="min-w-0 space-y-3" data-testid="company-calendar-page">
            {searchResultsPanel}
            {body}
          </div>
          <aside
            className={cn(
              'hidden lg:block',
              'sticky top-[calc(var(--app-sticky-chrome,0px)+1rem)] self-start',
              'max-h-[calc(100dvh-var(--app-sticky-chrome,0px)-2rem)] overflow-y-auto',
              'rounded-2xl border border-border bg-card p-4',
            )}
          >
            <h2 className="mb-4 text-sm font-semibold">
              {t('calendar.page.panelTitle', 'Filtres')}
            </h2>
            {canCreate ? (
              <Button type="button" className="mb-4 w-full" onClick={() => openCreate()}>
                <Plus className="mr-1.5 h-4 w-4" />
                {t('calendar.actions.create', 'Nou event')}
              </Button>
            ) : null}
            {filtersPanel}
          </aside>
        </div>
      </PageShell>

      <Sheet open={!isLarge && panelOpen} onOpenChange={setPanelOpen}>
        <SheetContent side="right" className="flex w-full flex-col gap-0 p-0 sm:max-w-md">
          <SheetHeader className="border-b border-border px-4 py-3 text-left">
            <SheetTitle>{t('calendar.page.panelTitle', 'Filtres')}</SheetTitle>
          </SheetHeader>
          <div className="min-h-0 flex-1 overflow-y-auto p-4">{filtersPanel}</div>
        </SheetContent>
      </Sheet>

      {activeEvent ? (
        <ActiveEventPermissionSync event={activeEvent} onResolved={setActiveCanEdit} />
      ) : null}

      <EventDetailSheet
        event={activeEvent}
        canEdit={activeCanEdit}
        isDesktop={isLarge}
        onClose={() => setActiveEvent(null)}
        onEdit={
          activeEvent && activeCanEdit ? () => openEdit(activeEvent) : undefined
        }
        onDelete={
          activeEvent?.entity_type === 'manual' && activeCanEdit
            ? () => {
                if (
                  window.confirm(
                    t('calendar.form.deleteConfirm', 'Segur que vols eliminar aquest event?'),
                  )
                ) {
                  if (activeEvent.id) deleteMutation.mutate(activeEvent.id)
                }
              }
            : undefined
        }
        deleting={deleteMutation.isPending}
      />

      <CreateEventForm
        open={createOpen}
        onOpenChange={(open) => {
          setCreateOpen(open)
          if (!open) {
            setEditEvent(null)
            setCreateAllDay(false)
          }
        }}
        initialDate={createDate}
        initialAllDay={createAllDay}
        siteId={querySiteId}
        requireScopeChoice={state.site === 'all'}
        isDesktop={isLarge}
        editEvent={editEvent}
      />
    </>
  )
}

function ActiveEventPermissionSync({
  event,
  onResolved,
}: {
  event: CalendarResolvedEvent
  onResolved: (canEdit: boolean) => void
}) {
  const canEdit = usePermission(event.editPermission, event.site_id ?? undefined)
  useEffect(() => {
    onResolved(canEdit)
  }, [canEdit, onResolved, event.id])
  return null
}
