import { renderCommercialDetailPage } from '@/lib/commercial-detail-page'

export default async function QuoteDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>
  searchParams: Promise<{ kind?: string }>
}) {
  const { id } = await params
  const sp = await searchParams
  const itemKind = sp.kind === 'agreement' ? 'agreement' : 'document'

  return renderCommercialDetailPage({
    id,
    action: 'get_quote_or_agreement',
    itemKind,
    current: 'quotes_agreements',
    backHref: '/dashboard/quotes',
    backLabelKey: 'nav.quotes_agreements',
    backLabelFallback: 'Pressupostos i acords',
  })
}
