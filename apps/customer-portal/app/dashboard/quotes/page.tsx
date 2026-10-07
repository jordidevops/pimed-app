import { renderCommercialCataloguePage } from '@/lib/commercial-page'

export default function QuotesAgreementsPage() {
  return renderCommercialCataloguePage({
    kind: 'quotes_agreements',
    current: 'quotes_agreements',
    titleKey: 'commercial.quotes_title',
    titleFallback: 'Pressupostos i acords',
    emptyKey: 'commercial.quotes_empty',
    emptyFallback: 'Encara no hi ha pressupostos ni acords visibles.',
  })
}
