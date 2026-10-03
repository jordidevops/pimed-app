import { useMemo, useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import PizZip from 'pizzip'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { localDateIso } from '@/lib/dateLocal'
import {
  claimCommercialExportBatch,
  finalizeCommercialExportBatch,
  listCommercialExportBatches,
  listSalesInvoicesPage,
  prepareCommercialExportBatch,
  upsertAccountingReview,
  type CommercialExportPackage,
  type SalesInvoiceListRow,
} from '../api/commercialFlowService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'

function monthStartIso(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`
}

function todayIso(): string {
  return localDateIso()
}

function downloadBlob(filename: string, blob: Blob) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}

function downloadJson(filename: string, payload: unknown) {
  downloadBlob(filename, new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' }))
}

function downloadText(filename: string, content: string, mime: string) {
  downloadBlob(filename, new Blob([content], { type: mime }))
}

/** Prefer ZIP of CSV files via PizZip; fall back to JSON + convenience CSV downloads. */
function downloadCommercialExportPackage(
  batchId: string,
  pkg: CommercialExportPackage | null,
  fallback: unknown,
) {
  const shortId = batchId.slice(0, 8)
  const files = pkg?.files
  const fileEntries =
    files && typeof files === 'object'
      ? Object.entries(files).filter((entry): entry is [string, string] => typeof entry[1] === 'string')
      : []

  if (fileEntries.length > 0) {
    try {
      const zip = new PizZip()
      for (const [name, content] of fileEntries) {
        zip.file(name, content)
      }
      if (pkg?.manifest && !fileEntries.some(([name]) => name === 'manifest.json')) {
        zip.file('manifest.json', JSON.stringify(pkg.manifest, null, 2))
      }
      const generated = zip.generate({ type: 'blob' })
      downloadBlob(`commercial-export-${shortId}.zip`, generated)
      return
    } catch {
      // Fall through to JSON + sequential CSV downloads.
    }

    downloadJson(`commercial-export-${shortId}.json`, pkg ?? fallback)
    const invoicesCsv = files?.['invoices.csv']
    if (typeof invoicesCsv === 'string') {
      downloadText('invoices.csv', invoicesCsv, 'text/csv;charset=utf-8')
    }
    if (pkg?.manifest) {
      downloadJson('manifest.json', pkg.manifest)
    }
    return
  }

  downloadJson(`commercial-export-${shortId}.json`, pkg ?? fallback)
}

export function SalesAccountingPage() {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const canExport = usePermission('invoices.export')
  const canReview = usePermission('invoices.review')
  const [periodFrom, setPeriodFrom] = useState(monthStartIso)
  const [periodTo, setPeriodTo] = useState(todayIso)
  const [busy, setBusy] = useState(false)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const exportOpIdRef = useRef<string | null>(null)
  const exportPeriodKeyRef = useRef<string | null>(null)

  function clientOpIdForExport(): string {
    const periodKey = `${periodFrom}|${periodTo}`
    if (exportPeriodKeyRef.current !== periodKey || !exportOpIdRef.current) {
      exportPeriodKeyRef.current = periodKey
      exportOpIdRef.current = generateClientOpId()
    }
    return exportOpIdRef.current
  }

  const batchesQuery = useQuery({
    queryKey: ['commercial_export_batches'],
    queryFn: () => listCommercialExportBatches(15),
    enabled: canExport || canReview,
  })

  const pendingQuery = useQuery({
    queryKey: ['sales_invoices_pending_review', periodFrom, periodTo],
    queryFn: () =>
      listSalesInvoicesPage({
        documentStatus: ['issued'],
        dateFrom: periodFrom || null,
        dateTo: periodTo || null,
        limit: 30,
      }),
    enabled: canReview || canExport,
  })

  const pendingItems = useMemo(
    () =>
      (pendingQuery.data?.items ?? []).filter(
        (row) => (row.review_status ?? 'pending') === 'pending',
      ),
    [pendingQuery.data?.items],
  )

  async function runExport() {
    if (!canExport) return
    setBusy(true)
    try {
      const prepared = await prepareCommercialExportBatch({
        periodFrom,
        periodTo,
        clientOpId: clientOpIdForExport(),
      })
      if (prepared.status === 'failed' || prepared.rowCount === 0) {
        // Failed batch frees the op id server-side; mint a new one for the next prepare.
        exportOpIdRef.current = null
        toast({
          variant: 'destructive',
          title: t('projects.sales.export_failed', 'Export fallit'),
          description: t(
            'projects.sales.export_no_docs',
            'No hi ha factures vàlides al període.',
          ),
        })
        void batchesQuery.refetch()
        return
      }
      await finalizeCommercialExportBatch(prepared.batchId)
      const claimed = await claimCommercialExportBatch(prepared.batchId)
      downloadCommercialExportPackage(
        prepared.batchId,
        claimed.package,
        {
          batch_id: claimed.batchId,
          checksum: claimed.checksum,
          row_count: claimed.rowCount,
        },
      )
      toast({
        title: t('projects.sales.export_ready', 'Export generat'),
        description: t('projects.sales.export_rows', '{{count}} factures', {
          count: claimed.rowCount,
        }),
      })
      void batchesQuery.refetch()
      void pendingQuery.refetch()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: commercialErrorMessage(err),
      })
    } finally {
      setBusy(false)
    }
  }

  async function claimAgain(batchId: string) {
    if (!canExport) return
    setBusy(true)
    try {
      const claimed = await claimCommercialExportBatch(batchId)
      downloadCommercialExportPackage(
        batchId,
        claimed.package,
        { batch_id: batchId },
      )
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: commercialErrorMessage(err),
      })
    } finally {
      setBusy(false)
    }
  }

  async function reviewSelected(status: 'reviewed' | 'needs_changes') {
    if (!selectedId || !canReview) return
    setBusy(true)
    try {
      await upsertAccountingReview({ documentId: selectedId, status })
      toast({ title: t('projects.sales.review_saved', 'Revisió desada') })
      setSelectedId(null)
      void pendingQuery.refetch()
      void queryClient.invalidateQueries({ queryKey: ['sales_invoices'] })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: commercialErrorMessage(err),
      })
    } finally {
      setBusy(false)
    }
  }

  if (!canExport && !canReview) {
    return (
      <div className="rounded-xl border border-dashed border-border px-4 py-8 text-center">
        <p className="text-sm text-muted-foreground">
          {t(
            'projects.sales.accounting_forbidden',
            'Cal permís de revisió o exportació comptable.',
          )}
        </p>
      </div>
    )
  }

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold">
          {t('projects.sales.accounting_title', 'Gestoria / export')}
        </h2>
        <p className="text-sm text-muted-foreground">
          {t(
            'projects.sales.accounting_help',
            'Export canònic PiMed (JSON amb CSV). Regenerar crea un lot nou.',
          )}
        </p>
      </div>

      <section className="space-y-3 rounded-xl border border-border bg-card p-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="space-y-1 text-xs text-muted-foreground">
            <span>{t('projects.collections.filter_issued_from', 'Des de')}</span>
            <Input
              type="date"
              value={periodFrom}
              onChange={(e) => setPeriodFrom(e.target.value)}
            />
          </label>
          <label className="space-y-1 text-xs text-muted-foreground">
            <span>{t('projects.collections.filter_issued_to', 'Fins a')}</span>
            <Input type="date" value={periodTo} onChange={(e) => setPeriodTo(e.target.value)} />
          </label>
        </div>
        {canExport ? (
          <Button type="button" disabled={busy || !periodFrom || !periodTo} onClick={() => void runExport()}>
            {t('projects.sales.generate_export', 'Generar export')}
          </Button>
        ) : null}
      </section>

      {canReview ? (
        <section className="space-y-3">
          <h3 className="text-sm font-semibold">
            {t('projects.sales.pending_review', 'Pendent de revisar')}
          </h3>
          {pendingQuery.isLoading ? (
            <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p>
          ) : null}
          <ul className="divide-y rounded-xl border border-border bg-card">
            {pendingItems.length === 0 ? (
              <li className="px-4 py-3 text-sm text-muted-foreground">—</li>
            ) : (
              pendingItems.map((row: SalesInvoiceListRow) => (
                <li
                  key={row.id}
                  className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm"
                >
                  <label className="flex items-center gap-2">
                    <input
                      type="radio"
                      name="review-doc"
                      checked={selectedId === row.id}
                      onChange={() => setSelectedId(row.id)}
                    />
                    <span className="font-medium">{row.doc_number ?? row.id.slice(0, 8)}</span>
                    <span className="text-muted-foreground">{row.client_display_name}</span>
                  </label>
                  <span className="tabular-nums text-muted-foreground">
                    {Number(row.total).toFixed(2)} €
                  </span>
                </li>
              ))
            )}
          </ul>
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              size="sm"
              disabled={busy || !selectedId}
              onClick={() => void reviewSelected('reviewed')}
            >
              {t('projects.sales.mark_reviewed', 'Marcar revisat')}
            </Button>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={busy || !selectedId}
              onClick={() => void reviewSelected('needs_changes')}
            >
              {t('projects.sales.mark_needs_changes', 'Demanar canvis')}
            </Button>
          </div>
        </section>
      ) : null}

      <section className="space-y-3">
        <h3 className="text-sm font-semibold">
          {t('projects.sales.recent_batches', 'Lots recents')}
        </h3>
        <ul className="divide-y rounded-xl border border-border bg-card">
          {(batchesQuery.data ?? []).length === 0 ? (
            <li className="px-4 py-3 text-sm text-muted-foreground">—</li>
          ) : (
            (batchesQuery.data ?? []).map((batch) => (
              <li
                key={batch.id}
                className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm"
              >
                <div>
                  <p className="font-medium">
                    {batch.period_from} → {batch.period_to}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {batch.status} · {batch.row_count} ok
                    {batch.failed_count ? ` · ${batch.failed_count} fail` : ''}
                    {batch.checksum ? ` · ${batch.checksum.slice(0, 8)}…` : ''}
                  </p>
                </div>
                {canExport && batch.status === 'ready' ? (
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={busy}
                    onClick={() => void claimAgain(batch.id)}
                  >
                    {t('projects.sales.download_export', 'Descarregar')}
                  </Button>
                ) : null}
              </li>
            ))
          )}
        </ul>
      </section>
    </div>
  )
}
