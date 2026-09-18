import { describe, expect, it } from 'vitest'
import { injectIssuedHtmlSignatureMarkers } from './commercialHtmlSignatureMarkers'

describe('injectIssuedHtmlSignatureMarkers', () => {
  it('reads 220×70 from the tag like the edge inject', () => {
    const html = injectIssuedHtmlSignatureMarkers(
      '<signature-field role="client_accept" name="Accepto" style="width:220px;height:70px;"></signature-field>',
    )
    expect(html).toContain('width:220px;height:70px;')
    expect(html).toContain('[FIRMA:client_accept]')
    expect(html).not.toContain('width:180px;height:60px;')
  })

  it('defaults to 180×60 when the tag has no size', () => {
    const html = injectIssuedHtmlSignatureMarkers(
      '<signature-field role="client_reject"></signature-field>',
    )
    expect(html).toContain('width:180px;height:60px;')
    expect(html).toContain('[FIRMA:client_reject]')
  })
})
