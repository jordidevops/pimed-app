import { describe, expect, it } from 'vitest'
import {
  COMMERCIAL_DELIVERY_DOCX_SIGNATURE_TAG,
  COMMERCIAL_QUOTE_DOCX_SIGNATURE_TAGS,
  COMMERCIAL_SIGNATURE_BOX_STYLE,
  commercialDeliveryConformityHtml,
  commercialQuoteAcceptRejectHtml,
  commercialSignatureHtml,
  commercialSigningRolesToEnsure,
  htmlHasEqualCommercialSignatureBoxes,
} from './commercialSignatureFields'
import { buildPlatformDeliveryNoteHtml, buildPlatformQuoteHtml } from '../../commercial/templates/platformCommercialHtml'

describe('commercialSignatureFields', () => {
  it('emits equal 220×70 HTML boxes and §2.1 role tokens for quotes', () => {
    const html = commercialQuoteAcceptRejectHtml()
    expect(html).toContain('role="client_accept"')
    expect(html).toContain('role="client_reject"')
    expect(html).toContain(COMMERCIAL_SIGNATURE_BOX_STYLE)
    expect(htmlHasEqualCommercialSignatureBoxes(html, 'quote')).toBe(true)
    expect(html.match(/width:220px/g)?.length).toBe(2)
  })

  it('emits a delivery conformity box of the same size', () => {
    const html = commercialDeliveryConformityHtml()
    expect(html).toContain('role="client_delivery"')
    expect(htmlHasEqualCommercialSignatureBoxes(html, 'delivery_note')).toBe(true)
    expect(commercialSignatureHtml('delivery_note')).toContain('client_delivery')
  })

  it('matches platform seed HTML and DOCX tag contract', () => {
    const quote = buildPlatformQuoteHtml('ca', 'generic')
    const delivery = buildPlatformDeliveryNoteHtml('ca')
    expect(htmlHasEqualCommercialSignatureBoxes(quote, 'quote')).toBe(true)
    expect(htmlHasEqualCommercialSignatureBoxes(delivery, 'delivery_note')).toBe(true)
    expect(COMMERCIAL_QUOTE_DOCX_SIGNATURE_TAGS[0]).toBe('{{Accepto;type=signature;role=client_accept}}')
    expect(COMMERCIAL_DELIVERY_DOCX_SIGNATURE_TAG).toContain('role=client_delivery')
  })

  it('lists signing roles to register on insert', () => {
    expect(commercialSigningRolesToEnsure('quote').map((r) => r.roleName)).toEqual([
      'client_accept',
      'client_reject',
    ])
    expect(commercialSigningRolesToEnsure('delivery_note')[0]?.roleName).toBe('client_delivery')
  })
})
