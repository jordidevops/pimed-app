export const PLATFORM_QUOTE_CONTRACT_TEMPLATE_ID =
  '76000000-0000-0000-0000-000000000006'
export const PLATFORM_AGREEMENT_TEMPLATE_ID =
  '76100000-0000-0000-0000-000000000001'
export const PLATFORM_MAINTENANCE_AGREEMENT_TEMPLATE_ID =
  '76100000-0000-0000-0000-000000000002'

export type CommercialRelationshipBadge =
  | 'quote'
  | 'quote_contract'
  | 'formal_contract'
  | 'agreement_pending'
  | 'agreement_active'

function isQuoteContractTemplate(templateId: string | null | undefined, templateName: string | null | undefined): boolean {
  if (templateId === PLATFORM_QUOTE_CONTRACT_TEMPLATE_ID) return true
  const name = (templateName ?? '').toLowerCase()
  return name.includes('pressupost i contracte') || name.includes('presupuesto y contrato')
}

export function commercialRelationshipBadges(input: {
  docType?: string | null
  formalizationMode?: string | null
  templateId?: string | null
  templateName?: string | null
  agreementStatus?: string | null
  versionStatus?: string | null
}): CommercialRelationshipBadge[] {
  if (input.docType === 'delivery_note') return []
  const badges: CommercialRelationshipBadge[] = []
  const separate = input.formalizationMode === 'separate_agreement'
  if (separate) badges.push('formal_contract')
  else if (isQuoteContractTemplate(input.templateId, input.templateName)) badges.push('quote_contract')
  else if (input.docType === 'quote' || input.docType === 'quote_amendment' || !input.docType) {
    badges.push('quote')
  }

  if (input.agreementStatus === 'active') badges.push('agreement_active')
  else if (input.versionStatus === 'pending_signature') badges.push('agreement_pending')
  return badges
}
