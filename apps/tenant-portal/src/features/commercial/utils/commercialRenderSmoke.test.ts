import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Liquid } from 'liquidjs'
import { describe, expect, it } from 'vitest'
import { buildCommercialDocumentHtml } from './buildCommercialDocumentHtml'
import { shouldUseFullBodyHtml } from './commercialDocumentContext'
import { injectIssuedHtmlSignatureMarkers } from './commercialHtmlSignatureMarkers'
import type { CommercialDocumentDetail, CommercialDocumentLine } from './commercialDocumentModel'
import {
  buildPlatformQuoteHtml,
  quoteSampleValues,
} from '../templates/platformCommercialHtml'

const SIGNING_FIELD_MAP = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../../../../supabase/functions/_shared/signing-field-map.ts',
)

function line(): CommercialDocumentLine {
  return {
    id: 'line-1',
    document_id: 'doc-1',
    kind: 'service',
    name: 'Visita estàndard',
    description: 'Desplaçament inclòs',
    unit: 'u',
    quantity: 2,
    unit_price: 50,
    discount_pct: 0,
    tax_rate: 21,
    line_subtotal: 100,
    line_tax: 21,
    line_total: 100,
    position: 0,
  }
}

function fallbackDoc(): CommercialDocumentDetail {
  return {
    id: 'doc-1',
    tenant_id: 'tenant-1',
    doc_type: 'quote',
    doc_number: 'PRE-2026-0001',
    client_id: 'client-1',
    project_id: 'project-1',
    status: 'issued',
    seller_snapshot: { display_name: 'Taller Nord', tax_id: 'B12345678' },
    buyer_snapshot: { display_name: 'Maria Client', tax_id: '12345678Z' },
    service_address_snapshot: { line1: 'Carrer Major 1', city: 'Vic', postal_code: '08500' },
    terms_text: 'Pagament 15 dies',
    locale: 'ca',
    currency: 'EUR',
    subtotal: 100,
    tax_breakdown: [{ tax_rate: 21, tax_amount: 21 }],
    total: 121,
    show_prices: true,
    issued_at: '2026-09-16T10:00:00.000Z',
    valid_until: '2026-10-16',
    parent_document_id: null,
    created_at: '2026-09-16T10:00:00.000Z',
    lines: [line()],
    events: [],
  }
}

describe('QT-5 render smoke', () => {
  it('keeps fallback HTML identical and free of full-body signature slots', () => {
    const first = buildCommercialDocumentHtml(fallbackDoc())
    const second = buildCommercialDocumentHtml(fallbackDoc())
    expect(first).toBe(second)
    expect(shouldUseFullBodyHtml(null)).toBe(false)
    expect(first).toContain('Pressupost PRE-2026-0001')
    expect(first).toContain('Taller Nord')
    expect(first).not.toContain('signature-field')
    expect(first).not.toContain('[FIRMA:')
    expect(first).not.toContain('sig-slot')
  })

  it('full-body HTML injects unsigned [FIRMA:client_accept] boxes (PDF base, no stamp)', async () => {
    const src = readFileSync(SIGNING_FIELD_MAP, 'utf8')
    expect(src).toContain('export function injectHtmlSignatureMarkers')
    expect(src).toContain('[FIRMA:${role}]')
    expect(src).toContain('class="sig-slot"')
    expect(src).not.toContain('stampPdf')

    const template = buildPlatformQuoteHtml('ca', 'generic')
    const rendered = await new Liquid({ strictVariables: false }).parseAndRender(
      template,
      quoteSampleValues('ca'),
    )
    expect(rendered).toContain('role="client_accept"')
    expect(rendered).toContain('role="client_reject"')
    expect(rendered).not.toContain('[FIRMA:')

    const marked = injectIssuedHtmlSignatureMarkers(rendered)
    expect(marked).toContain('[FIRMA:client_accept]')
    expect(marked).toContain('[FIRMA:client_reject]')
    expect(marked).toContain('class="sig-slot"')
    expect(marked).toContain('data-sig-role="client_accept"')
    expect(marked).toContain('width:220px;height:70px;')
    expect(marked).not.toContain('<signature-field')
    expect(marked).not.toMatch(/stamp|signature[_-]image|data:image\/png/i)
    expect(rendered).toContain('17/09/2026 12:00')
    expect(rendered).not.toMatch(/T10:00:00|\+00:00/)
  })
})
