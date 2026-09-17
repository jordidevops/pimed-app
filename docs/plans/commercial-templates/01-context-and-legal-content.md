# 01 — Contracte de variables i contingut legal

> **Pla:** [`README.md`](./README.md) · **Llegir primer:** [`00-agent-instructions-and-guardrails.md`](./00-agent-instructions-and-guardrails.md)
> **Estat QT-0:** **congelat 2026-09-17.** El contracte de §1 i la llista de tokens de §2.1 no es reobren sense documentar-ho a [`README.md`](./README.md) § Decisions tancades. QT-1 implementa `validate_commercial_template_locale` **tal com està escrit aquí**, sense afegir tokens.
> **Avís:** el contingut de clàusules d'aquest document **no és assessorament jurídic**. Ha de revisar-se per comunitat autònoma i sector abans d'activar-se en producció, tal com ja adverteix [`commercial-flow/01-legal-requirements.md`](../commercial-flow/01-legal-requirements.md).
> **Signatura:** els blocs d'acceptació/refús i de conformitat ja no són text pla — usen la sintaxi real de camps de signatura del motor DMS existent (`<signature-field>` / `{{...;type=signature;role=...}}`). Veure [`07-signing-integration.md`](./07-signing-integration.md) per al disseny complet.

## 1. Contracte de variables (context unificat)

Un únic objecte de context alimenta els tres motors (LiquidJS per HTML, Docxtemplater per DOCX, i el preview del frontend), seguint el mateix patró jeràrquic que `supabase/functions/_shared/context-builder.ts` ja usa per a la resta de plantilles del DMS.

Valors: **string / number / boolean / null**. Dates ISO-8601 (`timestamptz` tal com surten de Postgres). Imports numèrics tal com estan congelats a `commercial_documents` (`numeric`), sense reformatejar moneda al builder (la plantilla mostra el número; el locale del document ja és `document.locale`).

Addendum 2026-09-17: el context **conserva** `issued_at` / `valid_until` / `created_at` en ISO. Afegeix camps de presentació `issued_at_display`, `valid_until_display`, `created_at_display` (patró `default_date_format` / `default_time_format` del tenant; zona `Europe/Madrid` per `ca`/`es`, `Europe/London` per `en`). Les plantilles seed i els clons usen `*_display`. **No** formen part dels tokens obligatoris de §2.1.

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
  issued_at_display,   -- presentació; no substitueix ISO
  valid_until_display,
  created_at_display,
  is_amendment,        -- boolean derivat: doc_type === 'quote_amendment'
  parent_doc_number,   -- doc_number del parent, o null
  show_prices,
  terms_text
}

seller: { display_name, tax_id, email, phone, address_line1, address_line2, city, postal_code }

buyer:  { display_name, tax_id, email, phone, address_line1, address_line2, city, postal_code }

service_address: { label, line1, line2, city, postal_code, region, country }

lines: [
  { name, description, unit, quantity, unit_price, discount_pct, tax_rate, line_total, kind }
]

totals: {
  subtotal,
  tax_breakdown: [ { tax_rate, tax_amount } ],
  total
}

legal: { retention_days, jurisdiction_text }
```

Tots els imports i línies venen de camps ja calculats i congelats a `commercial_documents` / `commercial_document_lines` en el moment d'emetre el document (mai es recalculen a la plantilla). Una plantilla de tenant **mostra** aquests valors; no els pot alterar ni recalcular.

`kind` a cada línia és opcional per a l'autor (permet agrupar mà d'obra / peces / despeses). **No** forma part de la validació legal de §2.1.

`tax_breakdown[].tax_base` **no existeix** al snapshot (`jsonb_build_object('tax_rate', …, 'tax_amount', …)` a `20261160000001`). No s'exposa; no es deriva.

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

> **Nota per a l'agent implementador (QT-2/QT-6):** verificar amb una prova mínima si Docxtemplater (configuració actual a `docx-renderer.ts`, sense parser d'expressions explícit) resol camins amb punt (`[[document.doc_number]]`) dins d'un bucle `[[#lines]]`, o si cal exposar també claus planes (`doc_number` arrel, `name`/`quantity`/etc. dins de cada `line`). Si cal aplanar, `buildCommercialTemplateContext()` ha d'exposar **totes dues formes** sense duplicar lògica de càlcul. No assumir-ho sense provar-ho — veure guardrail 7 de `00-agent-instructions-and-guardrails.md`. Això **no** reobre el contracte de noms; només l'adaptació d'exposició.

### 1.3 Mapeig des de dades reals (verificat 2026-09-17)

`buildCommercialTemplateContext` (QT-2) construeix **només** aquest objecte. Fonts admeses:

| Camí de plantilla | Font | Notes |
|-------------------|------|--------|
| `globals.*` | Igual que `context-builder.ts`: `today`/`date` = `YYYY-MM-DD`, `year` string, `now` ISO | Generat a render, no desat al document |
| `tenant.name` | `tenants.name` (ja el carrega `loadTenantName`) | |
| `tenant.logo_url` | `loadLogoUrl` ja existent (snapshot o `email_configs.logo_url`) | |
| `tenant.address`, `tenant.phone`, `tenant.email` | Mateix `SELECT` de `tenants` que ja fa `context-builder.ts` (`address, phone, email, website`) | Ampliar `loadTenantName` a aquestes columnes. Si una columna no hi és en runtime, `null` |
| `tenant.tax_id` | `seller_snapshot.tax_id` si existeix; si no, `null` | `data.tenants` **no** té columna `tax_id`. QT-1/QT-2 **no** n'afegeixen |
| `document.doc_type` … `terms_text` | Columnes de `commercial_documents` | Ja les llegeix `render-commercial-document` |
| `document.issued_at_display` / `valid_until_display` / `created_at_display` | Derivats de les columnes ISO + `default_date_format`/`default_time_format` | Addendum 2026-09-17. `valid_until` només data; els altres data+hora. ISO es queda |
| `document.is_amendment` | `doc_type === 'quote_amendment'` | Booleà derivat, no un extra de BD |
| `document.parent_doc_number` | `commercial_documents.doc_number` del `parent_document_id` (mateix `tenant_id`) | **Una** consulta extra permesa a QT-2; si no hi ha parent, `null` |
| `seller.display_name` | Mateixa regla que `partyDisplayName`: `display_name` \|\| `legal_name` \|\| `name` | El snapshot d'emissor avui és `{ tenant_id, name, slug, settings }` |
| `seller.tax_id`, `email`, `phone` | Camps homònims del snapshot si hi són | Avui solen ser absents a l'emissor |
| `seller.address_line1` … `postal_code` | Camps homònims del snapshot si hi són | Avui absents; `null`. No parsejar `tenant.address` |
| `buyer.display_name` | `partyDisplayName(buyer_snapshot)` | Snapshot avui: `id, kind, display_name, legal_name, tax_id, email, phone, is_consumer, preferred_locale` |
| `buyer.tax_id`, `email`, `phone` | Snapshot | |
| `buyer.address_*` / `city` / `postal_code` | Snapshot si hi són; si no, `null` | Avui el comprador **no** porta adreça; l'adreça de servei és `service_address` |
| `service_address.label` | `name` del snapshot de site | Snapshot real: `id, name, address, street, street_number, city, province, postal_code, country_code` |
| `service_address.line1` | `street` + `street_number`, o `address` si street és buit | |
| `service_address.line2` | `null` (no hi ha equivalent) | |
| `service_address.city` | `city` | |
| `service_address.postal_code` | `postal_code` | |
| `service_address.region` | `province` | |
| `service_address.country` | `country_code` | |
| `lines[]` | `commercial_document_lines` ja carregades | `kind` = `catalog_item_kind` de la línia |
| `totals.subtotal` / `total` | Columnes del document | |
| `totals.tax_breakdown[]` | `tax_breakdown` jsonb `{ tax_rate, tax_amount }` | Sense `tax_base` |
| `legal.retention_days` | Constant `180` | Sis mesos, text de [`commercial-flow/01-legal-requirements.md`](../commercial-flow/01-legal-requirements.md). No és una columna |
| `legal.jurisdiction_text` | Constant buida `""` | El text viu a la plantilla (clàusula §3), no al context |

**Prohibit a QT-2:** noves consultes més enllà de (a) el que `render-commercial-document` ja fa, (b) ampliar el `SELECT` de `tenants` com `context-builder`, (c) l'únic lookup de `parent_doc_number`. No s'enriqueix `seller_snapshot` / `buyer_snapshot` en aquest pla (això seria `commercial-flow`).

Camps de snapshot no exposats al contracte (`slug`, `settings`, `is_consumer`, `preferred_locale`, `id` de comprador, `line_subtotal`, `line_tax`, …) **no** s'afegeixen. Si calen més endavant, es documenta com a reobertura.

## 2. Contingut mínim legal (obligatori a tota plantilla `quote`/`delivery_note`)

Extret de [`commercial-flow/01-legal-requirements.md`](../commercial-flow/01-legal-requirements.md). Una plantilla de pressupost ha d'incloure:

| Bloc | Camps del context |
|------|--------------------|
| Identificació | `seller.*`, `buyer.*` |
| Descripció del servei | bucle `lines` |
| Desglossament (mà d'obra/peces/despeses per separat) | `lines[].name`/`description`/`kind`, agrupació per l'autor de la plantilla |
| Import amb impostos | `totals.subtotal`, `totals.tax_breakdown`, `totals.total` |
| Terminis | `document.issued_at` i text lliure de l'autor |
| Validesa | `document.valid_until` |
| Data i signatura del responsable | text lliure + camp de signatura (`role` de l'emissor/operari) — veure [`07-signing-integration.md`](./07-signing-integration.md) |
| Resposta (acceptar/refusar) amb **espais de mida igual** | dos camps de signatura natius (`role="client_accept"` / `role="client_reject"`), mateixa mida per disseny — veure [`07-signing-integration.md`](./07-signing-integration.md) |

La funció de validació (`data.validate_commercial_template_locale`, veure [`02-rendering-architecture.md`](./02-rendering-architecture.md) §2 punt 4) comprova **només la presència** dels marcadors de §2.1. No valida disseny visual (mida idèntica), exactitud del text legal, ni que els valors de context estiguin omplerts. Això és responsabilitat humana (QT-D7: activar amb buits exigeix `p_acknowledge_legal_gaps`).

### 2.1 Tokens obligatoris (`validate_commercial_template_locale`) — congelat

La funció cerca **subcadenes** a `p_content` (sense parsejar Liquid/DOCX). Un requisit es compleix si **qualsevol** alternativa de la fila apareix. Comparació **sensible a majúscules** (els tokens del contracte són minúscules). Retorna `text[]` amb els **id** dels requisits absents, en aquest ordre, sense duplicats. Array buit = vàlid.

`p_mime_type`:

- HTML: `text/html` → alternatives HTML
- DOCX: `application/vnd.openxmlformats-officedocument.wordprocessingml.document` → alternatives DOCX
- qualsevol altre / `NULL`: retornar `{}` (no aplica; no és plantilla de cos complet d'aquest pla)

`p_doc_type`:

- `quote` i `quote_amendment` → mateix set (la categoria de plantilla és `quote`)
- `delivery_note` → set d'albarà
- altre valor: `RAISE EXCEPTION 'invalid_doc_type'`

#### Pressupost / ampliació (`quote`, `quote_amendment`)

| id (valor retornat si manca) | HTML (qualsevol) | DOCX (qualsevol) |
|------------------------------|------------------|------------------|
| `lines_loop` | `{% for line in lines %}` | `[[#lines]]` |
| `totals.total` | `totals.total` | `totals.total` |
| `document.doc_number` | `document.doc_number` | `document.doc_number` |
| `document.valid_until` | `document.valid_until` | `document.valid_until` |
| `tax_breakdown` | `totals.tax_breakdown` | `totals.tax_breakdown` |
| `client_accept` | `role="client_accept"` o `role='client_accept'` | `role=client_accept` |
| `client_reject` | `role="client_reject"` o `role='client_reject'` | `role=client_reject` |

#### Albarà (`delivery_note`)

No s'exigeix `valid_until` (a BD és `NULL` als albarans), ni acceptar/refusar, ni totals (els preus poden amagar-se amb `document.show_prices`).

| id | HTML (qualsevol) | DOCX (qualsevol) |
|----|------------------|------------------|
| `lines_loop` | `{% for line in lines %}` | `[[#lines]]` |
| `document.doc_number` | `document.doc_number` | `document.doc_number` |
| `client_delivery` | `role="client_delivery"` o `role='client_delivery'` | `role=client_delivery` |

`role=issuer` **no** és obligatori.

`p_content` és el text que ja té `upsert_document_template_locale` (`html_content` per HTML). La funció **no** llegeix Storage. En fase 2 (QT-6), qui activi un DOCX ha de passar a `p_content` un cos cercable (p.ex. `document.xml`); QT-1 no afegeix infra per descarregar el bucket.

### 2.2 Què la validació no fa (no ampliar a QT-1)

- No comprova mida CSS dels `<signature-field>`.
- No comprova que `seller`/`buyer` apareguin (el contingut legal de la taula §2 és guia d'autor; els tokens de §2.1 són el contracte executable).
- No parseja AST Liquid. Si algú escriu `{% for item in lines %}`, `lines_loop` falla — és intencionat (cerca simple; veure senyal d'alarma 4 de `00`).
- No bloqueja desar amb `is_active=false`.

## 3. Plantilla "Pressupost genèric" (ca) — contingut de referència

Estructura recomanada, de dalt a baix. El text de clàusules **no** forma part del contracte congelat de tokens; QT-3 el pot moure de redacció amb revisió humana, sense tocar §1 ni §2.1.

1. **Capçalera**: `tenant.logo_url`, `tenant.name`, "Pressupost núm. {{ document.doc_number }}", data d'emissió, validesa (`document.valid_until`).
2. **Bloc emissor / bloc client**: `seller.*` a l'esquerra, `buyer.*` a la dreta.
3. **Adreça del servei** (`service_address.*`), només si difereix de la del client.
4. **Taula de línies**: concepte, quantitat, preu, descompte, import — bucle `lines`.
5. **Desglossament d'IVA i total** (`totals.*`).
6. **Condicions generals** (text fix, editable pel tenant):
   > "Aquest pressupost té una validesa de 30 dies des de la data d'emissió, llevat que s'indiqui altrament. Els preus inclouen l'IVA aplicable. Qualsevol concepte no inclòs en aquest pressupost que aparegui durant l'execució del servei serà objecte d'una ampliació de pressupost, que haurà de ser acceptada abans de la seva execució i cobrament, d'acord amb la normativa de protecció de les persones consumidores. Per a qualsevol controvèrsia, les parts se sotmeten als jutjats i tribunals que correspongui per llei."
7. **Bloc d'acceptació/refús** (camps de signatura natius, mateixa mida — veure [`07-signing-integration.md`](./07-signing-integration.md)):
   ```html
   <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
   <signature-field name="Refuso"  role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
   ```
   Equivalent DOCX (Docxtemplater/DocuSeal tags): `{{Accepto;type=signature;role=client_accept}}` / `{{Refuso;type=signature;role=client_reject}}`.
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
4. Espai de conformitat de lliurament (no és acceptar/refusar; és un reconeixement de servei rebut), camp de signatura natiu:
   ```html
   <signature-field name="Conformitat" role="client_delivery" style="width:220px;height:70px;display:inline-block;"></signature-field>
   ```
   Equivalent DOCX: `{{Conformitat;type=signature;role=client_delivery}}`. Veure [`07-signing-integration.md`](./07-signing-integration.md) per al flux complet de firma.
5. Peu: "Aquest document no és una factura fiscal."

## 5. Traducció es

Totes dues plantilles (pressupost i albarà) es sembren també en castellà amb la mateixa estructura i camps, traduint únicament el text fix (etiquetes, condicions, avisos). Els noms de camps del context (`document.doc_number`, etc.) i els `role` de signatura **no** es tradueixen.
