import { describe, expect, it } from 'vitest'
import {
  DEFAULT_REGIME_POLICIES,
  commercialSettingsPatchWithRegimes,
  effectiveProjectCommercialPolicy,
  parseCommercialRegimes,
  resolveProjectCommercialSnapshot,
} from './commercialRegimePolicy'

describe('commercialRegimePolicy', () => {
  it('parses defaults when settings missing', () => {
    expect(parseCommercialRegimes(null)).toEqual(DEFAULT_REGIME_POLICIES)
  })

  it('merges partial tenant overrides', () => {
    const parsed = parseCommercialRegimes({
      commercial: {
        regimes: {
          consumer: { require_auth_before_work: 'block' },
        },
      },
    })
    expect(parsed.consumer.require_auth_before_work).toBe('block')
    expect(parsed.consumer.overage_on_close).toBe('block')
    expect(parsed.contractual.overage_on_delivery).toBe('warn')
  })

  it('assessment forces overage and auth off', () => {
    const policy = effectiveProjectCommercialPolicy({
      commercialRegime: 'consumer',
      serviceMode: 'assessment',
      tenantRegimes: DEFAULT_REGIME_POLICIES,
    })
    expect(policy.overage_on_close).toBe('off')
    expect(policy.overage_on_delivery).toBe('off')
    expect(policy.require_auth_before_work).toBe('off')
  })

  it('resolveProjectCommercialSnapshot ignores invalid / null', () => {
    expect(resolveProjectCommercialSnapshot(null)).toEqual({
      commercialRegime: 'consumer',
      serviceMode: 'execute',
    })
    expect(
      resolveProjectCommercialSnapshot({
        commercial_regime: 'contractual',
        service_mode: 'assessment',
      }),
    ).toEqual({ commercialRegime: 'contractual', serviceMode: 'assessment' })
    expect(
      resolveProjectCommercialSnapshot({
        commercial_regime: 'nope',
        service_mode: null,
      }),
    ).toEqual({ commercialRegime: 'consumer', serviceMode: 'execute' })
  })

  it('patches regimes without dropping other commercial keys', () => {
    const next = commercialSettingsPatchWithRegimes(
      { deviation_approval_threshold_eur: 10 },
      DEFAULT_REGIME_POLICIES,
    )
    expect(next.commercial.deviation_approval_threshold_eur).toBe(10)
    expect(next.commercial.regimes).toEqual(DEFAULT_REGIME_POLICIES)
  })
})
