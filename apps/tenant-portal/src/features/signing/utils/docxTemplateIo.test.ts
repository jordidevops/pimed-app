import { describe, expect, it } from 'vitest'
import PizZip from 'pizzip'
import {
  cloneLocaleHtmlContent,
  dottedPathParser,
  extractDocxDocumentXml,
  extractDocxSigningRoles,
  extractDocxVariableKeys,
  isDocxLocaleMime,
  searchableDocxFromBlob,
  searchableDocxPlainText,
  skipDocxSchemaVarMismatch,
} from './docxTemplateIo'

function fakeDocxBlob(xml: string): Blob {
  const zip = new PizZip()
  zip.file('word/document.xml', xml)
  return new Blob([zip.generate({ type: 'arraybuffer' })])
}

describe('docxTemplateIo', () => {
  it('resolves dotted Docxtemplater tags without flattening', () => {
    const scope = { document: { doc_number: 'PRE-1' }, totals: { total: 10 } }
    expect(dottedPathParser('document.doc_number').get(scope)).toBe('PRE-1')
    expect(dottedPathParser('totals.total').get(scope)).toBe(10)
    expect(dottedPathParser('document').get(scope)).toEqual({ doc_number: 'PRE-1' })
    expect(dottedPathParser('missing.path').get(scope)).toBeUndefined()
  })

  it('joins tokens split across XML runs for legal validation', () => {
    const xml = '<w:t>[[#</w:t><w:t>lines]]</w:t><w:t> [[document.doc_number]] {{Accepto;role=client_accept;type=signature}}</w:t>'
    const plain = searchableDocxPlainText(xml)
    expect(plain).toContain('[[#lines]]')
    expect(plain).toContain('document.doc_number')
    expect(plain).toContain('role=client_accept')
    expect(extractDocxVariableKeys(xml)).toEqual(['document.doc_number'])
    expect(extractDocxSigningRoles(xml)).toEqual(['client_accept'])
  })

  it('extracts document.xml from a zip blob', async () => {
    const blob = fakeDocxBlob('<w:t>[[#lines]] [[document.doc_number]]</w:t>')
    const xml = await extractDocxDocumentXml(blob)
    expect(xml).toContain('[[#lines]]')
    expect(await searchableDocxFromBlob(blob)).toContain('[[#lines]]')
  })

  it('skips schema-vs-docx mismatch only for full-body commercial categories', () => {
    expect(skipDocxSchemaVarMismatch('quote')).toBe(true)
    expect(skipDocxSchemaVarMismatch('delivery_note')).toBe(true)
    expect(skipDocxSchemaVarMismatch('hr')).toBe(false)
    expect(skipDocxSchemaVarMismatch('commercial')).toBe(false)
  })

  it('detects DOCX mime and extracts searchable xml on clone', async () => {
    expect(isDocxLocaleMime('application/vnd.openxmlformats-officedocument.wordprocessingml.document')).toBe(true)
    expect(isDocxLocaleMime('text/html')).toBe(false)

    const blob = fakeDocxBlob('<w:t>[[#lines]]</w:t>')
    const html = await cloneLocaleHtmlContent(
      {
        mime_type: 'text/html',
        storage_path: null,
        html_content: '{% for line in lines %}',
      },
      async () => blob,
    )
    expect(html).toBe('{% for line in lines %}')

    const docx = await cloneLocaleHtmlContent(
      {
        mime_type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        storage_path: 'platform/docx/commercial/quote-generic-ca.docx',
        html_content: null,
      },
      async (path) => {
        expect(path).toContain('quote-generic-ca')
        return blob
      },
    )
    expect(docx).toContain('[[#lines]]')

    await expect(
      cloneLocaleHtmlContent(
        { mime_type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', storage_path: null, html_content: null },
        async () => blob,
      ),
    ).rejects.toThrow('docx_clone_missing_storage_path')
  })
})
