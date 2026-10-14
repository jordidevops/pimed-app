/**
 * Liquid context for a commercial agreement (CT-3 / CF-21-f).
 * Keep in sync with apps/tenant-portal/src/features/commercial/utils/commercialAgreementContext.ts
 */

export type AgreementTemplateLine = {
  name: string
  description?: string | null
  unit?: string | null
  quantity?: number | string | null
  unit_price?: number | string | null
  discount_pct?: number | string | null
  tax_rate?: number | string | null
  line_subtotal?: number | string | null
  line_total?: number | string | null
}

export type AgreementSlaInput = {
  responseHours?: number | null
  resolutionHours?: number | null
  coverageNotes?: string | null
}

export type AgreementBillingInput = {
  cadence?: string | null
  amountCents?: number | null
  currency?: string | null
  anchorDay?: number | null
  nextBillingOn?: string | null
}

export type AgreementPartyInput = {
  displayName?: string | null
  taxId?: string | null
  email?: string | null
  phone?: string | null
  address?: string | null
}

export type AgreementTemplateContextInput = {
  agreementId: string
  agreementStatus: string
  agreementKind?: string | null
  workGate: string
  startsOn?: string | null
  endsOn?: string | null
  noticeDays?: number | null
  sla?: AgreementSlaInput | null
  billing?: AgreementBillingInput | null
  quoteId: string | null
  quoteNumber: string | null
  quoteContentHash: string | null
  quoteDocumentId: string | null
  locale: string
  currency: string
  subtotal: number
  total: number
  taxBreakdown?: string | null
  lines: AgreementTemplateLine[]
  tenantName: string
  tenantTaxId?: string | null
  tenantLogoUrl?: string | null
  seller?: AgreementPartyInput | null
  buyer?: AgreementPartyInput | null
  sellerName?: string | null
  buyerName?: string | null
}

function partyBlock(
  party: AgreementPartyInput | null | undefined,
  fallbackName: string | null | undefined,
): Record<string, string | null> {
  return {
    display_name: party?.displayName ?? fallbackName ?? null,
    tax_id: party?.taxId ?? null,
    email: party?.email ?? null,
    phone: party?.phone ?? null,
    address: party?.address ?? null,
  }
}

export function buildAgreementTemplateContext(
  input: AgreementTemplateContextInput,
): Record<string, unknown> {
  const kind = input.agreementKind?.trim() || "specific"
  const noQuote = !input.quoteId
  const sla = input.sla ?? {}
  const billing = input.billing ?? {}
  return {
    agreement: {
      id: input.agreementId,
      status: input.agreementStatus,
      kind,
      work_gate: input.workGate,
      starts_on: input.startsOn ?? null,
      ends_on: input.endsOn ?? null,
      notice_days: input.noticeDays ?? null,
      sla: {
        response_hours: sla.responseHours ?? null,
        resolution_hours: sla.resolutionHours ?? null,
        coverage_notes: sla.coverageNotes ?? null,
      },
      billing: {
        cadence: billing.cadence ?? null,
        amount_cents: billing.amountCents ?? null,
        currency: billing.currency ?? null,
        anchor_day: billing.anchorDay ?? null,
        next_billing_on: billing.nextBillingOn ?? null,
      },
    },
    source_quote: {
      id: input.quoteId,
      doc_number: noQuote ? "—" : input.quoteNumber,
      content_hash: noQuote ? "sense-annex" : input.quoteContentHash,
      document_id: input.quoteDocumentId,
    },
    document: {
      locale: input.locale,
      currency: input.currency,
    },
    tenant: {
      name: input.tenantName,
      tax_id: input.tenantTaxId ?? null,
      logo_url: input.tenantLogoUrl ?? null,
    },
    seller: partyBlock(input.seller, input.sellerName),
    buyer: partyBlock(input.buyer, input.buyerName),
    lines: input.lines,
    totals: {
      subtotal: input.subtotal,
      total: input.total,
      tax_breakdown: input.taxBreakdown ?? null,
    },
  }
}
