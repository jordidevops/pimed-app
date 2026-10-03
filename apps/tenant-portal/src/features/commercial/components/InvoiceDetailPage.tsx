import { useEffect, useMemo, useRef, useState } from 'react'
import { Link, Navigate, useParams, useSearchParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { useTenant } from '@/contexts/TenantContext'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { supabase } from '@/lib/supabase'
import {
  cancelInvoice,
  getCommercialDocumentDetail,
  listSalesInvoicesPage,
  recordInvoicePayment,
  type CommercialDocumentLine,
} from '../api/commercialFlowService'
import { useCommercialPdf } from '../hooks/useCommercialPdf'
import { commercialFilename } from '../utils/commercialDocumentModel'
import { downloadCommercialDocumentPdfFromUrl } from '../utils/commercialDocumentPrint'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import { centsToEuros } from '../utils/paymentReceipt'
import { PaymentReceiptSheet } from './PaymentReceiptSheet'

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

type LinkedDeliveryNote = {
  id: string
  doc_number: string | null
  project_id: string | null
  status: string
  total: number
}

export function InvoiceDetailPage() {
  const { id } = useParams<{ id: string }>()
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  const [searchParams, setSearchParams] = useSearchParams()
  const canEdit = usePermission('invoices.edit')
  const [busy, setBusy] = useState(false)
  const [receiptPaymentId, setReceiptPaymentId] = useState<string | null>(null)
  const [collectOpen, setCollectOpen] = useState(searchParams.get('collect') === '1')
  const [payAmount, setPayAmount] = useState('')
  const [payMethod, setPayMethod] = useState('transfer')
  const [payReference, setPayReference] = useState('')
  const payOpIdRef = useRef<string | null>(null)
  const payIntentKeyRef = useRef<string | null>(null)

  function resetPayOpId() {
    payOpIdRef.current = null
    payIntentKeyRef.current = null
  }

  function clientOpIdForPayment(amountCents: number, method: string, reference: string): string {
    const key = `${amountCents}|${method}|${reference}`
    if (payIntentKeyRef.current !== key || !payOpIdRef.current) {
      payIntentKeyRef.current = key
      payOpIdRef.current = generateClientOpId()
    }
    return payOpIdRef.current
  }

  function setCollectDialogOpen(open: boolean) {
    setCollectOpen(open)
    if (!open) resetPayOpId()
  }

  const detailQuery = useQuery({
    queryKey: ['commercial_document', id],
    queryFn: () => getCommercialDocumentDetail(id!),
    enabled: !!id,
  })

  const docForPdf = detailQuery.data
  const pdf = useCommercialPdf({
    documentId: id ?? null,
    tenantId: docForPdf?.tenant_id ?? activeTenant?.id ?? null,
    enabled: !!id && !!docForPdf && docForPdf.doc_type === 'invoice',
    initialRenderedDocumentId: docForPdf?.rendered_document_id,
    initialPdfJobId: docForPdf?.pdf_job_id,
  })

  const linkedQuery = useQuery({
    queryKey: ['invoice_delivery_notes', id],
    queryFn: async (): Promise<LinkedDeliveryNote[]> => {
      const { data: links, error: linkError } = await supabase
        .from('invoice_delivery_notes' as never)
        .select('delivery_note_id')
        .eq('invoice_id', id!)
        .is('released_at', null)
      if (linkError) throw linkError
      const ids = ((links ?? []) as Array<{ delivery_note_id: string }>).map(
        (row) => row.delivery_note_id,
      )
      if (ids.length === 0) return []
      const { data: docs, error: docsError } = await supabase
        .from('commercial_documents' as never)
        .select('id, doc_number, project_id, status, total')
        .in('id', ids)
      if (docsError) throw docsError
      return ((docs ?? []) as LinkedDeliveryNote[]).map((doc) => ({
        ...doc,
        total: Number(doc.total ?? 0),
      }))
    },
    enabled: !!id,
  })

  const doc = detailQuery.data
  const lines: CommercialDocumentLine[] = doc?.lines ?? []
  const linked = linkedQuery.data ?? []

  const totalCents = useMemo(() => Math.round(Number(doc?.total ?? 0) * 100), [doc?.total])

  const balanceQuery = useQuery({
    queryKey: ['sales_invoice_row', id, doc?.doc_number],
    queryFn: async () => {
      const page = await listSalesInvoicesPage({
        q: doc?.doc_number ?? id!.slice(0, 8),
        limit: 20,
      })
      return page.items.find((row) => row.id === id) ?? null
    },
    enabled: !!id && !!doc,
  })

  const remainingCents = balanceQuery.data?.remaining_cents ?? totalCents
  const collectionStatus = balanceQuery.data?.collection_status ?? 'pending'
  const collectDefaultCents = Math.max(0, remainingCents)

  useEffect(() => {
    if (!collectOpen || !balanceQuery.isSuccess) return
    setPayAmount((collectDefaultCents / 100).toFixed(2))
  }, [collectOpen, balanceQuery.isSuccess, collectDefaultCents])

  if (!id) return <Navigate to="/sales/invoices" replace />

  if (detailQuery.isLoading) {
    return (
      <div className="mx-auto max-w-5xl px-4 py-6">
        <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p>
      </div>
    )
  }

  if (!doc || detailQuery.error) {
    return (
      <div className="mx-auto max-w-5xl space-y-3 px-4 py-6">
        <p className="text-sm text-destructive" role="alert">
          {t('projects.collections.load_failed', 'Error en carregar')}
        </p>
        <Button asChild variant="outline" size="sm">
          <Link to="/sales/invoices">{t('common.back', 'Tornar')}</Link>
        </Button>
      </div>
    )
  }

  async function handleCollect() {
    if (!id || !canEdit) return
    const amountCents = Math.round(Number(payAmount.replace(',', '.')) * 100)
    if (!Number.isFinite(amountCents) || amountCents <= 0) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: t('projects.sales.invalid_amount', 'Import no vàlid'),
      })
      return
    }
    const reference = payReference.trim()
    setBusy(true)
    try {
      const result = await recordInvoicePayment({
        invoiceId: id,
        amountCents,
        method: payMethod,
        reference: reference || null,
        clientOpId: clientOpIdForPayment(amountCents, payMethod, reference),
      })
      setReceiptPaymentId(result.paymentId)
      setCollectDialogOpen(false)
      if (searchParams.get('collect') === '1') {
        const next = new URLSearchParams(searchParams)
        next.delete('collect')
        setSearchParams(next, { replace: true })
      }
      void queryClient.invalidateQueries({ queryKey: ['commercial_document', id] })
      void queryClient.invalidateQueries({ queryKey: ['sales_invoice_row', id] })
      void queryClient.invalidateQueries({ queryKey: ['sales_invoices'] })
      void queryClient.invalidateQueries({ queryKey: ['sales_dashboard_kpis'] })
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

  async function handleCancel() {
    if (!id || !canEdit) return
    setBusy(true)
    try {
      await cancelInvoice({ invoiceId: id })
      toast({ title: t('projects.commercial.cancelled', 'Cancel·lat') })
      void detailQuery.refetch()
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

  const documentStatus = doc.status
  const canCollect =
    canEdit && documentStatus === 'issued' && collectDefaultCents > 0 && collectionStatus !== 'paid'

  const collectionLabel =
    collectionStatus === 'paid'
      ? t('projects.sales.collection_paid', 'Cobrat')
      : collectionStatus === 'partial'
        ? t('projects.sales.collection_partial', 'Parcial')
        : t('projects.sales.collection_pending', 'Pendent de cobrar')

  return (
    <div className="mx-auto max-w-5xl space-y-5 px-4 py-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="space-y-2">
          <div className="flex flex-wrap items-center gap-2">
            <Button asChild variant="ghost" size="sm" className="-ml-2">
              <Link to="/sales/invoices">{t('common.back', 'Tornar')}</Link>
            </Button>
            <h1 className="text-2xl font-bold">{doc.doc_number ?? id.slice(0, 8)}</h1>
          </div>
          <div className="flex flex-wrap gap-2">
            <Badge variant="outline">
              {t('projects.sales.document', 'Document')}: {documentStatus}
            </Badge>
            <Badge variant="outline">
              {t('projects.sales.collection', 'Cobrament')}: {collectionLabel}
            </Badge>
          </div>
          <p className="text-sm text-muted-foreground">
            {(doc.buyer_snapshot as { display_name?: string } | undefined)?.display_name ?? '—'}
            {doc.issued_at ? ` · ${new Date(doc.issued_at).toLocaleDateString('ca-ES')}` : null}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          {canCollect ? (
            <Button
              type="button"
              size="sm"
              disabled={busy}
              onClick={() => {
                setPayAmount((collectDefaultCents / 100).toFixed(2))
                setPayReference('')
                resetPayOpId()
                setCollectDialogOpen(true)
              }}
            >
              {t('projects.sales.collect_invoice', 'Cobrar factura')}
            </Button>
          ) : null}
          {doc.doc_type === 'invoice' && pdf.status === 'ready' && pdf.downloadUrl ? (
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => {
                downloadCommercialDocumentPdfFromUrl(
                  pdf.downloadUrl!,
                  commercialFilename(doc, 'pdf'),
                )
              }}
            >
              {t('projects.commercial.share_pdf', 'Descarregar PDF')}
            </Button>
          ) : null}
          {doc.doc_type === 'invoice' && (pdf.status === 'loading' || pdf.status === 'pending') ? (
            <Button type="button" size="sm" variant="outline" disabled>
              {t('projects.commercial.pdf_generating', 'Generant PDF…')}
            </Button>
          ) : null}
          {doc.doc_type === 'invoice' && pdf.status === 'error' ? (
            <Button type="button" size="sm" variant="outline" onClick={() => void pdf.refresh()}>
              {t('projects.commercial.share_pdf', 'Descarregar PDF')}
            </Button>
          ) : null}
          {canEdit && documentStatus === 'issued' ? (
            <Button type="button" size="sm" variant="outline" disabled={busy} onClick={() => void handleCancel()}>
              {t('projects.commercial.cancel', 'Anul·lar')}
            </Button>
          ) : null}
        </div>      </div>

      <section className="space-y-2">
        <h2 className="text-sm font-semibold">{t('projects.sales.lines', 'Línies')}</h2>
        <ul className="divide-y rounded-xl border border-border bg-card">
          {lines.length === 0 ? (
            <li className="px-4 py-3 text-sm text-muted-foreground">—</li>
          ) : (
            lines.map((line) => (
              <li key={line.id} className="flex flex-wrap justify-between gap-2 px-4 py-3 text-sm">
                <span>{line.name || line.description || line.id.slice(0, 8)}</span>
                <span className="tabular-nums">
                  {moneyFmt.format(Number(line.line_total ?? line.unit_price ?? 0))} €
                </span>
              </li>
            ))
          )}
        </ul>
      </section>

      <section className="space-y-2">
        <h2 className="text-sm font-semibold">
          {t('projects.sales.linked_delivery_notes', 'Albarans enllaçats')}
        </h2>
        <ul className="divide-y rounded-xl border border-border bg-card">
          {linked.length === 0 ? (
            <li className="px-4 py-3 text-sm text-muted-foreground">—</li>
          ) : (
            linked.map((dn) => (
              <li key={dn.id} className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm">
                <Link to={`/sales/delivery-notes/${dn.id}`} className="font-medium hover:underline">
                  {dn.doc_number ?? dn.id.slice(0, 8)}
                </Link>
                <span className="tabular-nums text-muted-foreground">
                  {moneyFmt.format(dn.total)} €
                </span>
              </li>
            ))
          )}
        </ul>
      </section>

      <div className="space-y-1 text-right">
        <p className="text-lg font-semibold tabular-nums">
          {moneyFmt.format(centsToEuros(totalCents))} €
        </p>
        {collectDefaultCents !== totalCents ? (
          <p className="text-sm text-muted-foreground tabular-nums">
            {t('projects.collections.remaining', 'Pendent')}:{' '}
            {moneyFmt.format(centsToEuros(collectDefaultCents))} €
          </p>
        ) : null}
      </div>

      <Dialog
        open={collectOpen}
        onOpenChange={(open) => {
          if (busy) return
          setCollectDialogOpen(open)
          if (!open && searchParams.get('collect') === '1') {
            const next = new URLSearchParams(searchParams)
            next.delete('collect')
            setSearchParams(next, { replace: true })
          }
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t('projects.sales.collect_invoice', 'Cobrar factura')}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <p className="text-sm text-muted-foreground">
              {t('projects.collections.remaining', 'Pendent')}:{' '}
              <span className="font-medium tabular-nums text-foreground">
                {moneyFmt.format(centsToEuros(collectDefaultCents))} €
              </span>
            </p>
            <div className="space-y-1.5">
              <Label htmlFor="invoice-collect-amount">
                {t('projects.commercial.amount', 'Import')}
              </Label>
              <Input
                id="invoice-collect-amount"
                inputMode="decimal"
                value={payAmount}
                onChange={(e) => setPayAmount(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="invoice-collect-method">
                {t('projects.commercial.method', 'Mètode')}
              </Label>
              <select
                id="invoice-collect-method"
                className="h-10 w-full rounded-md border border-input bg-background px-3 text-sm"
                value={payMethod}
                onChange={(e) => setPayMethod(e.target.value)}
              >
                <option value="transfer">{t('projects.commercial.method_transfer', 'Transferència')}</option>
                <option value="card">{t('projects.commercial.method_card', 'Targeta')}</option>
                <option value="cash">{t('projects.commercial.method_cash', 'Efectiu')}</option>
                <option value="bizum">Bizum</option>
              </select>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="invoice-collect-ref">
                {t('projects.collections.payment_reference', 'Referència')}
              </Label>
              <Input
                id="invoice-collect-ref"
                value={payReference}
                onChange={(e) => setPayReference(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={busy}
              onClick={() => setCollectDialogOpen(false)}
            >
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" disabled={busy} onClick={() => void handleCollect()}>
              {t('projects.commercial.collect', 'Cobrar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {receiptPaymentId ? (
        <PaymentReceiptSheet
          paymentId={receiptPaymentId}
          open
          onClose={() => setReceiptPaymentId(null)}
        />
      ) : null}
    </div>
  )
}
