import {
  getEmailLogs,
  getTenantOptions,
  getEmailMetrics,
} from '@/app/admin/actions/email-logs'
import { getQueueMetrics } from '@/app/admin/actions/queue-metrics'
import { EmailLogsTable } from '@/components/dashboard/EmailLogsTable'
import { QueueMonitorDashboard } from '@/components/dashboard/QueueMonitorDashboard'
import { getT } from '@/lib/i18n/server'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function today(): string {
  return new Date().toISOString().slice(0, 10)
}

function sevenDaysAgo(): string {
  const d = new Date()
  d.setDate(d.getDate() - 7)
  return d.toISOString().slice(0, 10)
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

export const metadata = {
  title: 'Historial d\'Emails',
}

export default async function EmailLogsPage() {
  const t = getT('email_logs')
  const dateFrom = sevenDaysAgo()
  const dateTo = today()

  const initialParams = { dateFrom, dateTo, page: 1, pageSize: 50 }

  const [initialData, tenants, queueMetrics, initialMetrics] = await Promise.all([
    getEmailLogs(initialParams),
    getTenantOptions(),
    getQueueMetrics(),
    getEmailMetrics(initialParams),
  ])

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold text-gray-900">
          {t('email_logs.page.title', 'Historial d\'Emails')}
        </h1>
        <p className="mt-1 text-sm text-gray-500">
          {t('email_logs.page.description', 'Tots els registres d\'enviament d\'email de la plataforma.')}
        </p>
      </div>

      <EmailLogsTable
        initialData={initialData}
        tenants={tenants}
        initialParams={initialParams}
        initialMetrics={initialMetrics}
      />

      <QueueMonitorDashboard initialMetrics={queueMetrics} />
    </div>
  )
}
