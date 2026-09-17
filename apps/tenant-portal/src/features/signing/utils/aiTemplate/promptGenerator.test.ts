import { describe, expect, it, vi } from 'vitest'
import { commercialFullBodyPromptSection } from './commercialAiPrompt'
import { buildAiTemplatePrompt } from './promptGenerator'

vi.mock('../../api/useTenantRoleDefaults', () => ({
  buildPriorityDefaultsMap: () => ({}),
  useTenantRoleDefaults: () => ({ data: [] }),
}))

describe('commercialFullBodyPromptSection', () => {
  it('requires quote tokens and nested context, not letterhead blocks', () => {
    const prompt = commercialFullBodyPromptSection('quote', 'html')
    expect(prompt).toContain('{% for line in lines %}')
    expect(prompt).toContain('client_accept')
    expect(prompt).toContain('client_reject')
    expect(prompt).toContain('totals.total')
    expect(prompt).toContain('lines[].name')
    expect(prompt).toContain("NO ha d'incloure {{ document_header }}")
  })

  it('requires delivery_note tokens instead of accept/reject', () => {
    const prompt = commercialFullBodyPromptSection('delivery_note', 'html')
    expect(prompt).toContain('{% for line in lines %}')
    expect(prompt).toContain('client_delivery')
    expect(prompt).not.toContain('client_accept')
  })

  it('requires DOCX §2.1 tokens when templateType is docx', () => {
    const prompt = commercialFullBodyPromptSection('quote', 'docx')
    expect(prompt).toContain('[[#lines]]')
    expect(prompt).toContain('role=client_accept')
    expect(prompt).toContain('[[document.doc_number]]')
    expect(prompt).not.toContain('{% for line in lines %}')
  })
})

describe('buildAiTemplatePrompt wires the commercial contract', () => {
  it('includes quote tokens when category is quote', () => {
    const prompt = buildAiTemplatePrompt({
      targetLocale: 'ca',
      templateType: 'html',
      category: 'quote',
      contentBlocksActive: true,
    })
    expect(prompt).toContain('{% for line in lines %}')
    expect(prompt).toContain('client_accept')
    expect(prompt).not.toContain('Blocs de document:')
    expect(prompt).not.toContain('salari_brut')
  })
})
