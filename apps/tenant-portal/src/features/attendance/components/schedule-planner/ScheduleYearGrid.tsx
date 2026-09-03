import { useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { useVirtualizer } from '@tanstack/react-virtual'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { cn } from '@/lib/utils'
import type { PlannerActualRecord, PlannerGridRow } from '../../api/schedulePlannerService'
import { ScheduleEmployeeLabel } from './ScheduleEmployeeLabel'
import { ScheduleMonthMiniBlock } from './ScheduleMonthMiniBlock'

const VIRTUALIZE_THRESHOLD = 50
const ROW_HEIGHT_ESTIMATE = 80

interface ScheduleYearGridProps {
  year: number
  rows: PlannerGridRow[]
  isLoading?: boolean
  actuals?: Map<string, PlannerActualRecord>
  onMonthClick?: (month: number) => void
}

function YearGridRow({
  row,
  year,
  weekStartsOn,
  actuals,
}: {
  row: PlannerGridRow
  year: number
  weekStartsOn: number
  actuals?: Map<string, PlannerActualRecord>
}) {
  return (
    <TableRow className={cn(row.scope !== 'employee' && 'bg-muted/30')}>
      <TableCell
        className={cn(
          'sticky left-0 z-10 min-w-[160px] max-w-[220px] bg-background px-2 py-1 shadow-[2px_0_4px_-2px_rgba(0,0,0,0.1)]',
          row.scope !== 'employee' && 'bg-muted/30',
        )}
      >
        <ScheduleEmployeeLabel row={row} />
      </TableCell>
      {Array.from({ length: 12 }, (_, month) => (
        <TableCell key={month} className="px-1 py-1 align-top">
          <ScheduleMonthMiniBlock
            year={year}
            month={month}
            weekStartsOn={weekStartsOn}
            days={row.days}
            employeeId={row.employeeId}
            actuals={actuals}
            isReference={row.scope !== 'employee'}
          />
        </TableCell>
      ))}
    </TableRow>
  )
}

export function ScheduleYearGrid({
  year,
  rows,
  isLoading,
  actuals,
  onMonthClick,
}: ScheduleYearGridProps) {
  const { t } = useTranslation('attendance')
  const { weekStartsOn } = useCalendarDisplaySettings()
  const scrollRef = useRef<HTMLDivElement>(null)
  const months = t('labor_cal.months', { returnObjects: true }) as string[]
  const monthLabels = Array.isArray(months) ? months : []

  const useVirtual = rows.length > VIRTUALIZE_THRESHOLD

  const rowVirtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => ROW_HEIGHT_ESTIMATE,
    overscan: 5,
  })

  if (isLoading) {
    return (
      <div className="flex h-48 items-center justify-center text-sm text-muted-foreground">
        {t('schedule_planner.loading', 'Carregant horaris…')}
      </div>
    )
  }

  if (rows.length === 0) {
    return (
      <div className="flex h-48 items-center justify-center text-sm text-muted-foreground">
        {t('schedule_planner.empty', 'No hi ha dades per aquest període')}
      </div>
    )
  }

  const virtualItems = useVirtual ? rowVirtualizer.getVirtualItems() : null
  const paddingTop = virtualItems && virtualItems.length > 0 ? virtualItems[0].start : 0
  const paddingBottom = virtualItems && virtualItems.length > 0
    ? rowVirtualizer.getTotalSize() - virtualItems[virtualItems.length - 1].end
    : 0

  return (
    <div
      ref={scrollRef}
      className={cn('overflow-auto rounded-md border', useVirtual && 'max-h-[70vh]')}
    >
      <Table className="min-w-max border-collapse text-xs">
        <TableHeader className="sticky top-0 z-20 bg-background">
          <TableRow>
            <TableHead className="sticky left-0 z-30 min-w-[160px] bg-background px-2 shadow-[2px_0_4px_-2px_rgba(0,0,0,0.1)]">
              {t('schedule_planner.col_employee', 'Empleat / referència')}
            </TableHead>
            {monthLabels.map((label, month) => (
              <TableHead key={month} className="min-w-[88px] px-1 text-center">
                {onMonthClick ? (
                  <button
                    type="button"
                    className="w-full rounded px-1 py-0.5 text-[10px] font-semibold hover:bg-accent hover:text-accent-foreground"
                    onClick={() => onMonthClick(month)}
                    title={t('schedule_planner.open_month', 'Obrir vista mensual')}
                  >
                    {label}
                  </button>
                ) : (
                  <span className="text-[10px] font-semibold">{label}</span>
                )}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {useVirtual && paddingTop > 0 && (
            <TableRow style={{ height: paddingTop }} aria-hidden>
              <TableCell colSpan={13} className="p-0" />
            </TableRow>
          )}
          {(useVirtual ? virtualItems! : rows.map((_, i) => ({ index: i }))).map((item) => {
            const row = rows[item.index]
            return (
              <YearGridRow
                key={row.id}
                row={row}
                year={year}
                weekStartsOn={weekStartsOn}
                actuals={actuals}
              />
            )
          })}
          {useVirtual && paddingBottom > 0 && (
            <TableRow style={{ height: paddingBottom }} aria-hidden>
              <TableCell colSpan={13} className="p-0" />
            </TableRow>
          )}
        </TableBody>
      </Table>
    </div>
  )
}
