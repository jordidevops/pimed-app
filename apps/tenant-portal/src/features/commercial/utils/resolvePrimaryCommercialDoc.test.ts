import { describe, expect, it } from 'vitest'
import { resolvePrimaryCommercialDoc } from './resolvePrimaryCommercialDoc'

function doc(
  partial: Partial<{
    id: string
    doc_type: string
    status: string
    created_at: string
    valid_until: string | null
  }> & { id: string },
) {
  return {
    doc_type: 'quote',
    status: 'draft',
    created_at: '2026-01-01T00:00:00Z',
    valid_until: null,
    ...partial,
  }
}

describe('resolvePrimaryCommercialDoc', () => {
  it('prefers accepted over newer draft', () => {
    const primary = resolvePrimaryCommercialDoc([
      doc({ id: 'draft', status: 'draft', created_at: '2026-06-01T00:00:00Z' }),
      doc({ id: 'ok', status: 'accepted', created_at: '2026-01-01T00:00:00Z' }),
    ])
    expect(primary?.id).toBe('ok')
  })

  it('prefers issued amendment when it is the active deliverable', () => {
    const primary = resolvePrimaryCommercialDoc([
      doc({
        id: 'q',
        doc_type: 'quote',
        status: 'accepted',
        created_at: '2026-01-01T00:00:00Z',
      }),
      doc({
        id: 'a',
        doc_type: 'quote_amendment',
        status: 'issued',
        created_at: '2026-06-01T00:00:00Z',
      }),
    ])
    // accepted quote still wins over newer issued amendment
    expect(primary?.id).toBe('q')
  })

  it('returns issued amendment when no accepted quote', () => {
    const primary = resolvePrimaryCommercialDoc([
      doc({
        id: 'q',
        doc_type: 'quote',
        status: 'rejected',
        created_at: '2026-01-01T00:00:00Z',
      }),
      doc({
        id: 'a',
        doc_type: 'quote_amendment',
        status: 'issued',
        created_at: '2026-06-01T00:00:00Z',
      }),
    ])
    expect(primary?.id).toBe('a')
  })

  it('returns null when no quote-like docs', () => {
    expect(
      resolvePrimaryCommercialDoc([
        doc({ id: 'd', doc_type: 'delivery_note', status: 'issued' }),
      ]),
    ).toBeNull()
  })
})
