import { describe, expect, it } from 'vitest'
import { buildPreviewHtml } from './previewBlocks'

const NESTED_QUOTE = `
<!DOCTYPE html>
<html lang="ca"><body>
  <h1>{{ document.doc_number }}</h1>
  <p>{{ tenant.name }} · {{ tenant.email }}</p>
  <p>{{ buyer.display_name }}</p>
  {% for line in lines %}
    <div>{{ line.name }} {{ line.line_total }}</div>
  {% endfor %}
  {% for tax in totals.tax_breakdown %}IVA {{ tax.tax_rate }}% {{ tax.tax_amount }}{% endfor %}
  <strong>{{ totals.total }}</strong>
</body></html>
`

const sampleValues = {
  tenant: { name: 'Volt Serveis SL', email: 'hola@volt.example' },
  document: { doc_number: 'PRE-2026-0008' },
  buyer: { display_name: 'Client Exemple SL' },
  lines: [
    { name: 'Visita tècnica', line_total: 90 },
    { name: 'Recanvi', line_total: 72 },
  ],
  totals: {
    tax_breakdown: [
      { tax_rate: 21, tax_amount: 34.02 },
      { tax_rate: 10, tax_amount: 0.6 },
    ],
    total: 202.62,
  },
}

describe('buildPreviewHtml commercial nested context', () => {
  it('renders lines and totals from nested sample_values without undefined', () => {
    const html = buildPreviewHtml(NESTED_QUOTE, sampleValues, {
      tenant: { name: 'Tenant de prova', logo_url: null },
    })
    expect(html).toContain('PRE-2026-0008')
    expect(html).toContain('Client Exemple SL')
    expect(html).toContain('Visita tècnica')
    expect(html).toContain('202.62')
    expect(html).toContain('21%')
    expect(html).not.toContain('undefined')
    expect(html).toContain('hola@volt.example')
  })

  it('does not wrap a full HTML document inside another body', () => {
    const html = buildPreviewHtml(NESTED_QUOTE, sampleValues)
    expect(html.toLowerCase().indexOf('<html')).toBe(html.toLowerCase().lastIndexOf('<html'))
    expect(html).not.toMatch(/<body[^>]*>\s*<!doctype html/i)
  })
})
