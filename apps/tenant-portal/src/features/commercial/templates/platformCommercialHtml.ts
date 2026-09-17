/**
 * Platform HTML bodies for commercial full-body templates (QT-3).
 * Keep in sync with supabase/migrations/20261164000001_commercial_templates_seed_html.sql
 *
 * Clauses are a starting point for tenants to clone, not legal advice.
 */

export type CommercialTemplateLocale = 'ca' | 'es'

export const COMMERCIAL_QUOTE_ARCHETYPES = [
  'generic',
  'field_service',
  'workshop_maker',
  'practice',
  'hospitality',
] as const

export type CommercialQuoteArchetype = (typeof COMMERCIAL_QUOTE_ARCHETYPES)[number]

const QUOTE_EXTRA: Record<CommercialQuoteArchetype, Record<CommercialTemplateLocale, string>> = {
  generic: { ca: '', es: '' },
  field_service: {
    ca: "Els desplaçaments, urgències o intervencions fora d'horari habitual es facturen com a línia pròpia i identificable en aquest pressupost, mai com a recàrrec improvisat.",
    es: 'Los desplazamientos, urgencias o intervenciones fuera de horario habitual se facturan como línea propia e identificable en este presupuesto, nunca como recargo improvisado.',
  },
  workshop_maker: {
    ca: "Per a reparacions subjectes al Reial Decret 1457/1986, aquest pressupost té una validesa mínima de 12 dies hàbils.",
    es: 'Para reparaciones sujetas al Real Decreto 1457/1986, este presupuesto tiene una validez mínima de 12 días hábiles.',
  },
  practice: {
    ca: "Si el servei requereix el dipòsit de béns, se'n lliurarà un resguard acreditatiu independent d'aquest pressupost.",
    es: 'Si el servicio requiere el depósito de bienes, se entregará un resguardo acreditativo independiente de este presupuesto.',
  },
  hospitality: { ca: '', es: '' },
}

const COPY = {
  ca: {
    quoteTitle: 'Pressupost núm.',
    deliveryTitle: 'Albarà núm.',
    parentRef: 'Referència pressupost',
    issued: 'Data d’emissió',
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
    privacyBody:
      "Les dades facilitades es tracten amb la finalitat de gestionar aquest pressupost i, si escau, la relació contractual derivada. Es conserven durant un mínim de sis mesos des de la no-acceptació o des de la fi del servei. Podeu exercir els vostres drets d'accés, rectificació i supressió dirigint-vos a {{ tenant.email }}.",
    generated: 'Document generat per',
    deliveryConformity: 'Conformitat de lliurament',
    deliveryConformityHint: 'Reconeixement de servei rebut, no és acceptar ni refusar un pressupost.',
    notInvoice: 'Aquest document no és una factura fiscal.',
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
    privacyBody:
      'Los datos facilitados se tratan con la finalidad de gestionar este presupuesto y, en su caso, la relación contractual derivada. Se conservan durante un mínimo de seis meses desde la no aceptación o desde el fin del servicio. Puede ejercer sus derechos de acceso, rectificación y supresión dirigiéndose a {{ tenant.email }}.',
    generated: 'Documento generado por',
    deliveryConformity: 'Conformidad de entrega',
    deliveryConformityHint: 'Reconocimiento de servicio recibido; no es aceptar ni rechazar un presupuesto.',
    notInvoice: 'Este documento no es una factura fiscal.',
  },
} as const

const SHELL_START = `<!DOCTYPE html>
<html lang="{{ document.locale }}">
<head>
<meta charset="utf-8"/>
<style>
  body{font-family:Arial,Helvetica,sans-serif;font-size:12px;color:#111;margin:24px;}
  .hdr{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;margin-bottom:16px;}
  .logo{max-height:48px;max-width:160px;}
  h1{font-size:18px;margin:0 0 8px;}
  .meta,.parties,.addr{margin-bottom:14px;}
  .parties{display:flex;gap:24px;}
  .parties>div{flex:1;}
  table{width:100%;border-collapse:collapse;margin:8px 0 14px;}
  th,td{border-bottom:1px solid #ddd;padding:6px 4px;text-align:left;}
  th.num,td.num{text-align:right;white-space:nowrap;}
  .totals{margin-left:auto;width:280px;}
  .note{font-size:11px;line-height:1.45;margin:12px 0;}
  .sigs{display:flex;gap:24px;margin:16px 0;}
  .sigs>div{flex:1;}
  .foot{margin-top:24px;font-size:11px;color:#444;}
</style>
</head>
<body>
`

const SHELL_END = `
</body>
</html>
`

function partiesAndMeta(locale: CommercialTemplateLocale, kind: 'quote' | 'delivery'): string {
  const t = COPY[locale]
  const validity =
    kind === 'quote'
      ? `<div>${t.validUntil}: {{ document.valid_until_display }}</div>`
      : `{% if document.parent_doc_number %}<div>${t.parentRef}: {{ document.parent_doc_number }}</div>{% endif %}`
  return `
<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>${kind === 'quote' ? t.quoteTitle : t.deliveryTitle} {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>${t.issued}: {{ document.issued_at_display }}</div>
    ${validity}
  </div>
</div>
<div class="parties">
  <div>
    <strong>${t.seller}</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>${t.buyer}</strong>
    <div>{{ buyer.display_name }}</div>
    {% if buyer.tax_id %}<div>{{ buyer.tax_id }}</div>{% endif %}
    {% if buyer.email %}<div>{{ buyer.email }}</div>{% endif %}
    {% if buyer.phone %}<div>{{ buyer.phone }}</div>{% endif %}
    {% if buyer.address_line1 %}<div>{{ buyer.address_line1 }} {{ buyer.address_line2 }}</div>{% endif %}
    {% if buyer.city %}<div>{{ buyer.postal_code }} {{ buyer.city }}</div>{% endif %}
  </div>
</div>
{% if service_address.line1 %}
<div class="addr">
  <strong>${t.serviceAddress}</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}
`
}

function linesTable(locale: CommercialTemplateLocale, withPrices: boolean): string {
  const t = COPY[locale]
  if (withPrices) {
    return `
<table>
  <thead>
    <tr>
      <th>${t.concept}</th>
      <th class="num">${t.qty}</th>
      <th>${t.unit}</th>
      <th class="num">${t.price}</th>
      <th class="num">${t.discount}</th>
      <th class="num">${t.amount}</th>
    </tr>
  </thead>
  <tbody>
  {% for line in lines %}
    <tr>
      <td>{{ line.name }}{% if line.description %}<div>{{ line.description }}</div>{% endif %}</td>
      <td class="num">{{ line.quantity }}</td>
      <td>{{ line.unit }}</td>
      <td class="num">{{ line.unit_price }}</td>
      <td class="num">{{ line.discount_pct }}</td>
      <td class="num">{{ line.line_total }}</td>
    </tr>
  {% endfor %}
  </tbody>
</table>
<table class="totals">
  <tr><td>${t.subtotal}</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>${t.vat} {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>${t.total}</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
`
  }
  return `
<table>
  <thead>
    <tr>
      <th>${t.concept}</th>
      <th class="num">${t.qty}</th>
      <th>${t.unit}</th>
    </tr>
  </thead>
  <tbody>
  {% for line in lines %}
    <tr>
      <td>{{ line.name }}{% if line.description %}<div>{{ line.description }}</div>{% endif %}</td>
      <td class="num">{{ line.quantity }}</td>
      <td>{{ line.unit }}</td>
    </tr>
  {% endfor %}
  </tbody>
</table>
`
}

export function buildPlatformQuoteHtml(
  locale: CommercialTemplateLocale,
  archetype: CommercialQuoteArchetype,
): string {
  const t = COPY[locale]
  const extra = QUOTE_EXTRA[archetype][locale]
  const extraBlock = extra
    ? `<p class="note">${extra}</p>`
    : ''
  return (
    SHELL_START +
    partiesAndMeta(locale, 'quote') +
    linesTable(locale, true) +
    `<h2>${t.conditions}</h2><p class="note">${t.conditionsBody}</p>` +
    extraBlock +
    `<h2>${t.accept}</h2><p class="note">${t.acceptHint}</p>
<div class="sigs">
  <div>
    <div>${t.acceptLabel}</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>${t.rejectLabel}</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>${t.privacy}</h2>
<p class="note">${t.privacyBody}</p>
<div class="foot">${t.generated} {{ tenant.name }}.</div>` +
    SHELL_END
  )
}

export function buildPlatformDeliveryNoteHtml(locale: CommercialTemplateLocale): string {
  const t = COPY[locale]
  return (
    SHELL_START +
    partiesAndMeta(locale, 'delivery') +
    `{% if document.show_prices %}` +
    linesTable(locale, true) +
    `{% else %}` +
    linesTable(locale, false) +
    `{% endif %}` +
    `<h2>${t.deliveryConformity}</h2>
<p class="note">${t.deliveryConformityHint}</p>
<signature-field name="Conformitat" role="client_delivery" style="width:220px;height:70px;display:inline-block;"></signature-field>
<div class="foot">${t.notInvoice}<br/>${t.generated} {{ tenant.name }}.</div>` +
    SHELL_END
  )
}

/** Nested sample_values matching buildCommercialTemplateContext (QT-4 preview). */
export const PLATFORM_QUOTE_SAMPLE_VALUES = {
  globals: {
    today: '2026-09-17',
    date: '2026-09-17',
    year: '2026',
    now: '2026-09-17T10:00:00.000Z',
  },
  tenant: {
    name: 'Volt Serveis SL',
    tax_id: 'B00000000',
    address: 'Carrer Indústria 10, Vic',
    phone: '938000000',
    email: 'hola@volt.example',
    logo_url: 'https://cdn.example/logo.png',
  },
  document: {
    doc_type: 'quote',
    doc_number: 'PRE-2026-0008',
    status: 'issued',
    locale: 'ca',
    currency: 'EUR',
    issued_at: '2026-09-17T10:00:00.000Z',
    valid_until: '2026-10-17',
    created_at: '2026-09-17T09:00:00.000Z',
    issued_at_display: '17/09/2026 12:00',
    valid_until_display: '17/10/2026',
    created_at_display: '17/09/2026 11:00',
    is_amendment: false,
    parent_doc_number: null,
    show_prices: true,
    terms_text: '30 dies',
  },
  seller: {
    display_name: 'Volt Serveis SL',
    tax_id: 'B00000000',
    email: 'hola@volt.example',
    phone: '938000000',
    address_line1: 'Carrer Indústria 10',
    address_line2: null,
    city: 'Vic',
    postal_code: '08500',
  },
  buyer: {
    display_name: 'Client Exemple SL',
    tax_id: 'B12345678',
    email: 'facturacio@client-exemple.example',
    phone: '934000000',
    address_line1: 'Carrer Major 1',
    address_line2: null,
    city: 'Vic',
    postal_code: '08500',
  },
  service_address: {
    label: 'Nau 2',
    line1: 'Carrer del Pont 4',
    line2: null,
    city: 'Manlleu',
    postal_code: '08560',
    region: 'Barcelona',
    country: 'ES',
  },
  lines: [
    {
      name: 'Visita tècnica',
      description: 'Diagnosi in situ',
      unit: 'h',
      quantity: 2,
      unit_price: 45,
      discount_pct: 0,
      tax_rate: 21,
      line_total: 90,
      kind: 'service',
    },
    {
      name: 'Recanvi',
      description: 'Peça de catàleg',
      unit: 'u',
      quantity: 1,
      unit_price: 80,
      discount_pct: 10,
      tax_rate: 21,
      line_total: 72,
      kind: 'product',
    },
    {
      name: 'Desplaçament',
      description: null,
      unit: 'km',
      quantity: 15,
      unit_price: 0.4,
      discount_pct: 0,
      tax_rate: 10,
      line_total: 6,
      kind: 'expense',
    },
  ],
  totals: {
    subtotal: 168,
    tax_breakdown: [
      { tax_rate: 21, tax_amount: 34.02 },
      { tax_rate: 10, tax_amount: 0.6 },
    ],
    total: 202.62,
  },
  legal: {
    retention_days: 180,
    jurisdiction_text: '',
  },
} as const

export const PLATFORM_DELIVERY_SAMPLE_VALUES = {
  ...PLATFORM_QUOTE_SAMPLE_VALUES,
  document: {
    ...PLATFORM_QUOTE_SAMPLE_VALUES.document,
    doc_type: 'delivery_note',
    doc_number: 'ALB-2026-0003',
    valid_until: null,
    parent_doc_number: 'PRE-2026-0008',
    show_prices: true,
    terms_text: null,
  },
}

export function quoteSampleValues(locale: CommercialTemplateLocale) {
  return {
    ...PLATFORM_QUOTE_SAMPLE_VALUES,
    document: { ...PLATFORM_QUOTE_SAMPLE_VALUES.document, locale },
  }
}

export function deliverySampleValues(locale: CommercialTemplateLocale) {
  return {
    ...PLATFORM_DELIVERY_SAMPLE_VALUES,
    document: { ...PLATFORM_DELIVERY_SAMPLE_VALUES.document, locale },
  }
}

export const QUOTE_REQUIRED_HTML_TOKENS = [
  '{% for line in lines %}',
  'totals.total',
  'document.doc_number',
  'document.valid_until',
  'totals.tax_breakdown',
  'role="client_accept"',
  'role="client_reject"',
] as const

export const DELIVERY_REQUIRED_HTML_TOKENS = [
  '{% for line in lines %}',
  'document.doc_number',
  'role="client_delivery"',
] as const

export type PlatformQuoteTemplateDef = {
  id: string
  localeCaId: string
  localeEsId: string
  archetype: CommercialQuoteArchetype
  name: string
  description: string
  targetArchetypes: string[] | null
}

export const PLATFORM_QUOTE_TEMPLATES: PlatformQuoteTemplateDef[] = [
  {
    id: '76000000-0000-0000-0000-000000000001',
    localeCaId: '78000000-0000-0000-0000-000000000001',
    localeEsId: '79000000-0000-0000-0000-000000000001',
    archetype: 'generic',
    name: 'Pressupost genèric',
    description:
      'Plantilla de pressupost de cos complet (punt de partida; no és assessorament jurídic).',
    targetArchetypes: null,
  },
  {
    id: '76000000-0000-0000-0000-000000000002',
    localeCaId: '78000000-0000-0000-0000-000000000002',
    localeEsId: '79000000-0000-0000-0000-000000000002',
    archetype: 'field_service',
    name: 'Pressupost servei de camp',
    description:
      'Pressupost per a serveis a domicili o en ruta, amb clàusula de desplaçaments/urgències com a línia pròpia.',
    targetArchetypes: ['field_service'],
  },
  {
    id: '76000000-0000-0000-0000-000000000003',
    localeCaId: '78000000-0000-0000-0000-000000000003',
    localeEsId: '79000000-0000-0000-0000-000000000003',
    archetype: 'workshop_maker',
    name: 'Pressupost taller / maker',
    description:
      'Pressupost per a taller o maker, amb avís informatiu de validesa mínima (RD 1457/1986) quan aplica.',
    targetArchetypes: ['workshop_maker'],
  },
  {
    id: '76000000-0000-0000-0000-000000000004',
    localeCaId: '78000000-0000-0000-0000-000000000004',
    localeEsId: '79000000-0000-0000-0000-000000000004',
    archetype: 'practice',
    name: 'Pressupost consulta / pràctica',
    description:
      'Pressupost per a consulta o pràctica, amb avís de resguard independent si hi ha dipòsit de béns.',
    targetArchetypes: ['practice'],
  },
  {
    id: '76000000-0000-0000-0000-000000000005',
    localeCaId: '78000000-0000-0000-0000-000000000005',
    localeEsId: '79000000-0000-0000-0000-000000000005',
    archetype: 'hospitality',
    name: 'Pressupost hostaleria',
    description: 'Pressupost per a hostaleria (mateixa base genèrica; clàusules sectorials pendents).',
    targetArchetypes: ['hospitality'],
  },
]

export const PLATFORM_DELIVERY_TEMPLATE = {
  id: '77000000-0000-0000-0000-000000000001',
  localeCaId: '78000000-0000-0000-0000-000000000006',
  localeEsId: '79000000-0000-0000-0000-000000000006',
  name: 'Albarà genèric',
  description:
    'Albarà de cos complet (no és factura fiscal). Punt de partida; no és assessorament jurídic.',
  targetArchetypes: null as string[] | null,
}

function sqlText(value: string): string {
  return `'${value.split("'").join("''")}'`
}

function sqlTextArray(values: string[] | null): string {
  if (!values) return 'NULL'
  return `ARRAY[${values.map(sqlText).join(', ')}]::text[]`
}

function signingRolesSchema(kind: 'quote' | 'delivery', locale: CommercialTemplateLocale): string {
  if (kind === 'delivery') {
    const label = locale === 'ca' ? 'Conformitat' : 'Conformidad'
    return JSON.stringify({
      client_delivery: {
        entity_type: 'contact',
        label,
        order: 0,
        for_signing: true,
      },
    })
  }
  return JSON.stringify({
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
  })
}

function localeInsert(
  id: string,
  templateId: string,
  locale: CommercialTemplateLocale,
  html: string,
  sampleValues: unknown,
  kind: 'quote' | 'delivery',
): string {
  return `(
  ${sqlText(id)}, ${sqlText(templateId)}, ${sqlText(locale)}, 'text/html', NULL,
  $qt3html$${html}$qt3html$,
  '{}'::jsonb,
  $qt3json$${signingRolesSchema(kind, locale)}$qt3json$::jsonb,
  $qt3json$${JSON.stringify(sampleValues)}$qt3json$::jsonb,
  true
)`
}

/** SQL seed body (QT-3). Regenerar amb scripts/generate-qt3-html-seed.mjs */
export function buildQt3SeedSql(): string {
  const templateRows = [
    ...PLATFORM_QUOTE_TEMPLATES.map(
      (t) =>
        `(${sqlText(t.id)}, NULL, ${sqlText(t.name)}, ${sqlText(t.description)}, 'quote', 'html', true, true, NULL, ${sqlTextArray(t.targetArchetypes)})`,
    ),
    `(${sqlText(PLATFORM_DELIVERY_TEMPLATE.id)}, NULL, ${sqlText(PLATFORM_DELIVERY_TEMPLATE.name)}, ${sqlText(PLATFORM_DELIVERY_TEMPLATE.description)}, 'delivery_note', 'html', true, true, NULL, ${sqlTextArray(PLATFORM_DELIVERY_TEMPLATE.targetArchetypes)})`,
  ]

  const localeRows: string[] = []
  for (const t of PLATFORM_QUOTE_TEMPLATES) {
    localeRows.push(
      localeInsert(t.localeCaId, t.id, 'ca', buildPlatformQuoteHtml('ca', t.archetype), quoteSampleValues('ca'), 'quote'),
    )
    localeRows.push(
      localeInsert(t.localeEsId, t.id, 'es', buildPlatformQuoteHtml('es', t.archetype), quoteSampleValues('es'), 'quote'),
    )
  }
  localeRows.push(
    localeInsert(
      PLATFORM_DELIVERY_TEMPLATE.localeCaId,
      PLATFORM_DELIVERY_TEMPLATE.id,
      'ca',
      buildPlatformDeliveryNoteHtml('ca'),
      deliverySampleValues('ca'),
      'delivery',
    ),
  )
  localeRows.push(
    localeInsert(
      PLATFORM_DELIVERY_TEMPLATE.localeEsId,
      PLATFORM_DELIVERY_TEMPLATE.id,
      'es',
      buildPlatformDeliveryNoteHtml('es'),
      deliverySampleValues('es'),
      'delivery',
    ),
  )

  return `-- QT-3: plantilles HTML de plataforma (cos complet quote/delivery_note).
-- Prefixos: 76 quote, 77 delivery_note, 78 locales ca, 79 locales es.
-- tenant_id=NULL, is_platform_default=true. ON CONFLICT DO NOTHING.
-- El text legal és un punt de partida per clonar, no assessorament jurídic.
-- Regenerar: node scripts/generate-qt3-html-seed.mjs

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by, target_archetypes)
VALUES
${templateRows.join(',\n')}
ON CONFLICT DO NOTHING;

INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
${localeRows.join(',\n')}
ON CONFLICT DO NOTHING;
`
}
