import { useEffect, useMemo, useRef, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import {
  addDays,
  dateKey,
  formatShortRange,
  isSameDay,
  startOfDay,
  startOfWeek,
  endOfWeek,
  toUiLocale,
} from './calendarDateUtils'
import { resolveEventColor } from './projectEventsOntoDays'
import type { CalendarGridEvent } from './CalendarGrid'
import {
  DEFAULT_SCROLL_HOUR,
  SLOT_HEIGHT_PX,
  SLOT_MINUTES,
  SLOTS_PER_DAY,
  dateAtMinutes,
  isAllDayEvent,
  layoutTimedEventsForDay,
  slotLabel,
} from './calendarTimeGridLayout'

export type CalendarTimeGridView = 'day' | 'week'

export type CalendarTimeGridProps = {
  view: CalendarTimeGridView
  anchor: Date
  onAnchorChange: (next: Date) => void
  events: CalendarGridEvent[]
  weekStartsOn?: number
  onEventClick?: (event: CalendarGridEvent) => void
  /** Timed slot click — `start` is the slot start; default duration is 30 min. */
  onSlotClick?: (start: Date) => void
  /** All-day row click for a day (create all-day). */
  onAllDayClick?: (day: Date) => void
  onSelectDay?: (day: Date) => void
  allDayLabel?: string
  className?: string
  notice?: ReactNode
}

function eventById(events: CalendarGridEvent[], id: string): CalendarGridEvent | undefined {
  return events.find((e) => e.id === id)
}

export function CalendarTimeGrid({
  view,
  anchor,
  onAnchorChange,
  events,
  weekStartsOn = 1,
  onEventClick,
  onSlotClick,
  onAllDayClick,
  onSelectDay,
  allDayLabel,
  className,
  notice,
}: CalendarTimeGridProps) {
  const { t, i18n } = useTranslation('calendar')
  const locale = toUiLocale(i18n.resolvedLanguage)
  const scrollRef = useRef<HTMLDivElement>(null)
  const today = startOfDay(new Date())

  const weekStart = startOfWeek(anchor, weekStartsOn)
  const days = useMemo(() => {
    if (view === 'day') return [startOfDay(anchor)]
    return Array.from({ length: 7 }, (_, i) => addDays(weekStart, i))
  }, [view, anchor, weekStart])

  const resolvedAllDayLabel = allDayLabel ?? t('calendar.all_day', 'Tot el dia')
  const periodLabel =
    view === 'day'
      ? new Intl.DateTimeFormat(locale, {
          weekday: 'long',
          day: 'numeric',
          month: 'long',
        }).format(startOfDay(anchor))
      : formatShortRange(weekStart, endOfWeek(anchor, weekStartsOn), locale)

  useEffect(() => {
    const el = scrollRef.current
    if (!el) return
    el.scrollTop = DEFAULT_SCROLL_HOUR * 60 * (SLOT_HEIGHT_PX / SLOT_MINUTES)
  }, [view, dateKey(days[0] ?? today)])

  function goPrev() {
    onAnchorChange(addDays(startOfDay(anchor), view === 'day' ? -1 : -7))
  }

  function goNext() {
    onAnchorChange(addDays(startOfDay(anchor), view === 'day' ? 1 : 7))
  }

  function goToday() {
    onAnchorChange(today)
    onSelectDay?.(today)
  }

  const gutterWidth = '3.5rem'

  return (
    <div className={cn('space-y-3', className)} data-testid="calendar-time-grid">
      <div className="flex flex-wrap items-center gap-2">
        <Button type="button" variant="outline" size="sm" onClick={goToday}>
          {t('calendar.today', 'Avui')}
        </Button>
        <div className="flex items-center gap-1">
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="h-8 w-8"
            onClick={goPrev}
            aria-label={t('calendar.prev', 'Anterior')}
          >
            <ChevronLeft className="h-4 w-4" />
          </Button>
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="h-8 w-8"
            onClick={goNext}
            aria-label={t('calendar.next', 'Següent')}
          >
            <ChevronRight className="h-4 w-4" />
          </Button>
        </div>
        <p className="text-sm font-semibold capitalize">{periodLabel}</p>
        <div className="flex min-h-5 min-w-0 flex-1 items-center sm:justify-end">
          {notice ? <p className="text-sm text-muted-foreground">{notice}</p> : null}
        </div>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <div
          className="min-w-[320px]"
          style={{
            ['--tg-cols' as string]: days.length,
            ['--tg-gutter' as string]: gutterWidth,
          }}
        >
          {/* Day headers */}
          <div
            className="grid border-b border-border"
            style={{
              gridTemplateColumns: `${gutterWidth} repeat(${days.length}, minmax(0, 1fr))`,
            }}
          >
            <div className="border-r border-border" />
            {days.map((day) => {
              const isToday = isSameDay(day, today)
              return (
                <button
                  key={dateKey(day)}
                  type="button"
                  onClick={() => onSelectDay?.(day)}
                  className={cn(
                    'flex flex-col items-center gap-0.5 px-1 py-2 text-center hover:bg-muted/40',
                    isToday && 'bg-primary/5',
                  )}
                >
                  <span className="text-[10px] font-semibold uppercase text-muted-foreground">
                    {new Intl.DateTimeFormat(locale, { weekday: 'short' }).format(day)}
                  </span>
                  <span
                    className={cn(
                      'flex h-7 w-7 items-center justify-center rounded-full text-sm font-bold',
                      isToday && 'bg-primary text-primary-foreground',
                    )}
                  >
                    {day.getDate()}
                  </span>
                </button>
              )
            })}
          </div>

          {/* All-day row */}
          <div
            className="grid border-b border-border"
            style={{
              gridTemplateColumns: `${gutterWidth} repeat(${days.length}, minmax(0, 1fr))`,
            }}
          >
            <div className="flex items-start justify-end border-r border-border px-1 py-1.5 text-[10px] font-medium text-muted-foreground">
              {resolvedAllDayLabel}
            </div>
            {days.map((day) => {
              const allDayEvents = events.filter(
                (e) =>
                  isAllDayEvent(e) &&
                  // visible on this day via start/end span (inclusive start, exclusive midnight end)
                  (() => {
                    const start = startOfDay(new Date(e.start))
                    const endRaw = e.end != null ? new Date(e.end) : null
                    const last = endRaw
                      ? isMidnightLocal(endRaw)
                        ? addDays(startOfDay(endRaw), -1)
                        : startOfDay(endRaw)
                      : start
                    const d = startOfDay(day)
                    return d >= start && d <= last
                  })(),
              )
              return (
                <div
                  key={`allday-${dateKey(day)}`}
                  className="min-h-10 space-y-0.5 border-r border-border px-0.5 py-1 last:border-r-0"
                >
                  {allDayEvents.map((event) => (
                    <button
                      key={event.id}
                      type="button"
                      onClick={(ev) => {
                        ev.stopPropagation()
                        onEventClick?.(event)
                      }}
                      className={cn(
                        'block w-full truncate rounded px-1.5 py-0.5 text-left text-[11px] font-medium text-white hover:opacity-90',
                        event.dimmed && 'opacity-60',
                      )}
                      style={{ backgroundColor: resolveEventColor(event.color) }}
                      title={event.title}
                    >
                      {event.title}
                    </button>
                  ))}
                  {onAllDayClick || onSlotClick ? (
                    <button
                      type="button"
                      className="block h-5 w-full rounded hover:bg-muted/50"
                      aria-label={t('calendar.page.addAllDay', 'Afegir event de tot el dia')}
                      onClick={() => (onAllDayClick ?? onSlotClick)?.(startOfDay(day))}
                    />
                  ) : null}
                </div>
              )
            })}
          </div>

          {/* Timed grid */}
          <div
            ref={scrollRef}
            className="max-h-[min(70vh,40rem)] overflow-y-auto"
          >
            <div
              className="grid"
              style={{
                gridTemplateColumns: `${gutterWidth} repeat(${days.length}, minmax(0, 1fr))`,
              }}
            >
              {/* Time gutter */}
              <div className="relative border-r border-border">
                {Array.from({ length: SLOTS_PER_DAY }, (_, i) => {
                  const label = slotLabel(i, locale)
                  return (
                    <div
                      key={i}
                      className="relative border-b border-border/40"
                      style={{ height: SLOT_HEIGHT_PX }}
                    >
                      {label ? (
                        <span className="absolute -top-2 right-1 text-[10px] tabular-nums text-muted-foreground">
                          {label}
                        </span>
                      ) : null}
                    </div>
                  )
                })}
              </div>

              {/* Day columns */}
              {days.map((day) => {
                const timed = events.filter((e) => !isAllDayEvent(e))
                const layout = layoutTimedEventsForDay(timed, day)
                const isToday = isSameDay(day, today)
                return (
                  <div
                    key={`timed-${dateKey(day)}`}
                    className={cn(
                      'relative border-r border-border last:border-r-0',
                      isToday && 'bg-primary/[0.03]',
                    )}
                    style={{ height: SLOTS_PER_DAY * SLOT_HEIGHT_PX }}
                  >
                    {Array.from({ length: SLOTS_PER_DAY }, (_, i) => (
                      <button
                        key={i}
                        type="button"
                        className={cn(
                          'absolute inset-x-0 w-full border-b border-border/40 hover:bg-accent/40',
                          i % 2 === 1 && 'border-border/20',
                        )}
                        style={{ top: i * SLOT_HEIGHT_PX, height: SLOT_HEIGHT_PX }}
                        aria-label={t('calendar.page.addAtTime', 'Afegir event a {{time}}', {
                          time: dateAtMinutes(day, i * SLOT_MINUTES).toLocaleTimeString(locale, {
                            hour: '2-digit',
                            minute: '2-digit',
                          }),
                        })}
                        onClick={() => onSlotClick?.(dateAtMinutes(day, i * SLOT_MINUTES))}
                      />
                    ))}

                    {layout.map((rect) => {
                      const event = eventById(events, rect.id)
                      if (!event) return null
                      const top = (rect.startMin / SLOT_MINUTES) * SLOT_HEIGHT_PX
                      const height = Math.max(
                        SLOT_HEIGHT_PX / 2,
                        ((rect.endMin - rect.startMin) / SLOT_MINUTES) * SLOT_HEIGHT_PX - 1,
                      )
                      const widthPct = 100 / rect.columnCount
                      const leftPct = rect.column * widthPct
                      return (
                        <button
                          key={rect.id}
                          type="button"
                          className={cn(
                            'absolute z-[1] overflow-hidden rounded px-1 py-0.5 text-left text-[11px] font-medium text-white shadow-sm hover:opacity-95',
                            event.dimmed && 'opacity-60',
                          )}
                          style={{
                            top,
                            height,
                            left: `calc(${leftPct}% + 1px)`,
                            width: `calc(${widthPct}% - 3px)`,
                            backgroundColor: resolveEventColor(event.color),
                          }}
                          title={event.title}
                          onClick={(e) => {
                            e.stopPropagation()
                            onEventClick?.(event)
                          }}
                        >
                          <span className="block truncate">{event.title}</span>
                          {height >= SLOT_HEIGHT_PX && (
                            <span className="block truncate text-[10px] opacity-90">
                              {new Date(event.start).toLocaleTimeString(locale, {
                                hour: '2-digit',
                                minute: '2-digit',
                              })}
                            </span>
                          )}
                        </button>
                      )
                    })}
                  </div>
                )
              })}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
