import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Download, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  clearPendingPortalBatch,
  loadPendingPortalBatch,
  recoverEmployeePortalTokenBatch,
} from '../api/employeePortalBatchService'
import type {
  FetchPortalTokenBatchResults,
  StartPortalTokenBatchResult,
} from '../api/employeePortalBatchTypes'

interface PortalTokenBatchRecoveryBannerProps {
  onRecover: (payload: {
    start: StartPortalTokenBatchResult
    results: FetchPortalTokenBatchResults
  }) => void
}

export function PortalTokenBatchRecoveryBanner({
  onRecover,
}: PortalTokenBatchRecoveryBannerProps) {
  const { t, i18n } = useTranslation('employees')
  const [pending, setPending] = useState(() => loadPendingPortalBatch())
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    setPending(loadPendingPortalBatch())
  }, [])

  if (!pending) return null

  const expiresLabel = new Date(pending.expiresAt).toLocaleString(i18n.language)

  async function handleRecover() {
    setLoading(true)
    setError(null)
    try {
      const payload = await recoverEmployeePortalTokenBatch(pending!.batchId, pending!.expiresAt)
      onRecover(payload)
    } catch {
      clearPendingPortalBatch()
      setPending(null)
      setError(
        t(
          'employees.portal_access.batch_recovery_expired',
          'El lot ja no es pot recuperar (ha expirat).',
        ),
      )
    } finally {
      setLoading(false)
    }
  }

  function handleDismiss() {
    clearPendingPortalBatch()
    setPending(null)
  }

  return (
    <div className="rounded-xl border border-primary/30 bg-primary/5 px-4 py-3 flex flex-col sm:flex-row sm:items-center gap-3">
      <div className="flex-1 text-sm">
        <p className="font-medium text-foreground">
          {t(
            'employees.portal_access.batch_recovery_title',
            'Tens un lot pendent de descarregar',
          )}
        </p>
        <p className="text-muted-foreground">
          {t(
            'employees.portal_access.batch_recovery_hint',
            'Disponible fins a {{expires}}.',
            { expires: expiresLabel },
          )}
        </p>
        {error ? <p className="text-destructive mt-1">{error}</p> : null}
      </div>
      <div className="flex gap-2 shrink-0">
        <Button type="button" variant="outline" size="sm" onClick={handleDismiss}>
          {t('employees.portal_access.batch_recovery_dismiss', 'Descartar')}
        </Button>
        <Button type="button" size="sm" onClick={() => void handleRecover()} disabled={loading}>
          {loading ? (
            <Loader2 className="h-4 w-4 mr-2 animate-spin" />
          ) : (
            <Download className="h-4 w-4 mr-2" />
          )}
          {t('employees.portal_access.batch_recovery_action', 'Recuperar lot')}
        </Button>
      </div>
    </div>
  )
}
