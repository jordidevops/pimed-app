import { describe, expect, it } from 'vitest'
import {
  PLATFORM_QUOTE_CONTRACT_TEMPLATE_ID,
  commercialRelationshipBadges,
} from './commercialRelationshipBadges'
import { parseWorkGateDefault } from './deviationApprovalThreshold'

describe('commercialRelationshipBadges', () => {
  it('derives quote, quote-contract, formal contract and agreement state', () => {
    expect(commercialRelationshipBadges({
      docType: 'quote',
      formalizationMode: 'signed_quote',
    })).toEqual(['quote'])

    expect(commercialRelationshipBadges({
      docType: 'quote',
      formalizationMode: 'signed_quote',
      templateId: PLATFORM_QUOTE_CONTRACT_TEMPLATE_ID,
    })).toEqual(['quote_contract'])

    expect(commercialRelationshipBadges({
      docType: 'quote',
      formalizationMode: 'signed_quote',
      templateName: 'Pressupost i contracte de serveis (clon)',
    })).toEqual(['quote_contract'])

    expect(commercialRelationshipBadges({
      docType: 'quote',
      formalizationMode: 'separate_agreement',
      versionStatus: 'pending_signature',
    })).toEqual(['formal_contract', 'agreement_pending'])

    expect(commercialRelationshipBadges({
      docType: 'quote',
      formalizationMode: 'separate_agreement',
      agreementStatus: 'active',
      versionStatus: 'signed',
    })).toEqual(['formal_contract', 'agreement_active'])

    expect(commercialRelationshipBadges({ docType: 'delivery_note' })).toEqual([])
  })
})

describe('parseWorkGateDefault', () => {
  it('defaults to none unless the tenant asked for a signed agreement', () => {
    expect(parseWorkGateDefault(null)).toBe('none')
    expect(parseWorkGateDefault({
      commercial: { work_gate_default: 'require_signed_agreement' },
    })).toBe('require_signed_agreement')
    expect(parseWorkGateDefault({
      commercial: { work_gate_default: 'block' },
    })).toBe('none')
  })
})
