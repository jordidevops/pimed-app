import {
  getAuditLogs,
  getTenantOptionsForAudit,
  getAuditStats,
} from '@/app/admin/actions/audit-logs'
import { AuditLogsTable } from '@/components/dashboard/AuditLogsTable'
import { getT } from '@/lib/i18n/server'
import type { Metadata } from 'next'

// ---------------------------------------------------------------------------
// Metadata
// ---------------------------------------------------------------------------

export const metadata: Metadata = {
  title: "Activitat / Logs",
}

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

interface PageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}

export default async function ActivityPage({ searchParams }: PageProps) {
  const t = getT('activity')
  const params = await searchParams

  const getString = (key: string): string => {
    const v = params[key]
    return typeof v === 'string' ? v : ''
  }

  const dateFrom   = getString('dateFrom')   || sevenDaysAgo()
  const dateTo     = getString('dateTo')     || today()
  const tenantId   = getString('tenantId')   || undefined
  const action     = getString('action')     || undefined
  const entityType = getString('entityType') || undefined
  const search     = getString('search')     || undefined
  const pageNum    = Math.max(1, parseInt(getString('page') || '1', 10) || 1)

  const initialParams = {
    dateFrom,
    dateTo,
    page:       pageNum,
    pageSize:   50,
    tenantId,
    action,
    entityType,
    search,
    sortColumn: 'created_at',
    sortAsc:    false,
  }

  const initialFilters = {
    dateFrom,
    dateTo,
    tenantId:   tenantId   ?? '',
    action:     action     ?? '',
    entityType: entityType ?? '',
    search:     search     ?? '',
  }

  const [initialData, tenants, initialStats] = await Promise.all([
    getAuditLogs(initialParams),
    getTenantOptionsForAudit(),
    getAuditStats({ dateFrom, dateTo, tenantId }),
  ])

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold text-gray-900">
          {t('activity.page.title', 'Activitat / Logs')}
        </h1>
        <p className="mt-1 text-sm text-gray-500">
          {t(
            'activity.page.description',
            "Registre global d'auditoria de tota la plataforma.",
          )}
        </p>
      </div>

      <AuditLogsTable
        initialData={initialData}
        initialStats={initialStats}
        tenants={tenants}
        initialParams={initialParams}
        initialFilters={initialFilters}
      />
    </div>
  )
}
