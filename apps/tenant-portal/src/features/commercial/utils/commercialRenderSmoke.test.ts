import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Liquid } from 'liquidjs'
import { describe, expect, it } from 'vitest'
import { buildCommercialDocumentHtml } from './buildCommercialDocumentHtml'
import { shouldUseFullBodyHtml } from './commercialDocumentContext'
import type { CommercialDocumentDetail, CommercialDocumentLine } from './commercialDocumentModel'
import {
  buildPlatformQuoteHtml,
  quoteSampleValues,
} from '../templates/platformCommercialHtml'

const SIGNING_FIELD_MAP = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../../../../supabase/functions/_shared/signing-field-map.ts',
)

/**
 * Mirrors injectHtmlSignatureMarkers in signing-field-map.ts (HTML branch only).
 * QT-5 smoke avoids Deno/Gotenberg; the source-file assertion below binds the token format.
 */
function injectHtmlSignatureMarkers(html: string): {
  html: string
  roles: string[]
} {
  const roles: string[] = []
  const tagRe = /<signature-field\b([^>]*)\s*\/?>(?:<\/signature-field>)?/gi
  const newHtml = html.replace(tagRe, (_match, attrs: string) => {
    const role = attrs.match(/role=["']([^"']+)["']/i)?.[1]?.trim() ?? 'signer'
    if (!roles.includes(role)) roles.push(role)
    return (
      `<div class="sig-slot" data-sig-role="${role}" ` +
      `style="display:block;width:180px;height:60px;` +
      `border:1px dashed #999;position:relative;box-sizing:border-box;margin:10px 0;">` +
      `<span style="position:absolute;left:6px;top:6px;font-size:10pt;color:#555;">${role}</span>` +
      `<span style="position:absolute;left:6px;bottom:6px;font-size:9pt;color:#888;font-family:monospace;">` +
      `[FIRMA:${role}]</span>` +
      `</div>`
    )
  })
  return { html: newHtml, roles }
}

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

    const marked = injectHtmlSignatureMarkers(rendered)
    expect(marked.roles).toEqual(['client_accept', 'client_reject'])
    expect(marked.html).toContain('[FIRMA:client_accept]')
    expect(marked.html).toContain('[FIRMA:client_reject]')
    expect(marked.html).toContain('class="sig-slot"')
    expect(marked.html).toContain('data-sig-role="client_accept"')
    expect(marked.html).not.toContain('<signature-field')
    expect(marked.html).not.toMatch(/stamp|signature[_-]image|data:image\/png/i)
    expect(rendered).toContain('17/09/2026 12:00')
    expect(rendered).not.toMatch(/T10:00:00|\+00:00/)
  })
})
