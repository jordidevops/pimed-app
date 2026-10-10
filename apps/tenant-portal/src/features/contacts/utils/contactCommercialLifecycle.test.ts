import { describe, expect, it } from 'vitest'
import {
  buildLifecycleByContactId,
  deriveContactCommercialLifecycle,
} from './contactCommercialLifecycle'

describe('deriveContactCommercialLifecycle', () => {
  it('marks accepted quote as effective', () => {
    expect(
      deriveContactCommercialLifecycle({
        hasAcceptedOrSignedDoc: true,
        hasIssuedOpenQuote: true,
        hasExecuteProject: false,
      }),
    ).toBe('effective')
  })

  it('marks public_portal without work as potential', () => {
    expect(
      deriveContactCommercialLifecycle({
        source: 'public_portal',
        hasAcceptedOrSignedDoc: false,
        hasIssuedOpenQuote: false,
        hasExecuteProject: false,
      }),
    ).toBe('potential')
  })

  it('marks plain contact as agenda', () => {
    expect(
      deriveContactCommercialLifecycle({
        source: 'manual',
        hasAcceptedOrSignedDoc: false,
        hasIssuedOpenQuote: false,
        hasExecuteProject: false,
      }),
    ).toBe('agenda')
  })
})

describe('buildLifecycleByContactId', () => {
  it('aggregates docs and projects', () => {
    const map = buildLifecycleByContactId(
      [
        { id: 'c1', source: 'manual' },
        { id: 'c2', source: 'public_portal' },
        { id: 'c3', source: 'manual' },
      ],
      [
        { client_id: 'c1', doc_type: 'quote', status: 'accepted' },
        { client_id: 'c3', doc_type: 'quote', status: 'issued' },
      ],
      [
        { client_id: 'c3', type: 'work_order', status: 'in_progress', service_mode: 'execute' },
        {
          client_id: 'c2',
          type: 'work_order',
          status: 'draft',
          service_mode: 'execute',
          commercial_stage: 'prospect',
        },
      ],
    )
    expect(map.get('c1')).toBe('effective')
    expect(map.get('c2')).toBe('potential')
    expect(map.get('c3')).toBe('effective')
  })
})
