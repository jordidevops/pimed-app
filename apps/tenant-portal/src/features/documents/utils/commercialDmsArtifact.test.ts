import { describe, expect, it } from 'vitest'
import { isCommercialDmsArtifact } from './commercialDmsArtifact'

describe('isCommercialDmsArtifact', () => {
  it('detects commercial PDF records', () => {
    expect(isCommercialDmsArtifact({ entity_type: 'commercial_document' })).toBe(true)
  })

  it('ignores other DMS documents', () => {
    expect(isCommercialDmsArtifact({ entity_type: 'contact' })).toBe(false)
    expect(isCommercialDmsArtifact({ entity_type: null })).toBe(false)
    expect(isCommercialDmsArtifact(null)).toBe(false)
  })
})
