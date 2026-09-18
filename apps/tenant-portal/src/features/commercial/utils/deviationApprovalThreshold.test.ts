import { describe, expect, it } from 'vitest'
import {
  COMMERCIAL_FULL_BODY_TEMPLATE_NONE,
  commercialFullBodyTemplateSettingValue,
  commercialSettingsPatchWithFullBodyTemplates,
  commercialSettingsPatchWithThreshold,
  parseCommercialSettingId,
} from './deviationApprovalThreshold'

describe('commercial full-body settings patch', () => {
  it('keeps existing commercial keys when setting a quote template', () => {
    const next = commercialSettingsPatchWithFullBodyTemplates(
      { deviation_approval_threshold_eur: 25, document_template_id: 'letterhead' },
      { quote_template_id: '76000000-0000-0000-0000-000000000001' },
    )
    expect(next.commercial).toMatchObject({
      deviation_approval_threshold_eur: 25,
      document_template_id: 'letterhead',
      quote_template_id: '76000000-0000-0000-0000-000000000001',
    })
  })

  it('clears a template id with null without dropping other keys', () => {
    const next = commercialSettingsPatchWithFullBodyTemplates(
      { quote_template_id: 'abc', delivery_note_template_id: 'def' },
      { quote_template_id: null },
    )
    expect(next.commercial.quote_template_id).toBeNull()
    expect(next.commercial.delivery_note_template_id).toBe('def')
  })

  it('still patches the CF-13 threshold through the shared merge', () => {
    const next = commercialSettingsPatchWithThreshold({ quote_template_id: 'abc' }, 10)
    expect(next.commercial).toMatchObject({
      quote_template_id: 'abc',
      deviation_approval_threshold_eur: 10,
    })
  })

  it('reads nested commercial ids from effective settings', () => {
    expect(
      parseCommercialSettingId(
        { commercial: { quote_template_id: '  tpl-1  ' } },
        'quote_template_id',
      ),
    ).toBe('tpl-1')
    expect(parseCommercialSettingId({ commercial: { quote_template_id: '' } }, 'quote_template_id')).toBeNull()
    expect(
      parseCommercialSettingId(
        { commercial: { quote_template_id: COMMERCIAL_FULL_BODY_TEMPLATE_NONE } },
        'quote_template_id',
      ),
    ).toBeNull()
  })

  it('persists Cap as the none sentinel instead of null', () => {
    expect(commercialFullBodyTemplateSettingValue('')).toBe(COMMERCIAL_FULL_BODY_TEMPLATE_NONE)
    expect(commercialFullBodyTemplateSettingValue(null)).toBe(COMMERCIAL_FULL_BODY_TEMPLATE_NONE)
    const next = commercialSettingsPatchWithFullBodyTemplates(
      { quote_template_id: 'abc' },
      { quote_template_id: commercialFullBodyTemplateSettingValue('') },
    )
    expect(next.commercial.quote_template_id).toBe(COMMERCIAL_FULL_BODY_TEMPLATE_NONE)
  })
})
