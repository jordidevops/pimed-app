import { describe, expect, it } from 'vitest'
import {
  isAgreementIncluded,
  parseCommercialInclusion,
} from './agreementInclusion'

describe('parseCommercialInclusion', () => {
  it('parses included payload', () => {
    expect(
      parseCommercialInclusion({
        status: 'included',
        agreement_id: 'a1',
        maintenance_plan_id: 'p1',
        occurrence_id: 'o1',
      }),
    ).toEqual({
      status: 'included',
      agreementId: 'a1',
      maintenancePlanId: 'p1',
      occurrenceId: 'o1',
      reason: null,
      candidateAgreementIds: [],
    })
    expect(
      isAgreementIncluded(
        parseCommercialInclusion({ status: 'included', agreement_id: 'a1' }),
      ),
    ).toBe(true)
  })

  it('parses extra with reason and treats unknown as none', () => {
    expect(
      parseCommercialInclusion({
        status: 'extra',
        reason: 'coverage_miss',
        maintenance_plan_id: 'p1',
      }),
    ).toEqual({
      status: 'extra',
      agreementId: null,
      maintenancePlanId: 'p1',
      occurrenceId: null,
      reason: 'coverage_miss',
      candidateAgreementIds: [],
    })
    expect(isAgreementIncluded(parseCommercialInclusion({ status: 'extra' }))).toBe(
      false,
    )
    expect(parseCommercialInclusion(null).status).toBe('none')
    expect(parseCommercialInclusion({ status: 'weird' }).status).toBe('none')
  })

  it('parses ambiguous candidates', () => {
    expect(
      parseCommercialInclusion({
        status: 'extra',
        reason: 'ambiguous_agreements',
        candidate_agreement_ids: ['a1', 'a2'],
      }),
    ).toEqual({
      status: 'extra',
      agreementId: null,
      maintenancePlanId: null,
      occurrenceId: null,
      reason: 'ambiguous_agreements',
      candidateAgreementIds: ['a1', 'a2'],
    })
  })
})
