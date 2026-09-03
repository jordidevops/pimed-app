import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import { Users, AlertTriangle } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  useCoverageOperationalSnapshot,
  type CoverageGapAlert,
  type CoverageMissingNow,
} from '../../api/useCoverageOperationalSnapshot'

function kindLabel(kind: string, t: TFunction): string {
  switch (kind) {
    case 'understaffed_planned':
      return t('dashboard.coverage_kind_planned', 'Gap planificat')
    case 'understaffed_present':
      return t('dashboard.coverage_kind_present', 'Gap real')
    case 'understaffed_qualified':
      return t('dashboard.coverage_kind_qualified', 'Gap qualificat')
    case 'no_show':
      return t('dashboard.coverage_kind_noshow', 'No present')
    default:
      return kind
  }
}

function missingStatusLabel(status: string, t: TFunction): string {
  if (status === 'absent') return t('dashboard.coverage_status_absent', 'Absent')
  if (status === 'late') return t('dashboard.coverage_status_late', 'Tard')
  return status
}

function AlertRow({ alert, t }: { alert: CoverageGapAlert; t: TFunction }) {
  return (
    <li className="rounded-lg border bg-muted/20 px-3 py-2">
      <div className="flex flex-wrap items-center gap-1.5">
        <span className="text-sm font-medium tabular-nums">
          {alert.bucket_start}–{alert.bucket_end}
        </span>
        {alert.severity === 'now' ? (
          <Badge variant="destructive" className="text-[10px]">
            {t('dashboard.coverage_now', 'Ara')}
          </Badge>
        ) : (
          <Badge variant="outline" className="text-[10px]">
            {t('dashboard.coverage_upcoming', 'Proper')}
          </Badge>
        )}
        {alert.kinds.map((k) => (
          <Badge key={k} variant="outline" className="text-[10px]">
            {kindLabel(k, t)}
          </Badge>
        ))}
      </div>
      <p className="mt-1 text-xs text-muted-foreground tabular-nums">
        {t('dashboard.coverage_counts', 'P {{planned}} · R {{present}} · Q {{qualified}} / {{required}}', {
          planned: alert.planned,
          present: alert.present,
          qualified: alert.qualified,
          required: alert.required,
        })}
        {alert.role_name ? ` · ${alert.role_name}` : ''}
      </p>
    </li>
  )
}

function MissingRow({ row, t }: { row: CoverageMissingNow; t: TFunction }) {
  return (
    <li className="rounded-lg border bg-muted/20 px-3 py-2">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-sm font-medium">{row.employee_name}</span>
        <Badge
          variant="outline"
          className={
            row.status === 'absent'
              ? 'border-red-300 text-red-800 text-[10px]'
              : 'border-amber-300 text-amber-800 text-[10px]'
          }
        >
          {missingStatusLabel(row.status, t)}
        </Badge>
      </div>
      <p className="mt-0.5 text-xs text-muted-foreground tabular-nums">
        {row.slot_start}–{row.slot_end}
        {row.role_name ? ` · ${row.role_name}` : ''}
      </p>
    </li>
  )
}

export function DashboardCoverageGapsWidget({ t }: { t: TFunction }) {
  const { i18n } = useTranslation('attendance')
  void i18n
  const { data, isLoading, isError, error, refetch } = useCoverageOperationalSnapshot({
    horizonMinutes: 240,
    refetchIntervalMs: 60_000,
  })

  const current = data?.current
  const summary = data?.summary
  const alertCount = (summary?.open_gap_count ?? 0) + (summary?.missing_now_count ?? 0)
  const displayAlerts = (data?.alerts ?? []).filter((a) => {
    if (a.kinds.includes('no_show') && !a.kinds.some((k) => k !== 'no_show')) return false
    return true
  })

  return (
    <div className="rounded-xl border bg-card p-4 shadow-sm">
      <div className="mb-3 flex items-center justify-between gap-2">
        <p className="flex items-center gap-2 text-sm font-semibold">
          <Users className="h-4 w-4 text-sky-700" />
          {t('dashboard.coverage_widget_title', 'Cobertura ara')}
        </p>
        <div className="flex items-center gap-2">
          <Badge variant={alertCount > 0 ? 'destructive' : 'secondary'}>
            {alertCount}
          </Badge>
          <Button type="button" variant="link" size="sm" className="h-auto px-0 text-xs" asChild>
            <Link to="/attendance-mgmt/calendar?tab=demand">
              {t('dashboard.coverage_view_demand', 'Veure demanda')}
            </Link>
          </Button>
        </div>
      </div>

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('dashboard.loading', 'Carregant…')}</p>
      ) : isError ? (
        <div className="text-sm text-destructive">
          <p>{t('dashboard.coverage_load_error', 'No s\'ha pogut carregar la cobertura')}</p>
          <p className="mt-1 text-xs text-muted-foreground">
            {error instanceof Error ? error.message : String(error)}
          </p>
          <Button type="button" size="sm" variant="outline" className="mt-2" onClick={() => void refetch()}>
            {t('common.retry', 'Tornar a provar')}
          </Button>
        </div>
      ) : (
        <div className="space-y-3">
          {current && current.required > 0 ? (
            <div className="rounded-lg border border-dashed px-3 py-2 text-xs">
              <p className="font-medium text-foreground">
                {t('dashboard.coverage_current_bucket', 'Franja actual')}{' '}
                <span className="tabular-nums">{current.bucket_start}–{current.bucket_end}</span>
              </p>
              <p className="mt-1 text-muted-foreground tabular-nums">
                {t('dashboard.coverage_counts', 'P {{planned}} · R {{present}} · Q {{qualified}} / {{required}}', {
                  planned: current.planned ?? current.assigned ?? 0,
                  present: current.present ?? 0,
                  qualified: current.qualified ?? 0,
                  required: current.required,
                })}
              </p>
              {!summary?.current_ok && (
                <p className="mt-1 flex items-center gap-1 text-amber-800">
                  <AlertTriangle className="h-3.5 w-3.5" />
                  {t('dashboard.coverage_current_gap', 'Hi ha gap a la franja actual')}
                </p>
              )}
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">
              {t('dashboard.coverage_no_demand_now', 'Cap demanda activa en aquesta franja')}
            </p>
          )}

          {(data?.missing_now?.length ?? 0) > 0 && (
            <div>
              <p className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                {t('dashboard.coverage_missing_title', 'Planificats no presents')}
              </p>
              <ul className="space-y-2">
                {data!.missing_now.slice(0, 6).map((row) => (
                  <MissingRow key={row.employee_id} row={row} t={t} />
                ))}
              </ul>
            </div>
          )}

          {displayAlerts.length > 0 && (
            <div>
              <p className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                {t('dashboard.coverage_alerts_title', 'Alertes de gap')}
              </p>
              <ul className="space-y-2">
                {displayAlerts.slice(0, 6).map((alert) => (
                  <AlertRow
                    key={`${alert.bucket_start}-${alert.kinds.join(',')}`}
                    alert={alert}
                    t={t}
                  />
                ))}
              </ul>
            </div>
          )}

          {alertCount === 0 && (current?.required ?? 0) === 0 && (
            <p className="text-sm text-muted-foreground">
              {t('dashboard.coverage_all_ok', 'Sense gaps de cobertura en l\'horitzó')}
            </p>
          )}
        </div>
      )}
    </div>
  )
}
