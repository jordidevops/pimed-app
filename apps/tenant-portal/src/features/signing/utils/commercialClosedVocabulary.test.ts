import { describe, expect, it } from 'vitest'
import {
  extractCommercialTemplatePaths,
  findUnknownCommercialPaths,
  formatUnknownPathMessage,
  suggestCorrectPath,
} from './commercialClosedVocabulary'

describe('commercialClosedVocabulary', () => {
  it('extracts liquid paths including for-loops', () => {
    const html = `
      {{ document.doc_number }}
      {% for line in lines %}
        {{ line.name }} — {{ line.line_total }}
      {% endfor %}
      {{ buyer.display_name }}
    `
    expect(extractCommercialTemplatePaths(html, 'html')).toEqual([
      'buyer.display_name',
      'document.doc_number',
      'line.line_total',
      'line.name',
      'lines',
    ])
  })

  it('flags buyer.name with suggestion', () => {
    const hits = findUnknownCommercialPaths(
      '{{ buyer.name }} {{ buyer.display_name }}',
      'quote',
      'html',
    )
    expect(hits).toEqual([{ path: 'buyer.name', suggestion: 'buyer.display_name' }])
    expect(suggestCorrectPath('buyer.name')).toBe('buyer.display_name')
    expect(formatUnknownPathMessage(hits)).toContain('buyer.display_name')
  })

  it('allows agreement source_quote paths and rejects client_accept role paths as variables', () => {
    const ok = findUnknownCommercialPaths(
      '{{ source_quote.doc_number }} {{ buyer.display_name }} {% for line in lines %}{{ line.line_subtotal }}{% endfor %}',
      'commercial_agreement',
      'html',
    )
    expect(ok).toEqual([])

    const bad = findUnknownCommercialPaths(
      '{{ buyer.tax_id }}',
      'commercial_agreement',
      'html',
    )
    expect(bad.map((h) => h.path)).toEqual(['buyer.tax_id'])
  })

  it('allows bare line fields in docx loops', () => {
    expect(extractCommercialTemplatePaths('[[document.doc_number]] [[#lines]] [[name]]', 'docx')).toEqual([
      'document.doc_number',
      'lines',
      'name',
    ])
    expect(findUnknownCommercialPaths('[[#lines]][[name]][[/lines]]', 'quote', 'docx')).toEqual([])
  })
})
