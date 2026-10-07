import { describe, expect, it } from 'vitest'
import {
  commercialDecisionEmailIdempotencyKey,
  commercialDecisionRequestsEnabled,
  commercialDecisionSendCta,
  maskEmailForDisplay,
} from './commercialDecisionSend'

describe('commercialDecisionSend', () => {
  it('reads nested tenant flag', () => {
    expect(commercialDecisionRequestsEnabled(null)).toBe(false)
    expect(
      commercialDecisionRequestsEnabled({
        commercial: { decision_requests_enabled: true },
      }),
    ).toBe(true)
  })

  it('picks CTA hierarchy for issued docs', () => {
    expect(
      commercialDecisionSendCta({
        docStatus: 'issued',
        formalizationMode: 'signed_quote',
        hasOpenRequest: false,
        decisionRequestsEnabled: true,
      }),
    ).toBe('send_for_accept')

    expect(
      commercialDecisionSendCta({
        docStatus: 'issued',
        formalizationMode: 'signed_quote',
        hasOpenRequest: true,
        decisionRequestsEnabled: true,
      }),
    ).toBe('view_pending')

    expect(
      commercialDecisionSendCta({
        docStatus: 'draft',
        formalizationMode: 'signed_quote',
        hasOpenRequest: false,
        decisionRequestsEnabled: true,
      }),
    ).toBe('issue')

    expect(
      commercialDecisionSendCta({
        docStatus: 'issued',
        formalizationMode: 'separate_agreement',
        hasOpenRequest: false,
        decisionRequestsEnabled: true,
      }),
    ).toBe('none')

    expect(
      commercialDecisionSendCta({
        docStatus: 'issued',
        formalizationMode: 'separate_agreement',
        hasOpenRequest: false,
        decisionRequestsEnabled: true,
        agreementVersionStatus: 'pending_signature',
        agreementRendered: true,
      }),
    ).toBe('send_for_accept')

    expect(
      commercialDecisionSendCta({
        docStatus: 'accepted',
        formalizationMode: 'separate_agreement',
        hasOpenRequest: false,
        decisionRequestsEnabled: true,
        agreementVersionStatus: 'draft',
        agreementRendered: true,
      }),
    ).toBe('send_for_accept')

    expect(
      commercialDecisionSendCta({
        docStatus: 'issued',
        formalizationMode: 'separate_agreement',
        hasOpenRequest: true,
        decisionRequestsEnabled: true,
        agreementVersionStatus: 'pending_signature',
        agreementRendered: true,
      }),
    ).toBe('view_pending')

    expect(
      commercialDecisionSendCta({
        docStatus: 'issued',
        formalizationMode: 'signed_quote',
        hasOpenRequest: false,
        decisionRequestsEnabled: true,
        isExpired: true,
      }),
    ).toBe('none')
  })

  it('masks email and builds idempotency key', () => {
    expect(maskEmailForDisplay('anna@client.cat')).toBe('a***@client.cat')
    expect(commercialDecisionEmailIdempotencyKey('r1', 'd1')).toBe(
      'commercial-decision:r1:delivery:d1',
    )
  })
})
