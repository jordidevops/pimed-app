import {
  getSigningOpsDashboard,
  getSigningOpsLogs,
  getSigningOpsTenantOptions,
} from '@/app/admin/actions/signing-ops'
import { SigningOpsDashboard } from '@/components/dashboard/SigningOpsDashboard'
import { getT } from '@/lib/i18n/server'

function today(): string {
  return new Date().toISOString().slice(0, 10)
}

function sevenDaysAgo(): string {
  const d = new Date()
  d.setDate(d.getDate() - 7)
  return d.toISOString().slice(0, 10)
}

export const metadata = {
  title: 'Signing Ops',
}

interface PageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function SigningOpsPage({ searchParams }: PageProps) {
  const t = getT('common')
  const params = await searchParams
  const getString = (key: string): string => {
    const v = params[key]
    return typeof v === 'string' ? v : ''
  }

  const dateFrom = getString('dateFrom') || sevenDaysAgo()
  const dateTo = getString('dateTo') || today()
  const tenantId = getString('tenantId') || undefined
  const status = getString('status') || undefined
  const operationCode = getString('operationCode') || undefined
  const unresolvedOnly = getString('unresolvedOnly') === '1'

  const initialParams = {
    dateFrom,
    dateTo,
    tenantId,
    status,
    operationCode,
    unresolvedOnly,
    page: 1,
    pageSize: 50,
  }

  const [dashboard, logs, tenants] = await Promise.all([
    getSigningOpsDashboard(),
    getSigningOpsLogs(initialParams),
    getSigningOpsTenantOptions(),
  ])

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold text-gray-900">
          {t('common.nav.signingOps', 'Signing Ops')}
        </h1>
        <p className="mt-1 text-sm text-gray-500">
          Errors, cues, health de reconcile i estadístiques native/DocuSeal.
        </p>
      </div>

      <SigningOpsDashboard
        initialDashboard={dashboard}
        initialLogs={logs}
        tenants={tenants}
        initialParams={initialParams}
      />
    </div>
  )
}
