-- QT-3: plantilles HTML de plataforma (cos complet quote/delivery_note).
-- Prefixos: 76 quote, 77 delivery_note, 78 locales ca, 79 locales es.
-- tenant_id=NULL, is_platform_default=true. ON CONFLICT DO NOTHING.
-- El text legal és un punt de partida per clonar, no assessorament jurídic.
-- Regenerar: node scripts/generate-qt3-html-seed.mjs

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by, target_archetypes)
VALUES
('76000000-0000-0000-0000-000000000001', NULL, 'Pressupost genèric', 'Plantilla de pressupost de cos complet (punt de partida; no és assessorament jurídic).', 'quote', 'html', true, true, NULL, NULL),
('76000000-0000-0000-0000-000000000002', NULL, 'Pressupost servei de camp', 'Pressupost per a serveis a domicili o en ruta, amb clàusula de desplaçaments/urgències com a línia pròpia.', 'quote', 'html', true, true, NULL, ARRAY['field_service']::text[]),
('76000000-0000-0000-0000-000000000003', NULL, 'Pressupost taller / maker', 'Pressupost per a taller o maker, amb avís informatiu de validesa mínima (RD 1457/1986) quan aplica.', 'quote', 'html', true, true, NULL, ARRAY['workshop_maker']::text[]),
('76000000-0000-0000-0000-000000000004', NULL, 'Pressupost consulta / pràctica', 'Pressupost per a consulta o pràctica, amb avís de resguard independent si hi ha dipòsit de béns.', 'quote', 'html', true, true, NULL, ARRAY['practice']::text[]),
('76000000-0000-0000-0000-000000000005', NULL, 'Pressupost hostaleria', 'Pressupost per a hostaleria (mateixa base genèrica; clàusules sectorials pendents).', 'quote', 'html', true, true, NULL, ARRAY['hospitality']::text[]),
('77000000-0000-0000-0000-000000000001', NULL, 'Albarà genèric', 'Albarà de cos complet (no és factura fiscal). Punt de partida; no és assessorament jurídic.', 'delivery_note', 'html', true, true, NULL, NULL)
ON CONFLICT DO NOTHING;

INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
(
  '78000000-0000-0000-0000-000000000001', '76000000-0000-0000-0000-000000000001', 'ca', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Pressupost núm. {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Data d’emissió: {{ document.issued_at }}</div>
    <div>Validesa fins: {{ document.valid_until }}</div>
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emissor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Client</strong>
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
  <strong>Adreça del servei</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}

<table>
  <thead>
    <tr>
      <th>Concepte</th>
      <th class="num">Qtd</th>
      <th>Unitat</th>
      <th class="num">Preu</th>
      <th class="num">Dte. %</th>
      <th class="num">Import</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
<h2>Condicions generals</h2><p class="note">Aquest pressupost té una validesa de 30 dies des de la data d'emissió, llevat que s'indiqui altrament. Els preus inclouen l'IVA aplicable. Qualsevol concepte no inclòs en aquest pressupost que aparegui durant l'execució del servei serà objecte d'una ampliació de pressupost, que haurà de ser acceptada abans de la seva execució i cobrament, d'acord amb la normativa de protecció de les persones consumidores. Per a qualsevol controvèrsia, les parts se sotmeten als jutjats i tribunals que correspongui per llei.</p><h2>Acceptació</h2><p class="note">Cal signar una de les dues caselles (mateixa mida).</p>
<div class="sigs">
  <div>
    <div>Accepto</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>Refuso</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>Protecció de dades</h2>
<p class="note">Les dades facilitades es tracten amb la finalitat de gestionar aquest pressupost i, si escau, la relació contractual derivada. Es conserven durant un mínim de sis mesos des de la no-acceptació o des de la fi del servei. Podeu exercir els vostres drets d'accés, rectificació i supressió dirigint-vos a {{ tenant.email }}.</p>
<div class="foot">Document generat per {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_accept":{"entity_type":"contact","label":"Accepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Refuso","order":1,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '79000000-0000-0000-0000-000000000001', '76000000-0000-0000-0000-000000000001', 'es', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Presupuesto n.º {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Fecha de emisión: {{ document.issued_at }}</div>
    <div>Validez hasta: {{ document.valid_until }}</div>
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emisor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Cliente</strong>
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
  <strong>Dirección del servicio</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}

<table>
  <thead>
    <tr>
      <th>Concepto</th>
      <th class="num">Cant.</th>
      <th>Unidad</th>
      <th class="num">Precio</th>
      <th class="num">Dto. %</th>
      <th class="num">Importe</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
<h2>Condiciones generales</h2><p class="note">Este presupuesto tiene una validez de 30 días desde la fecha de emisión, salvo indicación en contrario. Los precios incluyen el IVA aplicable. Cualquier concepto no incluido en este presupuesto que aparezca durante la ejecución del servicio será objeto de una ampliación de presupuesto, que deberá ser aceptada antes de su ejecución y cobro, de acuerdo con la normativa de protección de las personas consumidoras. Para cualquier controversia, las partes se someten a los juzgados y tribunales que correspondan por ley.</p><h2>Aceptación</h2><p class="note">Hay que firmar una de las dos casillas (mismo tamaño).</p>
<div class="sigs">
  <div>
    <div>Acepto</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>Rechazo</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>Protección de datos</h2>
<p class="note">Los datos facilitados se tratan con la finalidad de gestionar este presupuesto y, en su caso, la relación contractual derivada. Se conservan durante un mínimo de seis meses desde la no aceptación o desde el fin del servicio. Puede ejercer sus derechos de acceso, rectificación y supresión dirigiéndose a {{ tenant.email }}.</p>
<div class="foot">Documento generado por {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_accept":{"entity_type":"contact","label":"Acepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Rechazo","order":1,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '78000000-0000-0000-0000-000000000002', '76000000-0000-0000-0000-000000000002', 'ca', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Pressupost núm. {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Data d’emissió: {{ document.issued_at }}</div>
    <div>Validesa fins: {{ document.valid_until }}</div>
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emissor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Client</strong>
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
  <strong>Adreça del servei</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}

<table>
  <thead>
    <tr>
      <th>Concepte</th>
      <th class="num">Qtd</th>
      <th>Unitat</th>
      <th class="num">Preu</th>
      <th class="num">Dte. %</th>
      <th class="num">Import</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
<h2>Condicions generals</h2><p class="note">Aquest pressupost té una validesa de 30 dies des de la data d'emissió, llevat que s'indiqui altrament. Els preus inclouen l'IVA aplicable. Qualsevol concepte no inclòs en aquest pressupost que aparegui durant l'execució del servei serà objecte d'una ampliació de pressupost, que haurà de ser acceptada abans de la seva execució i cobrament, d'acord amb la normativa de protecció de les persones consumidores. Per a qualsevol controvèrsia, les parts se sotmeten als jutjats i tribunals que correspongui per llei.</p><p class="note">Els desplaçaments, urgències o intervencions fora d'horari habitual es facturen com a línia pròpia i identificable en aquest pressupost, mai com a recàrrec improvisat.</p><h2>Acceptació</h2><p class="note">Cal signar una de les dues caselles (mateixa mida).</p>
<div class="sigs">
  <div>
    <div>Accepto</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>Refuso</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>Protecció de dades</h2>
<p class="note">Les dades facilitades es tracten amb la finalitat de gestionar aquest pressupost i, si escau, la relació contractual derivada. Es conserven durant un mínim de sis mesos des de la no-acceptació o des de la fi del servei. Podeu exercir els vostres drets d'accés, rectificació i supressió dirigint-vos a {{ tenant.email }}.</p>
<div class="foot">Document generat per {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_accept":{"entity_type":"contact","label":"Accepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Refuso","order":1,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '79000000-0000-0000-0000-000000000002', '76000000-0000-0000-0000-000000000002', 'es', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Presupuesto n.º {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Fecha de emisión: {{ document.issued_at }}</div>
    <div>Validez hasta: {{ document.valid_until }}</div>
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emisor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Cliente</strong>
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
  <strong>Dirección del servicio</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}

<table>
  <thead>
    <tr>
      <th>Concepto</th>
      <th class="num">Cant.</th>
      <th>Unidad</th>
      <th class="num">Precio</th>
      <th class="num">Dto. %</th>
      <th class="num">Importe</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
<h2>Condiciones generales</h2><p class="note">Este presupuesto tiene una validez de 30 días desde la fecha de emisión, salvo indicación en contrario. Los precios incluyen el IVA aplicable. Cualquier concepto no incluido en este presupuesto que aparezca durante la ejecución del servicio será objeto de una ampliación de presupuesto, que deberá ser aceptada antes de su ejecución y cobro, de acuerdo con la normativa de protección de las personas consumidoras. Para cualquier controversia, las partes se someten a los juzgados y tribunales que correspondan por ley.</p><p class="note">Los desplazamientos, urgencias o intervenciones fuera de horario habitual se facturan como línea propia e identificable en este presupuesto, nunca como recargo improvisado.</p><h2>Aceptación</h2><p class="note">Hay que firmar una de las dos casillas (mismo tamaño).</p>
<div class="sigs">
  <div>
    <div>Acepto</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>Rechazo</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>Protección de datos</h2>
<p class="note">Los datos facilitados se tratan con la finalidad de gestionar este presupuesto y, en su caso, la relación contractual derivada. Se conservan durante un mínimo de seis meses desde la no aceptación o desde el fin del servicio. Puede ejercer sus derechos de acceso, rectificación y supresión dirigiéndose a {{ tenant.email }}.</p>
<div class="foot">Documento generado por {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_accept":{"entity_type":"contact","label":"Acepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Rechazo","order":1,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '78000000-0000-0000-0000-000000000003', '76000000-0000-0000-0000-000000000003', 'ca', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Pressupost núm. {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Data d’emissió: {{ document.issued_at }}</div>
    <div>Validesa fins: {{ document.valid_until }}</div>
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emissor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Client</strong>
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
  <strong>Adreça del servei</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}

<table>
  <thead>
    <tr>
      <th>Concepte</th>
      <th class="num">Qtd</th>
      <th>Unitat</th>
      <th class="num">Preu</th>
      <th class="num">Dte. %</th>
      <th class="num">Import</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
<h2>Condicions generals</h2><p class="note">Aquest pressupost té una validesa de 30 dies des de la data d'emissió, llevat que s'indiqui altrament. Els preus inclouen l'IVA aplicable. Qualsevol concepte no inclòs en aquest pressupost que aparegui durant l'execució del servei serà objecte d'una ampliació de pressupost, que haurà de ser acceptada abans de la seva execució i cobrament, d'acord amb la normativa de protecció de les persones consumidores. Per a qualsevol controvèrsia, les parts se sotmeten als jutjats i tribunals que correspongui per llei.</p><p class="note">Per a reparacions subjectes al Reial Decret 1457/1986, aquest pressupost té una validesa mínima de 12 dies hàbils.</p><h2>Acceptació</h2><p class="note">Cal signar una de les dues caselles (mateixa mida).</p>
<div class="sigs">
  <div>
    <div>Accepto</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>Refuso</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>Protecció de dades</h2>
<p class="note">Les dades facilitades es tracten amb la finalitat de gestionar aquest pressupost i, si escau, la relació contractual derivada. Es conserven durant un mínim de sis mesos des de la no-acceptació o des de la fi del servei. Podeu exercir els vostres drets d'accés, rectificació i supressió dirigint-vos a {{ tenant.email }}.</p>
<div class="foot">Document generat per {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_accept":{"entity_type":"contact","label":"Accepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Refuso","order":1,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '79000000-0000-0000-0000-000000000003', '76000000-0000-0000-0000-000000000003', 'es', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Presupuesto n.º {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Fecha de emisión: {{ document.issued_at }}</div>
    <div>Validez hasta: {{ document.valid_until }}</div>
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emisor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Cliente</strong>
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
  <strong>Dirección del servicio</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}

<table>
  <thead>
    <tr>
      <th>Concepto</th>
      <th class="num">Cant.</th>
      <th>Unidad</th>
      <th class="num">Precio</th>
      <th class="num">Dto. %</th>
      <th class="num">Importe</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
<h2>Condiciones generales</h2><p class="note">Este presupuesto tiene una validez de 30 días desde la fecha de emisión, salvo indicación en contrario. Los precios incluyen el IVA aplicable. Cualquier concepto no incluido en este presupuesto que aparezca durante la ejecución del servicio será objeto de una ampliación de presupuesto, que deberá ser aceptada antes de su ejecución y cobro, de acuerdo con la normativa de protección de las personas consumidoras. Para cualquier controversia, las partes se someten a los juzgados y tribunales que correspondan por ley.</p><p class="note">Para reparaciones sujetas al Real Decreto 1457/1986, este presupuesto tiene una validez mínima de 12 días hábiles.</p><h2>Aceptación</h2><p class="note">Hay que firmar una de las dos casillas (mismo tamaño).</p>
<div class="sigs">
  <div>
    <div>Acepto</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>Rechazo</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>Protección de datos</h2>
<p class="note">Los datos facilitados se tratan con la finalidad de gestionar este presupuesto y, en su caso, la relación contractual derivada. Se conservan durante un mínimo de seis meses desde la no aceptación o desde el fin del servicio. Puede ejercer sus derechos de acceso, rectificación y supresión dirigiéndose a {{ tenant.email }}.</p>
<div class="foot">Documento generado por {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_accept":{"entity_type":"contact","label":"Acepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Rechazo","order":1,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '78000000-0000-0000-0000-000000000004', '76000000-0000-0000-0000-000000000004', 'ca', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Pressupost núm. {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Data d’emissió: {{ document.issued_at }}</div>
    <div>Validesa fins: {{ document.valid_until }}</div>
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emissor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Client</strong>
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
  <strong>Adreça del servei</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}

<table>
  <thead>
    <tr>
      <th>Concepte</th>
      <th class="num">Qtd</th>
      <th>Unitat</th>
      <th class="num">Preu</th>
      <th class="num">Dte. %</th>
      <th class="num">Import</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
<h2>Condicions generals</h2><p class="note">Aquest pressupost té una validesa de 30 dies des de la data d'emissió, llevat que s'indiqui altrament. Els preus inclouen l'IVA aplicable. Qualsevol concepte no inclòs en aquest pressupost que aparegui durant l'execució del servei serà objecte d'una ampliació de pressupost, que haurà de ser acceptada abans de la seva execució i cobrament, d'acord amb la normativa de protecció de les persones consumidores. Per a qualsevol controvèrsia, les parts se sotmeten als jutjats i tribunals que correspongui per llei.</p><p class="note">Si el servei requereix el dipòsit de béns, se'n lliurarà un resguard acreditatiu independent d'aquest pressupost.</p><h2>Acceptació</h2><p class="note">Cal signar una de les dues caselles (mateixa mida).</p>
<div class="sigs">
  <div>
    <div>Accepto</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>Refuso</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>Protecció de dades</h2>
<p class="note">Les dades facilitades es tracten amb la finalitat de gestionar aquest pressupost i, si escau, la relació contractual derivada. Es conserven durant un mínim de sis mesos des de la no-acceptació o des de la fi del servei. Podeu exercir els vostres drets d'accés, rectificació i supressió dirigint-vos a {{ tenant.email }}.</p>
<div class="foot">Document generat per {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_accept":{"entity_type":"contact","label":"Accepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Refuso","order":1,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '79000000-0000-0000-0000-000000000004', '76000000-0000-0000-0000-000000000004', 'es', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Presupuesto n.º {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Fecha de emisión: {{ document.issued_at }}</div>
    <div>Validez hasta: {{ document.valid_until }}</div>
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emisor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Cliente</strong>
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
  <strong>Dirección del servicio</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}

<table>
  <thead>
    <tr>
      <th>Concepto</th>
      <th class="num">Cant.</th>
      <th>Unidad</th>
      <th class="num">Precio</th>
      <th class="num">Dto. %</th>
      <th class="num">Importe</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
<h2>Condiciones generales</h2><p class="note">Este presupuesto tiene una validez de 30 días desde la fecha de emisión, salvo indicación en contrario. Los precios incluyen el IVA aplicable. Cualquier concepto no incluido en este presupuesto que aparezca durante la ejecución del servicio será objeto de una ampliación de presupuesto, que deberá ser aceptada antes de su ejecución y cobro, de acuerdo con la normativa de protección de las personas consumidoras. Para cualquier controversia, las partes se someten a los juzgados y tribunales que correspondan por ley.</p><p class="note">Si el servicio requiere el depósito de bienes, se entregará un resguardo acreditativo independiente de este presupuesto.</p><h2>Aceptación</h2><p class="note">Hay que firmar una de las dos casillas (mismo tamaño).</p>
<div class="sigs">
  <div>
    <div>Acepto</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>Rechazo</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>Protección de datos</h2>
<p class="note">Los datos facilitados se tratan con la finalidad de gestionar este presupuesto y, en su caso, la relación contractual derivada. Se conservan durante un mínimo de seis meses desde la no aceptación o desde el fin del servicio. Puede ejercer sus derechos de acceso, rectificación y supresión dirigiéndose a {{ tenant.email }}.</p>
<div class="foot">Documento generado por {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_accept":{"entity_type":"contact","label":"Acepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Rechazo","order":1,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '78000000-0000-0000-0000-000000000005', '76000000-0000-0000-0000-000000000005', 'ca', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Pressupost núm. {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Data d’emissió: {{ document.issued_at }}</div>
    <div>Validesa fins: {{ document.valid_until }}</div>
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emissor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Client</strong>
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
  <strong>Adreça del servei</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}

<table>
  <thead>
    <tr>
      <th>Concepte</th>
      <th class="num">Qtd</th>
      <th>Unitat</th>
      <th class="num">Preu</th>
      <th class="num">Dte. %</th>
      <th class="num">Import</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
<h2>Condicions generals</h2><p class="note">Aquest pressupost té una validesa de 30 dies des de la data d'emissió, llevat que s'indiqui altrament. Els preus inclouen l'IVA aplicable. Qualsevol concepte no inclòs en aquest pressupost que aparegui durant l'execució del servei serà objecte d'una ampliació de pressupost, que haurà de ser acceptada abans de la seva execució i cobrament, d'acord amb la normativa de protecció de les persones consumidores. Per a qualsevol controvèrsia, les parts se sotmeten als jutjats i tribunals que correspongui per llei.</p><h2>Acceptació</h2><p class="note">Cal signar una de les dues caselles (mateixa mida).</p>
<div class="sigs">
  <div>
    <div>Accepto</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>Refuso</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>Protecció de dades</h2>
<p class="note">Les dades facilitades es tracten amb la finalitat de gestionar aquest pressupost i, si escau, la relació contractual derivada. Es conserven durant un mínim de sis mesos des de la no-acceptació o des de la fi del servei. Podeu exercir els vostres drets d'accés, rectificació i supressió dirigint-vos a {{ tenant.email }}.</p>
<div class="foot">Document generat per {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_accept":{"entity_type":"contact","label":"Accepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Refuso","order":1,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '79000000-0000-0000-0000-000000000005', '76000000-0000-0000-0000-000000000005', 'es', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Presupuesto n.º {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Fecha de emisión: {{ document.issued_at }}</div>
    <div>Validez hasta: {{ document.valid_until }}</div>
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emisor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Cliente</strong>
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
  <strong>Dirección del servicio</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}

<table>
  <thead>
    <tr>
      <th>Concepto</th>
      <th class="num">Cant.</th>
      <th>Unidad</th>
      <th class="num">Precio</th>
      <th class="num">Dto. %</th>
      <th class="num">Importe</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
<h2>Condiciones generales</h2><p class="note">Este presupuesto tiene una validez de 30 días desde la fecha de emisión, salvo indicación en contrario. Los precios incluyen el IVA aplicable. Cualquier concepto no incluido en este presupuesto que aparezca durante la ejecución del servicio será objeto de una ampliación de presupuesto, que deberá ser aceptada antes de su ejecución y cobro, de acuerdo con la normativa de protección de las personas consumidoras. Para cualquier controversia, las partes se someten a los juzgados y tribunales que correspondan por ley.</p><h2>Aceptación</h2><p class="note">Hay que firmar una de las dos casillas (mismo tamaño).</p>
<div class="sigs">
  <div>
    <div>Acepto</div>
    <signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
  <div>
    <div>Rechazo</div>
    <signature-field name="Refuso" role="client_reject" style="width:220px;height:70px;display:inline-block;"></signature-field>
  </div>
</div>
<h2>Protección de datos</h2>
<p class="note">Los datos facilitados se tratan con la finalidad de gestionar este presupuesto y, en su caso, la relación contractual derivada. Se conservan durante un mínimo de seis meses desde la no aceptación o desde el fin del servicio. Puede ejercer sus derechos de acceso, rectificación y supresión dirigiéndose a {{ tenant.email }}.</p>
<div class="foot">Documento generado por {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_accept":{"entity_type":"contact","label":"Acepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Rechazo","order":1,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '78000000-0000-0000-0000-000000000006', '77000000-0000-0000-0000-000000000001', 'ca', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Albarà núm. {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Data d’emissió: {{ document.issued_at }}</div>
    {% if document.parent_doc_number %}<div>Referència pressupost: {{ document.parent_doc_number }}</div>{% endif %}
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emissor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Client</strong>
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
  <strong>Adreça del servei</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}
{% if document.show_prices %}
<table>
  <thead>
    <tr>
      <th>Concepte</th>
      <th class="num">Qtd</th>
      <th>Unitat</th>
      <th class="num">Preu</th>
      <th class="num">Dte. %</th>
      <th class="num">Import</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
{% else %}
<table>
  <thead>
    <tr>
      <th>Concepte</th>
      <th class="num">Qtd</th>
      <th>Unitat</th>
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
{% endif %}<h2>Conformitat de lliurament</h2>
<p class="note">Reconeixement de servei rebut, no és acceptar ni refusar un pressupost.</p>
<signature-field name="Conformitat" role="client_delivery" style="width:220px;height:70px;display:inline-block;"></signature-field>
<div class="foot">Aquest document no és una factura fiscal.<br/>Document generat per {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_delivery":{"entity_type":"contact","label":"Conformitat","order":0,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"delivery_note","doc_number":"ALB-2026-0003","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":null,"created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":"PRE-2026-0008","show_prices":true,"terms_text":null},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
),
(
  '79000000-0000-0000-0000-000000000006', '77000000-0000-0000-0000-000000000001', 'es', 'text/html', NULL,
  $qt3html$<!DOCTYPE html>
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

<div class="hdr">
  <div>
    {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="{{ tenant.name }}"/>{% endif %}
    <h1>Albarán n.º {{ document.doc_number }}</h1>
    <div>{{ tenant.name }}{% if tenant.tax_id %} · {{ tenant.tax_id }}{% endif %}</div>
  </div>
  <div class="meta">
    <div>Fecha de emisión: {{ document.issued_at }}</div>
    {% if document.parent_doc_number %}<div>Referencia presupuesto: {{ document.parent_doc_number }}</div>{% endif %}
  </div>
</div>
<div class="parties">
  <div>
    <strong>Emisor</strong>
    <div>{{ seller.display_name }}</div>
    {% if seller.tax_id %}<div>{{ seller.tax_id }}</div>{% endif %}
    {% if seller.email %}<div>{{ seller.email }}</div>{% endif %}
    {% if seller.phone %}<div>{{ seller.phone }}</div>{% endif %}
    {% if seller.address_line1 %}<div>{{ seller.address_line1 }} {{ seller.address_line2 }}</div>{% endif %}
    {% if seller.city %}<div>{{ seller.postal_code }} {{ seller.city }}</div>{% endif %}
  </div>
  <div>
    <strong>Cliente</strong>
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
  <strong>Dirección del servicio</strong>
  <div>{% if service_address.label %}{{ service_address.label }} · {% endif %}{{ service_address.line1 }} {% if service_address.line2 %}{{ service_address.line2 }}{% endif %}</div>
  <div>{{ service_address.postal_code }} {{ service_address.city }}{% if service_address.region %} ({{ service_address.region }}){% endif %} {% if service_address.country %}{{ service_address.country }}{% endif %}</div>
</div>
{% endif %}
{% if document.show_prices %}
<table>
  <thead>
    <tr>
      <th>Concepto</th>
      <th class="num">Cant.</th>
      <th>Unidad</th>
      <th class="num">Precio</th>
      <th class="num">Dto. %</th>
      <th class="num">Importe</th>
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
  <tr><td>Subtotal</td><td class="num">{{ totals.subtotal }} {{ document.currency }}</td></tr>
  {% for tax in totals.tax_breakdown %}
  <tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>
  {% endfor %}
  <tr><td><strong>Total</strong></td><td class="num"><strong>{{ totals.total }} {{ document.currency }}</strong></td></tr>
</table>
{% else %}
<table>
  <thead>
    <tr>
      <th>Concepto</th>
      <th class="num">Cant.</th>
      <th>Unidad</th>
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
{% endif %}<h2>Conformidad de entrega</h2>
<p class="note">Reconocimiento de servicio recibido; no es aceptar ni rechazar un presupuesto.</p>
<signature-field name="Conformitat" role="client_delivery" style="width:220px;height:70px;display:inline-block;"></signature-field>
<div class="foot">Este documento no es una factura fiscal.<br/>Documento generado por {{ tenant.name }}.</div>
</body>
</html>
$qt3html$,
  '{}'::jsonb,
  $qt3json${"client_delivery":{"entity_type":"contact","label":"Conformidad","order":0,"for_signing":true}}$qt3json$::jsonb,
  $qt3json${"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"delivery_note","doc_number":"ALB-2026-0003","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":null,"created_at":"2026-09-17T09:00:00.000Z","is_amendment":false,"parent_doc_number":"PRE-2026-0008","show_prices":true,"terms_text":null},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}$qt3json$::jsonb,
  true
)
ON CONFLICT DO NOTHING;
