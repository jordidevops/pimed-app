import { renderCommercialDetailPage } from '@/lib/commercial-detail-page'

export default async function DeliveryNoteDetailPage({
  params,
}: {
  params: Promise<{ id: string }>
}) {
  const { id } = await params
  return renderCommercialDetailPage({
    id,
    action: 'get_delivery_note',
    current: 'delivery_notes',
    backHref: '/dashboard/delivery-notes',
    backLabelKey: 'nav.delivery_notes',
    backLabelFallback: 'Albarans',
  })
}
