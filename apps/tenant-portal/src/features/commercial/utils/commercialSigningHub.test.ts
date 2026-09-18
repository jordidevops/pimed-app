import { describe, expect, it } from 'vitest'
import {
  commercialQuoteViewHref,
  commercialSignedPdfDocumentId,
  commercialSigningCentreHref,
  commercialSigningHubTitle,
  isCommercialQuoteLike,
  matchesSigningCenterSearch,
  signingProviderKind,
} from './commercialSigningHub'

describe('commercialSigningHub', () => {
  it('builds Centre and quotes hrefs', () => {
    expect(commercialSigningCentreHref('sub-1')).toBe('/documents/signing/sub-1')
    expect(commercialQuoteViewHref('doc-1')).toBe('/quotes?view=doc-1')
  })

  it('titles a commercial hub row like the DMS commercial link', () => {
    expect(
      commercialSigningHubTitle(
        { docType: 'quote', docNumber: 'PRE-1' },
        'Pressupost',
      ),
    ).toBe('Pressupost PRE-1')
    expect(
      commercialSigningHubTitle(
        { docType: 'delivery_note', docNumber: null },
        'Albarà',
      ),
    ).toBe('Albarà')
  })

  it('treats native provider as Firma pròpia and everything else as DocuSeal', () => {
    expect(signingProviderKind('native')).toBe('native')
    expect(signingProviderKind('docuseal')).toBe('docuseal')
    expect(signingProviderKind(null)).toBe('docuseal')
  })

  it('matches Centre search by title, id or signer (not only id)', () => {
    const row = {
      id: 'aaaa-bbbb',
      document_title: 'Pressupost PRE-9',
      signers: [{ name: 'Anna Client', email: 'anna@example.com' }],
    }
    expect(matchesSigningCenterSearch(row, 'PRE-9')).toBe(true)
    expect(matchesSigningCenterSearch(row, 'anna@')).toBe(true)
    expect(matchesSigningCenterSearch(row, 'aaaa')).toBe(true)
    expect(matchesSigningCenterSearch(row, 'inexistent')).toBe(false)
  })

  it('recognises quote-like commercial types', () => {
    expect(isCommercialQuoteLike('quote')).toBe(true)
    expect(isCommercialQuoteLike('quote_amendment')).toBe(true)
    expect(isCommercialQuoteLike('delivery_note')).toBe(false)
  })

  it('prefers result_* for the signed DMS copy', () => {
    expect(
      commercialSignedPdfDocumentId({
        resultDocumentId: 'result-doc',
        sourceDocumentId: 'source-doc',
        signingStatus: 'completed',
      }),
    ).toBe('result-doc')
    expect(
      commercialSignedPdfDocumentId({
        resultDocumentId: null,
        sourceDocumentId: 'source-doc',
        signingStatus: 'completed',
      }),
    ).toBe('source-doc')
    expect(
      commercialSignedPdfDocumentId({
        resultDocumentId: null,
        sourceDocumentId: 'source-doc',
        signingStatus: 'pending',
      }),
    ).toBeNull()
  })
})
