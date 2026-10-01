import { describe, expect, it } from 'vitest'
import {
  hintFromAgreementState,
  hintFromQuoteWithoutAgreement,
  pickStrongerQuotePickerHint,
  rankQuotePickerHint,
} from './quotePickerCommercialHintsLogic'

describe('quotePickerCommercialHints ranking', () => {
  it('ranks active contract above pending prepare and open quote', () => {
    expect(rankQuotePickerHint('agreement_active')).toBeGreaterThan(
      rankQuotePickerHint('needs_prepare'),
    )
    expect(rankQuotePickerHint('needs_prepare')).toBeGreaterThan(
      rankQuotePickerHint('quote_open'),
    )
    expect(rankQuotePickerHint('quote_open')).toBeGreaterThan(
      rankQuotePickerHint('no_quote'),
    )
  })

  it('pickStronger keeps the higher-priority hint', () => {
    expect(pickStrongerQuotePickerHint('no_quote', 'quote_open')).toBe('quote_open')
    expect(pickStrongerQuotePickerHint('agreement_active', 'needs_prepare')).toBe(
      'agreement_active',
    )
    expect(pickStrongerQuotePickerHint('quote_open', null)).toBe('quote_open')
  })

  it('derives needs_prepare only for accepted separate_agreement quotes', () => {
    expect(
      hintFromQuoteWithoutAgreement({
        status: 'accepted',
        formalization_mode: 'separate_agreement',
      }),
    ).toBe('needs_prepare')
    expect(
      hintFromQuoteWithoutAgreement({
        status: 'accepted',
        formalization_mode: 'signed_quote',
      }),
    ).toBe('other')
    expect(
      hintFromQuoteWithoutAgreement({
        status: 'issued',
        formalization_mode: 'separate_agreement',
      }),
    ).toBe('quote_open')
  })

  it('maps agreement + version status to hints', () => {
    expect(hintFromAgreementState({ status: 'active' }, { status: 'signed' })).toBe(
      'agreement_active',
    )
    expect(
      hintFromAgreementState({ status: 'pending_start' }, { status: 'pending_signature' }),
    ).toBe('agreement_pending')
    expect(
      hintFromAgreementState({ status: 'pending_start' }, { status: 'draft' }),
    ).toBe('agreement_draft')
    expect(
      hintFromAgreementState({ status: 'pending_start' }, { status: 'signed' }),
    ).toBe('agreement_active')
    expect(
      hintFromAgreementState({ status: 'finished' }, { status: 'signed' }),
    ).toBe('other')
  })
})
