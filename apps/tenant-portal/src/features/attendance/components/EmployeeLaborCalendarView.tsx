/**
 * Calendari laboral resolt per a un empleat — vista any/mes compartida entre
 * /attendance/calendar (lectura + sol·licitud d'absències) i la pestanya d'empleat.
 */
import { useState, useEffect, useCallback, useRef, useMemo, type MouseEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight, CalendarDays, Loader2, Plus, ChevronDown, ChevronUp, CalendarClock } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { WeeklyRecurringBaseEditor } from './WeeklyRecurringBaseEditor'
import { useTenant } from '@/contexts/TenantContext'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import {
  useEmployeeCalendarData,
  useCalendarGroups,
  useUpsertLaborCalendarDays,
  sanitizeOptionalUuid,
  type TenantDayType,
} from '../api/useLaborCalendar'
import type { WorkInterval } from '../api/workIntervals'
import { useMyAbsences } from '../api/useAbsences'
import type { EmployeeAbsence } from '../api/shiftsService'
import { ScheduleFilterBar, useScheduleFilters } from './ScheduleFilterBar'
import { RequestAbsenceDialog } from './RequestAbsenceDialog'
import { formatSelectedDatesLabel } from './formatSelectedDates'
import {
  buildDayMap,
  DAY_STYLE,
  DayInspector,
  MonthMiniGrid,
  MonthFullGrid,
  CalendarEditSidebar,
  rectDateRange,
  allDatesInYear,
  allDatesInMonth,
  computePeriodStats,
  StatsSummary,
  type ResolvedDay,
} from './LaborCalendarGrid'

function rotateMonFirstLabels<T>(weekStartsOn: number, labelsMonFirst: T[]): T[] {
  const MON_FIRST_JS = [1, 2, 3, 4, 5, 6, 0]
  const order: number[] = []
  for (let i = 0; i < 7; i++) order.push((weekStartsOn + i) % 7)
  return order.map((jsDow) => {
    const idx = MON_FIRST_JS.indexOf(jsDow)
    return labelsMonFirst[idx]
  })
}

const ABSENCE_STATUS_RING: Record<string, string> = {
  approved: 'ring-2 ring-inset ring-violet-600',
  requested: 'ring-2 ring-inset ring-dashed ring-violet-400',
  rejected: 'ring-1 ring-inset ring-red-300 opacity-60',
  cancelled: 'opacity-50',
}

export interface EmployeeLaborCalendarViewProps {
  employeeId: string
  siteId?: string | null
  calendarGroupId?: string | null
  /** Permet editar overrides de l'empleat (pestanya admin). */
  canWrite?: boolean
  /** Mode empleat: selecció de dies → sol·licitud d'absència. */
  absenceRequestMode?: boolean
}

export function EmployeeLaborCalendarView({
  employeeId,
  siteId,
  calendarGroupId,
  canWrite = false,
  absenceRequestMode = false,
}: EmployeeLaborCalendarViewProps) {
  const { t } = useTranslation('attendance')
  const { activeTenant } = useTenant()
  const { dateFormat, weekStartsOn } = useCalendarDisplaySettings()
  const overnightSuffix = t('labor_cal.overnight_suffix', ' (+1)')

  const monthNames = t('labor_cal.months', { returnObjects: true }) as string[]
  const dowAbbrMonFirst = t('labor_cal.dow_abbr', { returnObjects: true }) as string[]
  const dowFullMonFirst = t('labor_cal.dow_full', { returnObjects: true }) as string[]
  const dowAbbrHeaders = useMemo(() => rotateMonFirstLabels(weekStartsOn, dowAbbrMonFirst), [weekStartsOn, dowAbbrMonFirst])
  const dowFullHeaders = useMemo(() => rotateMonFirstLabels(weekStartsOn, dowFullMonFirst), [weekStartsOn, dowFullMonFirst])

  const currentYear = new Date().getFullYear()
  const [year, setYear] = useState(currentYear)
  const [view, setView] = useState<'year' | 'month'>('year')
  const [month, setMonth] = useState(new Date().getMonth())
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [dragAnchor, setDragAnchor] = useState<string | null>(null)
  const [showAbsenceDialog, setShowAbsenceDialog] = useState(false)
  const isDragging = useRef(false)
  const didDrag = useRef(false)
  const panelRef = useRef<HTMLElement>(null)

  const tenantId = activeTenant?.id ?? null
  const { data: calendarGroups = [] } = useCalendarGroups(sanitizeOptionalUuid(siteId))
  const assignedGroup = calendarGroups.find((g) => g.id === calendarGroupId)
  const calendarGroupSiteId = assignedGroup?.site_id ?? null

  const { overrides, assignedHolidays, isLoading } = useEmployeeCalendarData(
    year, tenantId, siteId, employeeId, calendarGroupId,
  )

  const dayMap = useMemo(
    () => buildDayMap(
      year,
      overrides,
      assignedHolidays,
      siteId ?? null,
      calendarGroupId,
      employeeId,
      undefined,
      calendarGroupSiteId,
    ),
    [year, overrides, assignedHolidays, siteId, calendarGroupId, employeeId, calendarGroupSiteId],
  )

  const yearFrom = `${year}-01-01`
  const yearTo = `${year}-12-31`
  const { data: absences = [] } = useMyAbsences(
    absenceRequestMode ? employeeId : null,
    yearFrom,
    yearTo,
  )

  const absencesByDate = useMemo(() => {
    const map = new Map<string, EmployeeAbsence>()
    for (const a of absences) {
      if (!a.start_date || !a.end_date) continue
      const start = new Date(a.start_date + 'T00:00:00')
      const end = new Date(a.end_date + 'T00:00:00')
      const cur = new Date(start)
      while (cur <= end) {
        const key = cur.toISOString().slice(0, 10)
        if (!map.has(key)) map.set(key, a)
        cur.setDate(cur.getDate() + 1)
      }
    }
    return map
  }, [absences])

  const dayOverlayClass = useCallback((date: string) => {
    const abs = absencesByDate.get(date)
    if (!abs) return undefined
    return ABSENCE_STATUS_RING[abs.status ?? 'requested'] ?? ABSENCE_STATUS_RING.requested
  }, [absencesByDate])

  const { mutate: upsertDays, isPending: saving } = useUpsertLaborCalendarDays()
  const sf = useScheduleFilters(dayMap)

  useEffect(() => {
    const up = () => { isDragging.current = false }
    document.addEventListener('mouseup', up)
    document.addEventListener('touchend', up)
    return () => {
      document.removeEventListener('mouseup', up)
      document.removeEventListener('touchend', up)
    }
  }, [])

  const scrollToPanel = useCallback(() => {
    if (typeof window === 'undefined' || window.innerWidth >= 1280) return
    requestAnimationFrame(() => {
      panelRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })
    })
  }, [])

  const handleMouseDown = useCallback((date: string, e: MouseEvent) => {
    if (e.button !== 0) return
    const coarse = typeof window !== 'undefined' && window.matchMedia('(pointer: coarse)').matches
    if (coarse) return
    if (e.ctrlKey || e.metaKey) {
      e.preventDefault()
      isDragging.current = false
      didDrag.current = false
      setDragAnchor(null)
      setSelected((prev) => {
        const next = new Set(prev)
        if (next.has(date)) next.delete(date)
        else next.add(date)
        return next
      })
      return
    }
    isDragging.current = true
    didDrag.current = false
    setDragAnchor(date)
    setSelected(new Set([date]))
  }, [])

  const handleMouseEnter = useCallback((date: string) => {
    if (!isDragging.current || !dragAnchor || date === dragAnchor) return
    didDrag.current = true
    setSelected(new Set(rectDateRange(dragAnchor, date, weekStartsOn)))
  }, [dragAnchor, weekStartsOn])

  const handleDayClick = useCallback((date: string, e: MouseEvent) => {
    if (e.ctrlKey || e.metaKey) return
    if (didDrag.current) {
      didDrag.current = false
      return
    }
    const coarse = typeof window !== 'undefined' && window.matchMedia('(pointer: coarse)').matches
    if (!coarse) return
    e.preventDefault()
    setSelected(new Set([date]))
    setDragAnchor(null)
    isDragging.current = false
  }, [])

  const selectedDates = useMemo(() => [...selected].sort(), [selected])
  const selectedStates = useMemo(
    () => selectedDates.map((d) => dayMap.get(d)).filter((s): s is ResolvedDay => !!s),
    [selectedDates, dayMap],
  )
  const inspectedState = selectedDates.length === 1 ? dayMap.get(selectedDates[0]) : null
  const hasEmployeeOverride = selectedDates.length === 1 && !!inspectedState?.employeeOverride

  const yearStats = useMemo(() => computePeriodStats(dayMap, allDatesInYear(year)), [dayMap, year])
  const monthStats = useMemo(() => computePeriodStats(dayMap, allDatesInMonth(year, month)), [dayMap, year, month])
  const viewStats = view === 'year' ? yearStats : monthStats
  const monthLabel = monthNames[month] ?? String(month + 1)

  const selectionStart = selectedDates[0] ?? ''
  const selectionEnd = selectedDates[selectedDates.length - 1] ?? ''

  const selectionLabel = useMemo(
    () => formatSelectedDatesLabel(selectedDates, dateFormat, t),
    [selectedDates, dateFormat, t],
  )

  useEffect(() => {
    if (absenceRequestMode && selectedDates.length > 0) {
      scrollToPanel()
    }
  }, [absenceRequestMode, selectedDates.length, selectionStart, scrollToPanel])

  const gridCommon = {
    dayMap,
    selected,
    dragAnchor,
    weekStartsOn,
    dateFormat,
    onDayMouseDown: handleMouseDown,
    onDayMouseEnter: handleMouseEnter,
    onDayClick: handleDayClick,
    overnightSuffix,
    t,
    scheduleFilters: sf.filterState(),
    dayOverlayClass: absenceRequestMode ? dayOverlayClass : undefined,
  }

  function clearSelection() {
    setSelected(new Set())
    setDragAnchor(null)
  }

  function handleApplyEdit(params: { dayType: TenantDayType; dayName?: string; workIntervals?: WorkInterval[] }) {
    upsertDays({
      dates: selectedDates,
      dayType: params.dayType,
      dayName: params.dayName ?? null,
      workIntervals: params.workIntervals ?? null,
      siteId: null,
      employeeId,
    }, { onSuccess: clearSelection })
  }

  const yearAbsences = useMemo(
    () => absences.filter((a) => a.start_date && a.start_date <= yearTo && (a.end_date ?? '') >= yearFrom),
    [absences, yearFrom, yearTo],
  )

  return (
    <div className="select-none flex flex-col xl:flex-row gap-0 items-start w-full">
      <div className="flex-1 min-w-0 w-full space-y-4 xl:pr-4">
        {!siteId && (
          <p className="text-xs rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-amber-800">
            {t('calendar.no_site_notice', 'No tens un centre assignat. Es mostra el calendari general de l\'empresa.')}
          </p>
        )}

        {canWrite && !absenceRequestMode && (
          <WeeklyBaseSection employeeId={employeeId} />
        )}

        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="flex items-center gap-2 flex-wrap">
            <Button
              variant="outline"
              size="sm"
              className="h-8 w-8 p-0"
              onClick={() => (view === 'year' ? setYear((y) => y - 1) : month === 0 ? (setYear((y) => y - 1), setMonth(11)) : setMonth((m) => m - 1))}
            >
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <span className="min-w-[9rem] text-center text-sm font-semibold">
              {view === 'year' ? year : `${monthLabel} ${year}`}
            </span>
            <Button
              variant="outline"
              size="sm"
              className="h-8 w-8 p-0"
              onClick={() => (view === 'year' ? setYear((y) => y + 1) : month === 11 ? (setYear((y) => y + 1), setMonth(0)) : setMonth((m) => m + 1))}
            >
              <ChevronRight className="h-4 w-4" />
            </Button>
            <Button
              variant="outline"
              size="sm"
              className="h-8 text-xs"
              onClick={() => { setYear(currentYear); setMonth(new Date().getMonth()) }}
            >
              {t('labor_cal.today', 'Avui')}
            </Button>
            <StatsSummary stats={viewStats} t={t} />
          </div>
          <div className="flex items-center gap-2">
            <div className="flex rounded-md border p-0.5">
              {(['year', 'month'] as const).map((v) => (
                <button
                  key={v}
                  type="button"
                  className={`rounded px-3 py-1 text-xs font-medium ${view === v ? 'bg-primary text-primary-foreground' : 'hover:bg-accent'}`}
                  onClick={() => setView(v)}
                >
                  {v === 'year' ? t('labor_cal.view_year', 'Any') : t('labor_cal.view_month', 'Mes')}
                </button>
              ))}
            </div>
          </div>
        </div>

        <ScheduleFilterBar
          scheduleIndex={sf.scheduleIndex}
          hourBuckets={sf.hourBuckets}
          intervalFilterKey={sf.intervalFilterKey}
          hourFilter={sf.hourFilter}
          overnightSuffix={overnightSuffix}
          onClear={sf.clearFilters}
          onToggleInterval={sf.toggleIntervalFilter}
          onToggleHour={sf.toggleHourFilter}
        />

        <div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-muted-foreground">
          {(['work', 'holiday', 'vacation', 'undefined'] as const).map((type) => {
            const s = DAY_STYLE[type]
            return (
              <div key={type} className="flex items-center gap-2">
                <span className={`inline-block h-3.5 w-3.5 rounded-sm shrink-0 ${s.legendMark}`} aria-hidden />
                <span>{t(`labor_cal.type_${type}`, s.label)}</span>
              </div>
            )
          })}
          {absenceRequestMode && (
            <div className="flex items-center gap-2">
              <span className="inline-block h-3.5 w-3.5 rounded-sm shrink-0 ring-2 ring-inset ring-violet-600" aria-hidden />
              <span>{t('calendar.legend.absence', 'Absència sol·licitada')}</span>
            </div>
          )}
        </div>

        {isLoading ? (
          <div className="flex justify-center py-12">
            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
          </div>
        ) : view === 'year' ? (
          <div className="grid grid-cols-1 min-[480px]:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4 gap-3">
            {Array.from({ length: 12 }, (_, m) => {
              const mStats = computePeriodStats(dayMap, allDatesInMonth(year, m))
              return (
                <div key={m} className="rounded-lg border bg-card p-2 sm:p-3">
                  <div className="mb-1 flex items-center justify-between gap-1">
                    <div className="min-w-0">
                      <span className="text-xs font-semibold">{monthNames[m] ?? m + 1}</span>
                      <div className="mt-0.5">
                        <StatsSummary stats={mStats} compact t={t} />
                      </div>
                    </div>
                    <button
                      type="button"
                      className="text-muted-foreground hover:text-primary shrink-0 p-1"
                      onClick={() => { setMonth(m); setView('month') }}
                      title={t('labor_cal.view_month_btn', 'Veure mes')}
                    >
                      <CalendarDays className="h-3.5 w-3.5" />
                    </button>
                  </div>
                  <MonthMiniGrid year={year} month={m} compact dowAbbr={dowAbbrHeaders} dowFull={dowFullHeaders} {...gridCommon} />
                </div>
              )
            })}
          </div>
        ) : (
          <div className="rounded-lg border bg-card p-3 sm:p-4">
            <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
              <h3 className="text-sm font-semibold">{monthLabel} {year}</h3>
              <StatsSummary stats={monthStats} t={t} />
            </div>
            <MonthFullGrid year={year} month={month} dowAbbr={dowAbbrHeaders} {...gridCommon} />
          </div>
        )}

        {absenceRequestMode && (
          <div className="space-y-3 pt-2">
            <h2 className="text-base font-semibold">
              {t('calendar.my_absences_title', 'Les meves absències')}
            </h2>
            {yearAbsences.length === 0 ? (
              <p className="text-sm text-muted-foreground py-4 text-center border rounded-lg">
                {t('calendar.empty_absences_year', 'Cap absència registrada aquest any')}
              </p>
            ) : (
              <div className="flex flex-col gap-2">
                {yearAbsences.map((a) => (
                  <div key={a.id} className="border rounded-lg p-3 flex flex-wrap items-center gap-2 sm:gap-3">
                    <span className="text-sm font-medium">
                      {t(`absences.types.${a.absence_type ?? 'other'}`, a.absence_type ?? 'other')}
                    </span>
                    <span className="text-sm text-muted-foreground tabular-nums">
                      {a.start_date} → {a.end_date}
                    </span>
                    <span
                      className={`ml-auto text-xs px-2 py-0.5 rounded-full border font-medium ${
                        a.status === 'approved'
                          ? 'bg-green-100 text-green-800 border-green-200'
                          : a.status === 'rejected'
                          ? 'bg-red-100 text-red-800 border-red-200'
                          : 'bg-yellow-100 text-yellow-800 border-yellow-200'
                      }`}
                    >
                      {t(`absences.status.${a.status ?? 'requested'}`, a.status ?? 'requested')}
                    </span>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}

        {canWrite && calendarGroupId && (
          <p className="text-[11px] text-muted-foreground italic">
            {t('labor_cal.employee_cal_group_notice',
              'Les modificacions aquí afecten només aquest empleat. La resta de dies segueixen el calendari del grup, centre i empresa.')}
          </p>
        )}
      </div>

      {/* Panell lateral / inferior segons mode */}
      {canWrite && !absenceRequestMode ? (
        <CalendarEditSidebar
          count={selected.size}
          selectedDates={selectedDates}
          selectedStates={selectedStates}
          inspectedState={inspectedState}
          dateFormat={dateFormat}
          overnightSuffix={overnightSuffix}
          onApply={handleApplyEdit}
          onClear={clearSelection}
          isPending={saving}
          footerExtra={hasEmployeeOverride ? (
            <Button
              size="sm"
              variant="outline"
              disabled={saving}
              className="w-full h-8 text-xs text-destructive border-destructive/40 hover:bg-destructive/10"
              onClick={() => {
                upsertDays({
                  dates: selectedDates,
                  dayType: 'undefined',
                  dayName: null,
                  workIntervals: null,
                  siteId: null,
                  employeeId,
                }, { onSuccess: clearSelection })
              }}
            >
              {t('labor_cal.remove_override', "Eliminar override de l'empleat")}
            </Button>
          ) : undefined}
          t={t}
        />
      ) : absenceRequestMode ? (
        <aside
          ref={panelRef}
          className="w-full xl:w-80 shrink-0 border-t xl:border-t-0 xl:border-l bg-muted/15 flex flex-col xl:max-h-[calc(100vh-6rem)] xl:sticky xl:top-16 xl:self-start mt-4 xl:mt-0 scroll-mt-4"
        >
          <div className="px-4 py-3 border-b bg-background/80 shrink-0">
            <h3 className="text-sm font-semibold">
              {selectedDates.length >= 1
                ? selectionLabel
                : t('calendar.panel_title', 'Detall del dia')}
            </h3>
            {selectedDates.length === 0 && (
              <p className="text-[11px] text-muted-foreground mt-1">
                {t('calendar.panel_hint', 'Toca un dia per veure el detall. Arrossega per un període consecutiu. Ctrl+clic per afegir dies no consecutius.')}
              </p>
            )}
          </div>
          <div className="flex-1 min-h-0 overflow-y-auto p-4 space-y-4">
            {selectedDates.length === 0 ? (
              <p className="text-xs text-muted-foreground">
                {t('calendar.panel_empty', 'Selecciona un o més dies al calendari per veure l\'horari o sol·licitar una absència.')}
              </p>
            ) : (
              <>
                {inspectedState && selectedDates.length === 1 && (
                  <DayInspector
                    state={inspectedState}
                    dateFormat={dateFormat}
                    overnightSuffix={overnightSuffix}
                    hideCascade
                    hideSelectedTitle
                    t={t}
                  />
                )}
                {selectedDates.length > 1 && (
                  <p className="text-xs text-muted-foreground rounded-md border bg-muted/30 px-3 py-2">
                    {t('calendar.multi_day_hint', 'Selecciona un sol dia per veure l\'horari detallat.')}
                  </p>
                )}
              </>
            )}
          </div>
          {selectedDates.length > 0 && (
            <div className="shrink-0 border-t bg-background p-4 flex flex-col sm:flex-row xl:flex-col gap-2">
              <Button size="sm" variant="outline" onClick={clearSelection} className="flex-1 h-9">
                {t('labor_cal.cancel', 'Cancel·lar')}
              </Button>
              <Button size="sm" className="flex-1 h-9 gap-1" onClick={() => setShowAbsenceDialog(true)}>
                <Plus className="h-3.5 w-3.5" />
                {t('calendar.request_absence', 'Sol·licitar absència')}
              </Button>
            </div>
          )}
        </aside>
      ) : null}

      {showAbsenceDialog && (
        <RequestAbsenceDialog
          employeeId={employeeId}
          initialStartDate={selectionStart}
          initialEndDate={selectionEnd}
          onClose={() => {
            setShowAbsenceDialog(false)
            clearSelection()
          }}
        />
      )}
    </div>
  )
}

// ─── Base recurrent setmanal (ADR-0003) ──────────────────────────────────────

function WeeklyBaseSection({ employeeId }: { employeeId: string }) {
  const { t } = useTranslation('attendance')
  const [open, setOpen] = useState(false)

  return (
    <div className="rounded-lg border">
      <button
        type="button"
        className="w-full flex items-center justify-between gap-2 px-3 py-2.5 text-left"
        onClick={() => setOpen((o) => !o)}
      >
        <span className="flex items-center gap-2 text-sm font-semibold">
          <CalendarClock className="h-4 w-4" />
          {t('weekly_base.employee_title', "Patró setmanal individual")}
        </span>
        {open ? <ChevronUp className="h-4 w-4 shrink-0" /> : <ChevronDown className="h-4 w-4 shrink-0" />}
      </button>
      {open && (
        <div className="px-3 pb-3 space-y-3">
          <p className="text-[11px] text-muted-foreground">
            {t(
              'weekly_base.employee_hint',
              "Override recurrent per aquest empleat: per sobre del patró del grup, per sota dels overrides puntuals d'un dia concret.",
            )}
          </p>
          <WeeklyRecurringBaseEditor mode="employee" entityId={employeeId} />
        </div>
      )}
    </div>
  )
}
