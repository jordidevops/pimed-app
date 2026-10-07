import { renderCommercialDetailPage } from '@/lib/commercial-detail-page'

export default async function InvoiceDetailPage({
  params,
}: {
  params: Promise<{ id: string }>
}) {
  const { id } = await params
  return renderCommercialDetailPage({
    id,
    action: 'get_invoice',
    current: 'invoices',
    backHref: '/dashboard/invoices',
    backLabelKey: 'nav.invoices',
    backLabelFallback: 'Factures',
  })
}
