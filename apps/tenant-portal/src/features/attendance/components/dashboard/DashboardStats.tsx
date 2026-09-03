import { Link } from 'react-router-dom'
import type { TFunction } from 'i18next'
import { AlertTriangle, Clock, LogIn, PauseCircle, UserCheck, UserX, Users } from 'lucide-react'
import { cn } from '@/lib/utils'
import type { TodayDashboardRow } from '../../api/todayDashboardService'
import { computeArrivalStatus, hasNotPunchedToday } from '../../api/todayDashboardService'
import { employeeDashboardHref } from './DashboardLocationModal'

interface DashboardStatsProps {
  rows: TodayDashboardRow[]
  t: TFunction
}

export function DashboardStats({ rows, t }: DashboardStatsProps) {
  const working = rows.filter((r) => r.current_state === 'working').length
  const onPause = rows.filter((r) => r.current_state === 'on_pause').length
  const notPunched = rows.filter((r) => hasNotPunchedToday(r)).length
  const awaiting = rows.filter(
    (r) => hasNotPunchedToday(r) && computeArrivalStatus(r.expected_start, r.first_in_at) === 'awaiting',
  ).length
  const absent = rows.filter(
    (r) => hasNotPunchedToday(r) && computeArrivalStatus(r.expected_start, r.first_in_at) === 'absent',
  ).length
  const incidents = rows.filter((r) => r.needs_review || (r.anomaly_codes?.length ?? 0) > 0).length

  const workingRows = rows.filter((r) => r.current_state === 'working')
  const pauseRows = rows.filter((r) => r.current_state === 'on_pause')
  const incidentRows = rows.filter((r) => r.needs_review || (r.anomaly_codes?.length ?? 0) > 0)

  const cards = [
    { key: 'scheduled', label: t('dashboard.stat_scheduled', 'Programats avui'), value: rows.length, icon: Users, tone: 'text-foreground', href: null as string | null },
    { key: 'working', label: t('control_horari.stats.working', 'Treballant'), value: working, icon: UserCheck, tone: 'text-emerald-700', href: workingRows[0] ? employeeDashboardHref(workingRows[0].employee_id) : null },
    { key: 'pause', label: t('control_horari.stats.on_pause', 'En pausa'), value: onPause, icon: PauseCircle, tone: 'text-amber-700', href: pauseRows[0] ? employeeDashboardHref(pauseRows[0].employee_id) : null },
    { key: 'not_punched', label: t('dashboard.stat_not_punched', 'Sense fitxar'), value: notPunched, icon: LogIn, tone: 'text-slate-700', href: null },
    { key: 'awaiting', label: t('dashboard.stat_awaiting', "Dins l'horari"), value: awaiting, icon: Clock, tone: 'text-sky-700', href: null },
    { key: 'absent', label: t('dashboard.stat_absent', 'Absents'), value: absent, icon: UserX, tone: 'text-red-700', href: null },
    { key: 'incidents', label: t('control_horari.stats.incidents', 'Incidències'), value: incidents, icon: AlertTriangle, tone: 'text-orange-700', href: incidentRows[0] ? employeeDashboardHref(incidentRows[0].employee_id) : null },
  ]

  return (
    <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4 2xl:grid-cols-7">
      {cards.map((card) => {
        const inner = (
          <>
            <p className="flex items-center gap-2 text-xs font-medium text-muted-foreground">
              <card.icon className="h-3.5 w-3.5" />
              {card.label}
            </p>
            <p className={cn('mt-2 text-2xl font-bold tabular-nums', card.tone)}>{card.value}</p>
          </>
        )

        if (card.href && card.value > 0) {
          return (
            <Link
              key={card.key}
              to={card.href}
              className="rounded-xl border bg-card p-4 shadow-sm transition-colors hover:border-primary/40 hover:bg-accent/30"
            >
              {inner}
            </Link>
          )
        }

        return (
          <div key={card.key} className="rounded-xl border bg-card p-4 shadow-sm">
            {inner}
          </div>
        )
      })}
    </div>
  )
}
