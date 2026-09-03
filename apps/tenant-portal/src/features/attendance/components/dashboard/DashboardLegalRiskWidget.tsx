import { Link } from 'react-router-dom'
import type { TFunction } from 'i18next'
import { AlertTriangle, Scale } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { useSiteLegalRisk } from '../../api/useSiteLegalRisk'
import { formatTimesheetMinutes } from '../../api/timesheetService'

interface DashboardLegalRiskWidgetProps {
  siteId: string
  t: TFunction
}

export function DashboardLegalRiskWidget({ siteId, t }: DashboardLegalRiskWidgetProps) {
  const { data, isLoading } = useSiteLegalRisk(siteId, 80)

  const employees = data?.employees ?? []

  return (
    <div className="rounded-xl border bg-card p-4 shadow-sm">
      <div className="mb-3 flex items-center justify-between gap-2">
        <p className="flex items-center gap-2 text-sm font-semibold">
          <Scale className="h-4 w-4 text-orange-600" />
          {t('dashboard.legal_risk_title', 'Risc legal equip')}
        </p>
        <Badge variant={employees.length > 0 ? 'destructive' : 'secondary'}>
          {employees.length}
        </Badge>
      </div>

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('admin.loading', 'Carregant...')}</p>
      ) : employees.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('dashboard.legal_risk_empty', 'Cap empleat per sobre del 80% del límit d’hores extra')}
        </p>
      ) : (
        <ul className="space-y-2">
          {employees.slice(0, 6).map((row) => (
            <li key={row.employee_id} className="rounded-lg border bg-muted/20 px-3 py-2">
              <div className="flex items-center justify-between gap-2">
                <Link
                  to={`/employees/${row.employee_id}?tab=timesheet`}
                  className="text-sm font-medium hover:underline"
                >
                  {row.employee_name ?? row.employee_id.slice(0, 8)}
                </Link>
                <span className="flex items-center gap-1 text-xs font-semibold tabular-nums text-orange-800">
                  <AlertTriangle className="h-3.5 w-3.5" />
                  {row.pct_statutory_overtime}%
                </span>
              </div>
              {row.overtime_pending_ytd > 0 && (
                <p className="mt-0.5 text-[11px] text-muted-foreground">
                  {t('dashboard.legal_risk_pending', 'Extra pendents')}:{' '}
                  {formatTimesheetMinutes(row.overtime_pending_ytd)}
                </p>
              )}
            </li>
          ))}
        </ul>
      )}

      {employees.length > 6 && (
        <p className="mt-2 text-center text-xs text-muted-foreground">
          {t('dashboard.legal_risk_more', '+ {{count}} més', { count: employees.length - 6 })}
        </p>
      )}

      <div className="mt-3 flex justify-end">
        <Button type="button" variant="link" size="sm" className="h-auto px-0 text-xs" asChild>
          <Link to="/settings/attendance-control">
            {t('dashboard.legal_risk_settings', 'Revisar límits legals')}
          </Link>
        </Button>
      </div>
    </div>
  )
}
