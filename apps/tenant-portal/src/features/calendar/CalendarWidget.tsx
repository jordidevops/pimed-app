import { memo, useEffect, useMemo, useRef, useState, type TouchEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight, Lock, Plus } from 'lucide-react'
import { Link } from 'react-router-dom'
import { useCalendarEvents } from './useCalendarEvents'
import type { CalendarResolvedEvent } from './calendar.types'
import { CreateEventForm } from './CreateEventForm'
import { Button } from '../../components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '../../components/ui/dialog'
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
} from '../../components/ui/drawer'
import { usePermission } from '../../hooks/usePermission'

interface CalendarWidgetProps {
  siteId?: string | null
}

function startOfDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

function addDays(date: Date, amount: number): Date {
  const d = new Date(date)
  d.setDate(d.getDate() + amount)
  return d
}

function startOfWeekMonday(date: Date): Date {
  const d = startOfDay(date)
  const day = (d.getDay() + 6) % 7
  return addDays(d, -day)
}

function endOfWeekMonday(date: Date): Date {
  const weekStart = startOfWeekMonday(date)
  return new Date(weekStart.getFullYear(), weekStart.getMonth(), weekStart.getDate() + 6, 23, 59, 59)
}

function endOfMonth(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth() + 1, 0, 23, 59, 59)
}

function getMonthGridDays(anchor: Date): Date[] {
  const firstDayOfMonth = new Date(anchor.getFullYear(), anchor.getMonth(), 1)
  const gridStart = startOfWeekMonday(firstDayOfMonth)
  return Array.from({ length: 42 }, (_, i) => addDays(gridStart, i))
}

function dateKey(dateLike: Date | string): string {
  // Sempre convertim a Date i usem mètodes locals per evitar desfasaments de timezone.
  // La regexp UTC (/^\d{4}-\d{2}-\d{2}/) agafaria el dia UTC, que pot ser el dia anterior
  // per a usuaris a UTC+X quan l'event és a mitjanit local.
  const d = typeof dateLike === 'string' ? new Date(dateLike) : dateLike
  const year = d.getFullYear()
  const month = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function toUiLocale(language?: string): string {
  if (!language) return 'ca-ES'
  if (language.startsWith('ca')) return 'ca-ES'
  if (language.startsWith('es')) return 'es-ES'
  return 'en-US'
}

function formatShortRange(start: Date, end: Date, locale: string): string {
  const startLabel = new Intl.DateTimeFormat(locale, { day: 'numeric' }).format(start)
  const endLabel = new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'short' }).format(end)
  return `${startLabel}-${endLabel}`
}

function isSameDay(a: Date, b: Date): boolean {
  return dateKey(a) === dateKey(b)
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

interface DefaultEventDetailProps {
  event: CalendarResolvedEvent
  canEdit: boolean
  onEdit?: () => void
}

function DefaultEventDetail({ event, canEdit, onEdit }: DefaultEventDetailProps) {
  const { t, i18n } = useTranslation('calendar')
  const locale = toUiLocale(i18n.resolvedLanguage)
  const projectHref = event.entity_type === 'project' && event.entity_id
    ? `/projects/${event.entity_id}`
    : null

  const meta = (event.metadata && typeof event.metadata === 'object' && !Array.isArray(event.metadata))
    ? (event.metadata as Record<string, unknown>)
    : null
  const slotDate = meta?.slot_date != null ? String(meta.slot_date) : null
  const locationName = meta?.location_name != null ? String(meta.location_name) : null
  const shiftsHref = event.entity_type === 'shift_slot'
    ? (slotDate
      ? `/attendance-mgmt/planning/shifts?week=${encodeURIComponent(slotDate)}`
      : '/attendance-mgmt/planning/shifts')
    : null

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        {projectHref ? (
          <Link
            to={projectHref}
            className="inline-flex items-center gap-2 font-medium text-primary underline-offset-2 hover:underline"
            title={t('calendar.detail.openProject', 'Obrir projecte')}
          >
            {typeof event.resolvedIcon === 'string' ? <span>{event.resolvedIcon}</span> : null}
            {t(`calendar.entity.${event.entity_type}`, event.resolvedLabel)}
          </Link>
        ) : shiftsHref ? (
          <Link
            to={shiftsHref}
            className="inline-flex items-center gap-2 font-medium text-primary underline-offset-2 hover:underline"
            title={t('calendar.detail.openShiftsPlanner', 'Obrir planificador de torns')}
          >
            {typeof event.resolvedIcon === 'string' ? <span>{event.resolvedIcon}</span> : null}
            {t(`calendar.entity.${event.entity_type}`, event.resolvedLabel)}
            {event.title ? ` · ${event.title}` : ''}
          </Link>
        ) : (
          <>
            {typeof event.resolvedIcon === 'string' ? <span>{event.resolvedIcon}</span> : null}
            <span className="font-medium">
              {t(`calendar.entity.${event.entity_type}`, event.resolvedLabel)}
              {event.entity_type === 'shift_slot' && event.title ? ` · ${event.title}` : ''}
            </span>
          </>
        )}
      </div>

      <p className="text-sm text-muted-foreground">
        {event.description ?? t('calendar.noDescription', 'Sense descripcio')}
      </p>

      <div className="space-y-1 text-sm">
        <p>
          <strong>{t('calendar.detail.start', 'Inici')}:</strong>{' '}
          {event.start_at
            ? new Date(event.start_at).toLocaleString(locale)
            : t('calendar.notAvailable', 'No disponible')}
        </p>
        <p>
          <strong>{t('calendar.detail.end', 'Fi')}:</strong>{' '}
          {event.end_at
            ? new Date(event.end_at).toLocaleString(locale)
            : t('calendar.noEndDate', 'Sense data de fi')}
        </p>
        {event.entity_type === 'shift_slot' && slotDate ? (
          <p>
            <strong>{t('calendar.detail.slotDate', 'Data')}:</strong> {slotDate}
          </p>
        ) : null}
        {event.entity_type === 'shift_slot' && locationName ? (
          <p>
            <strong>{t('calendar.detail.location', 'Ubicació')}:</strong> {locationName}
          </p>
        ) : null}
      </div>

      {event.addonUnavailable ? (
        <div className="rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-800">
          {t('calendar.addonUpgrade', 'Aquest modul no esta actiu al teu pla. Actualitza el pla per gestionar aquest event.')}
        </div>
      ) : null}

      {!canEdit ? (
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <Lock className="h-4 w-4" />
          {t('calendar.readOnly', 'Mode nomes lectura')}
        </div>
      ) : event.entity_type === 'manual' && onEdit ? (
        <div className="flex justify-end pt-2">
          <Button type="button" size="sm" variant="outline" onClick={onEdit}>
            {t('calendar.actions.edit', 'Editar event')}
          </Button>
        </div>
      ) : null}
    </div>
  )
}

function getResponsiveValue(): boolean {
  if (typeof window === 'undefined') return true
  return window.matchMedia('(min-width: 768px)').matches
}

export function CalendarWidget({ siteId }: CalendarWidgetProps) {
  const { t, i18n } = useTranslation('calendar')
  const locale = toUiLocale(i18n.resolvedLanguage)

  const today = useMemo(() => startOfDay(new Date()), [])
  const [selectedDay, setSelectedDay] = useState<Date>(today)
  const [monthAnchor, setMonthAnchor] = useState<Date>(new Date(today.getFullYear(), today.getMonth(), 1))
  const [isDesktop, setIsDesktop] = useState<boolean>(getResponsiveValue)

  const [activeEvent, setActiveEvent] = useState<CalendarResolvedEvent | null>(null)
  const [activeCanEdit, setActiveCanEdit] = useState(false)
  const [createFormOpen, setCreateFormOpen] = useState(false)
  const [createFormDate, setCreateFormDate] = useState<Date>(today)
  const [editEvent, setEditEvent] = useState<CalendarResolvedEvent | null>(null)

  function openEditForm(event: CalendarResolvedEvent) {
    setEditEvent(event)
    setActiveEvent(null)
    setCreateFormOpen(true)
  }

  useEffect(() => {
    if (typeof window === 'undefined') return

    const mediaQuery = window.matchMedia('(min-width: 768px)')
    const onChange = () => setIsDesktop(mediaQuery.matches)
    onChange()

    mediaQuery.addEventListener('change', onChange)
    return () => mediaQuery.removeEventListener('change', onChange)
  }, [])

  const weekStart = useMemo(() => startOfWeekMonday(selectedDay), [selectedDay])
  const mobileWeekDays = useMemo(() => Array.from({ length: 7 }, (_, i) => addDays(weekStart, i)), [weekStart])

  const rangeStart = useMemo(() => {
    const monthStart = new Date(monthAnchor.getFullYear(), monthAnchor.getMonth(), 1)
    return addDays(monthStart < weekStart ? monthStart : weekStart, -7)
  }, [monthAnchor, weekStart])

  const rangeEnd = useMemo(() => {
    const monthEnd = endOfMonth(monthAnchor)
    const weekEnd = endOfWeekMonday(selectedDay)
    return addDays(monthEnd > weekEnd ? monthEnd : weekEnd, 7)
  }, [monthAnchor, selectedDay])

  const { data: events = [], isLoading } = useCalendarEvents({
    rangeStart,
    rangeEnd,
    siteId,
  })

  const eventsByDay = useMemo(() => {
    const grouped = new Map<string, CalendarResolvedEvent[]>()
    for (const event of events) {
      if (!event.start_at) continue
      const key = dateKey(event.start_at)
      const list = grouped.get(key) ?? []
      list.push(event)
      grouped.set(key, list)
    }
    return grouped
  }, [events])

  const monthGridDays = useMemo(() => getMonthGridDays(monthAnchor), [monthAnchor])
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

  const modalTitle = activeEvent?.title ?? t('calendar.untitled', '(Sense títol)')
  const DetailComponent = activeEvent?.moduleDefinition?.DetailModal

  const desktopSwipe = useHorizontalSwipe(
    () => setMonthAnchor((prev) => new Date(prev.getFullYear(), prev.getMonth() + 1, 1)),
    () => setMonthAnchor((prev) => new Date(prev.getFullYear(), prev.getMonth() - 1, 1)),
  )

  const mobileSwipe = useHorizontalSwipe(
    () => setSelectedDay((prev) => addDays(prev, 7)),
    () => setSelectedDay((prev) => addDays(prev, -7)),
  )

  const weekdayLabels = [
    t('calendar.weekdays.mon', 'Dl'),
    t('calendar.weekdays.tue', 'Dt'),
    t('calendar.weekdays.wed', 'Dc'),
    t('calendar.weekdays.thu', 'Dj'),
    t('calendar.weekdays.fri', 'Dv'),
    t('calendar.weekdays.sat', 'Ds'),
    t('calendar.weekdays.sun', 'Dg'),
  ]

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

        <Button
          type="button"
          variant="ghost"
          size="sm"
          onClick={() => {
            setCreateFormDate(selectedDay)
            setCreateFormOpen(true)
          }}
          className="ml-2"
        >
          <Plus className="h-4 w-4 mr-1" />
          {t('calendar.actions.create', 'Nou event')}
        </Button>
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
                <p className="text-[11px] uppercase text-muted-foreground">{weekdayLabels[(day.getDay() + 6) % 7]}</p>
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

      <Dialog open={Boolean(activeEvent && isDesktop)} onOpenChange={(open) => { if (!open) setActiveEvent(null) }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{modalTitle}</DialogTitle>
            <DialogDescription>
              {activeEvent
                ? t(`calendar.entity.${activeEvent.entity_type}`, activeEvent.resolvedLabel)
                : t('calendar.detail.defaultDescription', 'Detall de l\'event')}
            </DialogDescription>
          </DialogHeader>

          {activeEvent ? (
            DetailComponent ? (
              <DetailComponent
                event={activeEvent}
                canEdit={activeCanEdit}
                onClose={() => setActiveEvent(null)}
              />
            ) : (
              <DefaultEventDetail
                event={activeEvent}
                canEdit={activeCanEdit}
                onEdit={activeCanEdit ? () => openEditForm(activeEvent) : undefined}
              />
            )
          ) : null}
        </DialogContent>
      </Dialog>

      <Drawer open={Boolean(activeEvent && !isDesktop)} onOpenChange={(open: boolean) => { if (!open) setActiveEvent(null) }}>
        <DrawerContent>
          <DrawerHeader>
            <DrawerTitle>{modalTitle}</DrawerTitle>
            <DrawerDescription>
              {activeEvent
                ? t(`calendar.entity.${activeEvent.entity_type}`, activeEvent.resolvedLabel)
                : t('calendar.detail.defaultDescription', 'Detall de l\'event')}
            </DrawerDescription>
          </DrawerHeader>

          {activeEvent ? (
            DetailComponent ? (
              <DetailComponent
                event={activeEvent}
                canEdit={activeCanEdit}
                onClose={() => setActiveEvent(null)}
              />
            ) : (
              <DefaultEventDetail
                event={activeEvent}
                canEdit={activeCanEdit}
                onEdit={activeCanEdit ? () => openEditForm(activeEvent) : undefined}
              />
            )
          ) : null}
        </DrawerContent>
      </Drawer>

      <CreateEventForm
        open={createFormOpen}
        onOpenChange={(open) => {
          setCreateFormOpen(open)
          if (!open) setEditEvent(null)
        }}
        initialDate={createFormDate}
        siteId={siteId}
        isDesktop={isDesktop}
        editEvent={editEvent}
      />
    </div>
  )
}
