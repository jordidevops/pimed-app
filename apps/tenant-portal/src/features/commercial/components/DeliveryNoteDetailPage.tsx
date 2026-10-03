import { Link, Navigate, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { supabase } from '@/lib/supabase'
import {
  commercialDocumentOrderPath,
  getCommercialDocumentDetail,
  getDeliveryNoteCollectionDetail,
} from '../api/commercialFlowService'
import { CollectPaymentDialog } from './CollectPaymentDialog'
import { CommercialDocumentShareSheet } from './CommercialDocumentShareSheet'
import { CommercialDocumentView } from './CommercialDocumentView'
import { CommercialNativeSignDialog } from './CommercialNativeSignDialog'
import { RectifyDeliveryNoteDialog } from './RectifyDeliveryNoteDialog'
import { useState } from 'react'
import { passesGate, useNavGateContext } from '@/features/sidebar-nav'

function conformityLabel(
  status: string,
  t: (key: string, fallback: string) => string,
): string {
  if (status === 'signed' || status === 'accepted') {
    return t('projects.commercial.status_signed', 'Signat')
  }
  if (status === 'issued') {
    return t('projects.commercial.status_pending_signature', 'Pendent de signatura')
  }
  if (status === 'cancelled') {
    return t('projects.commercial.status_cancelled', 'Cancel·lat')
  }
  return status
}

function billingLabel(
  status: string,
  t: (key: string, fallback: string) => string,
): string {
  if (status === 'rectified') return t('projects.sales.billing_rectified', 'Rectificat')
  if (status === 'invoiced') return t('projects.sales.billing_invoiced', 'Facturat')
  if (status === 'draft_invoice') return t('projects.sales.billing_draft', 'En esborrany')
  return t('projects.sales.billing_to_invoice', 'Per facturar')
}

function collectionLabel(
  status: string,
  t: (key: string, fallback: string) => string,
): string {
  if (status === 'paid') return t('projects.sales.collection_paid', 'Cobrat')
  if (status === 'partial') return t('projects.sales.collection_partial', 'Parcial')
  return t('projects.sales.collection_pending', 'Pendent de cobrar')
}

export function DeliveryNoteDetailPage() {
  const { id } = useParams<{ id: string }>()
  const { t } = useTranslation('projects')
  const isFieldService = useIsFieldService()
  const projectBase = isFieldService ? '/field/orders' : '/projects'
  const { ctx, gatesLoading } = useNavGateContext()
  const isOffice = !gatesLoading && passesGate('isOffice', ctx)

  const [shareOpen, setShareOpen] = useState(false)
  const [signOpen, setSignOpen] = useState(false)
  const [collectOpen, setCollectOpen] = useState(false)
  const [rectifyOpen, setRectifyOpen] = useState(false)
  const [viewOpen, setViewOpen] = useState(false)
  const [busy, setBusy] = useState(false)

  const detailQuery = useQuery({
    queryKey: ['commercial_document', id],
    queryFn: () => getCommercialDocumentDetail(id!),
    enabled: !!id,
  })

  const invoiceLinkQuery = useQuery({
    queryKey: ['delivery_note_invoice_link', id],
    queryFn: async () => {
      const { data: link, error } = await supabase
        .from('invoice_delivery_notes' as never)
        .select('invoice_id')
        .eq('delivery_note_id', id!)
        .is('released_at', null)
        .maybeSingle()
      if (error) throw error
      const invoiceId = (link as { invoice_id?: string } | null)?.invoice_id
      if (!invoiceId) return null
      const { data: inv, error: invError } = await supabase
        .from('commercial_documents' as never)
        .select('id, doc_number, status')
        .eq('id', invoiceId)
        .maybeSingle()
      if (invError) throw invError
      return (inv as { id: string; doc_number: string | null; status: string } | null) ?? null
    },
    enabled: !!id,
  })

  const collectionQuery = useQuery({
    queryKey: ['delivery_note_collection_detail', id],
    queryFn: () => getDeliveryNoteCollectionDetail(id!),
    enabled: !!id,
  })

  if (!id) return <Navigate to="/sales/delivery-notes" replace />

  if (detailQuery.isLoading || gatesLoading) {
    return (
      <div className="mx-auto max-w-5xl px-4 py-6">
        <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p>
      </div>
    )
  }

  const doc = detailQuery.data
  if (!doc || detailQuery.error) {
    return (
      <div className="mx-auto max-w-5xl space-y-3 px-4 py-6">
        <p className="text-sm text-destructive" role="alert">
          {t('projects.collections.load_failed', 'Error en carregar')}
        </p>
        <Button asChild variant="outline" size="sm">
          <Link to="/sales/delivery-notes">{t('common.back', 'Tornar')}</Link>
        </Button>
      </div>
    )
  }

  const collection = collectionQuery.data
  const invoice = invoiceLinkQuery.data
  const invoiceId = invoice?.id ?? null
  const invoiceRef = invoice?.doc_number ?? collection?.external_invoice_ref ?? null
  const billingStatus =
    doc.status === 'cancelled'
      ? 'rectified'
      : invoice
        ? invoice.status === 'draft'
          ? 'draft_invoice'
          : 'invoiced'
        : collection?.invoiced
          ? 'invoiced'
          : 'to_invoice'
  const remainingCents =
    collection?.remaining_cents ?? Math.round(Number(doc.total ?? 0) * 100)
  const paidCents = collection?.paid_cents ?? 0
  const collectionStatus =
    doc.status === 'cancelled'
      ? 'paid'
      : remainingCents <= 0
        ? 'paid'
        : paidCents > 0
          ? 'partial'
          : 'pending'
  const canCollect =
    billingStatus === 'to_invoice' && remainingCents > 0 && doc.status !== 'cancelled'

  return (
    <div className="mx-auto max-w-5xl space-y-5 px-4 py-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="space-y-2">
          <div className="flex flex-wrap items-center gap-2">
            <Button asChild variant="ghost" size="sm" className="-ml-2">
              <Link to="/sales/delivery-notes">{t('common.back', 'Tornar')}</Link>
            </Button>
            <h1 className="text-2xl font-bold">
              {doc.doc_number ?? id.slice(0, 8)}
            </h1>
          </div>
          <div className="flex flex-wrap gap-2">
            <Badge variant="outline">
              {t('projects.sales.conformity', 'Conformitat')}:{' '}
              {conformityLabel(doc.status, t)}
            </Badge>
            <Badge variant="outline">
              {t('projects.sales.billing', 'Facturació')}:{' '}
              {billingLabel(billingStatus, t)}
            </Badge>
            <Badge variant="outline">
              {t('projects.sales.collection', 'Cobrament')}:{' '}
              {collectionLabel(collectionStatus, t)}
            </Badge>
          </div>
          {invoiceId || invoiceRef ? (
            <p className="text-sm text-muted-foreground">
              {t('projects.collections.included_in_invoice', 'Inclòs a la factura {{ref}}', {
                ref: invoiceRef ?? invoiceId?.slice(0, 8),
              })}
              {invoiceId ? (
                <>
                  {' · '}
                  <Link
                    to={`/sales/invoices/${invoiceId}`}
                    className="font-medium text-foreground underline"
                  >
                    {t('projects.sales.open_invoice', 'Obrir factura')}
                  </Link>
                </>
              ) : null}
            </p>
          ) : null}
        </div>
        <div className="flex flex-wrap gap-2">
          <Button type="button" size="sm" variant="outline" onClick={() => setViewOpen(true)}>
            {t('projects.commercial.view', 'Veure')}
          </Button>
          <Button type="button" size="sm" variant="outline" onClick={() => setShareOpen(true)}>
            {t('projects.commercial.send', 'Enviar')}
          </Button>
          {doc.status === 'issued' ? (
            <Button type="button" size="sm" variant="outline" onClick={() => setSignOpen(true)}>
              {t('projects.commercial.sign_delivery', 'Signar conformitat')}
            </Button>
          ) : null}
          {canCollect ? (
            <Button type="button" size="sm" onClick={() => setCollectOpen(true)}>
              {t('projects.commercial.collect', 'Cobrar')}
            </Button>
          ) : null}
          {invoiceId ? (
            <Button type="button" size="sm" asChild>
              <Link to={`/sales/invoices/${invoiceId}`}>
                {t('projects.sales.open_invoice', 'Obrir factura')}
              </Link>
            </Button>
          ) : null}
          {isOffice && billingStatus === 'to_invoice' ? (
            <Button type="button" size="sm" variant="outline" onClick={() => setRectifyOpen(true)}>
              {t('projects.commercial.rectify', 'Rectificar')}
            </Button>
          ) : null}
          {doc.project_id ? (
            <Button type="button" size="sm" variant="outline" asChild>
              <Link to={commercialDocumentOrderPath(projectBase, doc.project_id, 'delivery_note')}>
                {t('projects.collections.open_order', 'Obrir OS')}
              </Link>
            </Button>
          ) : null}
        </div>
      </div>

      <div className="rounded-xl border border-border bg-card p-4 text-sm">
        <p>
          <span className="text-muted-foreground">{t('projects.quotes.client', 'Client')}: </span>
          {(doc.buyer_snapshot as { display_name?: string } | undefined)?.display_name ?? '—'}
        </p>
        <p className="mt-1 tabular-nums">
          <span className="text-muted-foreground">{t('projects.commercial.total', 'Total')}: </span>
          {Number(doc.total).toFixed(2)} {doc.currency ?? 'EUR'}
        </p>
        <p className="mt-1 text-muted-foreground">
          {t('projects.sales.lines', 'Línies')}: {doc.lines?.length ?? 0}
        </p>
      </div>

      {viewOpen ? (
        <CommercialDocumentView
          documentId={id}
          open
          onClose={() => setViewOpen(false)}
          onChanged={() => {
            void detailQuery.refetch()
            void collectionQuery.refetch()
            void invoiceLinkQuery.refetch()
          }}
          onShare={() => setShareOpen(true)}
        />
      ) : null}
      {shareOpen ? (
        <CommercialDocumentShareSheet documentId={id} open onClose={() => setShareOpen(false)} />
      ) : null}
      {signOpen ? (
        <CommercialNativeSignDialog
          documentId={id}
          action="delivery"
          open
          onClose={() => setSignOpen(false)}
          onCompleted={() => {
            void detailQuery.refetch()
            void collectionQuery.refetch()
          }}
        />
      ) : null}
      {collectOpen ? (
        <CollectPaymentDialog
          open
          documentId={id}
          documentNumber={doc.doc_number}
          remainingCents={remainingCents}
          previousPayments={[]}
          advancePaidCents={collection?.advance_applied_cents ?? 0}
          onClose={() => setCollectOpen(false)}
          onCollected={() => {
            setCollectOpen(false)
            void detailQuery.refetch()
            void collectionQuery.refetch()
          }}
        />
      ) : null}
      <RectifyDeliveryNoteDialog
        documentId={rectifyOpen ? id : null}
        open={rectifyOpen}
        busy={busy}
        onBusyChange={setBusy}
        onClose={() => setRectifyOpen(false)}
        onCompleted={() => {
          void detailQuery.refetch()
          void collectionQuery.refetch()
          void invoiceLinkQuery.refetch()
        }}
      />
    </div>
  )
}
