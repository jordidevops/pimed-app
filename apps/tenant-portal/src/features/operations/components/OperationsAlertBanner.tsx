import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { AlertCircle } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { fetchUnresolvedOperationCount } from '../api/operationsRpc'
import { getOperationsDashboardSeenAt } from '../lastDashboardVisit'

interface OperationsAlertBannerProps {
  userId: string | undefined
  tenantId: string | undefined
  canView: boolean
}

export function OperationsAlertBanner({ userId, tenantId, canView }: OperationsAlertBannerProps) {
  const { t } = useTranslation('settings')

  const sinceLastVisit = useMemo(
    () => getOperationsDashboardSeenAt(userId, tenantId),
    [userId, tenantId],
  )

  const { data: count = 0, isLoading } = useQuery({
    queryKey: ['operations-since-last-visit', tenantId, userId, sinceLastVisit],
    queryFn: () => fetchUnresolvedOperationCount(tenantId!, sinceLastVisit),
    enabled: Boolean(tenantId && userId && canView),
    staleTime: 30_000,
  })

  if (!canView || isLoading || count === 0) return null

  return (
    <div
      className="bg-destructive/10 border border-destructive/20 rounded-xl p-4 flex items-start gap-3"
      role="alert"
    >
      <AlertCircle className="w-5 h-5 text-destructive shrink-0 mt-0.5" aria-hidden />
      <div className="flex-1">
        <h4 className="text-sm font-semibold text-destructive">
          {t('operations.dashboardBannerTitle', 'Incidències d\'operacions')}
        </h4>
        <p className="text-sm text-destructive/90 mt-1">
          {t(
            'operations.dashboardBannerDesc',
            '{{count}} operacions han fallat des del darrer accés al tauler. Revisa-les a Operacions.',
            { count },
          )}
        </p>
        <Link
          to="/settings/operations"
          className="inline-block mt-2 text-sm font-medium text-destructive underline hover:text-destructive/80"
        >
          {t('operations.dashboardBannerLink', 'Veure historial d\'operacions')}
        </Link>
      </div>
    </div>
  )
}
