#!/usr/bin/env node
/**
 * QT-6: plantilles DOCX de cos complet (quote + delivery_note).
 * Helpers nous: linesTable / totalsBlock / acceptRejectBlock.
 * IDs prefix 74 (quote) / 75 (delivery). Locales 748 (ca) / 749 (es).
 *
 * Cridat des de generate-docx-seed.mjs o:
 *   cd scripts && node generate-commercial-docx-seed.mjs
 *
 * La pujada a Storage necessita el JWT service_role (`supabase status`), no el JWT secret.
 * El text legal és un punt de partida per clonar, no assessorament jurídic.
 */
import {
  Document, Packer,
  Paragraph, TextRun, HeadingLevel,
  Table, TableRow, TableCell, WidthType,
} from 'docx'
import PizZip from 'pizzip'
import Docxtemplater from 'docxtemplater'
import { writeFile, mkdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadServiceRoleJwt } from './load-service-role-jwt.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SUPABASE_URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321'
const SERVICE_ROLE_KEY = loadServiceRoleJwt()
const BUCKET = 'document-templates'
const DOCX_MIME = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
const MIGRATION_FILE = path.join(
  __dirname, '..', 'supabase', 'migrations',
  '20261168000001_commercial_templates_seed_docx.sql',
)

const T = (text) => new TextRun(text)
const B = (text) => new TextRun({ text, bold: true })
const V = (key) => new TextRun({ text: `[[${key}]]`, bold: true, color: '1D4ED8' })
const F = (name, type, role) => new TextRun({
  text: `{{${name};type=${type};role=${role}}}`,
  bold: true,
  color: '7C3AED',
})
const P = (...children) => new Paragraph({ children })
const BR = () => new Paragraph({ text: '' })
const H1 = (text) => new Paragraph({
  heading: HeadingLevel.HEADING_1,
  children: [new TextRun({ text, bold: true })],
})
const H2 = (text) => new Paragraph({
  heading: HeadingLevel.HEADING_2,
  children: [new TextRun(text)],
})

function dataRow(label, varKey) {
  return new TableRow({
    children: [
      new TableCell({
        width: { size: 2800, type: WidthType.DXA },
        children: [new Paragraph({ children: [new TextRun(label)] })],
      }),
      new TableCell({
        width: { size: 6200, type: WidthType.DXA },
        children: [new Paragraph({ children: [V(varKey)] })],
      }),
    ],
  })
}

function infoTable(rows) {
  return new Table({
    width: { size: 9000, type: WidthType.DXA },
    rows: rows.map(([label, key]) => dataRow(label, key)),
  })
}

function cell(children, width) {
  return new TableCell({
    width: { size: width, type: WidthType.DXA },
    children: [new Paragraph({ children })],
  })
}

/** Fila de capçalera + fila Docxtemplater `[[#lines]]…[[/lines]]`. */
function linesTable(copy, withPrices) {
  const header = withPrices
    ? [copy.concept, copy.qty, copy.unit, copy.price, copy.discount, copy.amount]
    : [copy.concept, copy.qty, copy.unit]
  const widths = withPrices
    ? [2800, 1000, 1000, 1400, 1200, 1600]
    : [5000, 2000, 2000]
  const headerRow = new TableRow({
    children: header.map((label, i) => cell([new TextRun({ text: label, bold: true })], widths[i])),
  })
  const dataChildren = withPrices
    ? [
      cell([V('#lines'), V('name')], widths[0]),
      cell([V('quantity')], widths[1]),
      cell([V('unit')], widths[2]),
      cell([V('unit_price')], widths[3]),
      cell([V('discount_pct')], widths[4]),
      cell([V('line_total'), V('/lines')], widths[5]),
    ]
    : [
      cell([V('#lines'), V('name')], widths[0]),
      cell([V('quantity')], widths[1]),
      cell([V('unit'), V('/lines')], widths[2]),
    ]
  return new Table({
    width: { size: 9000, type: WidthType.DXA },
    rows: [headerRow, new TableRow({ children: dataChildren })],
  })
}

function totalsBlock(copy) {
  return [
    P(B(copy.subtotal), T(': '), V('totals.subtotal'), T(' '), V('document.currency')),
    P(
      V('#totals.tax_breakdown'),
      T(`${copy.vat} `),
      V('tax_rate'),
      T('%: '),
      V('tax_amount'),
      T(' '),
      V('document.currency'),
      V('/totals.tax_breakdown'),
    ),
    P(B(copy.total), T(': '), V('totals.total'), T(' '), V('document.currency')),
  ]
}

function acceptRejectBlock(copy) {
  const w = 4500
  return new Table({
    width: { size: 9000, type: WidthType.DXA },
    rows: [
      new TableRow({
        children: [
          new TableCell({
            width: { size: w, type: WidthType.DXA },
            children: [
              P(B(copy.acceptLabel)),
              P(F('Accepto', 'signature', 'client_accept')),
            ],
          }),
          new TableCell({
            width: { size: w, type: WidthType.DXA },
            children: [
              P(B(copy.rejectLabel)),
              P(F('Refuso', 'signature', 'client_reject')),
            ],
          }),
        ],
      }),
    ],
  })
}

const COPY = {
  ca: {
    quoteTitle: 'Pressupost núm.',
    deliveryTitle: 'Albarà núm.',
    parentRef: 'Referència pressupost',
    issued: "Data d’emissió",
    validUntil: 'Validesa fins',
    seller: 'Emissor',
    buyer: 'Client',
    serviceAddress: 'Adreça del servei',
    concept: 'Concepte',
    qty: 'Qtd',
    unit: 'Unitat',
    price: 'Preu',
    discount: 'Dte. %',
    amount: 'Import',
    subtotal: 'Subtotal',
    vat: 'IVA',
    total: 'Total',
    conditions: 'Condicions generals',
    conditionsBody:
      "Aquest pressupost té una validesa de 30 dies des de la data d'emissió, llevat que s'indiqui altrament. Els preus inclouen l'IVA aplicable. Qualsevol concepte no inclòs en aquest pressupost que aparegui durant l'execució del servei serà objecte d'una ampliació de pressupost, que haurà de ser acceptada abans de la seva execució i cobrament, d'acord amb la normativa de protecció de les persones consumidores. Per a qualsevol controvèrsia, les parts se sotmeten als jutjats i tribunals que correspongui per llei.",
    accept: 'Acceptació',
    acceptHint: 'Cal signar una de les dues caselles (mateixa mida).',
    acceptLabel: 'Accepto',
    rejectLabel: 'Refuso',
    privacy: 'Protecció de dades',
    privacyPrefix:
      "Les dades facilitades es tracten amb la finalitat de gestionar aquest pressupost i, si escau, la relació contractual derivada. Es conserven durant un mínim de sis mesos des de la no-acceptació o des de la fi del servei. Podeu exercir els vostres drets d'accés, rectificació i supressió dirigint-vos a ",
    generated: 'Document generat per',
    deliveryConformity: 'Conformitat de lliurament',
    deliveryConformityHint: 'Reconeixement de servei rebut, no és acceptar ni refusar un pressupost.',
    notInvoice: 'Aquest document no és una factura fiscal.',
    extra: {
      generic: '',
      field_service:
        "Els desplaçaments, urgències o intervencions fora d'horari habitual es facturen com a línia pròpia i identificable en aquest pressupost, mai com a recàrrec improvisat.",
      workshop_maker:
        'Per a reparacions subjectes al Reial Decret 1457/1986, aquest pressupost té una validesa mínima de 12 dies hàbils.',
      practice:
        "Si el servei requereix el dipòsit de béns, se'n lliurarà un resguard acreditatiu independent d'aquest pressupost.",
      hospitality: '',
    },
  },
  es: {
    quoteTitle: 'Presupuesto n.º',
    deliveryTitle: 'Albarán n.º',
    parentRef: 'Referencia presupuesto',
    issued: 'Fecha de emisión',
    validUntil: 'Validez hasta',
    seller: 'Emisor',
    buyer: 'Cliente',
    serviceAddress: 'Dirección del servicio',
    concept: 'Concepto',
    qty: 'Cant.',
    unit: 'Unidad',
    price: 'Precio',
    discount: 'Dto. %',
    amount: 'Importe',
    subtotal: 'Subtotal',
    vat: 'IVA',
    total: 'Total',
    conditions: 'Condiciones generales',
    conditionsBody:
      'Este presupuesto tiene una validez de 30 días desde la fecha de emisión, salvo indicación en contrario. Los precios incluyen el IVA aplicable. Cualquier concepto no incluido en este presupuesto que aparezca durante la ejecución del servicio será objeto de una ampliación de presupuesto, que deberá ser aceptada antes de su ejecución y cobro, de acuerdo con la normativa de protección de las personas consumidoras. Para cualquier controversia, las partes se someten a los juzgados y tribunales que correspondan por ley.',
    accept: 'Aceptación',
    acceptHint: 'Hay que firmar una de las dos casillas (mismo tamaño).',
    acceptLabel: 'Acepto',
    rejectLabel: 'Rechazo',
    privacy: 'Protección de datos',
    privacyPrefix:
      'Los datos facilitados se tratan con la finalidad de gestionar este presupuesto y, en su caso, la relación contractual derivada. Se conservan durante un mínimo de seis meses desde la no aceptación o desde el fin del servicio. Puede ejercer sus derechos de acceso, rectificación y supresión dirigiéndose a ',
    generated: 'Documento generado por',
    deliveryConformity: 'Conformidad de entrega',
    deliveryConformityHint: 'Reconocimiento de servicio recibido; no es aceptar ni rechazar un presupuesto.',
    notInvoice: 'Este documento no es una factura fiscal.',
    extra: {
      generic: '',
      field_service:
        'Los desplazamientos, urgencias o intervenciones fuera de horario habitual se facturan como línea propia e identificable en este presupuesto, nunca como recargo improvisado.',
      workshop_maker:
        'Para reparaciones sujetas al Real Decreto 1457/1986, este presupuesto tiene una validez mínima de 12 días hábiles.',
      practice:
        'Si el servicio requiere el depósito de bienes, se entregará un resguardo acreditativo independiente de este presupuesto.',
      hospitality: '',
    },
  },
}

function headerBlock(copy, kind) {
  const title = kind === 'quote' ? copy.quoteTitle : copy.deliveryTitle
  const validity = kind === 'quote'
    ? [P(T(`${copy.validUntil}: `), V('document.valid_until_display'))]
    : [P(T(`${copy.parentRef}: `), V('document.parent_doc_number'))]
  return [
    H1(title),
    P(V('tenant.name'), T(' · '), V('tenant.tax_id')),
    P(T(`${copy.issued}: `), V('document.issued_at_display')),
    ...validity,
    P(B(`${title} `), V('document.doc_number')),
    BR(),
    P(B(copy.seller)),
    infoTable([
      ['', 'seller.display_name'],
      ['NIF', 'seller.tax_id'],
      ['Email', 'seller.email'],
      ['Tel', 'seller.phone'],
    ]),
    BR(),
    P(B(copy.buyer)),
    infoTable([
      ['', 'buyer.display_name'],
      ['NIF', 'buyer.tax_id'],
      ['Email', 'buyer.email'],
      ['Tel', 'buyer.phone'],
    ]),
    BR(),
    P(B(copy.serviceAddress)),
    P(V('service_address.label'), T(' '), V('service_address.line1'), T(' '), V('service_address.city')),
    BR(),
  ]
}

function quoteChildren(locale, archetype) {
  const copy = COPY[locale]
  const extra = copy.extra[archetype]
  return [
    ...headerBlock(copy, 'quote'),
    linesTable(copy, true),
    BR(),
    ...totalsBlock(copy),
    BR(),
    H2(copy.conditions),
    P(T(copy.conditionsBody)),
    ...(extra ? [P(T(extra))] : []),
    BR(),
    H2(copy.accept),
    P(T(copy.acceptHint)),
    acceptRejectBlock(copy),
    BR(),
    H2(copy.privacy),
    P(T(copy.privacyPrefix), V('tenant.email'), T('.')),
    BR(),
    P(T(`${copy.generated} `), V('tenant.name'), T('.')),
  ]
}

function deliveryChildren(locale) {
  const copy = COPY[locale]
  return [
    ...headerBlock(copy, 'delivery'),
    P(V('#document.show_prices')),
    linesTable(copy, true),
    ...totalsBlock(copy),
    P(V('/document.show_prices')),
    P(V('^document.show_prices')),
    linesTable(copy, false),
    P(V('/document.show_prices')),
    BR(),
    H2(copy.deliveryConformity),
    P(T(copy.deliveryConformityHint)),
    P(F('Conformitat', 'signature', 'client_delivery')),
    BR(),
    P(T(copy.notInvoice)),
    P(T(`${copy.generated} `), V('tenant.name'), T('.')),
  ]
}

const SAMPLE_QUOTE = {
  globals: { today: '2026-09-17', date: '2026-09-17', year: '2026', now: '2026-09-17T10:00:00.000Z' },
  tenant: {
    name: 'Volt Serveis SL', tax_id: 'B00000000', address: "Carrer Indústria 10, Vic",
    phone: '938000000', email: 'hola@volt.example', logo_url: 'https://cdn.example/logo.png',
  },
  document: {
    doc_type: 'quote', doc_number: 'PRE-2026-0008', status: 'issued', locale: 'ca', currency: 'EUR',
    issued_at: '2026-09-17T10:00:00.000Z', valid_until: '2026-10-17', created_at: '2026-09-17T09:00:00.000Z',
    issued_at_display: '17/09/2026 12:00', valid_until_display: '17/10/2026', created_at_display: '17/09/2026 11:00',
    is_amendment: false, parent_doc_number: null, show_prices: true, terms_text: '30 dies',
  },
  seller: {
    display_name: 'Volt Serveis SL', tax_id: 'B00000000', email: 'hola@volt.example', phone: '938000000',
    address_line1: "Carrer Indústria 10", address_line2: null, city: 'Vic', postal_code: '08500',
  },
  buyer: {
    display_name: 'Client Exemple SL', tax_id: 'B12345678', email: 'facturacio@client-exemple.example',
    phone: '934000000', address_line1: 'Carrer Major 1', address_line2: null, city: 'Vic', postal_code: '08500',
  },
  service_address: {
    label: 'Nau 2', line1: 'Carrer del Pont 4', line2: null, city: 'Manlleu',
    postal_code: '08560', region: 'Barcelona', country: 'ES',
  },
  lines: [
    { name: 'Visita tècnica', description: 'Diagnosi in situ', unit: 'h', quantity: 2, unit_price: 45, discount_pct: 0, tax_rate: 21, line_total: 90, kind: 'service' },
    { name: 'Recanvi', description: 'Peça de catàleg', unit: 'u', quantity: 1, unit_price: 80, discount_pct: 10, tax_rate: 21, line_total: 72, kind: 'product' },
    { name: 'Desplaçament', description: null, unit: 'km', quantity: 15, unit_price: 0.4, discount_pct: 0, tax_rate: 10, line_total: 6, kind: 'expense' },
  ],
  totals: {
    subtotal: 168,
    tax_breakdown: [
      { tax_rate: 21, tax_amount: 34.02 },
      { tax_rate: 10, tax_amount: 0.6 },
    ],
    total: 202.62,
  },
  legal: { retention_days: 180, jurisdiction_text: '' },
}

const QUOTE_TEMPLATES = [
  {
    id: '74000000-0000-0000-0000-000000000001',
    slug: 'quote-generic',
    archetype: 'generic',
    name: 'Pressupost genèric (DOCX)',
    description: 'Plantilla DOCX de pressupost de cos complet (punt de partida; no és assessorament jurídic).',
    targetArchetypes: null,
  },
  {
    id: '74000000-0000-0000-0000-000000000002',
    slug: 'quote-field-service',
    archetype: 'field_service',
    name: 'Pressupost servei de camp (DOCX)',
    description: 'Pressupost DOCX per a serveis a domicili o en ruta, amb clàusula de desplaçaments/urgències com a línia pròpia.',
    targetArchetypes: ['field_service'],
  },
  {
    id: '74000000-0000-0000-0000-000000000003',
    slug: 'quote-workshop-maker',
    archetype: 'workshop_maker',
    name: 'Pressupost taller / maker (DOCX)',
    description: 'Pressupost DOCX per a taller o maker, amb avís informatiu de validesa mínima (RD 1457/1986) quan aplica.',
    targetArchetypes: ['workshop_maker'],
  },
  {
    id: '74000000-0000-0000-0000-000000000004',
    slug: 'quote-practice',
    archetype: 'practice',
    name: 'Pressupost consulta / pràctica (DOCX)',
    description: 'Pressupost DOCX per a consulta o pràctica, amb avís de resguard independent si hi ha dipòsit de béns.',
    targetArchetypes: ['practice'],
  },
  {
    id: '74000000-0000-0000-0000-000000000005',
    slug: 'quote-hospitality',
    archetype: 'hospitality',
    name: 'Pressupost hostaleria (DOCX)',
    description: 'Pressupost DOCX per a hostaleria (mateixa base genèrica; clàusules sectorials pendents).',
    targetArchetypes: ['hospitality'],
  },
]

const DELIVERY_TEMPLATE = {
  id: '75000000-0000-0000-0000-000000000001',
  slug: 'delivery-generic',
  name: 'Albarà genèric (DOCX)',
  description: 'Albarà DOCX de cos complet (no és factura fiscal). Punt de partida; no és assessorament jurídic.',
}

function localeIds(index1, locale) {
  const prefix = locale === 'ca' ? '74800000' : '74900000'
  const n = String(index1).padStart(12, '0')
  return `${prefix}-0000-0000-0000-${n}`
}

function signingRoles(kind, locale) {
  if (kind === 'delivery') {
    return {
      client_delivery: {
        entity_type: 'contact',
        label: locale === 'ca' ? 'Conformitat' : 'Conformidad',
        order: 0,
        for_signing: true,
      },
    }
  }
  return {
    client_accept: {
      entity_type: 'contact',
      label: locale === 'ca' ? 'Accepto' : 'Acepto',
      order: 0,
      for_signing: true,
    },
    client_reject: {
      entity_type: 'contact',
      label: locale === 'ca' ? 'Refuso' : 'Rechazo',
      order: 1,
      for_signing: true,
    },
  }
}

function sampleFor(kind, locale) {
  if (kind === 'delivery') {
    return {
      ...SAMPLE_QUOTE,
      document: {
        ...SAMPLE_QUOTE.document,
        doc_type: 'delivery_note',
        doc_number: 'ALB-2026-0003',
        locale,
        valid_until: null,
        parent_doc_number: 'PRE-2026-0008',
        show_prices: true,
        terms_text: null,
      },
    }
  }
  return { ...SAMPLE_QUOTE, document: { ...SAMPLE_QUOTE.document, locale } }
}

function buildEntries() {
  const entries = []
  QUOTE_TEMPLATES.forEach((tpl, i) => {
    for (const locale of ['ca', 'es']) {
      entries.push({
        templateId: tpl.id,
        localeId: localeIds(i + 1, locale),
        locale,
        name: tpl.name,
        description: tpl.description,
        category: 'quote',
        targetArchetypes: tpl.targetArchetypes,
        storagePath: `platform/docx/commercial/${tpl.slug}-${locale}.docx`,
        sampleValues: sampleFor('quote', locale),
        signingRolesSchema: signingRoles('quote', locale),
        children: () => quoteChildren(locale, tpl.archetype),
        kind: 'quote',
      })
    }
  })
  for (const locale of ['ca', 'es']) {
    entries.push({
      templateId: DELIVERY_TEMPLATE.id,
      localeId: localeIds(6, locale),
      locale,
      name: DELIVERY_TEMPLATE.name,
      description: DELIVERY_TEMPLATE.description,
      category: 'delivery_note',
      targetArchetypes: null,
      storagePath: `platform/docx/commercial/${DELIVERY_TEMPLATE.slug}-${locale}.docx`,
      sampleValues: sampleFor('delivery', locale),
      signingRolesSchema: signingRoles('delivery', locale),
      children: () => deliveryChildren(locale),
      kind: 'delivery',
    })
  }
  return entries
}

async function buildDocxBuffer(entry) {
  const doc = new Document({
    creator: 'App Seed Script',
    title: entry.name,
    description: entry.description,
    sections: [{
      properties: {
        page: { margin: { top: 1440, right: 1080, bottom: 1440, left: 1080 } },
      },
      children: entry.children(),
    }],
  })
  return Packer.toBuffer(doc)
}

function searchableContent(buffer) {
  const zip = new PizZip(buffer)
  const xml = zip.file('word/document.xml').asText()
  return [...xml.matchAll(/<w:t[^>]*>([^<]*)<\/w:t>/g)].map((m) => m[1]).join('')
}

const QUOTE_TOKENS = [
  '[[#lines]]',
  'totals.total',
  'document.doc_number',
  'document.valid_until',
  'totals.tax_breakdown',
  'role=client_accept',
  'role=client_reject',
]
const DELIVERY_TOKENS = [
  '[[#lines]]',
  'document.doc_number',
  'role=client_delivery',
]

function assertTokens(entry, haystack) {
  const tokens = entry.kind === 'delivery' ? DELIVERY_TOKENS : QUOTE_TOKENS
  const missing = tokens.filter((tok) => !haystack.includes(tok))
  if (missing.length) {
    throw new Error(`${entry.storagePath} missing tokens: ${missing.join(', ')}`)
  }
}

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

function renderedPlainText(buffer, context) {
  const zip = new PizZip(buffer)
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
  const xml = doc.getZip().file('word/document.xml').asText()
  return xml.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim()
}

function assertRendered(entry, buffer) {
  const text = renderedPlainText(buffer, entry.sampleValues)
  if (!text.includes(entry.sampleValues.document.doc_number)) {
    throw new Error(`${entry.storagePath} render missing doc_number`)
  }
  if (!text.includes('Visita tècnica') && !text.includes('Client Exemple SL')) {
    throw new Error(`${entry.storagePath} render missing line/buyer`)
  }
  if (text.includes('[[')) {
    throw new Error(`${entry.storagePath} leftover tags: ${text.slice(0, 200)}`)
  }
}

async function uploadToStorage(storagePath, buffer) {
  const url = `${SUPABASE_URL}/storage/v1/object/${BUCKET}/${storagePath}`
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      apikey: SERVICE_ROLE_KEY,
      'Content-Type': DOCX_MIME,
      'x-upsert': 'true',
    },
    body: buffer,
  })
  if (!res.ok) {
    const msg = await res.text().catch(() => '')
    throw new Error(`HTTP ${res.status}: ${msg.slice(0, 200)}`)
  }
}

function sqlStr(s) {
  return s === null ? 'NULL' : `'${String(s).replace(/'/g, "''")}'`
}
function sqlBool(b) { return b ? 'true' : 'false' }
function sqlJson(o) {
  return o === null ? 'NULL' : `'${JSON.stringify(o).replace(/'/g, "''")}'`
}
function sqlTextArray(values) {
  if (!values) return 'NULL'
  return `ARRAY[${values.map(sqlStr).join(', ')}]::text[]`
}

function generateSQL(templates, locales) {
  const tplRows = templates.map((t) =>
    `  (${sqlStr(t.id)}, NULL, ${sqlStr(t.name)}, ${sqlStr(t.description)}, ${sqlStr(t.category)}, 'docx', true, true, NULL, ${sqlTextArray(t.targetArchetypes)})`,
  )
  const locRows = locales.map((l) => `(
  ${sqlStr(l.localeId)}, ${sqlStr(l.templateId)}, ${sqlStr(l.locale)},
  '${DOCX_MIME}',
  ${sqlStr(l.storagePath)},
  NULL,
  '{}'::jsonb,
  ${sqlJson(l.signingRolesSchema)}::jsonb,
  ${sqlJson(l.sampleValues)}::jsonb,
  true
)`)
  return `-- QT-6: plantilles DOCX de plataforma (cos complet quote/delivery_note).
-- Prefixos: 74 quote, 75 delivery_note, 748 locales ca, 749 locales es.
-- tenant_id=NULL, is_platform_default=true. ON CONFLICT DO NOTHING.
-- html_content és NULL (chk_doc_template_locale_content_consistency: DOCX no pot tenir HTML).
-- Tokens §2.1 es verifiquen en generar (assertTokens) sobre word/document.xml.
-- El text legal és un punt de partida per clonar, no assessorament jurídic.
-- Regenerar: cd scripts && node generate-commercial-docx-seed.mjs
-- Els fitxers cal pujar-los al bucket document-templates (SUPABASE_SERVICE_ROLE_KEY).

CREATE OR REPLACE FUNCTION api.get_commercial_full_body_locale(
  p_tenant_id uuid,
  p_template_id uuid,
  p_locale text DEFAULT 'ca'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_is_service boolean := COALESCE(auth.role(), '') = 'service_role';
  v_locale text := COALESCE(NULLIF(btrim(p_locale), ''), 'ca');
  v_tpl data.document_templates%ROWTYPE;
  v_html text;
  v_path text;
  v_type text;
BEGIN
  IF p_tenant_id IS NULL OR p_template_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT v_is_service
     AND NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'access_denied' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
    INTO v_tpl
  FROM data.document_templates t
  WHERE t.id = p_template_id
    AND t.is_active
    AND (
      t.tenant_id = p_tenant_id
      OR (t.tenant_id IS NULL AND t.is_platform_default)
    );

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_type := v_tpl.template_type;

  SELECT l.html_content, l.storage_path
    INTO v_html, v_path
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id
    AND l.is_active
    AND l.locale = v_locale
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT l.html_content, l.storage_path
      INTO v_html, v_path
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id
      AND l.is_active
    ORDER BY CASE WHEN l.locale = 'ca' THEN 0 ELSE 1 END, l.locale
    LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'template_type', v_type,
    'html_content', v_html,
    'storage_path', v_path
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_commercial_full_body_locale(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_commercial_full_body_locale(uuid, uuid, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by, target_archetypes)
VALUES
${tplRows.join(',\n')}
ON CONFLICT DO NOTHING;

INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
${locRows.join(',\n')}
ON CONFLICT DO NOTHING;
`
}

export async function runCommercialDocxSeed() {
  console.log('\n🔷  Generant plantilles DOCX comercials (QT-6)...\n')
  const outDir = path.join(__dirname, '..', 'tmp', 'docx-seed', 'commercial')
  if (!existsSync(outDir)) await mkdir(outDir, { recursive: true })

  const doUpload = Boolean(SERVICE_ROLE_KEY)
  if (!doUpload) {
    console.log('⚠  No hi ha un JWT service_role (eyJ…). El JWT secret hex no serveix per a Storage.')
    console.log('    Usa `supabase status` i exporta SUPABASE_SERVICE_ROLE_KEY, o deixa que el script el llegeixi del CLI.\n')
  }

  const entries = buildEntries()
  const localeRows = []
  let ok = 0
  let uploadOk = 0

  for (const entry of entries) {
    const fileName = path.basename(entry.storagePath)
    let buffer
    try {
      buffer = await buildDocxBuffer(entry)
      const haystack = searchableContent(buffer)
      assertTokens(entry, haystack)
      assertRendered(entry, buffer)
      await writeFile(path.join(outDir, fileName), buffer)
      console.log(`  ✓  ${fileName}  (${(buffer.length / 1024).toFixed(1)} KB)`)
      ok++
      localeRows.push({ ...entry, haystack })
    } catch (err) {
      console.error(`  ✗  ${fileName}: ${err.message}`)
      continue
    }
    if (doUpload) {
      try {
        await uploadToStorage(entry.storagePath, buffer)
        console.log(`       ↑ pujat → ${entry.storagePath}`)
        uploadOk++
      } catch (err) {
        console.error(`       ✗ error pujant ${entry.storagePath}: ${err.message}`)
      }
    }
  }

  const templates = [
    ...QUOTE_TEMPLATES.map((t) => ({
      id: t.id, name: t.name, description: t.description,
      category: 'quote', targetArchetypes: t.targetArchetypes,
    })),
    {
      id: DELIVERY_TEMPLATE.id, name: DELIVERY_TEMPLATE.name,
      description: DELIVERY_TEMPLATE.description, category: 'delivery_note',
      targetArchetypes: null,
    },
  ]
  const sql = generateSQL(templates, localeRows)
  await writeFile(MIGRATION_FILE, sql, 'utf8')
  await writeFile(path.join(__dirname, '..', 'tmp', 'seed-commercial-docx-templates.sql'), sql, 'utf8')

  console.log(`\n─────────────────────────────────────────────────────────────────────────────`)
  console.log(`  DOCX comercials:  ${ok} / ${entries.length}  →  tmp/docx-seed/commercial/`)
  if (doUpload) console.log(`  Pujats Storage:   ${uploadOk} / ${ok}  →  bucket "${BUCKET}"`)
  console.log(`  SQL migració:     supabase/migrations/20261168000001_commercial_templates_seed_docx.sql`)
  console.log(`─────────────────────────────────────────────────────────────────────────────\n`)
}

const invokedDirectly = process.argv[1] && path.basename(process.argv[1]).includes('generate-commercial-docx-seed')
if (invokedDirectly) {
  runCommercialDocxSeed().catch((err) => {
    console.error('\n✗  Error fatal:', err.message)
    process.exit(1)
  })
}
