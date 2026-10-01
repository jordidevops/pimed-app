/** Commercial hint used to filter/label work orders in the new-quote picker. */
export type QuotePickerCommercialHint =
  | 'no_quote'
  | 'quote_open'
  | 'needs_prepare'
  | 'agreement_draft'
  | 'agreement_pending'
  | 'agreement_active'
  | 'other'

export function rankQuotePickerHint(hint: QuotePickerCommercialHint): number {
  switch (hint) {
    case 'agreement_active':
      return 60
    case 'agreement_pending':
      return 50
    case 'agreement_draft':
      return 40
    case 'needs_prepare':
      return 30
    case 'quote_open':
      return 20
    case 'other':
      return 10
    case 'no_quote':
    default:
      return 0
  }
}

export function pickStrongerQuotePickerHint(
  current: QuotePickerCommercialHint,
  next: QuotePickerCommercialHint | null | undefined,
): QuotePickerCommercialHint {
  if (!next) return current
  return rankQuotePickerHint(next) > rankQuotePickerHint(current) ? next : current
}

export function hintFromAgreementState(
  agreement: { status: string } | undefined,
  version: { status: string } | undefined,
): QuotePickerCommercialHint | null {
  if (!agreement) return null
  if (['cancelled'].includes(agreement.status)) return null
  if (version?.status === 'pending_signature') return 'agreement_pending'
  if (version?.status === 'draft') return 'agreement_draft'
  if (agreement.status === 'active' || agreement.status === 'pending_start') {
    return 'agreement_active'
  }
  if (version?.status === 'signed') {
    return agreement.status === 'finished' || agreement.status === 'suspended'
      ? 'other'
      : 'agreement_active'
  }
  if (['suspended', 'finished'].includes(agreement.status)) return 'other'
  return 'agreement_draft'
}

export function hintFromQuoteWithoutAgreement(quote: {
  status: string
  formalization_mode: string | null
}): QuotePickerCommercialHint {
  if (quote.status === 'accepted' && quote.formalization_mode === 'separate_agreement') {
    return 'needs_prepare'
  }
  if (['draft', 'issued', 'pending_approval'].includes(quote.status)) {
    return 'quote_open'
  }
  return 'other'
}
