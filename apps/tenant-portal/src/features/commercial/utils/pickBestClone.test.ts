import { describe, expect, it } from 'vitest'
import { pickBestClone } from './pickBestClone'

describe('pickBestClone', () => {
  it('prefers active over newer incomplete', () => {
    const best = pickBestClone(
      [
        {
          id: '1',
          status: 'incomplete',
          cloned_from_catalog_id: 'cat',
          updated_at: '2026-01-02',
        },
        {
          id: '2',
          status: 'active',
          cloned_from_catalog_id: 'cat',
          updated_at: '2026-01-01',
        },
      ],
      'cat',
    )
    expect(best?.id).toBe('2')
  })

  it('falls back to newest non-archived', () => {
    const best = pickBestClone(
      [
        {
          id: '1',
          status: 'draft',
          cloned_from_catalog_id: 'cat',
          updated_at: '2026-01-01',
        },
        {
          id: '2',
          status: 'incomplete',
          cloned_from_catalog_id: 'cat',
          updated_at: '2026-01-03',
        },
      ],
      'cat',
    )
    expect(best?.id).toBe('2')
  })
})
