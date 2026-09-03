import { AlertTriangle } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import {
  getEntityRiskAlerts,
  type EntityRiskAlert,
} from '../api/riskService'
import type { EntityTimelineType } from '../api/timelineService'

interface RiskAlertsBannerProps {
  entityType: EntityTimelineType
  entityId: string
}

function formatAlert(t: (key: string, opts?: Record<string, unknown>) => string, alert: EntityRiskAlert): string {
  if (alert.kind === 'unread_mention') {
    return t('risk.alerts.unread_mention', {
      name: alert.mention_name ?? '?',
      defaultValue: '{{name}} no ha vist el teu missatge',
    })
  }
  return alert.message ?? t('risk.alerts.status_churn', {
    count: alert.change_count ?? 0,
    defaultValue: 'Alta rotació interna — {{count}} canvis d\'estat en 30 dies',
  })
}

export function RiskAlertsBanner({ entityType, entityId }: RiskAlertsBannerProps) {
  const { t } = useTranslation('activity')

  const { data: alerts = [] } = useQuery({
    queryKey: ['entity-risk-alerts', entityType, entityId],
    queryFn: () => getEntityRiskAlerts(entityType, entityId),
  })

  if (alerts.length === 0) return null

  return (
    <div className="rounded-xl border border-amber-300/60 bg-amber-50/80 dark:bg-amber-950/30 dark:border-amber-800 px-4 py-3 space-y-2">
      <div className="flex items-center gap-2 text-amber-900 dark:text-amber-200">
        <AlertTriangle className="h-4 w-4 shrink-0" aria-hidden />
        <p className="text-sm font-medium">
          {t('risk.alerts.title', 'Alertes de risc')}
        </p>
      </div>
      <ul className="space-y-1.5">
        {alerts.map((alert, idx) => (
          <li key={alert.incident_id ?? alert.comment_id ?? idx} className="text-sm text-amber-950 dark:text-amber-100">
            {formatAlert(t, alert)}
          </li>
        ))}
      </ul>
    </div>
  )
}
