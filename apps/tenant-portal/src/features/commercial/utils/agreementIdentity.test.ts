import { describe, expect, it } from 'vitest'
import {
  AGREEMENT_FLOW_STEPS,
  agreementFlowStep,
  formatAgreementIdentity,
  isAgreementNearingExpiry,
} from './agreementIdentity'

describe('agreementIdentity', () => {
  const t = (_key: string, fallback: string) => fallback

  it('builds title · number · status', () => {
    expect(
      formatAgreementIdentity({
        primaryLineName: 'Instal·lació d’aerotèrmia',
        quoteNumber: 'P-2026-9004',
        versionStatus: 'draft',
        t,
      }),
    ).toBe('Instal·lació d’aerotèrmia · P-2026-9004 · Contracte preparat, encara sense enviar')
  })

  it('shows pending activation when signed but starts later', () => {
    expect(
      formatAgreementIdentity({
        kind: 'framework',
        agreementStatus: 'pending_start',
        versionStatus: 'signed',
        startsOn: '2099-01-01',
        t,
      }),
    ).toBe('Acord marc · Firmat, pendent d’activació')
  })

  it('maps version status to flow steps', () => {
    expect(agreementFlowStep({})).toBe('prepare')
    expect(agreementFlowStep({ versionStatus: 'draft' })).toBe('send')
    expect(agreementFlowStep({ versionStatus: 'pending_signature' })).toBe('send')
    expect(agreementFlowStep({ versionStatus: 'signed' })).toBe('signed')
    expect(AGREEMENT_FLOW_STEPS).toEqual(['accepted', 'prepare', 'send', 'signed'])
  })

  it('detects nearing expiry within notice window', () => {
    const now = new Date('2026-06-01T12:00:00')
    expect(
      isAgreementNearingExpiry({
        endsOn: '2026-06-20',
        noticeDays: 30,
        now,
      }),
    ).toBe(true)
    expect(
      isAgreementNearingExpiry({
        endsOn: '2026-08-01',
        noticeDays: 30,
        now,
      }),
    ).toBe(false)
  })
})
