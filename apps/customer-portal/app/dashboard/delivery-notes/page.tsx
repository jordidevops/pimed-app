import { renderCommercialCataloguePage } from '@/lib/commercial-page'

export default function DeliveryNotesPage() {
  return renderCommercialCataloguePage({
    kind: 'delivery_notes',
    current: 'delivery_notes',
    titleKey: 'commercial.delivery_notes_title',
    titleFallback: 'Albarans',
    emptyKey: 'commercial.delivery_notes_empty',
    emptyFallback: 'Encara no hi ha albarans visibles.',
  })
}
