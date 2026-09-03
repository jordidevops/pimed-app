import { useState } from 'react'

import { Link } from 'react-router-dom'

import type { TFunction } from 'i18next'

import { AlertTriangle } from 'lucide-react'

import {

  computeArrivalStatus,

  formatPunchTime,

  hasNotPunchedToday,

  madridTodayIso,

  needsPauseResolution,

  punchTypeKey,

  resolvedWorkedMinutesToday,

  type TodayDashboardRow,

} from '../../api/todayDashboardService'

import { formatIntervalsList } from '../../api/workIntervals'

import { formatTimesheetMinutes } from '../../api/timesheetService'

import { ResolveOpenPauseDialog } from './ResolveOpenPauseDialog'

import { DashboardMap, DashboardMapPreview } from './DashboardMap'

import { employeeDashboardHref } from './DashboardLocationModal'

import { RecordsListActions } from '../records/RecordsListActions'

import {
  AttendanceDayDetailDialog,
  type DayDetailSelection,
} from '../records/AttendanceDayDetailDialog'

import {
  PunchDetailsDialog,
  type PunchDetailsSelection,
} from '../records/PunchDetailsDialog'

import { Badge } from '@/components/ui/badge'

import { Button } from '@/components/ui/button'

import { cn } from '@/lib/utils'

import {

  Table,

  TableBody,

  TableCell,

  TableHead,

  TableHeader,

  TableRow,

} from '@/components/ui/table'



const stateColors: Record<string, string> = {

  working: 'bg-emerald-100 text-emerald-800',

  on_pause: 'bg-amber-100 text-amber-800',

  outside: 'bg-slate-100 text-slate-600',

  unknown: 'bg-gray-100 text-gray-600',

}



const arrivalColors: Record<string, string> = {

  absent: 'bg-red-100 text-red-800',

  awaiting: 'bg-sky-100 text-sky-800',

  early: 'bg-violet-100 text-violet-800',

  on_time: 'bg-emerald-100 text-emerald-800',

  late: 'bg-orange-100 text-orange-800',

}



interface DashboardEmployeeListProps {

  rows: TodayDashboardRow[]

  view: 'table' | 'cards'

  t: TFunction

  overnightSuffix: string

  showMapAbove?: boolean

}



function WorkedTodayCell({ row, t }: { row: TodayDashboardRow; t: TFunction }) {
  const minutes = resolvedWorkedMinutesToday(row)
  if (minutes == null) return <span className="text-muted-foreground">—</span>
  return (
    <span className="font-medium tabular-nums text-foreground">
      {formatTimesheetMinutes(minutes)}
    </span>
  )
}



function LastPunchCell({ row, t }: { row: TodayDashboardRow; t: TFunction }) {

  if (!row.last_punch_at) return <span className="text-muted-foreground">—</span>

  const typeKey = punchTypeKey(row.last_punch_type)

  const typeLabel = typeKey

    ? t(`dashboard.punch_${typeKey}`, typeKey)

    : row.last_punch_type ?? '—'

  return (

    <div className="text-sm">

      <span className="font-medium tabular-nums">{formatPunchTime(row.last_punch_at)}</span>

      <span className="ml-1.5 text-xs text-muted-foreground">· {typeLabel}</span>

      {row.last_is_remote && (

        <span className="ml-1 text-[10px] uppercase text-muted-foreground">

          ({t('dashboard.remote', 'remot')})

        </span>

      )}

    </div>

  )

}



function StateBadgeLink({ row, t }: { row: TodayDashboardRow; t: TFunction }) {

  return (

    <Link to={employeeDashboardHref(row.employee_id)}>

      <Badge className={cn('hover:opacity-90', stateColors[row.current_state] ?? stateColors.unknown)}>

        {t(`control_horari.state.${row.current_state}`, row.current_state)}

      </Badge>

    </Link>

  )

}



function ArrivalBadge({ row, t }: { row: TodayDashboardRow; t: TFunction }) {

  if (hasNotPunchedToday(row)) {

    const status = computeArrivalStatus(row.expected_start, row.first_in_at)

    if (status === 'absent') {

      return (

        <Badge className={arrivalColors.absent}>

          {t('dashboard.arrival_absent', 'Absent')}

        </Badge>

      )

    }

    if (row.expected_start) {

      return (

        <Badge className={arrivalColors.awaiting}>

          {t('dashboard.arrival_awaiting', 'Entrada prevista {{time}}', { time: row.expected_start })}

        </Badge>

      )

    }

    return (

      <Badge className="bg-slate-100 text-slate-700">

        {t('dashboard.not_punched', 'Sense fitxar')}

      </Badge>

    )

  }



  const status = computeArrivalStatus(row.expected_start, row.first_in_at)

  if (status === 'early' || status === 'late' || status === 'on_time') {

    return (

      <Badge className={arrivalColors[status] ?? arrivalColors.on_time}>

        {t(`dashboard.arrival_${status}`, status)}

      </Badge>

    )

  }

  return (

    <Badge className={arrivalColors.on_time}>

      {t('dashboard.arrival_on_time', "A l'hora")}

    </Badge>

  )

}



function PauseResolutionAction({

  row,

  t,

  onResolve,

}: {

  row: TodayDashboardRow

  t: TFunction

  onResolve: (row: TodayDashboardRow) => void

}) {

  if (!needsPauseResolution(row)) return null

  return (

    <Button

      type="button"

      variant="outline"

      size="sm"

      className="h-8 border-amber-300 text-amber-900 hover:bg-amber-50"

      onClick={() => onResolve(row)}

    >

      <AlertTriangle className="mr-1.5 h-3.5 w-3.5" aria-hidden />

      {t('dashboard.resolve_pause_action', 'Resoldre pausa')}

    </Button>

  )

}



function hasPunchesToday(row: TodayDashboardRow): boolean {
  return Boolean(row.first_in_at || row.last_punch_at)
}



function DashboardRowActions({

  row,

  today,

  t,

  onOpenPunches,

  onOpenDay,

  onResolve,

}: {

  row: TodayDashboardRow

  today: string

  t: TFunction

  onOpenPunches: (selection: PunchDetailsSelection) => void

  onOpenDay: (selection: DayDetailSelection) => void

  onResolve: (row: TodayDashboardRow) => void

}) {

  return (

    <div className="flex flex-wrap items-center justify-end gap-0.5">

      <RecordsListActions

        punchCount={hasPunchesToday(row) ? 1 : 0}

        onOpenPunches={() =>

          onOpenPunches({

            employeeId: row.employee_id,

            employeeName: row.employee_name,

            workDate: today,

          })

        }

        onOpenDay={() =>

          onOpenDay({

            employeeId: row.employee_id,

            employeeName: row.employee_name,

            workDate: today,

          })

        }

      />

      <PauseResolutionAction row={row} t={t} onResolve={onResolve} />

    </div>

  )

}



export function DashboardEmployeeList({

  rows,

  view,

  t,

  overnightSuffix,

  showMapAbove = false,

}: DashboardEmployeeListProps) {

  const [resolveRow, setResolveRow] = useState<TodayDashboardRow | null>(null)

  const [punchSelection, setPunchSelection] = useState<PunchDetailsSelection | null>(null)

  const [detailSelection, setDetailSelection] = useState<DayDetailSelection | null>(null)

  const today = madridTodayIso()



  if (rows.length === 0) {

    return (

      <div className="rounded-xl border bg-muted/20 px-6 py-12 text-center text-sm text-muted-foreground">

        {t('dashboard.empty_scheduled', 'Cap empleat amb jornada programada avui')}

      </div>

    )

  }



  return (

    <>

      {view === 'cards' ? (

        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4">

          {rows.map((row) => (

            <article

              key={row.employee_id}

              className={cn(

                'rounded-xl border bg-card p-4 shadow-sm transition-shadow hover:shadow-md',

                needsPauseResolution(row) && 'border-amber-300 ring-1 ring-amber-200',

              )}

            >

              <div className="flex items-start justify-between gap-2">

                <div>

                  <Link

                    to={employeeDashboardHref(row.employee_id)}

                    className="font-semibold leading-tight text-foreground hover:text-primary hover:underline"

                  >

                    {row.employee_name}

                  </Link>

                  {row.work_intervals.length > 0 && (

                    <p className="mt-1 text-xs text-muted-foreground tabular-nums">

                      {formatIntervalsList(row.work_intervals, overnightSuffix)}

                    </p>

                  )}

                </div>

                <StateBadgeLink row={row} t={t} />

              </div>

              <div className="mt-3 flex flex-wrap gap-2">

                <ArrivalBadge row={row} t={t} />

                {(row.needs_review || (row.anomaly_codes?.length ?? 0) > 0) && (

                  <Link to={employeeDashboardHref(row.employee_id)}>

                    <Badge variant="outline" className="border-amber-300 text-amber-800 hover:bg-amber-50">

                      {t('dashboard.incident', 'Incidència')}

                    </Badge>

                  </Link>

                )}

              </div>

              <div className="mt-3 border-t pt-3">

                <p className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">

                  {t('dashboard.col_worked_today', 'Treballat avui')}

                </p>

                <WorkedTodayCell row={row} t={t} />

              </div>

              <div className="mt-3 border-t pt-3">

                <p className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">

                  {t('control_horari.col.last_punch', 'Darrer fitxatge')}

                </p>

                <LastPunchCell row={row} t={t} />

              </div>

              <div className="mt-3 border-t pt-3">

                <DashboardRowActions

                  row={row}

                  today={today}

                  t={t}

                  onOpenPunches={setPunchSelection}

                  onOpenDay={setDetailSelection}

                  onResolve={setResolveRow}

                />

              </div>

            </article>

          ))}

        </div>

      ) : (

        <div className="space-y-4">

          {showMapAbove && (

            <DashboardMap rows={rows} t={t} overnightSuffix={overnightSuffix} compact />

          )}

          <div className="overflow-hidden rounded-xl border">

            <Table>

              <TableHeader>

                <TableRow>

                  <TableHead>{t('control_horari.col.employee', 'Empleat')}</TableHead>

                  <TableHead>{t('dashboard.col_schedule', 'Horari')}</TableHead>

                  <TableHead>{t('dashboard.col_arrival', 'Entrada')}</TableHead>

                  <TableHead>{t('control_horari.col.state', 'Estat')}</TableHead>

                  <TableHead>{t('dashboard.col_worked_today', 'Treballat avui')}</TableHead>

                  <TableHead>{t('dashboard.col_location', 'Ubicació')}</TableHead>

                  <TableHead>{t('control_horari.col.last_punch', 'Darrer fitxatge')}</TableHead>

                  <TableHead className="min-w-[7.5rem]">{t('dashboard.col_actions', 'Accions')}</TableHead>

                </TableRow>

              </TableHeader>

              <TableBody>

                {rows.map((row) => (

                  <TableRow

                    key={row.employee_id}

                    className={needsPauseResolution(row) ? 'bg-amber-50/60' : undefined}

                  >

                    <TableCell className="font-medium">

                      <Link

                        to={employeeDashboardHref(row.employee_id)}

                        className="hover:text-primary hover:underline"

                      >

                        {row.employee_name}

                      </Link>

                    </TableCell>

                    <TableCell className="text-xs text-muted-foreground tabular-nums">

                      {row.work_intervals.length > 0

                        ? formatIntervalsList(row.work_intervals, overnightSuffix)

                        : '—'}

                    </TableCell>

                    <TableCell>

                      <ArrivalBadge row={row} t={t} />

                    </TableCell>

                    <TableCell>

                      <StateBadgeLink row={row} t={t} />

                    </TableCell>

                    <TableCell>

                      <WorkedTodayCell row={row} t={t} />

                    </TableCell>

                    <TableCell>

                      <DashboardMapPreview row={row} t={t} overnightSuffix={overnightSuffix} />

                    </TableCell>

                    <TableCell>

                      <LastPunchCell row={row} t={t} />

                    </TableCell>

                    <TableCell>

                      <DashboardRowActions

                        row={row}

                        today={today}

                        t={t}

                        onOpenPunches={setPunchSelection}

                        onOpenDay={setDetailSelection}

                        onResolve={setResolveRow}

                      />

                    </TableCell>

                  </TableRow>

                ))}

              </TableBody>

            </Table>

          </div>

        </div>

      )}



      <ResolveOpenPauseDialog

        row={resolveRow}

        open={resolveRow != null}

        onOpenChange={(open) => {

          if (!open) setResolveRow(null)

        }}

      />

      <PunchDetailsDialog

        selection={punchSelection}

        open={punchSelection != null}

        onOpenChange={(open) => {

          if (!open) setPunchSelection(null)

        }}

      />

      <AttendanceDayDetailDialog

        selection={detailSelection}

        open={detailSelection != null}

        onOpenChange={(open) => {

          if (!open) setDetailSelection(null)

        }}

      />

    </>

  )

}

