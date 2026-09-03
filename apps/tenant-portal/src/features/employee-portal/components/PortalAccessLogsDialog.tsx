import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useEmployeePortalAccessLogs } from '../api/useEmployeePortalTokens'
import type { EmployeePortalToken } from '../api/employeePortalTypes'
import {
  portalAccessLogActionLabel,
  portalAccessLogFailureLabel,
  portalAccessLogMetadataDetail,
} from '../utils/portalAccessLogLabels'

interface PortalAccessLogsDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  token: EmployeePortalToken | null
}

function formatDateTime(value: string | null): string {
  if (!value) return '—'
  try {
    return new Date(value).toLocaleString()
  } catch {
    return value
  }
}

export function PortalAccessLogsDialog({
  open,
  onOpenChange,
  token,
}: PortalAccessLogsDialogProps) {
  const { t } = useTranslation('employees')
  const { data: logs = [], isLoading } = useEmployeePortalAccessLogs(token?.id ?? null, open)

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-2xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {t('employees.portal_access.logs_title', 'Historial d\'accés')}
            {token?.label ? ` — ${token.label}` : ''}
          </DialogTitle>
        </DialogHeader>

        {isLoading ? (
          <div className="flex justify-center py-8">
            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
          </div>
        ) : logs.length === 0 ? (
          <p className="text-sm text-muted-foreground py-4">
            {t('employees.portal_access.logs_empty', 'Encara no hi ha accessos registrats.')}
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b text-left text-muted-foreground">
                  <th className="py-2 pr-3">{t('employees.portal_access.logs_when', 'Quan')}</th>
                  <th className="py-2 pr-3">{t('employees.portal_access.logs_action', 'Acció')}</th>
                  <th className="py-2 pr-3">{t('employees.portal_access.logs_ip', 'IP')}</th>
                  <th className="py-2">{t('employees.portal_access.logs_status', 'HTTP')}</th>
                </tr>
              </thead>
              <tbody>
                {logs.map((log) => {
                  const failureLabel = portalAccessLogFailureLabel(log.failure_reason, t)
                  const metadataDetail = portalAccessLogMetadataDetail(log.metadata, t)
                  return (
                    <tr key={`${log.id}-${log.accessed_at}`} className="border-b last:border-0">
                      <td className="py-2 pr-3 whitespace-nowrap">{formatDateTime(log.accessed_at)}</td>
                      <td className="py-2 pr-3">
                        <p>{portalAccessLogActionLabel(log.action, t)}</p>
                        {(failureLabel || metadataDetail) && (
                          <p className="text-muted-foreground text-xs">
                            {[failureLabel, metadataDetail].filter(Boolean).join(' · ')}
                          </p>
                        )}
                      </td>
                      <td className="py-2 pr-3 font-mono text-xs">{log.ip_address ?? '—'}</td>
                      <td className="py-2">{log.http_status ?? '—'}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
