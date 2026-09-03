import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { AlertTriangle, MapPin } from 'lucide-react'
import { formatTimesheetMinutes } from '../../api/timesheetService'
import type { LocationWorkSummaryRow } from '../../utils/locationWorkSummary'
import { Badge } from '@/components/ui/badge'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'

export interface LocationWorkSummaryTableProps {
  rows: LocationWorkSummaryRow[]
}

function SummaryTotals({ rows }: { rows: LocationWorkSummaryRow[] }) {
  const { t } = useTranslation('attendance')
  const totals = useMemo(() => {
    const byLocation = new Map<string, number>()
    let grandTotal = 0
    let openIntervals = 0
    for (const row of rows) {
      byLocation.set(row.location_name, (byLocation.get(row.location_name) ?? 0) + row.work_minutes)
      grandTotal += row.work_minutes
      openIntervals += row.open_interval_count
    }
    return {
      byLocation: [...byLocation.entries()].sort((a, b) => a[0].localeCompare(b[0], 'ca')),
      grandTotal,
      openIntervals,
    }
  }, [rows])

  if (rows.length === 0) return null

  return (
    <div className="grid gap-3 sm:grid-cols-2">
      <div className="rounded-lg border bg-muted/20 p-3">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('location_summary.total_by_location', 'Total per ubicació')}
        </p>
        <ul className="mt-2 space-y-1 text-sm">
          {totals.byLocation.map(([name, minutes]) => (
            <li key={name} className="flex items-center justify-between gap-2">
              <span className="truncate">{name}</span>
              <span className="font-medium tabular-nums">{formatTimesheetMinutes(minutes)}</span>
            </li>
          ))}
        </ul>
      </div>
      <div className="rounded-lg border p-3">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('location_summary.grand_total', 'Total del període')}
        </p>
        <p className="mt-2 text-2xl font-semibold tabular-nums">
          {formatTimesheetMinutes(totals.grandTotal)}
        </p>
        {totals.openIntervals > 0 ? (
          <p className="mt-1 flex items-center gap-1 text-xs text-amber-700">
            <AlertTriangle className="h-3.5 w-3.5 shrink-0" aria-hidden />
            {t(
              'location_summary.open_intervals_hint',
              '{{count}} interval(s) obert(s) sense sortida — no comptats als minuts',
              { count: totals.openIntervals },
            )}
          </p>
        ) : null}
      </div>
    </div>
  )
}

export function LocationWorkSummaryTable({ rows }: LocationWorkSummaryTableProps) {
  const { t } = useTranslation('attendance')

  if (rows.length === 0) {
    return (
      <div className="rounded-lg border py-12 text-center text-sm text-muted-foreground">
        {t('location_summary.empty', 'Cap temps registrat per ubicació en aquest període')}
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <SummaryTotals rows={rows} />
      <div className="overflow-hidden rounded-xl border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>{t('admin.col_employee', 'Empleat/da')}</TableHead>
              <TableHead>{t('punch_export.col_location', 'Ubicació')}</TableHead>
              <TableHead className="text-right">{t('location_summary.col_worked', 'Treballat')}</TableHead>
              <TableHead className="text-right">{t('location_summary.col_intervals', 'Intervals')}</TableHead>
              <TableHead className="text-right">{t('location_summary.col_open', 'Oberts')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={`${row.employee_id}-${row.location_id ?? 'none'}`}>
                <TableCell className="font-medium">{row.employee_name}</TableCell>
                <TableCell>
                  <span className="inline-flex items-center gap-1.5">
                    <MapPin className="h-3.5 w-3.5 text-muted-foreground" aria-hidden />
                    {row.location_name}
                  </span>
                </TableCell>
                <TableCell className="text-right font-medium tabular-nums">
                  {formatTimesheetMinutes(row.work_minutes)}
                </TableCell>
                <TableCell className="text-right tabular-nums text-muted-foreground">
                  {row.interval_count}
                </TableCell>
                <TableCell className="text-right">
                  {row.open_interval_count > 0 ? (
                    <Badge variant="outline" className="tabular-nums">
                      {row.open_interval_count}
                    </Badge>
                  ) : (
                    <span className="text-muted-foreground">0</span>
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  )
}
