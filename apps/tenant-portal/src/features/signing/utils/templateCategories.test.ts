import type { TFunction } from 'i18next'
import { describe, expect, it } from 'vitest'
import {
  DOCUMENT_TEMPLATE_CATEGORY_OPTIONS,
  isFullBodyTemplateCategory,
  templateCategoryLabel,
  templateKindLabel,
} from './templateCategories'

const t = ((key: string, fallback?: string) => fallback ?? key) as TFunction

describe('templateCategories', () => {
  it('keeps short filter labels for quote and delivery_note', () => {
    expect(templateCategoryLabel(t, 'quote')).toBe('Pressupost')
    expect(templateCategoryLabel(t, 'delivery_note')).toBe('Albarà')
    expect(templateCategoryLabel(t, 'commercial')).toBe('Comercial')
    expect(templateCategoryLabel(t, 'operations')).toBe('Operacions')
    expect(templateCategoryLabel(t, 'attendance')).toBe('Control horari')
    expect(templateCategoryLabel(t, 'custom_x')).toBe('custom_x')
  })

  it('uses kind labels for quote and delivery_note badges and form options', () => {
    expect(templateKindLabel(t, 'quote')).toBe('Plantilla de pressupost')
    expect(templateKindLabel(t, 'delivery_note')).toBe("Plantilla d'albarà")
    expect(templateKindLabel(t, 'commercial')).toBe('Comercial')
    expect(templateKindLabel(t, 'operations')).toBe('Operacions')
    expect(templateKindLabel(t, 'attendance')).toBe('Control horari')
  })

  it('includes seeded catalog categories in the form dropdown allowlist', () => {
    const values = DOCUMENT_TEMPLATE_CATEGORY_OPTIONS.map((opt) => opt.value)
    expect(values).toContain('attendance')
    expect(values).toContain('operations')
  })

  it('marks quote and delivery_note as full-body, not commercial letterhead', () => {
    expect(isFullBodyTemplateCategory('quote')).toBe(true)
    expect(isFullBodyTemplateCategory('delivery_note')).toBe(true)
    expect(isFullBodyTemplateCategory('commercial')).toBe(false)
  })
})
