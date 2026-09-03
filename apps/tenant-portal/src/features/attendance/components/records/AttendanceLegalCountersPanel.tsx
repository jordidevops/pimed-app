import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { AlertTriangle, Loader2, Scale } from 'lucide-react'
import { cn } from '@/lib/utils'
import { formatTimesheetMinutes } from '../../api/timesheetService'
import type { LegalCounterRow } from '../../api/legalCountersService'
import { useAttendanceLegalCounters } from '../../api/useAttendanceLegalCounters'

function pctTone(pct: number | null | undefined): string {
  if (pct == null) return 'text-muted-foreground'
  if (pct >= 100) return 'text-red-700'
  if (pct >= 90) return 'text-amber-700'
  if (pct >= 80) return 'text-orange-700'
  return 'text-emerald-700'
}

function CounterBar({
  label,
  current,
  limit,
  pct,
}: {
  label: string
  current: number
  limit: number | null | undefined
  pct: number | null | undefined
}) {
  if (limit == null || limit <= 0) return null
  const width = Math.min(100, Math.max(0, pct ?? 0))

  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between gap-2 text-xs">
        <span className="text-muted-foreground">{label}</span>
        <span className={cn('font-medium tabular-nums', pctTone(pct))}>
          {formatTimesheetMinutes(current)} / {formatTimesheetMinutes(limit)}
          {pct != null ? ` (${pct}%)` : ''}
        </span>
      </div>
      <div className="h-2 overflow-hidden rounded-full bg-muted">
        <div
          className={cn(
            'h-full rounded-full transition-all',
            (pct ?? 0) >= 100 ? 'bg-red-500' : (pct ?? 0) >= 90 ? 'bg-amber-500' : 'bg-primary/70',
          )}
          style={{ width: `${width}%` }}
        />
      </div>
    </div>
  )
}

function PeriodBlock({ row, t }: { row: LegalCounterRow; t: (k: string, f: string) => string }) {
  const otPct = row.pct.statutory_overtime
  const showWarning = otPct != null && otPct >= 80

  return (
    <div className="space-y-3 rounded-lg border bg-muted/20 p-3">
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
        {t('legal_counters.period', 'Període')}: {row.period_key}
      </p>
      <CounterBar
        label={t('legal_counters.statutory_overtime', 'Hores extra (legal)')}
        current={row.overtime_authorized_ytd}
        limit={row.limits.statutory_overtime_minutes}
        pct={row.pct.statutory_overtime}
      />
      {row.limits.convenio_overtime_minutes != null && (
        <CounterBar
          label={t('legal_counters.convenio_overtime', 'Hores extra (conveni)')}
          current={row.overtime_authorized_ytd}
          limit={row.limits.convenio_overtime_minutes}
          pct={row.pct.convenio_overtime}
        />
      )}
      {row.limits.statutory_work_minutes != null && (
        <CounterBar
          label={t('legal_counters.statutory_work', 'Jornada anual (remunerable)')}
          current={row.paid_minutes_ytd}
          limit={row.limits.statutory_work_minutes}
          pct={row.pct.statutory_work}
        />
      )}
      {row.overtime_pending_ytd > 0 && (
        <p className="text-xs text-amber-800">
          {t('legal_counters.ot_pending', 'Extra pendents d’autorització')}:{' '}
          <span className="font-medium tabular-nums">
            {formatTimesheetMinutes(row.overtime_pending_ytd)}
          </span>
        </p>
      )}
      {showWarning && (
        <p className="flex items-center gap-1.5 text-xs text-amber-800">
          <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
          {t('legal_counters.threshold_warning', 'Proper al límit legal configurat')}
        </p>
      )}
    </div>
  )
}

interface AttendanceLegalCountersPanelProps {
  employeeId: string
  className?: string
}

export function AttendanceLegalCountersPanel({
  employeeId,
  className = '',
}: AttendanceLegalCountersPanelProps) {
  const { t } = useTranslation('attendance')
  const { data, isLoading, error } = useAttendanceLegalCounters(employeeId)

  if (isLoading) {
    return (
      <div className={cn('flex items-center gap-2 text-sm text-muted-foreground', className)}>
        <Loader2 className="h-4 w-4 animate-spin" />
        {t('legal_counters.loading', 'Carregant comptadors legals…')}
      </div>
    )
  }

  if (error || !data || data.counters.length === 0) {
    return null
  }

  const primary = data.counters[0]

  return (
    <section className={cn('space-y-3 rounded-xl border bg-card p-4 shadow-sm', className)}>
      <div className="flex items-start gap-2">
        <Scale className="mt-0.5 h-4 w-4 text-muted-foreground" />
        <div>
          <h3 className="text-sm font-semibold">
            {t('legal_counters.title', 'Comptadors legals i compensació')}
          </h3>
          <p className="text-xs text-muted-foreground">
            {t('legal_counters.subtitle', 'Acumulat del període · actualitzat en consolidar cada dia')}
          </p>
        </div>
      </div>

      {primary && <PeriodBlock row={primary} t={t} />}

      <p className="text-[11px] text-muted-foreground">
        {t(
          'legal_counters.settings_hint',
          'Els límits es configuren a Configuració → Control horari → Límits legals.',
        )}{' '}
        <Link to="/settings/attendance-control" className="underline">
          {t('legal_counters.settings_link', 'Anar-hi')}
        </Link>
      </p>
    </section>
  )
}
