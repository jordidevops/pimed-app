import { renderCommercialCataloguePage } from '@/lib/commercial-page'

export default function InvoicesPage() {
  return renderCommercialCataloguePage({
    kind: 'invoices',
    current: 'invoices',
    titleKey: 'commercial.invoices_title',
    titleFallback: 'Factures',
    emptyKey: 'commercial.invoices_empty',
    emptyFallback: 'Encara no hi ha factures visibles.',
  })
}
