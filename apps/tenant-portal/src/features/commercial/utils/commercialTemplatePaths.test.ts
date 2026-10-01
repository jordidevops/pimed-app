import { describe, expect, it } from 'vitest'
import {
  AGREEMENT_TEMPLATES_HREF,
  QUOTE_TEMPLATES_HREF,
  commercialTemplatesHref,
} from './commercialTemplatePaths'

describe('commercialTemplatesHref', () => {
  it('builds category deep-links', () => {
    expect(QUOTE_TEMPLATES_HREF).toBe('/documents/templates?category=quote')
    expect(AGREEMENT_TEMPLATES_HREF).toBe(
      '/documents/templates?category=commercial_agreement',
    )
  })

  it('can open create modal for a category', () => {
    expect(commercialTemplatesHref('quote', { create: true })).toBe(
      '/documents/templates?category=quote&create=1',
    )
  })
})
