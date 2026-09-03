import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Check, Copy, Download, Loader2, Printer } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  clearPendingPortalBatch,
  resolveBatchRowPortalUrl,
} from '../api/employeePortalBatchService'
import { useAckEmployeePortalBatch } from '../api/useEmployeePortalBatch'
import type {
  FetchPortalTokenBatchResults,
  PortalTokenBatchResultRow,
  StartPortalTokenBatchResult,
} from '../api/employeePortalBatchTypes'
import {
  buildPortalBatchExportFilename,
  downloadPortalLabelCsv,
  type PortalLabelExportRow,
} from '../utils/portalLabelExport'
import { formatPortalAccessCopyLine } from '../utils/portalDocumentId'
import { printPortalQrCards } from '../utils/portalQrPrint'

function batchStatusLabel(
  t: (key: string, fallback: string) => string,
  status: PortalTokenBatchResultRow['status'],
): string {
  switch (status) {
    case 'created':
      return t('employees.portal_access.batch_status_created', 'Creat')
    case 'skipped':
      return t('employees.portal_access.batch_status_skipped', 'Omesa')
    case 'error':
      return t('employees.portal_access.batch_status_error', 'Error')
    default:
      return status
  }
}

function batchRowErrorLabel(
  t: (key: string, fallback: string) => string,
  errorCode: string | null,
): string {
  switch (errorCode) {
    case 'employee_not_active':
      return t('employees.portal_access.batch_row_inactive', 'Empleat inactiu')
    case 'employee_missing_document_id':
      return t(
        'employees.portal_access.batch_row_missing_document',
        'Falta DNI/NIE a la fitxa',
      )
    case 'no_published_public_site':
      return t(
        'employees.portal_access.batch_row_no_site',
        'Falta configurar l\'adreça del portal d\'empleat (domini o URL local en dev)',
      )
    case 'insufficient_privilege':
      return t(
        'employees.portal_access.portal_url_permission_error',
        'Sense permís attendance.manage',
      )
    case 'employee_not_found':
      return t('employees.portal_access.batch_row_not_found', 'Empleat no trobat')
    default:
      return errorCode ?? t('employees.portal_access.batch_row_error', 'Error')
  }
}

function statusBadgeVariant(status: PortalTokenBatchResultRow['status']) {
  if (status === 'created') return 'default'
  if (status === 'skipped') return 'secondary'
  return 'destructive'
}

interface PortalTokenBatchResultsDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  start: StartPortalTokenBatchResult | null
  results: FetchPortalTokenBatchResults | null
  onOpenRecentBatches?: () => void
}

export function PortalTokenBatchResultsDialog({
  open,
  onOpenChange,
  start,
  results,
  onOpenRecentBatches,
}: PortalTokenBatchResultsDialogProps) {
  const { t, i18n } = useTranslation('employees')
  const [printing, setPrinting] = useState(false)
  const [copied, setCopied] = useState(false)
  const [ackConfirmOpen, setAckConfirmOpen] = useState(false)
  const { mutate: ackBatch, isPending: acking } = useAckEmployeePortalBatch()

  const batchId = results?.batchId ?? start?.batchId ?? null

  const createdRows = useMemo(
    () => (results?.rows ?? []).filter((row) => row.status === 'created'),
    [results],
  )

  const exportRows: PortalLabelExportRow[] = useMemo(
    () =>
      createdRows
        .map((row) => {
          const portalUrl = resolveBatchRowPortalUrl(row)
          if (!portalUrl) return null
          return {
            employeeName: row.employeeName?.trim() || '',
            employeeCode: row.employeeCode?.trim() || '',
            portalUrl,
            label: row.label?.trim() || '',
          }
        })
        .filter((row): row is PortalLabelExportRow => row !== null),
    [createdRows],
  )

  const expiresLabel = useMemo(() => {
    const expiresAt = results?.expiresAt ?? start?.expiresAt
    if (!expiresAt) return ''
    return new Date(expiresAt).toLocaleString(i18n.language)
  }, [results?.expiresAt, start?.expiresAt, i18n.language])

  async function handlePrint() {
    if (exportRows.length === 0) return
    setPrinting(true)
    try {
      await printPortalQrCards(
        exportRows.map((row) => ({
          employeeName: row.employeeName || t('employees.portal_access.print_unknown_name', 'Empleat'),
          portalUrl: row.portalUrl,
          scanHint: t('employees.portal_access.print_scan_hint', 'Escaneja per accedir al portal.'),
        })),
      )
    } finally {
      setPrinting(false)
    }
  }

  function handleExportCsv() {
    if (exportRows.length === 0) return
    downloadPortalLabelCsv(exportRows, buildPortalBatchExportFilename())
  }

  async function handleCopyUrls() {
    const lines = exportRows.map((row) => formatPortalAccessCopyLine(row)).join('\n')
    if (!lines) return
    await navigator.clipboard.writeText(lines)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  function handleClose(nextOpen: boolean) {
    if (!nextOpen) setAckConfirmOpen(false)
    onOpenChange(nextOpen)
  }

  function handleAckConfirm() {
    if (!batchId) return
    ackBatch(batchId, {
      onSuccess: () => {
        clearPendingPortalBatch()
        setAckConfirmOpen(false)
        handleClose(false)
      },
    })
  }

  const summary = start?.summary
  const allRows = results?.rows ?? []

  return (
    <>
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="sm:max-w-3xl max-h-[90vh] flex flex-col">
        <DialogHeader>
          <DialogTitle>
            {t('employees.portal_access.batch_results_title', 'Resultats del lot')}
          </DialogTitle>
          <DialogDescription>
            {summary
              ? t(
                  'employees.portal_access.batch_results_summary',
                  '{{created}} creats, {{skipped}} omesos, {{errors}} errors de {{requested}} sol·licitats.',
                  {
                    created: summary.created,
                    skipped: summary.skipped,
                    errors: summary.errors,
                    requested: summary.requested,
                  },
                )
              : null}
          </DialogDescription>
        </DialogHeader>

        {expiresLabel ? (
          <p className="text-sm text-amber-800 dark:text-amber-200 rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/30 px-3 py-2">
            {t(
              'employees.portal_access.batch_expires_notice',
              'Pots tornar a descarregar aquest lot fins a {{expires}}. Després els enllaços continuaran vàlids però no es podran recuperar aquí.',
              { expires: expiresLabel },
            )}
          </p>
        ) : null}

        {start?.status === 'failed' && !results ? (
          <p className="text-sm text-destructive rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2">
            {t(
              'employees.portal_access.batch_failed_all',
              'No s\'ha creat cap enllaç en aquest lot.',
            )}
          </p>
        ) : null}

        {allRows.length > 0 ? (
          <div className="overflow-auto flex-1 min-h-0 rounded-md border">
            <table className="w-full text-sm">
              <thead className="bg-muted/50 sticky top-0">
                <tr>
                  <th className="text-left px-3 py-2 font-medium">
                    {t('employees.portal_access.batch_col_name', 'Nom')}
                  </th>
                  <th className="text-left px-3 py-2 font-medium">
                    {t('employees.portal_access.batch_col_code', 'Codi')}
                  </th>
                  <th className="text-left px-3 py-2 font-medium">
                    {t('employees.portal_access.batch_col_status', 'Estat')}
                  </th>
                  <th className="text-left px-3 py-2 font-medium">
                    {t('employees.portal_access.batch_col_detail', 'Detall')}
                  </th>
                </tr>
              </thead>
              <tbody>
                {allRows.map((row) => (
                  <tr key={row.employeeId} className="border-t">
                    <td className="px-3 py-2">{row.employeeName ?? '—'}</td>
                    <td className="px-3 py-2 text-muted-foreground">{row.employeeCode ?? '—'}</td>
                    <td className="px-3 py-2">
                      <Badge variant={statusBadgeVariant(row.status)}>
                        {batchStatusLabel(t, row.status)}
                      </Badge>
                    </td>
                    <td className="px-3 py-2 text-muted-foreground max-w-xs truncate">
                      {row.status === 'created'
                        ? (() => {
                            const url = resolveBatchRowPortalUrl(row)
                            return url
                              ? url
                              : t(
                                  'employees.portal_access.batch_row_url_unavailable',
                                  'Token creat però no s\'ha pogut construir l\'URL',
                                )
                          })()
                        : batchRowErrorLabel(t, row.errorCode)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : null}

        <DialogFooter className="flex-col sm:flex-row gap-2 sm:flex-wrap">
          {createdRows.length > 0 ? (
            <div className="flex flex-wrap gap-2 sm:mr-auto">
              <Button
                type="button"
                variant="outline"
                onClick={() => void handlePrint()}
                disabled={printing || exportRows.length === 0}
              >
                {printing ? (
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                ) : (
                  <Printer className="h-4 w-4 mr-2" />
                )}
                {t('employees.portal_access.print_qr', 'Imprimir QR')}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={handleExportCsv}
                disabled={exportRows.length === 0}
              >
                <Download className="h-4 w-4 mr-2" />
                {t('employees.portal_access.export_csv', 'Exportar CSV')}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={() => void handleCopyUrls()}
                disabled={exportRows.length === 0}
              >
                {copied ? (
                  <Check className="h-4 w-4 mr-2 text-green-600" />
                ) : (
                  <Copy className="h-4 w-4 mr-2" />
                )}
                {t('employees.portal_access.batch_copy_lines', 'Copiar enllaços (Nom · DNI · URL)')}
              </Button>
            </div>
          ) : null}
          {batchId && createdRows.length > 0 ? (
            <Button
              type="button"
              variant="secondary"
              onClick={() => setAckConfirmOpen(true)}
              disabled={acking}
            >
              {t('employees.portal_access.batch_ack_open', 'Ja he descarregat')}
            </Button>
          ) : null}
          <Button type="button" onClick={() => handleClose(false)}>
            {t('employees.portal_access.batch_results_done', 'Tancar')}
          </Button>
          {onOpenRecentBatches ? (
            <Button type="button" variant="link" className="sm:order-first" onClick={onOpenRecentBatches}>
              {t('employees.portal_access.batch_recent_open', 'Lots recents')}
            </Button>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <Dialog open={ackConfirmOpen} onOpenChange={setAckConfirmOpen}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {t('employees.portal_access.batch_ack_title', 'Confirmar descàrrega')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'employees.portal_access.batch_ack_description',
              'Els enllaços d\'accés continuaran actius per als empleats, però no podràs tornar a copiar ni exportar aquest lot des d\'aquí.',
            )}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter className="gap-2 sm:gap-0">
          <Button type="button" variant="outline" onClick={() => setAckConfirmOpen(false)} disabled={acking}>
            {t('employees.portal_access.batch_ack_cancel', 'Encara no')}
          </Button>
          <Button type="button" onClick={handleAckConfirm} disabled={acking}>
            {acking ? (
              <Loader2 className="h-4 w-4 mr-2 animate-spin" />
            ) : null}
            {t('employees.portal_access.batch_ack_confirm', 'Sí, ja he descarregat')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
    </>
  )
}
