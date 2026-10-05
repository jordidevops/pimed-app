import { Navigate, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { getCommercialDocumentDetail } from '../api/commercialFlowService'
import { CommercialDocumentDetail } from './CommercialDocumentDetail'
import { CommercialDocumentShareSheet } from './CommercialDocumentShareSheet'

export function QuoteDetailPage() {
  const { id } = useParams<{ id: string }>()
  const [shareOpen, setShareOpen] = useState(false)

  const detailQuery = useQuery({
    queryKey: ['commercial_document', id, 'type-guard'],
    queryFn: () => getCommercialDocumentDetail(id!),
    enabled: !!id,
  })

  if (!id) return <Navigate to="/sales/quotes" replace />

  const docType = detailQuery.data?.doc_type
  if (docType === 'delivery_note') {
    return <Navigate to={`/sales/delivery-notes/${id}`} replace />
  }
  if (docType === 'invoice') {
    return <Navigate to={`/sales/invoices/${id}`} replace />
  }
  if (
    detailQuery.isSuccess &&
    docType &&
    docType !== 'quote' &&
    docType !== 'quote_amendment'
  ) {
    return <Navigate to="/sales/quotes" replace />
  }

  return (
    <>
      <CommercialDocumentDetail
        documentId={id}
        backTo="/sales/quotes"
        dmsReturnTo={`/sales/quotes/${id}`}
        onShare={() => setShareOpen(true)}
      />
      {shareOpen ? (
        <CommercialDocumentShareSheet documentId={id} open onClose={() => setShareOpen(false)} />
      ) : null}
    </>
  )
}
