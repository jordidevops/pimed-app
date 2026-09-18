import { Liquid } from 'liquidjs'
import { describe, expect, it } from 'vitest'
import {
  buildPlatformDeliveryNoteHtml,
  buildPlatformQuoteHtml,
  COMMERCIAL_QUOTE_ARCHETYPES,
  DELIVERY_REQUIRED_HTML_TOKENS,
  deliverySampleValues,
  PLATFORM_DELIVERY_TEMPLATE,
  PLATFORM_QUOTE_TEMPLATES,
  QUOTE_REQUIRED_HTML_TOKENS,
  quoteSampleValues,
} from './platformCommercialHtml'

async function render(html: string, values: unknown): Promise<string> {
  return new Liquid({ strictVariables: false }).parseAndRender(html, values as object)
}

function expectCompletePreview(html: string) {
  expect(html).not.toContain('undefined')
  expect(html.toLowerCase()).not.toContain('liquid error')
  expect(html).toContain('Client Exemple SL')
  expect(html).toContain('Volt Serveis SL')
}

describe('QT-3 platform commercial HTML', () => {
  it('seeds five quote archetypes plus one delivery note, ca and es', () => {
    expect(PLATFORM_QUOTE_TEMPLATES).toHaveLength(5)
    expect(PLATFORM_QUOTE_TEMPLATES.map((t) => t.archetype)).toEqual([...COMMERCIAL_QUOTE_ARCHETYPES])
    expect(PLATFORM_DELIVERY_TEMPLATE.id.startsWith('77000000')).toBe(true)
  })

  it.each(COMMERCIAL_QUOTE_ARCHETYPES)(
    'quote %s ca/es contains frozen tokens and renders sample_values',
    async (archetype) => {
      for (const locale of ['ca', 'es'] as const) {
        const html = buildPlatformQuoteHtml(locale, archetype)
        for (const token of QUOTE_REQUIRED_HTML_TOKENS) {
          expect(html, `${locale} missing ${token}`).toContain(token)
        }
        const rendered = await render(html, quoteSampleValues(locale))
        expectCompletePreview(rendered)
        expect(rendered).toContain('PRE-2026-0008')
        expect(rendered).toContain('17/09/2026 12:00')
        expect(rendered).not.toMatch(/2026-09-17T10:00:00/)
        expect(rendered).toContain('202.62')
        expect(rendered).toContain('21%')
        expect(rendered).toContain('10%')
        expect(rendered).toContain('Visita tècnica') // catàleg sample; overlay de vocabulari no el toca
        expect(rendered).toContain('role="client_accept"')
        expect(rendered).toContain('role="client_reject"')
        if (archetype === 'field_service') {
          expect(rendered).toMatch(/desplaçaments|desplazamientos/)
        }
        if (archetype === 'workshop_maker') {
          expect(rendered).toContain('1457/1986')
        }
        if (archetype === 'practice') {
          expect(rendered).toMatch(/resguard|resguardo/)
        }
      }
    },
  )

  it('delivery note ca/es contains frozen tokens and renders with and without prices', async () => {
    for (const locale of ['ca', 'es'] as const) {
      const html = buildPlatformDeliveryNoteHtml(locale)
      for (const token of DELIVERY_REQUIRED_HTML_TOKENS) {
        expect(html).toContain(token)
      }
      const withPrices = await render(html, deliverySampleValues(locale))
      expectCompletePreview(withPrices)
      expect(withPrices).toContain('ALB-2026-0003')
      expect(withPrices).toContain('PRE-2026-0008')
      expect(withPrices).toContain('202.62')
      expect(withPrices).toContain('role="client_delivery"')
      expect(withPrices).toMatch(/no és una factura fiscal|no es una factura fiscal/)

      const withoutPrices = await render(html, {
        ...deliverySampleValues(locale),
        document: { ...deliverySampleValues(locale).document, show_prices: false },
      })
      expectCompletePreview(withoutPrices)
      expect(withoutPrices).not.toContain('202.62')
      expect(withoutPrices).toContain('Visita tècnica')
    }
  })
})
