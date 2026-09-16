# 01 — Contracte de variables i contingut legal

> **Pla:** [`README.md`](./README.md) · **Llegir primer:** [`00-agent-instructions-and-guardrails.md`](./00-agent-instructions-and-guardrails.md)
> **Avís:** el contingut de clàusules d'aquest document **no és assessorament jurídic**. Ha de revisar-se per comunitat autònoma i sector abans d'activar-se en producció, tal com ja adverteix [`commercial-flow/01-legal-requirements.md`](../commercial-flow/01-legal-requirements.md).

## 1. Contracte de variables (context unificat)

Un únic objecte de context alimenta els tres motors (LiquidJS per HTML, Docxtemplater per DOCX, i el preview del frontend), seguint el mateix patró jeràrquic que `supabase/functions/_shared/context-builder.ts` ja usa per a la resta de plantilles del DMS.

```
globals: { today, date, year, now }

tenant:  { name, tax_id, address, phone, email, logo_url }

document: {
  doc_type,            -- 'quote' | 'quote_amendment' | 'delivery_note'
  doc_number,
  status,
  locale,
  currency,
  issued_at,
  valid_until,
  created_at,
  is_amendment,
  parent_doc_number,
  show_prices,
  terms_text
}

seller: { display_name, tax_id, email, phone, address_line1, address_line2, city, postal_code }

buyer:  { display_name, tax_id, email, phone, address_line1, address_line2, city, postal_code }

service_address: { label, line1, line2, city, postal_code, region, country }

lines: [
  { name, description, unit, quantity, unit_price, discount_pct, tax_rate, line_total }
]

totals: {
  subtotal,
  tax_breakdown: [ { tax_rate, tax_base, tax_amount } ],
  total
}

legal: { retention_days, jurisdiction_text }
```

Tots els valors venen de camps ja calculats i congelats a `commercial_documents`/`commercial_document_lines` en el moment d'emetre el document (mai es recalculen a la plantilla). Una plantilla de tenant **mostra** aquests valors; no els pot alterar ni recalcular.

### 1.1 Sintaxi HTML (LiquidJS)

```
Pressupost núm. {{ document.doc_number }} — {{ document.issued_at }}

{% for line in lines %}
  {{ line.name }} — {{ line.quantity }} {{ line.unit }} x {{ line.unit_price }} = {{ line.line_total }}
{% endfor %}

Subtotal: {{ totals.subtotal }}
{% for tax in totals.tax_breakdown %}
  IVA {{ tax.tax_rate }}%: {{ tax.tax_amount }}
{% endfor %}
Total: {{ totals.total }}

{% if document.show_prices %} ... {% endif %}
```

### 1.2 Sintaxi DOCX (Docxtemplater)

```
[[document.doc_number]]

[[#lines]]
  [[name]] — [[quantity]] [[unit]] x [[unit_price]] = [[line_total]]
[[/lines]]

Subtotal: [[totals.subtotal]]
[[#totals.tax_breakdown]]
  IVA [[tax_rate]]%: [[tax_amount]]
[[/totals.tax_breakdown]]
Total: [[totals.total]]
```

> **Nota per a l'agent implementador (QT-2/QT-6):** verificar amb una prova mínima si Docxtemplater (configuració actual a `docx-renderer.ts`, sense parser d'expressions explícit) resol camins amb punt (`[[document.doc_number]]`) dins d'un bucle `[[#lines]]`, o si cal exposar també claus planes (`doc_number` arrel, `name`/`quantity`/etc. dins de cada `line`). Si cal aplanar, `buildCommercialTemplateContext()` ha d'exposar **totes dues formes** sense duplicar lògica de càlcul. No assumir-ho sense provar-ho — veure guardrail 7 de `00-agent-instructions-and-guardrails.md`.

## 2. Contingut mínim legal (obligatori a tota plantilla `quote`/`delivery_note`)

Extret de [`commercial-flow/01-legal-requirements.md`](../commercial-flow/01-legal-requirements.md). Una plantilla de pressupost ha d'incloure:

| Bloc | Camps del context |
|------|--------------------|
| Identificació | `seller.*`, `buyer.*` |
| Descripció del servei | bucle `lines` |
| Desglossament (mà d'obra/peces/despeses per separat) | `lines[].name`/`description`, agrupació per l'autor de la plantilla |
| Import amb impostos | `totals.subtotal`, `totals.tax_breakdown`, `totals.total` |
| Terminis | `document.issued_at` i text lliure de l'autor |
| Validesa | `document.valid_until` |
| Data i signatura del responsable | text lliure + espai de signatura |
| Resposta (acceptar/refusar) amb **espais de mida igual** | dues columnes simètriques, cadascuna amb línia de signatura i data — **responsabilitat visual de qui edita la plantilla**; QT-0 només valida la presència textual dels dos blocs, no la simetria visual |

La funció de validació (`data.validate_commercial_template_locale`, veure [`02-rendering-architecture.md`](./02-rendering-architecture.md)) comprova la **presència** d'aquests marcadors com a mínim: bucle de línies, `totals.total`/`total`, `document.doc_number`/`doc_number`, `document.valid_until`/`valid_until`, un marcador de desglossament d'impostos, i dos marcadors d'acceptació/refús. No pot validar disseny visual ni exactitud del text legal — això és responsabilitat humana.

## 3. Plantilla "Pressupost genèric" (ca) — contingut de referència

Estructura recomanada, de dalt a baix:

1. **Capçalera**: `tenant.logo_url`, `tenant.name`, "Pressupost núm. {{ document.doc_number }}", data d'emissió, validesa (`document.valid_until`).
2. **Bloc emissor / bloc client**: `seller.*` a l'esquerra, `buyer.*` a la dreta.
3. **Adreça del servei** (`service_address.*`), només si difereix de la del client.
4. **Taula de línies**: concepte, quantitat, preu, descompte, import — bucle `lines`.
5. **Desglossament d'IVA i total** (`totals.*`).
6. **Condicions generals** (text fix, editable pel tenant):
   > "Aquest pressupost té una validesa de 30 dies des de la data d'emissió, llevat que s'indiqui altrament. Els preus inclouen l'IVA aplicable. Qualsevol concepte no inclòs en aquest pressupost que aparegui durant l'execució del servei serà objecte d'una ampliació de pressupost, que haurà de ser acceptada abans de la seva execució i cobrament, d'acord amb la normativa de protecció de les persones consumidores. Per a qualsevol controvèrsia, les parts se sotmeten als jutjats i tribunals que correspongui per llei."
7. **Bloc d'acceptació/refús** (espais visuals idèntics):
   > `[ ] Accepto aquest pressupost` — Signatura: __________________ Data: __________
   > `[ ] Refuso aquest pressupost` — Signatura: __________________ Data: __________
8. **Avís de protecció de dades**:
   > "Les dades facilitades es tracten amb la finalitat de gestionar aquest pressupost i, si escau, la relació contractual derivada. Es conserven durant un mínim de sis mesos des de la no-acceptació o des de la fi del servei. Podeu exercir els vostres drets d'accés, rectificació i supressió dirigint-vos a {{ tenant.email }}."
9. **Peu**: "Document generat per {{ tenant.name }}."

### 3.1 Variants per arquetip (paràgraf addicional, no substitueix el genèric)

| Arquetip | Afegit |
|----------|--------|
| `generic` | Cap afegit |
| `field_service` | "Els desplaçaments, urgències o intervencions fora d'horari habitual es facturen com a línia pròpia i identificable en aquest pressupost, mai com a recàrrec improvisat." |
| `workshop_maker` | "Per a reparacions subjectes al Reial Decret 1457/1986, aquest pressupost té una validesa mínima de 12 dies hàbils." *(text informatiu; l'aplicació no imposa aquest mínim numèricament — veure `06-phases-and-backlog.md` § fora d'abast)* |
| `practice` | "Si el servei requereix el dipòsit de béns, se'n lliurarà un resguard acreditatiu independent d'aquest pressupost." |
| `hospitality` | Cap afegit específic (revisar més endavant si el sector ho requereix) |

## 4. Plantilla "Albarà genèric" (ca) — contingut de referència

1. Capçalera: "Albarà núm. {{ document.doc_number }}", referència al pressupost origen (`document.parent_doc_number`) si n'hi ha.
2. Bloc emissor/client (igual que el pressupost).
3. Taula de línies — preus **només si** `document.show_prices` és cert.
4. Espai de conformitat de lliurament (no és acceptar/refusar; és un reconeixement de servei rebut):
   > Signatura de conformitat: __________________ Data: __________
5. Peu: "Aquest document no és una factura fiscal."

## 5. Traducció es

Totes dues plantilles (pressupost i albarà) es sembren també en castellà amb la mateixa estructura i camps, traduint únicament el text fix (etiquetes, condicions, avisos). Els noms de camps del context (`document.doc_number`, etc.) no es tradueixen.
