import { useEffect, useState, type CSSProperties, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight, Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import {
  addDays,
  dateKey,
  formatShortRange,
  getMonthGridDays,
  isMidnightLocal,
  isSameDay,
  startOfDay,
  endOfWeek,
  startOfWeek,
  toUiLocale,
} from './calendarDateUtils'
import { projectEventsOntoDays, resolveEventColor } from './projectEventsOntoDays'

export type CalendarGridView = 'week' | 'month'

export type CalendarGridEvent = {
  id: string
  start: string
  end?: string | null
  title: string
  subtitle?: string | null
  tone?: 'work_order' | 'maintenance' | 'muted' | 'default'
  /** Resolved hex color for company calendar; overrides tone fill when set. */
  color?: string | null
  allDay?: boolean | null
  badges?: string[]
  dimmed?: boolean
}

export type CalendarGridProps = {
  view: CalendarGridView
  anchor: Date
  onAnchorChange: (next: Date) => void
  events: CalendarGridEvent[]
  selectedDay?: Date
  onSelectDay?: (day: Date) => void
  onEventClick?: (event: CalendarGridEvent) => void
  onDayAction?: (day: Date) => void
  renderEvent?: (event: CalendarGridEvent) => ReactNode
  allDayWhenMidnight?: boolean
  allDayLabel?: string
  className?: string
  /** JS day-of-week: 0=Sunday … 6=Saturday (default Monday). */
  weekStartsOn?: number
  /**
   * Month cells: `dots` = color markers only (portrait mobile);
   * `cards` = event titles; `auto` picks by viewport width.
   */
  monthCellMode?: 'auto' | 'dots' | 'cards'
  /** Max event cards per month cell before "+N" (landscape / desktop). */
  monthMaxCards?: number
  /** Fixed-height slot beside the period label (empty notices, etc.). */
  notice?: ReactNode
}

const TONE_CLASS: Record<NonNullable<CalendarGridEvent['tone']>, string> = {
  work_order: 'bg-sky-600 text-white',
  maintenance: 'bg-emerald-700 text-white',
  muted: 'bg-muted text-muted-foreground',
  default: 'bg-primary text-primary-foreground',
}

const TONE_DOT: Record<NonNullable<CalendarGridEvent['tone']>, string> = {
  work_order: 'bg-sky-600',
  maintenance: 'bg-emerald-700',
  muted: 'bg-muted-foreground',
  default: 'bg-primary',
}

function usePreferMonthDots(mode: 'auto' | 'dots' | 'cards'): boolean {
  const [preferDots, setPreferDots] = useState(() => {
    if (mode === 'dots') return true
    if (mode === 'cards') return false
    if (typeof window === 'undefined') return false
    return window.matchMedia('(max-width: 639px)').matches
  })

  useEffect(() => {
    if (mode === 'dots') {
      setPreferDots(true)
      return
    }
    if (mode === 'cards') {
      setPreferDots(false)
      return
    }
    if (typeof window === 'undefined') return
    const mq = window.matchMedia('(max-width: 639px)')
    const onChange = () => setPreferDots(mq.matches)
    onChange()
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [mode])

  return preferDots
}

function eventSurfaceStyle(event: CalendarGridEvent): { className: string; style?: CSSProperties } {
  if (event.color) {
    return {
      className: 'text-white',
      style: { backgroundColor: resolveEventColor(event.color) },
    }
  }
  return { className: TONE_CLASS[event.tone ?? 'default'] }
}

function DefaultEventCard({
  event,
  allDayWhenMidnight,
  onClick,
  compact = false,
}: {
  event: CalendarGridEvent
  allDayWhenMidnight: boolean
  onClick?: () => void
  compact?: boolean
}) {
  const start = new Date(event.start)
  const treatAllDay = Boolean(event.allDay) || (allDayWhenMidnight && isMidnightLocal(start))
  const showTime = !treatAllDay
  const timeLabel = showTime
    ? start.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
    : null
  const surface = eventSurfaceStyle(event)

  if (compact) {
    return (
      <button
        type="button"
        onClick={(e) => {
          e.stopPropagation()
          onClick?.()
        }}
        className={cn(
          'w-full truncate rounded px-1 py-0.5 text-left text-[10px] leading-tight transition hover:opacity-90',
          surface.className,
          event.dimmed && 'opacity-60',
        )}
        style={surface.style}
        title={event.title}
      >
        {timeLabel && <span className="font-semibold tabular-nums">{timeLabel} </span>}
        <span className="font-medium">{event.title}</span>
      </button>
    )
  }

  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        'w-full rounded-md px-2 py-1.5 text-left text-xs transition hover:opacity-90',
        surface.className,
        event.dimmed && 'opacity-60',
      )}
      style={surface.style}
    >
      {timeLabel && <span className="font-semibold tabular-nums">{timeLabel} </span>}
      <span className="font-medium">{event.title}</span>
      {event.subtitle && (
        <span className="mt-0.5 block truncate opacity-90">{event.subtitle}</span>
      )}
      {event.badges && event.badges.length > 0 && (
        <span className="mt-0.5 block truncate text-[10px] opacity-80">
          {event.badges.join(' · ')}
        </span>
      )}
    </button>
  )
}

export function CalendarGrid({
  view,
  anchor,
  onAnchorChange,
  events,
  selectedDay,
  onSelectDay,
  onEventClick,
  onDayAction,
  renderEvent,
  allDayWhenMidnight = true,
  allDayLabel,
  className,
  weekStartsOn = 1,
  monthCellMode = 'auto',
  monthMaxCards = 2,
  notice,
}: CalendarGridProps) {
  const { t, i18n } = useTranslation('calendar')
  const locale = toUiLocale(i18n.resolvedLanguage)
  const today = startOfDay(new Date())
  const weekStart = startOfWeek(anchor, weekStartsOn)
  const weekDays = Array.from({ length: 7 }, (_, i) => addDays(weekStart, i))
  const monthDays = getMonthGridDays(anchor, weekStartsOn)
  const rangeStart = view === 'month' ? monthDays[0]! : weekStart
  const rangeEnd = view === 'month' ? monthDays[monthDays.length - 1]! : endOfWeek(anchor, weekStartsOn)
  const eventsByDay = projectEventsOntoDays(
    events.map((e) => ({
      ...e,
      allDay: e.allDay ?? (allDayWhenMidnight && isMidnightLocal(e.start)),
    })),
    rangeStart,
    rangeEnd,
  )
  const resolvedAllDayLabel = allDayLabel ?? t('calendar.all_day', 'Tot el dia')
  const monthDots = usePreferMonthDots(monthCellMode)

  const monthLabel = new Intl.DateTimeFormat(locale, { month: 'long', year: 'numeric' }).format(
    view === 'month' ? anchor : weekStart,
  )
  const weekLabel = formatShortRange(weekStart, endOfWeek(anchor, weekStartsOn), locale)

  function goPrev() {
    if (view === 'month') {
      onAnchorChange(new Date(anchor.getFullYear(), anchor.getMonth() - 1, 1))
    } else {
      onAnchorChange(addDays(weekStart, -7))
    }
  }

  function goNext() {
    if (view === 'month') {
      onAnchorChange(new Date(anchor.getFullYear(), anchor.getMonth() + 1, 1))
    } else {
      onAnchorChange(addDays(weekStart, 7))
    }
  }

  function goToday() {
    onAnchorChange(today)
    onSelectDay?.(today)
  }

  function renderDayEvents(day: Date, compact: boolean) {
    const dayEvents = eventsByDay.get(dateKey(day)) ?? []
    if (dayEvents.length === 0) {
      // Spacer keeps column height stable when navigating empty ↔ busy weeks.
      return <div className="min-h-16" aria-hidden />
    }

    const allDay = dayEvents.filter(
      (e) => Boolean(e.allDay) || (allDayWhenMidnight && isMidnightLocal(e.start)),
    )
    const timed = dayEvents.filter(
      (e) => !(Boolean(e.allDay) || (allDayWhenMidnight && isMidnightLocal(e.start))),
    )

    return (
      <div className={cn('space-y-1', compact && 'space-y-0.5')}>
        {allDay.length > 0 && (
          <div className="space-y-1">
            <p className="px-1 text-[10px] font-semibold uppercase tracking-wide text-muted-foreground">
              {resolvedAllDayLabel}
            </p>
            {allDay.map((event) =>
              renderEvent ? (
                <div key={event.id}>{renderEvent(event)}</div>
              ) : (
                <DefaultEventCard
                  key={event.id}
                  event={event}
                  allDayWhenMidnight={allDayWhenMidnight}
                  onClick={() => onEventClick?.(event)}
                />
              ),
            )}
          </div>
        )}
        {timed.map((event) =>
          renderEvent ? (
            <div key={event.id}>{renderEvent(event)}</div>
          ) : (
            <DefaultEventCard
              key={event.id}
              event={event}
              allDayWhenMidnight={allDayWhenMidnight}
              onClick={() => onEventClick?.(event)}
            />
          ),
        )}
      </div>
    )
  }

  return (
    <div className={cn('space-y-3', className)}>
      <div className="flex flex-wrap items-center gap-2">
        <Button type="button" variant="outline" size="sm" onClick={goToday}>
          {t('calendar.today', 'Avui')}
        </Button>
        <div className="flex items-center gap-1">
          <Button type="button" variant="ghost" size="icon" className="h-8 w-8" onClick={goPrev} aria-label={t('calendar.prev', 'Anterior')}>
            <ChevronLeft className="h-4 w-4" />
          </Button>
          <Button type="button" variant="ghost" size="icon" className="h-8 w-8" onClick={goNext} aria-label={t('calendar.next', 'Següent')}>
            <ChevronRight className="h-4 w-4" />
          </Button>
        </div>
        <p className="text-sm font-semibold capitalize">
          {view === 'month' ? monthLabel : weekLabel}
        </p>
        <div className="flex min-h-5 min-w-0 flex-1 items-center sm:justify-end">
          {notice ? (
            <p className="text-sm text-muted-foreground">{notice}</p>
          ) : null}
        </div>
      </div>

      {view === 'week' ? (
        <div className="grid grid-cols-1 gap-2 md:grid-cols-7">
          {weekDays.map((day) => {
            const isToday = isSameDay(day, today)
            const isSelected = selectedDay ? isSameDay(day, selectedDay) : false
            return (
              <section
                key={dateKey(day)}
                className={cn(
                  // Stable height so empty ↔ busy weeks don't jump the layout.
                  'flex min-h-48 flex-col rounded-xl border border-border bg-card p-2 md:min-h-52',
                  isToday && 'ring-1 ring-primary/40',
                  isSelected && 'ring-2 ring-primary',
                )}
              >
                <div className="mb-2 flex shrink-0 items-center justify-between gap-1">
                  <button
                    type="button"
                    className="text-left"
                    onClick={() => onSelectDay?.(day)}
                  >
                    <p className="text-[10px] font-semibold uppercase text-muted-foreground">
                      {new Intl.DateTimeFormat(locale, { weekday: 'short' }).format(day)}
                    </p>
                    <p className={cn('text-sm font-bold', isToday && 'text-primary')}>
                      {day.getDate()}
                    </p>
                  </button>
                  {onDayAction && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      className="h-7 w-7"
                      onClick={() => onDayAction(day)}
                      aria-label={t('calendar.add', 'Afegir')}
                    >
                      <Plus className="h-3.5 w-3.5" />
                    </Button>
                  )}
                </div>
                <div className="min-h-0 flex-1 overflow-y-auto [@media(max-height:560px)]:max-h-40 md:max-h-none">
                  {renderDayEvents(day, false)}
                </div>
              </section>
            )
          })}
        </div>
      ) : (
        <div className="overflow-hidden rounded-xl border border-border">
          <div className="grid grid-cols-7 border-b border-border bg-muted/40">
            {weekDays.map((day) => (
              <div
                key={`h-${dateKey(day)}`}
                className="px-1 py-2 text-center text-[10px] font-semibold uppercase text-muted-foreground"
              >
                {new Intl.DateTimeFormat(locale, { weekday: 'short' }).format(day)}
              </div>
            ))}
          </div>
          <div className="grid grid-cols-7">
            {monthDays.map((day) => {
              const inMonth =
                day.getMonth() === anchor.getMonth() &&
                day.getFullYear() === anchor.getFullYear()
              const isToday = isSameDay(day, today)
              const dayEvents = eventsByDay.get(dateKey(day)) ?? []
              const visibleCards = dayEvents.slice(0, monthMaxCards)
              const overflow = dayEvents.length - visibleCards.length
              return (
                <div
                  key={dateKey(day)}
                  className={cn(
                    'border-b border-r border-border p-1',
                    monthDots ? 'min-h-14 sm:min-h-16' : 'min-h-24 p-1.5 md:min-h-28',
                    !inMonth && 'bg-muted/20 text-muted-foreground',
                    isToday && 'bg-primary/5',
                    dayEvents.length > 0 && 'cursor-pointer',
                  )}
                  onClick={() => {
                    if (dayEvents.length > 0) onSelectDay?.(day)
                  }}
                >
                  <div className="mb-0.5 flex items-center justify-between gap-0.5">
                    <button
                      type="button"
                      className={cn(
                        'flex h-6 w-6 items-center justify-center rounded-full text-xs',
                        isToday && 'bg-primary font-bold text-primary-foreground',
                      )}
                      onClick={(e) => {
                        e.stopPropagation()
                        onSelectDay?.(day)
                      }}
                    >
                      {day.getDate()}
                    </button>
                    {onDayAction && inMonth && !monthDots && (
                      <button
                        type="button"
                        className="rounded p-0.5 text-muted-foreground hover:bg-accent hover:text-foreground"
                        onClick={(e) => {
                          e.stopPropagation()
                          onDayAction(day)
                        }}
                        aria-label={t('calendar.add', 'Afegir')}
                      >
                        <Plus className="h-3 w-3" />
                      </button>
                    )}
                  </div>
                  {monthDots ? (
                    dayEvents.length > 0 && (
                      <div className="flex flex-wrap items-center gap-0.5 px-0.5">
                        {dayEvents.slice(0, 3).map((event) => (
                          <span
                            key={event.id}
                            className={cn(
                              'h-1.5 w-1.5 rounded-full',
                              !event.color && TONE_DOT[event.tone ?? 'default'],
                            )}
                            style={
                              event.color
                                ? { backgroundColor: resolveEventColor(event.color) }
                                : undefined
                            }
                            title={event.title}
                          />
                        ))}
                        {dayEvents.length > 3 && (
                          <span className="text-[9px] font-medium text-muted-foreground">
                            +{dayEvents.length - 3}
                          </span>
                        )}
                      </div>
                    )
                  ) : (
                    <div className="space-y-0.5">
                      {visibleCards.map((event) =>
                        renderEvent ? (
                          <div
                            key={event.id}
                            onClick={(e) => e.stopPropagation()}
                          >
                            {renderEvent(event)}
                          </div>
                        ) : (
                          <DefaultEventCard
                            key={event.id}
                            event={event}
                            allDayWhenMidnight={allDayWhenMidnight}
                            compact
                            onClick={() => onEventClick?.(event)}
                          />
                        ),
                      )}
                      {overflow > 0 && (
                        <p className="px-1 text-[10px] text-muted-foreground">+{overflow}</p>
                      )}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        </div>
      )}
    </div>
  )
}
