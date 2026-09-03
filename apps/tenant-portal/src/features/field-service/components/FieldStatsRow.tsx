import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { countProjects } from '@/features/projects/api/projectsService'
import { useTenant } from '@/contexts/TenantContext'
import { useTodayOrders } from '../api/useTodayOrders'
import { localDayRange } from '@/lib/dateLocal'

export function FieldStatsRow() {
  const { t } = useTranslation('field-service')
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id
  const { data: today } = useTodayOrders()
  const { from, to } = localDayRange()

  const { data: openCount = 0 } = useQuery({
    queryKey: ['field-service', 'open-orders-count', tenantId],
    enabled: !!tenantId,
    queryFn: () =>
      countProjects(tenantId!, {
        type: 'work_order',
        openOnly: true,
      }),
  })

  const { data: visitsToday = today?.totalCount ?? 0 } = useQuery({
    queryKey: ['field-service', 'visits-today-count', tenantId, from.slice(0, 10)],
    enabled: !!tenantId,
    queryFn: () =>
      countProjects(tenantId!, {
        type: 'work_order',
        openOnly: true,
        plannedStartFrom: from,
        plannedStartTo: to,
      }),
    initialData: today?.totalCount,
  })

  return (
    <div className="grid grid-cols-2 gap-3">
      <Link
        to="/field/today"
        className="rounded-2xl border border-border bg-card p-4 min-h-16"
      >
        <p className="text-xs uppercase tracking-wide text-muted-foreground">
          {t('widgets.visits_today', 'Visites avui')}
        </p>
        <p className="text-2xl font-bold mt-1">{visitsToday}</p>
      </Link>
      <Link
        to="/field/orders?fsFilter=open"
        className="rounded-2xl border border-border bg-card p-4 min-h-16"
      >
        <p className="text-xs uppercase tracking-wide text-muted-foreground">
          {t('widgets.open_orders', 'Ordres obertes')}
        </p>
        <p className="text-2xl font-bold mt-1">{openCount}</p>
      </Link>
    </div>
  )
}
