import { Link, Navigate, useNavigate, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useIsFieldService, useSectorLabel } from '@/hooks/useSectorLabel'
import { supabase } from '@/lib/supabase'
import {
  commercialDocumentOrderPath,
  getCommercialDocumentDetail,
  getDeliveryNoteCollectionDetail,
} from '../api/commercialFlowService'
import { CollectPaymentDialog } from './CollectPaymentDialog'
import { CommercialDocumentShareSheet } from './CommercialDocumentShareSheet'
import { CommercialDocumentDetail } from './CommercialDocumentDetail'
import { RectifyDeliveryNoteDialog } from './RectifyDeliveryNoteDialog'
import { useState } from 'react'
import { passesGate, useNavGateContext } from '@/features/sidebar-nav'

export function DeliveryNoteDetailPage() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const { t } = useTranslation(['projects', 'field-service', 'common'])
  const isFieldService = useIsFieldService()
  const projectLabel = useSectorLabel(
    'project',
    isFieldService
      ? t('field-service:orders.singular', 'OS')
      : t('projects.list.singular', 'Projecte'),
  )
  const projectBase = isFieldService ? '/field/orders' : '/projects'
  const { ctx, gatesLoading } = useNavGateContext()
  const isOffice = !gatesLoading && passesGate('isOffice', ctx)

  const [shareOpen, setShareOpen] = useState(false)
  const [collectOpen, setCollectOpen] = useState(false)
  const [rectifyOpen, setRectifyOpen] = useState(false)
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
      <div className="px-4 py-6 sm:px-6">
        <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p>
      </div>
    )
  }

  const doc = detailQuery.data
  if (!doc || detailQuery.error) {
    return (
      <div className="space-y-3 px-4 py-6 sm:px-6">
        <p className="text-sm text-destructive" role="alert">
          {t('projects.collections.load_failed', 'Error en carregar')}
        </p>
        <Button asChild variant="outline" size="sm">
          <Link to="/sales/delivery-notes">{t('common:back', 'Tornar')}</Link>
        </Button>
      </div>
    )
  }

  const collection = collectionQuery.data
  const invoice = invoiceLinkQuery.data
  const invoiceId = invoice?.id ?? null
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
  const canCollect =
    billingStatus === 'to_invoice' && remainingCents > 0 && doc.status !== 'cancelled'

  function refetchAll() {
    void detailQuery.refetch()
    void collectionQuery.refetch()
    void invoiceLinkQuery.refetch()
  }

  const commercialActions = (
    <>
      {canCollect ? (
        <Button type="button" size="sm" onClick={() => setCollectOpen(true)}>
          {t('projects.commercial.collect', 'Cobrar')}
        </Button>
      ) : null}
      {invoiceId ? (
        <Button type="button" size="sm" variant="outline" asChild>
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
            {projectLabel}
          </Link>
        </Button>
      ) : null}
    </>
  )

  return (
    <>
      <CommercialDocumentDetail
        documentId={id}
        backTo="/sales/delivery-notes"
        dmsReturnTo={`/sales/delivery-notes/${id}`}
        commercialActions={commercialActions}
        onShare={() => setShareOpen(true)}
        onChanged={refetchAll}
      />
      {shareOpen ? (
        <CommercialDocumentShareSheet documentId={id} open onClose={() => setShareOpen(false)} />
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
            refetchAll()
          }}
        />
      ) : null}
      <RectifyDeliveryNoteDialog
        documentId={rectifyOpen ? id : null}
        open={rectifyOpen}
        busy={busy}
        onBusyChange={setBusy}
        onClose={() => setRectifyOpen(false)}
        onCompleted={(newDocumentId) => {
          refetchAll()
          if (newDocumentId && newDocumentId !== id) {
            void navigate(`/sales/delivery-notes/${newDocumentId}`, { replace: true })
          }
        }}
      />
    </>
  )
}
