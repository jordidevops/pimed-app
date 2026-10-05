import { memo, useEffect, useMemo, useRef, useState, type TouchEvent } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ChevronLeft, ChevronRight, Plus } from 'lucide-react'
import { useCalendarEvents } from './useCalendarEvents'
import type { CalendarResolvedEvent } from './calendar.types'
import { CreateEventForm } from './CreateEventForm'
import { EventDetailSheet } from './EventDetailSheet'
import { projectEventsOntoDays, toProjectableResolvedEvents } from './projectEventsOntoDays'
import { formatCalendarDate } from './companyCalendarUrlState'
import {
  addDays,
  dateKey,
  endOfMonth,
  endOfWeek,
  formatShortRange,
  getMonthGridDays,
  isSameDay,
  startOfDay,
  startOfWeek,
  toUiLocale,
} from './calendarDateUtils'
import { Button } from '../../components/ui/button'
import { usePermission } from '../../hooks/usePermission'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { supabase } from '@/lib/supabase'

interface CalendarWidgetProps {
  siteId?: string | null
}

function useHorizontalSwipe(onSwipeLeft: () => void, onSwipeRight: () => void) {
  const touchStartX = useRef<number | null>(null)
  const threshold = 48

  return {
    onTouchStart: (event: TouchEvent<HTMLElement>) => {
      touchStartX.current = event.changedTouches[0].clientX
    },
    onTouchEnd: (event: TouchEvent<HTMLElement>) => {
      if (touchStartX.current === null) return
      const deltaX = event.changedTouches[0].clientX - touchStartX.current
      touchStartX.current = null

      if (Math.abs(deltaX) < threshold) return
      if (deltaX < 0) onSwipeLeft()
      if (deltaX > 0) onSwipeRight()
    },
  }
}

interface EventChipProps {
  event: CalendarResolvedEvent
  onOpenDetail: (event: CalendarResolvedEvent, canEdit: boolean) => void
}

const EventChip = memo(function EventChip({ event, onOpenDetail }: EventChipProps) {
  const { t } = useTranslation('calendar')
  // Per events globals (site_id = null), passa `undefined` per usar el site actiu del context.
  // Passar `null` explícit força una comprovació *only-global* que falla per a usuaris site-only.
  const eventSiteCtx = event.site_id ?? undefined
  const canEdit = usePermission(event.editPermission, eventSiteCtx)
  // La visibilitat d'events la decideix la RLS a backend. No ocultem chips al frontend
  // per evitar falsos negatius quan el JWT del navegador encara no porta app_metadata nova.

  const eventTitle = event.title ?? t('calendar.untitled', '(Sense títol)')
  const chipTitle = event.addonUnavailable
    ? `${eventTitle} (${t('calendar.addonInactive', 'Mòdul inactiu')})`
    : eventTitle

  return (
    <button
      type="button"
      onClick={(eventClick) => {
        eventClick.stopPropagation()
        onOpenDetail(event, canEdit)
      }}
      className={[
        'mb-1 flex min-h-12 w-full items-center gap-1.5 rounded-md px-2 py-1 text-left text-[13px] text-white',
        'transition hover:opacity-90',
        event.addonUnavailable ? 'opacity-50' : '',
      ].join(' ')}
      style={{ backgroundColor: event.resolvedColor || '#6366f1' }}
      title={chipTitle}
      aria-label={`${event.resolvedLabel}: ${eventTitle}`}
      data-color={event.resolvedColor}
    >
      {typeof event.resolvedIcon === 'string' ? <span>{event.resolvedIcon}</span> : null}
      <span className="truncate">{eventTitle}</span>
    </button>
  )
})

interface DesktopDayCellProps {
  day: Date
  events: CalendarResolvedEvent[]
  isToday: boolean
  isSelected: boolean
  isCurrentMonth: boolean
  onSelectDay: (day: Date) => void
}

const DesktopDayCell = memo(function DesktopDayCell({
  day,
  events,
  isToday,
  isSelected,
  isCurrentMonth,
  onSelectDay,
}: DesktopDayCellProps) {
  return (
    <div
      onClick={() => onSelectDay(day)}
      className={[
        'h-28 cursor-pointer bg-white p-2 transition-colors hover:bg-muted/20 dark:bg-gray-900',
        'overflow-hidden',
        !isCurrentMonth ? 'bg-muted/30 text-muted-foreground' : '',
        isToday ? 'ring-1 ring-inset ring-blue-400' : '',
        isSelected ? 'ring-2 ring-inset ring-indigo-500' : '',
      ].join(' ')}
    >
      <div className="mb-2 flex items-center justify-between">
        <span
          className={[
            'flex h-6 w-6 items-center justify-center rounded-full text-xs',
            isToday
              ? 'bg-blue-500 font-bold text-white'
              : isCurrentMonth
                ? 'text-gray-700 dark:text-gray-300'
                : 'text-gray-400 dark:text-gray-500',
          ].join(' ')}
        >
          {day.getDate()}
        </span>

        {events.length > 0 ? (
          <span className="rounded-full bg-muted px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground">
            {events.length}
          </span>
        ) : null}
      </div>

      {events.length > 0 ? (
        <div className="flex flex-wrap items-center gap-1">
          {events.slice(0, 3).map((event) => (
            <span
              key={event.id}
              className="h-2 w-2 rounded-full"
              style={{ backgroundColor: event.resolvedColor || '#6366f1' }}
              title={event.title ?? undefined}
            />
          ))}
          {events.length > 3 ? (
            <span className="text-[10px] font-medium text-muted-foreground">
              +{events.length - 3}
            </span>
          ) : null}
        </div>
      ) : null}
    </div>
  )
})

function getResponsiveValue(): boolean {
  if (typeof window === 'undefined') return true
  return window.matchMedia('(min-width: 768px)').matches
}

export function CalendarWidget({ siteId }: CalendarWidgetProps) {
  const { t, i18n } = useTranslation('calendar')
  const locale = toUiLocale(i18n.resolvedLanguage)
  const queryClient = useQueryClient()
  const { weekStartsOn } = useCalendarDisplaySettings()
  const canCreate = usePermission('calendar.edit')

  const today = useMemo(() => startOfDay(new Date()), [])
  const [selectedDay, setSelectedDay] = useState<Date>(today)
  const [monthAnchor, setMonthAnchor] = useState<Date>(new Date(today.getFullYear(), today.getMonth(), 1))
  const [isDesktop, setIsDesktop] = useState<boolean>(getResponsiveValue)

  const [activeEvent, setActiveEvent] = useState<CalendarResolvedEvent | null>(null)
  const [activeCanEdit, setActiveCanEdit] = useState(false)
  const [createFormOpen, setCreateFormOpen] = useState(false)
  const [editEvent, setEditEvent] = useState<CalendarResolvedEvent | null>(null)

  function openEditForm(event: CalendarResolvedEvent) {
    setEditEvent(event)
    setActiveEvent(null)
    setCreateFormOpen(true)
  }

  const createHref = useMemo(() => {
    const params = new URLSearchParams({
      create: '1',
      date: formatCalendarDate(selectedDay),
    })
    if (typeof siteId === 'string' && siteId.trim()) {
      params.set('site', siteId)
    }
    return `/calendar?${params.toString()}`
  }, [selectedDay, siteId])

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

  useEffect(() => {
    if (typeof window === 'undefined') return

    const mediaQuery = window.matchMedia('(min-width: 768px)')
    const onChange = () => setIsDesktop(mediaQuery.matches)
    onChange()

    mediaQuery.addEventListener('change', onChange)
    return () => mediaQuery.removeEventListener('change', onChange)
  }, [])

  const weekStart = useMemo(
    () => startOfWeek(selectedDay, weekStartsOn),
    [selectedDay, weekStartsOn],
  )
  const mobileWeekDays = useMemo(
    () => Array.from({ length: 7 }, (_, i) => addDays(weekStart, i)),
    [weekStart],
  )

  const rangeStart = useMemo(() => {
    const monthStart = new Date(monthAnchor.getFullYear(), monthAnchor.getMonth(), 1)
    return addDays(monthStart < weekStart ? monthStart : weekStart, -7)
  }, [monthAnchor, weekStart])

  const rangeEnd = useMemo(() => {
    const monthEnd = endOfMonth(monthAnchor)
    const weekEnd = endOfWeek(selectedDay, weekStartsOn)
    return addDays(monthEnd > weekEnd ? monthEnd : weekEnd, 7)
  }, [monthAnchor, selectedDay, weekStartsOn])

  const { data: events = [], isLoading } = useCalendarEvents({
    rangeStart,
    rangeEnd,
    siteId,
  })

  const eventsByDay = useMemo(() => {
    return projectEventsOntoDays(
      toProjectableResolvedEvents(events),
      rangeStart,
      rangeEnd,
    )
  }, [events, rangeStart, rangeEnd])

  const monthGridDays = useMemo(
    () => getMonthGridDays(monthAnchor, weekStartsOn),
    [monthAnchor, weekStartsOn],
  )
  const monthLabel = useMemo(
    () => new Intl.DateTimeFormat(locale, { month: 'long', year: 'numeric' }).format(monthAnchor),
    [locale, monthAnchor],
  )
  const selectedDayLabel = useMemo(
    () => new Intl.DateTimeFormat(locale, { weekday: 'long', day: 'numeric', month: 'long' }).format(selectedDay),
    [locale, selectedDay],
  )

  const agendaEvents = useMemo(
    () => (eventsByDay.get(dateKey(selectedDay)) ?? []).sort((a, b) => new Date(a.start_at ?? '').getTime() - new Date(b.start_at ?? '').getTime()),
    [eventsByDay, selectedDay],
  )

  const desktopSwipe = useHorizontalSwipe(
    () => setMonthAnchor((prev) => new Date(prev.getFullYear(), prev.getMonth() + 1, 1)),
    () => setMonthAnchor((prev) => new Date(prev.getFullYear(), prev.getMonth() - 1, 1)),
  )

  const mobileSwipe = useHorizontalSwipe(
    () => setSelectedDay((prev) => addDays(prev, 7)),
    () => setSelectedDay((prev) => addDays(prev, -7)),
  )

  const weekdayLabelsMonFirst = useMemo(
    () => [
      t('calendar.weekdays.mon', 'Dl'),
      t('calendar.weekdays.tue', 'Dt'),
      t('calendar.weekdays.wed', 'Dc'),
      t('calendar.weekdays.thu', 'Dj'),
      t('calendar.weekdays.fri', 'Dv'),
      t('calendar.weekdays.sat', 'Ds'),
      t('calendar.weekdays.sun', 'Dg'),
    ],
    [t, i18n.resolvedLanguage],
  )
  const weekdayLabels = useMemo(() => {
    const order = Array.from({ length: 7 }, (_, i) => (weekStartsOn + i) % 7)
    // Labels array is Mon-first (index 0 = Monday = JS day 1).
    return order.map((jsDow) => weekdayLabelsMonFirst[(jsDow + 6) % 7]!)
  }, [weekStartsOn, weekdayLabelsMonFirst])

  const mobileWeekLabel = useMemo(
    () => formatShortRange(mobileWeekDays[0], mobileWeekDays[6], locale),
    [locale, mobileWeekDays],
  )

  return (
    <div
      className="space-y-4 rounded-2xl border border-border/70 bg-linear-to-b from-background to-muted/20 p-3 shadow-sm md:p-4"
      data-testid="calendar-widget"
    >
      <div className="flex items-center justify-between rounded-xl bg-card/70 px-2 py-1 backdrop-blur">
        <button
          type="button"
          onClick={() => {
            if (isDesktop) setMonthAnchor((prev) => new Date(prev.getFullYear(), prev.getMonth() - 1, 1))
            else setSelectedDay((prev) => addDays(prev, -7))
          }}
          className="rounded-lg p-2.5 text-foreground hover:bg-muted"
          aria-label={t('calendar.navigation.prev', 'Anterior')}
          data-testid="calendar-nav-prev"
        >
          <ChevronLeft className="h-4 w-4" />
        </button>

        <p className="text-sm font-semibold capitalize text-foreground flex-1 text-center" data-testid="calendar-nav-label">
          {isDesktop ? monthLabel : mobileWeekLabel}
        </p>

        <button
          type="button"
          onClick={() => {
            if (isDesktop) setMonthAnchor((prev) => new Date(prev.getFullYear(), prev.getMonth() + 1, 1))
            else setSelectedDay((prev) => addDays(prev, 7))
          }}
          className="rounded-lg p-2.5 text-foreground hover:bg-muted"
          aria-label={t('calendar.navigation.next', 'Següent')}
          data-testid="calendar-nav-next"
        >
          <ChevronRight className="h-4 w-4" />
        </button>

        {canCreate ? (
          <Button type="button" variant="ghost" size="sm" className="ml-2" asChild>
            <Link to={createHref} data-testid="calendar-widget-create">
              <Plus className="h-4 w-4 mr-1" />
              {t('calendar.actions.create', 'Nou event')}
            </Link>
          </Button>
        ) : null}
      </div>

      <section className="hidden md:block" {...desktopSwipe} data-testid="calendar-desktop-view">
        <div className="mb-1 grid grid-cols-7 text-center text-xs font-medium text-muted-foreground">
          {weekdayLabels.map((label) => (
            <div key={label} className="py-1">{label}</div>
          ))}
        </div>

        {isLoading ? (
          <div className="rounded-lg border py-10 text-center text-sm text-muted-foreground">
            {t('calendar.loading', 'Carregant events...')}
          </div>
        ) : (
          <div className="grid grid-cols-7 gap-px overflow-hidden rounded-lg bg-muted">
            {monthGridDays.map((day) => (
              <DesktopDayCell
                key={dateKey(day)}
                day={day}
                events={eventsByDay.get(dateKey(day)) ?? []}
                isToday={isSameDay(day, today)}
                isSelected={isSameDay(day, selectedDay)}
                isCurrentMonth={
                  day.getMonth() === monthAnchor.getMonth()
                  && day.getFullYear() === monthAnchor.getFullYear()
                }
                onSelectDay={(pickedDay) => {
                  setSelectedDay(pickedDay)
                  if (
                    pickedDay.getMonth() !== monthAnchor.getMonth()
                    || pickedDay.getFullYear() !== monthAnchor.getFullYear()
                  ) {
                    setMonthAnchor(new Date(pickedDay.getFullYear(), pickedDay.getMonth(), 1))
                  }
                }}
              />
            ))}
          </div>
        )}

        <div className="mt-3 space-y-2 rounded-xl border bg-background p-3 shadow-sm" data-testid="calendar-desktop-agenda">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            {t('calendar.desktopAgendaTitle', 'Events del dia seleccionat')}
          </p>
          <p className="text-sm font-medium capitalize text-foreground">{selectedDayLabel}</p>

          {isLoading ? (
            <p className="py-5 text-sm text-muted-foreground">{t('calendar.loading', 'Carregant events...')}</p>
          ) : agendaEvents.length === 0 ? (
            <p className="py-5 text-sm text-muted-foreground">{t('calendar.emptyDay', 'No hi ha events per aquest dia')}</p>
          ) : (
            <div className="space-y-1">
              {agendaEvents.map((event) => (
                <EventChip
                  key={event.id}
                  event={event}
                  onOpenDetail={(entry, canEdit) => {
                    setActiveEvent(entry)
                    setActiveCanEdit(canEdit)
                  }}
                />
              ))}
            </div>
          )}
        </div>
      </section>

      <section className="space-y-3 md:hidden" {...mobileSwipe} data-testid="calendar-mobile-view">
        <div className="mt-1 flex gap-2 overflow-x-auto pt-1 pb-3" data-testid="calendar-mobile-week-strip">
          {mobileWeekDays.map((day) => {
            const selected = isSameDay(day, selectedDay)
            const isCurrent = isSameDay(day, today)

            return (
              <button
                key={dateKey(day)}
                type="button"
                onClick={() => setSelectedDay(day)}
                className={[
                  'min-h-14 min-w-16 rounded-xl border px-2 py-2 text-center shadow-sm transition',
                  selected
                    ? 'border-indigo-500 bg-indigo-50 text-indigo-700 dark:border-indigo-400 dark:bg-indigo-950/50 dark:text-indigo-200'
                    : 'border-border bg-background',
                ].join(' ')}
              >
                <p className="text-[11px] uppercase text-muted-foreground">
                  {weekdayLabelsMonFirst[(day.getDay() + 6) % 7]}
                </p>
                <p className={['text-base font-semibold', isCurrent ? 'text-blue-600' : 'text-foreground'].join(' ')}>{day.getDate()}</p>
              </button>
            )
          })}
        </div>

        <div className="space-y-2 rounded-xl border bg-background p-3 shadow-sm" data-testid="calendar-mobile-agenda">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            {t('calendar.mobileAgendaTitle', 'Agenda del dia')}
          </p>

          {isLoading ? (
            <p className="py-5 text-sm text-muted-foreground">{t('calendar.loading', 'Carregant events...')}</p>
          ) : agendaEvents.length === 0 ? (
            <p className="py-5 text-sm text-muted-foreground">{t('calendar.emptyDay', 'No hi ha events per aquest dia')}</p>
          ) : (
            <div className="space-y-1">
              {agendaEvents.map((event) => (
                <EventChip
                  key={event.id}
                  event={event}
                  onOpenDetail={(entry, canEdit) => {
                    setActiveEvent(entry)
                    setActiveCanEdit(canEdit)
                  }}
                />
              ))}
            </div>
          )}
        </div>
      </section>

      <EventDetailSheet
        event={activeEvent}
        canEdit={activeCanEdit}
        isDesktop={isDesktop}
        onClose={() => setActiveEvent(null)}
        onEdit={
          activeEvent && activeCanEdit ? () => openEditForm(activeEvent) : undefined
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
        open={createFormOpen}
        onOpenChange={(open) => {
          setCreateFormOpen(open)
          if (!open) setEditEvent(null)
        }}
        initialDate={
          editEvent?.start_at ? new Date(editEvent.start_at) : selectedDay
        }
        siteId={siteId}
        requireScopeChoice={siteId === undefined || siteId === null}
        isDesktop={isDesktop}
        editEvent={editEvent}
      />
    </div>
  )
}
