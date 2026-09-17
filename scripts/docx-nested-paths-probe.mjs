#!/usr/bin/env node
/**
 * QT-6 guardrail 7: does Docxtemplater (same options as docx-renderer.ts,
 * no expression parser) resolve dotted paths and loops?
 *
 * Run: cd scripts && npm install && node docx-nested-paths-probe.mjs
 */
import {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType,
} from 'docx'
import PizZip from 'pizzip'
import Docxtemplater from 'docxtemplater'

const V = (key) => new TextRun({ text: `[[${key}]]` })
const T = (text) => new TextRun(text)
const P = (...children) => new Paragraph({ children })

function cell(children, width = 1800) {
  return new TableCell({
    width: { size: width, type: WidthType.DXA },
    children: [new Paragraph({ children })],
  })
}

/** Same idea as docxtemplater FAQ nested objects; default parser does not split dots. */
function dottedPathParser(tag) {
  const keys = tag === '.' ? [] : String(tag).split('.')
  return {
    get(scope) {
      if (tag === '.') return scope
      let current = scope
      for (const key of keys) {
        if (current == null || typeof current !== 'object') return undefined
        current = current[key]
      }
      return current
    },
  }
}

function renderDocxLikeEdge(input, context) {
  const zip = new PizZip(input)
  const doc = new Docxtemplater(zip, {
    delimiters: { start: '[[', end: ']]' },
    paragraphLoop: true,
    linebreaks: true,
    parser: dottedPathParser,
    nullGetter: (part) => {
      const raw = part?.raw?.trim()
      return raw ? `[[${raw}]]` : ''
    },
  })
  doc.render(context)
  return doc.getZip().generate({ type: 'uint8array' })
}

function xmlText(bytes) {
  const zip = new PizZip(bytes)
  const xml = zip.file('word/document.xml').asText()
  return xml.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim()
}

function rawXml(bytes) {
  return new PizZip(bytes).file('word/document.xml').asText()
}

function minimalDocx(bodyXml) {
  const zip = new PizZip()
  zip.file('[Content_Types].xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>`)
  zip.file('_rels/.rels', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>`)
  zip.file('word/_rels/document.xml.rels', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>`)
  zip.file('word/document.xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>${bodyXml}<w:sectPr/></w:body>
</w:document>`)
  return zip.generate({ type: 'uint8array' })
}

const template = new Document({
  sections: [{
    children: [
      P(T('Doc '), V('document.doc_number')),
      P(V('#lines'), T(' LINE:'), V('name'), T(' x'), V('quantity'), T(' parent:'), V('document.doc_number'), V('/lines')),
      new Table({
        width: { size: 9000, type: WidthType.DXA },
        rows: [
          new TableRow({
            children: [
              cell([T('Concepte')]),
              cell([T('Qtd')]),
              cell([T('Import')]),
            ],
          }),
          new TableRow({
            children: [
              cell([V('#lines'), V('name')]),
              cell([V('quantity')]),
              cell([V('line_total'), V('/lines')]),
            ],
          }),
        ],
      }),
      P(T('Subtotal '), V('totals.subtotal')),
      P(V('#totals.tax_breakdown'), T(' IVA '), V('tax_rate'), T('% '), V('tax_amount'), V('/totals.tax_breakdown')),
      P(T('Total '), V('totals.total')),
      P(V('#document.show_prices'), T('PRICES_ON'), V('/document.show_prices')),
      P(V('^document.show_prices'), T('PRICES_OFF'), V('/document.show_prices')),
    ],
  }],
})

const context = {
  document: { doc_number: 'PRE-2026-0008', show_prices: true },
  lines: [
    { name: 'Visita', quantity: 2, line_total: 90 },
    { name: 'Recanvi', quantity: 1, line_total: 72 },
  ],
  totals: {
    subtotal: 168,
    tax_breakdown: [
      { tax_rate: 21, tax_amount: 34.02 },
      { tax_rate: 10, tax_amount: 0.6 },
    ],
    total: 202.62,
  },
}

const buffer = await Packer.toBuffer(template)
const tXml = rawXml(buffer)
const wt = [...tXml.matchAll(/<w:t[^>]*>([^<]*)<\/w:t>/g)].map((m) => m[1])
console.log('TEMPLATE w:t runs:', JSON.stringify(wt))
const rendered = renderDocxLikeEdge(buffer, context)
const text = xmlText(rendered)

const checks = [
  ['root dotted document.doc_number', text.includes('PRE-2026-0008')],
  ['loop line name Visita', text.includes('Visita')],
  ['loop line name Recanvi', text.includes('Recanvi')],
  ['dotted path inside loop (parent scope)', text.includes('parent: PRE-2026-0008') || text.includes('parent:PRE-2026-0008')],
  ['nested loop totals.tax_breakdown 21', text.includes('21') && text.includes('34.02')],
  ['nested loop totals.tax_breakdown 10', text.includes('10') && text.includes('0.6')],
  ['dotted totals.total', text.includes('202.62')],
  ['truthy section document.show_prices', text.includes('PRICES_ON') && !text.includes('PRICES_OFF')],
  ['no leftover [[ tags', !text.includes('[[')],
]

let failed = 0
for (const [label, ok] of checks) {
  if (!ok) {
    failed++
    console.error(`  FAIL  ${label}`)
  } else {
    console.log(`  OK    ${label}`)
  }
}

if (failed) {
  console.error('\nRendered text:\n', text)
}

const p = (inner) => `<w:p><w:r><w:t xml:space="preserve">${inner}</w:t></w:r></w:p>`
const rawBytes = minimalDocx(
  p('Doc [[document.doc_number]]') +
  p('[[#lines]] LINE:[[name]] x[[quantity]] parent:[[document.doc_number]] [[/lines]]') +
  p('Subtotal [[totals.subtotal]]') +
  p('[[#totals.tax_breakdown]] IVA [[tax_rate]]% [[tax_amount]] [[/totals.tax_breakdown]]') +
  p('Total [[totals.total]]') +
  p('[[#document.show_prices]]PRICES_ON[[/document.show_prices]]') +
  p('[[^document.show_prices]]PRICES_OFF[[/document.show_prices]]'),
)
const rawRendered = xmlText(renderDocxLikeEdge(rawBytes, context))
console.log('\nRAW XML rendered:', rawRendered)
const rawOk = rawRendered.includes('PRE-2026-0008')
  && rawRendered.includes('Visita')
  && rawRendered.includes('Recanvi')
  && rawRendered.includes('202.62')
  && rawRendered.includes('34.02')
  && rawRendered.includes('PRICES_ON')
  && !rawRendered.includes('PRICES_OFF')
  && !rawRendered.includes('[[')
console.log(rawOk ? '  OK    raw XML dotted paths' : '  FAIL  raw XML dotted paths')

if (failed || !rawOk) {
  console.error('\nFlattening may be required.')
  process.exit(1)
}

console.log('\nDocxtemplater nested paths OK with dottedPathParser. Flattening not required.')
console.log('QT-6 must pass this parser into renderDocx (default parser does not split dots).')
