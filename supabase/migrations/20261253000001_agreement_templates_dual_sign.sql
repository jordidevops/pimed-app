-- Platform agreement templates: richer HTML + issuer+client signature fields (CS-D6 acords).
-- Client signature remains mandatory; issuer is allowed and seeded on platform templates.

CREATE OR REPLACE FUNCTION data.validate_commercial_agreement_template_locale(
  p_content text,
  p_mime_type text
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $validate$
DECLARE
  v_content text := COALESCE(p_content, '');
  v_missing text[] := '{}';
BEGIN
  IF p_mime_type IS DISTINCT FROM 'text/html' THEN
    RETURN ARRAY['html_only'];
  END IF;

  IF position('source_quote.doc_number' IN v_content) = 0 THEN
    v_missing := array_append(v_missing, 'source_quote.doc_number');
  END IF;
  IF position('source_quote.content_hash' IN v_content) = 0 THEN
    v_missing := array_append(v_missing, 'source_quote.content_hash');
  END IF;
  IF position('{% for line in lines %}' IN v_content) = 0 THEN
    v_missing := array_append(v_missing, 'lines_loop');
  END IF;
  IF position('totals.total' IN v_content) = 0 THEN
    v_missing := array_append(v_missing, 'totals.total');
  END IF;
  IF position('role="client"' IN v_content) = 0
     AND position($$role='client'$$ IN v_content) = 0 THEN
    v_missing := array_append(v_missing, 'client');
  END IF;
  IF position('client_accept' IN v_content) > 0 THEN
    v_missing := array_append(v_missing, 'forbidden_client_accept');
  END IF;
  IF position('client_reject' IN v_content) > 0 THEN
    v_missing := array_append(v_missing, 'forbidden_client_reject');
  END IF;

  RETURN v_missing;
END;
$validate$;

-- CA: formal services contract
UPDATE data.document_template_locales
SET
  html_content = $html$<!DOCTYPE html>
<html lang="ca">
<head><meta charset="utf-8"/><title>Contracte de serveis</title>
<style>
  body{font-family:Georgia,serif;font-size:11pt;line-height:1.45;color:#111;margin:24px}
  h1{font-size:18pt;margin:0 0 8px} h2{font-size:12pt;margin:18px 0 6px}
  .meta,.parties{display:flex;gap:24px;margin:12px 0}
  .parties>div{flex:1} table{width:100%;border-collapse:collapse;margin:8px 0}
  th,td{border-bottom:1px solid #ddd;padding:4px 6px;text-align:left;font-size:10pt}
  th{font-weight:600} .total{text-align:right;font-weight:700;margin-top:8px}
  .sig{display:flex;gap:32px;margin-top:36px} .sig>div{flex:1}
  .muted{color:#555;font-size:9pt}
</style>
</head>
<body>
  <h1>Contracte de serveis</h1>
  <p class="muted">{{ tenant.name }}{% if tenant.tax_id %} · NIF {{ tenant.tax_id }}{% endif %}</p>
  <div class="parties">
    <div>
      <strong>Prestador</strong><br/>
      {{ seller.display_name }}{% if seller.tax_id %}<br/>NIF {{ seller.tax_id }}{% endif %}
      {% if seller.email %}<br/>{{ seller.email }}{% endif %}
      {% if seller.phone %}<br/>{{ seller.phone }}{% endif %}
    </div>
    <div>
      <strong>Client</strong><br/>
      {{ buyer.display_name }}{% if buyer.tax_id %}<br/>NIF {{ buyer.tax_id }}{% endif %}
      {% if buyer.email %}<br/>{{ buyer.email }}{% endif %}
      {% if buyer.phone %}<br/>{{ buyer.phone }}{% endif %}
    </div>
  </div>
  <p>Les parts acorden els serveis descrits a l’annex (pressupost
    <strong>{{ source_quote.doc_number }}</strong>). Empremta de contingut:
    <code>{{ source_quote.content_hash }}</code>.</p>
  {% if agreement.starts_on or agreement.ends_on %}
  <p>Vigència: {{ agreement.starts_on }} — {{ agreement.ends_on }}
    {% if agreement.notice_days %}(preavís {{ agreement.notice_days }} dies){% endif %}.</p>
  {% endif %}
  <h2>Full de preus (annex)</h2>
  <table>
    <thead><tr><th>Concepte</th><th>Qtat</th><th>Preu</th><th>Total</th></tr></thead>
    <tbody>
    {% for line in lines %}
      <tr>
        <td>{{ line.name }}{% if line.description %}<br/><span class="muted">{{ line.description }}</span>{% endif %}</td>
        <td>{{ line.quantity }} {{ line.unit }}</td>
        <td>{{ line.unit_price }}</td>
        <td>{{ line.line_total }}</td>
      </tr>
    {% endfor %}
    </tbody>
  </table>
  <p class="total">Subtotal {{ totals.subtotal }} {{ document.currency }} ·
    {% if totals.tax_breakdown %}IVA {{ totals.tax_breakdown }} · {% endif %}
    <strong>Total {{ totals.total }} {{ document.currency }}</strong></p>
  <p class="muted">Aquest document no constitueix assessorament jurídic. Les condicions del pressupost annex formen part del contracte.</p>
  <div class="sig">
    <div>
      <p><strong>Representant del prestador</strong></p>
      <signature-field name="Firma prestador" role="issuer" style="min-height:72px;border:1px solid #999;display:block"></signature-field>
    </div>
    <div>
      <p><strong>Representant del client</strong></p>
      <signature-field name="Firma client" role="client" style="min-height:72px;border:1px solid #999;display:block"></signature-field>
    </div>
  </div>
</body>
</html>$html$,
  signing_roles_schema = '{"roles":["issuer","client"]}'::jsonb,
  sample_values = '{"tenant":{"name":"Empresa Demo","tax_id":"B12345678"},"seller":{"display_name":"Empresa Demo"},"buyer":{"display_name":"Client Demo"},"source_quote":{"doc_number":"P-2026-0001","content_hash":"abc"},"totals":{"subtotal":100,"total":121},"document":{"currency":"EUR"},"lines":[{"name":"Servei","quantity":1,"unit":"u","unit_price":100,"line_total":100}]}'::jsonb,
  updated_at = now()
WHERE id = '78100000-0000-0000-0000-000000000011';

UPDATE data.document_template_locales
SET
  html_content = $html$<!DOCTYPE html>
<html lang="es">
<head><meta charset="utf-8"/><title>Contrato de servicios</title>
<style>
  body{font-family:Georgia,serif;font-size:11pt;line-height:1.45;color:#111;margin:24px}
  h1{font-size:18pt;margin:0 0 8px} h2{font-size:12pt;margin:18px 0 6px}
  .parties{display:flex;gap:24px;margin:12px 0}
  .parties>div{flex:1} table{width:100%;border-collapse:collapse;margin:8px 0}
  th,td{border-bottom:1px solid #ddd;padding:4px 6px;text-align:left;font-size:10pt}
  th{font-weight:600} .total{text-align:right;font-weight:700;margin-top:8px}
  .sig{display:flex;gap:32px;margin-top:36px} .sig>div{flex:1}
  .muted{color:#555;font-size:9pt}
</style>
</head>
<body>
  <h1>Contrato de servicios</h1>
  <p class="muted">{{ tenant.name }}{% if tenant.tax_id %} · NIF {{ tenant.tax_id }}{% endif %}</p>
  <div class="parties">
    <div>
      <strong>Prestador</strong><br/>
      {{ seller.display_name }}{% if seller.tax_id %}<br/>NIF {{ seller.tax_id }}{% endif %}
    </div>
    <div>
      <strong>Cliente</strong><br/>
      {{ buyer.display_name }}{% if buyer.tax_id %}<br/>NIF {{ buyer.tax_id }}{% endif %}
    </div>
  </div>
  <p>Las partes acuerdan los servicios del anexo (presupuesto
    <strong>{{ source_quote.doc_number }}</strong>). Huella:
    <code>{{ source_quote.content_hash }}</code>.</p>
  <h2>Hoja de precios (anexo)</h2>
  <table>
    <thead><tr><th>Concepto</th><th>Cant.</th><th>Precio</th><th>Total</th></tr></thead>
    <tbody>
    {% for line in lines %}
      <tr>
        <td>{{ line.name }}</td>
        <td>{{ line.quantity }} {{ line.unit }}</td>
        <td>{{ line.unit_price }}</td>
        <td>{{ line.line_total }}</td>
      </tr>
    {% endfor %}
    </tbody>
  </table>
  <p class="total">Subtotal {{ totals.subtotal }} {{ document.currency }} ·
    <strong>Total {{ totals.total }} {{ document.currency }}</strong></p>
  <div class="sig">
    <div>
      <p><strong>Representante del prestador</strong></p>
      <signature-field name="Firma prestador" role="issuer" style="min-height:72px;border:1px solid #999;display:block"></signature-field>
    </div>
    <div>
      <p><strong>Representante del cliente</strong></p>
      <signature-field name="Firma cliente" role="client" style="min-height:72px;border:1px solid #999;display:block"></signature-field>
    </div>
  </div>
</body>
</html>$html$,
  signing_roles_schema = '{"roles":["issuer","client"]}'::jsonb,
  updated_at = now()
WHERE id = '79100000-0000-0000-0000-000000000011';

-- CA: maintenance agreement
UPDATE data.document_template_locales
SET
  html_content = $html$<!DOCTYPE html>
<html lang="ca">
<head><meta charset="utf-8"/><title>Acord de manteniment</title>
<style>
  body{font-family:Georgia,serif;font-size:11pt;line-height:1.45;color:#111;margin:24px}
  h1{font-size:18pt} h2{font-size:12pt;margin-top:16px}
  table{width:100%;border-collapse:collapse} th,td{border-bottom:1px solid #ddd;padding:4px 6px;text-align:left;font-size:10pt}
  .sig{display:flex;gap:32px;margin-top:36px} .sig>div{flex:1}
  .muted{color:#555;font-size:9pt}
</style>
</head>
<body>
  <h1>Acord de manteniment / vigència</h1>
  <p>{{ seller.display_name }} i {{ buyer.display_name }} acorden el servei periòdic.</p>
  <p>Tipus: {{ agreement.kind }}. Vigència: {{ agreement.starts_on }} — {{ agreement.ends_on }}.
    Preavís: {{ agreement.notice_days }} dies.</p>
  <p>SLA — resposta: {{ agreement.sla.response_hours }} h; resolució: {{ agreement.sla.resolution_hours }} h.
    Cobertura: {{ agreement.sla.coverage_notes }}.</p>
  <p class="muted">Annex: pressupost {{ source_quote.doc_number }}. Empremta {{ source_quote.content_hash }}.</p>
  <h2>Serveis inclosos</h2>
  <table>
    <thead><tr><th>Concepte</th><th>Total</th></tr></thead>
    <tbody>
    {% for line in lines %}
      <tr><td>{{ line.name }}</td><td>{{ line.line_total }}</td></tr>
    {% endfor %}
    </tbody>
  </table>
  <p><strong>Total de referència {{ totals.total }} {{ document.currency }}</strong></p>
  <div class="sig">
    <div>
      <p><strong>Prestador</strong></p>
      <signature-field name="Firma prestador" role="issuer" style="min-height:72px;border:1px solid #999;display:block"></signature-field>
    </div>
    <div>
      <p><strong>Client</strong></p>
      <signature-field name="Firma client" role="client" style="min-height:72px;border:1px solid #999;display:block"></signature-field>
    </div>
  </div>
</body>
</html>$html$,
  signing_roles_schema = '{"roles":["issuer","client"]}'::jsonb,
  updated_at = now()
WHERE id = '78100000-0000-0000-0000-000000000012';

UPDATE data.document_template_locales
SET
  html_content = $html$<!DOCTYPE html>
<html lang="es">
<head><meta charset="utf-8"/><title>Acuerdo de mantenimiento</title>
<style>
  body{font-family:Georgia,serif;font-size:11pt;line-height:1.45;color:#111;margin:24px}
  h1{font-size:18pt} .sig{display:flex;gap:32px;margin-top:36px} .sig>div{flex:1}
  table{width:100%;border-collapse:collapse} th,td{border-bottom:1px solid #ddd;padding:4px 6px;text-align:left;font-size:10pt}
</style>
</head>
<body>
  <h1>Acuerdo de mantenimiento / vigencia</h1>
  <p>{{ seller.display_name }} y {{ buyer.display_name }} acuerdan el servicio periódico.</p>
  <p>Tipo: {{ agreement.kind }}. Vigencia: {{ agreement.starts_on }} — {{ agreement.ends_on }}.</p>
  <p>Anexo: presupuesto {{ source_quote.doc_number }}. Huella {{ source_quote.content_hash }}.</p>
  <table>
    <thead><tr><th>Concepto</th><th>Total</th></tr></thead>
    <tbody>
    {% for line in lines %}
      <tr><td>{{ line.name }}</td><td>{{ line.line_total }}</td></tr>
    {% endfor %}
    </tbody>
  </table>
  <p><strong>Total {{ totals.total }} {{ document.currency }}</strong></p>
  <div class="sig">
    <div>
      <p><strong>Prestador</strong></p>
      <signature-field name="Firma prestador" role="issuer" style="min-height:72px;border:1px solid #999;display:block"></signature-field>
    </div>
    <div>
      <p><strong>Cliente</strong></p>
      <signature-field name="Firma cliente" role="client" style="min-height:72px;border:1px solid #999;display:block"></signature-field>
    </div>
  </div>
</body>
</html>$html$,
  signing_roles_schema = '{"roles":["issuer","client"]}'::jsonb,
  updated_at = now()
WHERE id = '79100000-0000-0000-0000-000000000012';
