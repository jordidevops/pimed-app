import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import {
  flexRender,
  getCoreRowModel,
  useReactTable,
  type ColumnDef,
} from '@tanstack/react-table'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { cn } from '@/lib/utils'
import type { PlannerActualRecord, PlannerGridRow } from '../../api/schedulePlannerService'
import { detectDiscrepancy } from '../../api/schedulePlannerFilters'
import { ScheduleEmployeeLabel } from './ScheduleEmployeeLabel'
import { ScheduleDayCell, type ScheduleCellVariant } from './ScheduleDayCell'
import type { PlannerDataMode } from './SchedulePlannerToolbar'

interface SchedulePlannerGridProps {
  rows: PlannerGridRow[]
  dates: string[]
  isLoading?: boolean
  cellVariant?: ScheduleCellVariant
  dataMode?: PlannerDataMode
  actuals?: Map<string, PlannerActualRecord>
}

function dayHeaderLabel(isoDate: string, dowAbbr: string[]): string {
  const d = new Date(`${isoDate}T12:00:00`)
  const dow = dowAbbr[(d.getDay() + 6) % 7] ?? ''
  const day = isoDate.slice(8, 10)
  return `${dow}\n${day}`
}

export function SchedulePlannerGrid({
  rows,
  dates,
  isLoading,
  cellVariant = 'compact',
  dataMode = 'planned',
  actuals,
}: SchedulePlannerGridProps) {
  const { t } = useTranslation('attendance')
  const { dateFormat } = useCalendarDisplaySettings()
  const overnightSuffix = t('labor_cal.overnight_suffix', ' (+1)')
  const dowAbbr = t('labor_cal.dow_abbr', { returnObjects: true }) as string[]

  const colSize = cellVariant === 'expanded' ? 96 : 40

  const columns = useMemo<ColumnDef<PlannerGridRow>[]>(() => {
    const dayCols: ColumnDef<PlannerGridRow>[] = dates.map((date) => ({
      id: date,
      header: () => (
        <span className="whitespace-pre text-center text-[10px] font-medium leading-tight tabular-nums">
          {dayHeaderLabel(date, Array.isArray(dowAbbr) ? dowAbbr : [])}
        </span>
      ),
      cell: ({ row }) => {
        const planned = row.original.days[date]
        const actual = row.original.employeeId && actuals
          ? actuals.get(`${row.original.employeeId}|${date}`)
          : undefined
        const actualsLoaded = actuals !== undefined
        const discrepancy = actualsLoaded && row.original.scope === 'employee'
          ? detectDiscrepancy(planned, actual, undefined, true)
          : null

        return (
          <ScheduleDayCell
            state={planned}
            variant={cellVariant}
            dataMode={dataMode}
            actual={actual}
            discrepancy={discrepancy}
            dateFormat={dateFormat}
            overnightSuffix={overnightSuffix}
            t={t}
            isReference={row.original.scope !== 'employee'}
          />
        )
      },
      size: colSize,
    }))

    return [
      {
        id: 'employee',
        accessorKey: 'label',
        header: () => t('schedule_planner.col_employee', 'Empleat / referència'),
        cell: ({ row }) => <ScheduleEmployeeLabel row={row.original} fillCell />,
        size: 180,
      },
      ...dayCols,
    ]
  }, [dates, dateFormat, dowAbbr, overnightSuffix, t, cellVariant, dataMode, actuals, colSize])

  const table = useReactTable({
    data: rows,
    columns,
    getCoreRowModel: getCoreRowModel(),
    initialState: {
      columnPinning: { left: ['employee'] },
    },
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

  return (
    <div className="overflow-x-auto rounded-md border">
      <Table className="min-w-max border-collapse text-xs">
        <TableHeader>
          {table.getHeaderGroups().map((hg) => (
            <TableRow key={hg.id}>
              {hg.headers.map((header) => {
                const pinned = header.column.getIsPinned()
                return (
                  <TableHead
                    key={header.id}
                    className={cn(
                      'h-10 px-1 py-1',
                      pinned === 'left' && 'sticky left-0 z-20 bg-background shadow-[2px_0_4px_-2px_rgba(0,0,0,0.1)]',
                      header.id === 'employee' && 'min-w-[160px]',
                    )}
                    style={{ width: header.getSize() }}
                  >
                    {flexRender(header.column.columnDef.header, header.getContext())}
                  </TableHead>
                )
              })}
            </TableRow>
          ))}
        </TableHeader>
        <TableBody>
          {table.getRowModel().rows.map((row) => {
            const isGroup = row.original.scope === 'group'
            return (
            <TableRow
              key={row.id}
              className={cn(
                row.original.scope !== 'employee' && !isGroup && 'bg-muted/30',
                isGroup && 'bg-muted/50 hover:bg-muted/50',
              )}
            >
              {row.getVisibleCells().map((cell, cellIdx) => {
                const pinned = cell.column.getIsPinned()
                if (isGroup && cellIdx > 0) return null
                return (
                  <TableCell
                    key={cell.id}
                    colSpan={isGroup && cellIdx === 0 ? dates.length + 1 : undefined}
                    className={cn(
                      'px-1 py-1 align-top',
                      pinned === 'left' && 'sticky left-0 z-10 bg-background shadow-[2px_0_4px_-2px_rgba(0,0,0,0.1)]',
                      row.original.scope !== 'employee' && !isGroup && pinned === 'left' && 'bg-muted/30',
                      isGroup && pinned === 'left' && 'bg-muted/50',
                      pinned === 'left' && row.original.scope === 'employee' && 'group/cell',
                    )}
                  >
                    {flexRender(cell.column.columnDef.cell, cell.getContext())}
                  </TableCell>
                )
              })}
            </TableRow>
            )
          })}
        </TableBody>
      </Table>
    </div>
  )
}
