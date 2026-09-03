import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { useTenant } from '@/contexts/TenantContext'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import { getTenantStorageBreakdown } from '@/features/storage/api/storageService'
import { formatBytes } from '@/features/storage/utils/fileUtils'
import type { TenantStorageBreakdown } from '@/features/storage/types/storage.types'
import { DocumentsSubNav } from './DocumentsSubNav'

export function DocumentsStoragePage() {
  const { t } = useTranslation('documents')
  const { activeTenant } = useTenant()
  const projectLabel = useSectorLabel('project', t('storage.project_fallback', 'Projecte'))
  const [breakdown, setBreakdown] = useState<TenantStorageBreakdown | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    if (!activeTenant?.id) {
      setBreakdown(null)
      setLoading(false)
      return
    }
    setLoading(true)
    getTenantStorageBreakdown(activeTenant.id)
      .then((bd) => {
        if (!cancelled) setBreakdown(bd)
      })
      .catch(() => {
        if (!cancelled) setBreakdown(null)
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [activeTenant?.id])

  const docs =
    (breakdown?.documents_committed_bytes ?? 0) + (breakdown?.documents_reserved_bytes ?? 0)
  const drive = breakdown?.total_bytes ?? 0
  const total = Math.max(docs + drive, 1)
  const docsPct = Math.round((docs / total) * 100)
  const drivePct = 100 - docsPct

  return (
    <div className="mx-auto max-w-3xl space-y-6 p-6">
      <DocumentsSubNav />
      <div>
        <h1 className="text-xl font-semibold">
          {t('storage.title', 'Emmagatzematge')}
        </h1>
        <p className="mt-1 text-sm text-muted-foreground">
          {t(
            'storage.hint',
            "Ús de Documents (DMS) vs Fitxers (Drive). Els arxius de {{project}} van a Fitxers.",
            { project: projectLabel },
          )}
        </p>
      </div>

      {loading ? (
        <p className="text-sm text-muted-foreground">{t('page.loading', 'Carregant...')}</p>
      ) : !breakdown ? (
        <p className="text-sm text-muted-foreground">
          {t('storage.empty', 'Sense dades d\'ús encara.')}
        </p>
      ) : (
        <div className="space-y-4 rounded-xl border border-border p-4">
          <div
            className="flex h-40 w-40 mx-auto overflow-hidden rounded-full"
            style={{
              background: `conic-gradient(hsl(var(--primary)) 0 ${docsPct}%, hsl(var(--muted)) ${docsPct}% 100%)`,
            }}
            role="img"
            aria-label={t('storage.pie_label', 'Documents {{docs}}%, Fitxers {{drive}}%', {
              docs: docsPct,
              drive: drivePct,
            })}
          />
          <ul className="space-y-2 text-sm">
            <li className="flex justify-between gap-4">
              <span className="flex items-center gap-2">
                <span className="inline-block h-2.5 w-2.5 rounded-full bg-primary" />
                {t('storage.documents', 'Documents')}
              </span>
              <span className="text-muted-foreground">
                {formatBytes(docs)} ({docsPct}%) · {breakdown.documents_file_count}{' '}
                {t('storage.files_word', 'fitxers')}
              </span>
            </li>
            <li className="flex justify-between gap-4">
              <span className="flex items-center gap-2">
                <span className="inline-block h-2.5 w-2.5 rounded-full bg-muted-foreground/40" />
                {t('storage.drive', 'Fitxers')}
              </span>
              <span className="text-muted-foreground">
                {formatBytes(drive)} ({drivePct}%) · {breakdown.file_count}{' '}
                {t('storage.files_word', 'fitxers')}
              </span>
            </li>
            <li className="flex justify-between gap-4 border-t border-border pt-2 font-medium">
              <span>{t('storage.total', 'Total')}</span>
              <span>{formatBytes(breakdown.grand_total_bytes)}</span>
            </li>
          </ul>
          <p className="text-xs text-muted-foreground">
            <Link to="/files" className="text-primary underline-offset-2 hover:underline">
              {t('storage.open_files', 'Obrir Fitxers')}
            </Link>
          </p>
        </div>
      )}
    </div>
  )
}
