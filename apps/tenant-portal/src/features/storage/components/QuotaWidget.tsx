import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useStorageUsage } from '../api/useStorageUsage'
import { getAppDriveCapBytes, getTenantStorageBreakdown } from '../api/storageService'
import { formatBytes } from '../utils/fileUtils'
import type { StorageDrive, TenantStorageBreakdown } from '../types/storage.types'

interface QuotaWidgetProps {
  tenantId: string | undefined
  /** When set, shows quota for that specific BYOS drive. null = App Drive (5 GB cap). */
  activeDriveId?: string | null
  /** Pre-fetched BYOS drives list from the sidebar — avoids a duplicate fetch. */
  drives?: StorageDrive[]
}

export function QuotaWidget({ tenantId, activeDriveId, drives = [] }: QuotaWidgetProps) {
  const { t } = useTranslation('storage')
  const { data: usage, isLoading } = useStorageUsage(tenantId, activeDriveId)
  const [appDriveCapBytes, setAppDriveCapBytes] = useState<number | null>(null)
  const [breakdown, setBreakdown] = useState<TenantStorageBreakdown | null>(null)

  useEffect(() => {
    let cancelled = false
    if (!tenantId) {
      setAppDriveCapBytes(null)
      setBreakdown(null)
      return
    }
    Promise.all([
      getAppDriveCapBytes(tenantId),
      // Only load breakdown on App Drive view (no BYOS selected)
      activeDriveId == null ? getTenantStorageBreakdown(tenantId) : Promise.resolve(null),
    ]).then(([cap, bd]) => {
      if (!cancelled) {
        setAppDriveCapBytes(cap)
        setBreakdown(bd)
      }
    }).catch(() => {
      if (!cancelled) {
        setAppDriveCapBytes(null)
        setBreakdown(null)
      }
    })
    return () => { cancelled = true }
  }, [tenantId, activeDriveId])

  if (isLoading) {
    return (
      <div className="px-3 py-3 animate-pulse">
        <div className="h-2 bg-muted rounded w-full mb-2" />
        <div className="h-3 bg-muted rounded w-2/3" />
      </div>
    )
  }

  const activeDrive = activeDriveId ? drives.find((d) => d.id === activeDriveId) : null
  const isUnlimitedByos = !!activeDrive && activeDrive.quota_limit_bytes == null

  // When on App Drive and breakdown is available (owner/manager), use the pre-computed
  // grand_total (Drive + Documents). Otherwise fall back to the per-drive query.
  const isAppDrive = !activeDriveId
  const total = isAppDrive && breakdown
    ? breakdown.grand_total_bytes
    : (usage?.total_bytes ?? 0)
  const fileCount = usage?.file_count ?? 0

  const CAP = activeDrive
    ? activeDrive.quota_limit_bytes
    : (appDriveCapBytes ?? 5 * 1024 * 1024 * 1024)
  const percent = !isUnlimitedByos && CAP && CAP > 0
    ? Math.min(100, Math.round((total / CAP) * 100))
    : 0

  const barColor =
    percent >= 90 ? 'bg-red-500' : percent >= 70 ? 'bg-amber-500' : 'bg-indigo-500'

  const docsBytes = isAppDrive && breakdown
    ? (breakdown.documents_committed_bytes + breakdown.documents_reserved_bytes)
    : 0

  return (
    <div className="px-3 py-3">
      <p className="text-[10px] font-semibold uppercase tracking-widest text-muted-foreground mb-2">
        {t('storage.explorer.quota_title', 'Emmagatzematge')}
      </p>

      {/* Progress bar */}
      <div className="h-1.5 rounded-full bg-muted overflow-hidden mb-1.5">
        <div
          className={`h-full rounded-full transition-all ${barColor}`}
          style={{ width: `${percent}%` }}
        />
      </div>

      <p className="text-xs text-muted-foreground">
        {formatBytes(total)}
        <span className="text-muted-foreground/40 mx-1">/</span>
        {isUnlimitedByos
          ? t('storage.explorer.quota_unlimited', 'Il·limitada')
          : formatBytes(CAP)}
      </p>
      <p className="text-[11px] text-muted-foreground mt-0.5">
        {t('storage.explorer.quota_files', '{{count}} fitxers', { count: fileCount })}
      </p>

      {/* Breakdown: Drive vs Documents (only on App Drive, only for owner/manager) */}
      {isAppDrive && breakdown && docsBytes > 0 && (
        <div className="mt-1.5 space-y-0.5">
          <p className="text-[10px] text-muted-foreground/70">
            {t('storage.explorer.quota_drive', 'Drive')}: {formatBytes(breakdown.total_bytes)}
          </p>
          <p className="text-[10px] text-muted-foreground/70">
            {t('storage.explorer.quota_documents', 'Documents')}: {formatBytes(docsBytes)}
          </p>
        </div>
      )}
    </div>
  )
}
