import { Liquid } from 'liquidjs'
import { describe, expect, it } from 'vitest'
import { buildCommercialDocumentHtml } from './buildCommercialDocumentHtml'
import {
  buildCommercialTemplateContext,
  COMMERCIAL_LEGAL_RETENTION_DAYS,
  isFullBodyTemplateOwnedByTenant,
  shouldUseFullBodyHtml,
  shouldUseFullBodyDocx,
} from './commercialDocumentContext'
import type { CommercialDocumentDetail, CommercialDocumentLine } from './commercialDocumentModel'

const CONTRACT_LIQUID = `
{{ globals.today }} {{ globals.date }} {{ globals.year }} {{ globals.now }}
{{ tenant.name }} {{ tenant.tax_id }} {{ tenant.address }} {{ tenant.phone }} {{ tenant.email }} {{ tenant.logo_url }}
{{ document.doc_type }} {{ document.doc_number }} {{ document.status }} {{ document.locale }} {{ document.currency }}
{{ document.issued_at }} {{ document.valid_until }} {{ document.created_at }} {{ document.is_amendment }}
{{ document.parent_doc_number }} {{ document.show_prices }} {{ document.terms_text }}
{{ seller.display_name }} {{ seller.tax_id }} {{ seller.email }} {{ seller.phone }}
{{ seller.address_line1 }} {{ seller.address_line2 }} {{ seller.city }} {{ seller.postal_code }}
{{ buyer.display_name }} {{ buyer.tax_id }} {{ buyer.email }} {{ buyer.phone }}
{{ service_address.label }} {{ service_address.line1 }} {{ service_address.city }} {{ service_address.postal_code }} {{ service_address.region }} {{ service_address.country }}
{% for line in lines %}
  {{ line.name }} {{ line.description }} {{ line.unit }} {{ line.quantity }} {{ line.unit_price }} {{ line.discount_pct }} {{ line.tax_rate }} {{ line.line_total }} {{ line.kind }}
{% endfor %}
{{ totals.subtotal }}
{% for tax in totals.tax_breakdown %}{{ tax.tax_rate }} {{ tax.tax_amount }} {{ tax.tax_base }}{% endfor %}
{{ totals.total }}
{{ legal.retention_days }} {{ legal.jurisdiction_text }}
`.trim()

function sampleDoc(): Parameters<typeof buildCommercialTemplateContext>[0] {
  return {
    now: new Date('2026-09-17T08:00:00.000Z'),
    logoUrl: 'https://cdn.example/logo.png',
    parentDocNumber: 'P-2026-0001',
    tenant: {
      name: 'Volt Serveis',
      address: 'Carrer Indústria 10',
      phone: '938000000',
      email: 'hola@volt.test',
    },
    doc: {
      doc_type: 'quote_amendment',
      doc_number: 'P-2026-0002',
      status: 'issued',
      locale: 'ca',
      currency: 'EUR',
      issued_at: '2026-09-17T10:00:00.000Z',
      valid_until: '2026-10-17T10:00:00.000Z',
      created_at: '2026-09-17T09:00:00.000Z',
      show_prices: true,
      terms_text: '30 dies',
      seller_snapshot: { name: 'Volt Serveis', tax_id: 'B00000000' },
      buyer_snapshot: {
        display_name: 'Maria Client',
        tax_id: '12345678Z',
        email: 'maria@client.test',
        phone: '600000000',
      },
      service_address_snapshot: {
        name: 'Nau 2',
        street: 'Carrer Major',
        street_number: '1',
        city: 'Vic',
        postal_code: '08500',
        province: 'Barcelona',
        country_code: 'ES',
      },
      subtotal: 100,
      tax_breakdown: [{ tax_rate: 21, tax_amount: 21, tax_base: 999 }],
      total: 121,
    },
    lines: [
      {
        name: 'Visita',
        description: 'Desplaçament',
        unit: 'h',
        quantity: 2,
        unit_price: 50,
        discount_pct: 0,
        tax_rate: 21,
        line_total: 121,
        kind: 'service',
      },
    ],
  }
}

describe('buildCommercialTemplateContext', () => {
  it('passes through snapshot tax_base and does not invent seller address', () => {
    const ctx = buildCommercialTemplateContext(sampleDoc())
    expect(ctx.globals).toEqual({
      today: '2026-09-17',
      date: '2026-09-17',
      year: '2026',
      now: '2026-09-17T08:00:00.000Z',
    })
    expect(ctx.tenant).toMatchObject({
      name: 'Volt Serveis',
      tax_id: 'B00000000',
      logo_url: 'https://cdn.example/logo.png',
    })
    expect(ctx.document).toMatchObject({
      is_amendment: true,
      parent_doc_number: 'P-2026-0001',
      doc_number: 'P-2026-0002',
    })
    expect(ctx.seller).toMatchObject({
      display_name: 'Volt Serveis',
      tax_id: 'B00000000',
      address_line1: null,
      city: null,
    })
    expect(ctx.service_address).toEqual({
      label: 'Nau 2',
      line1: 'Carrer Major 1',
      line2: null,
      city: 'Vic',
      postal_code: '08500',
      region: 'Barcelona',
      country: 'ES',
    })
    const totals = ctx.totals as { tax_breakdown: Array<Record<string, unknown>>; total: number }
    expect(totals.total).toBe(121)
    expect(totals.tax_breakdown).toEqual([{ tax_rate: 21, tax_amount: 21, tax_base: 999 }])
    expect(ctx.legal).toEqual({
      retention_days: COMMERCIAL_LEGAL_RETENTION_DAYS,
      jurisdiction_text: '',
    })
  })

  it('derives tax_base from frozen line_subtotal when the snapshot omits it', () => {
    const input = sampleDoc()
    input.doc.tax_breakdown = [{ tax_rate: 21, tax_amount: 21 }]
    input.lines[0] = { ...input.lines[0], line_subtotal: 100 }
    const ctx = buildCommercialTemplateContext(input)
    const totals = ctx.totals as { tax_breakdown: Array<Record<string, unknown>> }
    expect(totals.tax_breakdown).toEqual([{ tax_rate: 21, tax_amount: 21, tax_base: 100 }])
  })

  it('renders the frozen Liquid contract without syntax errors or empty required fields', async () => {
    const ctx = buildCommercialTemplateContext(sampleDoc())
    const html = await new Liquid({ strictVariables: false }).parseAndRender(CONTRACT_LIQUID, ctx)
    expect(html).toContain('Volt Serveis')
    expect(html).toContain('P-2026-0002')
    expect(html).toContain('Maria Client')
    expect(html).toContain('Carrer Major 1')
    expect(html).toContain('Visita')
    expect(html).toContain('121')
    expect(html).not.toContain('undefined')
    expect(html).not.toContain('liquid error')
  })

  it('keeps ISO dates and adds Europe/Madrid display fields', () => {
    const ctx = buildCommercialTemplateContext(sampleDoc())
    const document = ctx.document as Record<string, unknown>
    expect(document.issued_at).toBe('2026-09-17T10:00:00.000Z')
    expect(document.valid_until).toBe('2026-10-17T10:00:00.000Z')
    expect(document.created_at).toBe('2026-09-17T09:00:00.000Z')
    expect(document.issued_at_display).toBe('17/09/2026 12:00')
    expect(document.valid_until_display).toBe('17/10/2026')
    expect(document.created_at_display).toBe('17/09/2026 11:00')
  })

  it('uses tenant date/time patterns and Europe/London for en', () => {
    const ctx = buildCommercialTemplateContext({
      ...sampleDoc(),
      doc: { ...sampleDoc().doc, locale: 'en' },
      dateFormat: 'yyyy-MM-dd',
      timeFormat: 'HH:mm',
    })
    const document = ctx.document as Record<string, unknown>
    expect(document.issued_at).toBe('2026-09-17T10:00:00.000Z')
    expect(document.issued_at_display).toBe('2026-09-17 11:00')
    expect(document.valid_until_display).toBe('2026-10-17')
  })
})

describe('shouldUseFullBodyHtml', () => {
  it('only takes the HTML full-body branch when type and content exist', () => {
    expect(shouldUseFullBodyHtml(null)).toBe(false)
    expect(shouldUseFullBodyHtml({ template_type: 'html', html_content: '' })).toBe(false)
    expect(shouldUseFullBodyHtml({ template_type: 'docx', html_content: '<p>x</p>' })).toBe(false)
    expect(shouldUseFullBodyHtml({ template_type: 'html', html_content: '<p>x</p>' })).toBe(true)
  })
})

describe('shouldUseFullBodyDocx', () => {
  it('only takes the DOCX full-body branch when type and storage_path exist', () => {
    expect(shouldUseFullBodyDocx(null)).toBe(false)
    expect(shouldUseFullBodyDocx({ template_type: 'docx', storage_path: '' })).toBe(false)
    expect(shouldUseFullBodyDocx({ template_type: 'html', storage_path: 'platform/docx/x.docx' })).toBe(false)
    expect(shouldUseFullBodyDocx({ template_type: 'docx', storage_path: 'platform/docx/x.docx' })).toBe(true)
  })
})

describe('isFullBodyTemplateOwnedByTenant', () => {
  const tenantA = 'tenant-a'
  const tenantB = 'tenant-b'

  it('allows the owning tenant and platform defaults, never another tenant', () => {
    expect(isFullBodyTemplateOwnedByTenant(null, tenantA)).toBe(false)
    expect(
      isFullBodyTemplateOwnedByTenant(
        { tenant_id: tenantA, is_platform_default: false, is_active: true },
        tenantA,
      ),
    ).toBe(true)
    expect(
      isFullBodyTemplateOwnedByTenant(
        { tenant_id: tenantB, is_platform_default: false, is_active: true },
        tenantA,
      ),
    ).toBe(false)
    expect(
      isFullBodyTemplateOwnedByTenant(
        { tenant_id: tenantB, is_platform_default: true, is_active: true },
        tenantA,
      ),
    ).toBe(false)
    expect(
      isFullBodyTemplateOwnedByTenant(
        { tenant_id: null, is_platform_default: true, is_active: true },
        tenantA,
      ),
    ).toBe(true)
    expect(
      isFullBodyTemplateOwnedByTenant(
        { tenant_id: tenantA, is_platform_default: false, is_active: false },
        tenantA,
      ),
    ).toBe(false)
  })
})

describe('fallback HTML builder (QT-D1)', () => {
  it('is unchanged: issued quote still embeds snapshot letterhead labels', () => {
    const line: CommercialDocumentLine = {
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
    const doc: CommercialDocumentDetail = {
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
      lines: [line],
      events: [],
    }
    const html = buildCommercialDocumentHtml(doc)
    expect(html).toContain('Pressupost PRE-2026-0001')
    expect(html).toContain('Taller Nord')
    expect(html).toContain('Maria Client')
    expect(html).toContain('16/09/2026 12:00')
    expect(html).not.toContain('2026-09-16T10:00:00.000Z')
  })
})
