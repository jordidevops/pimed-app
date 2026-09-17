-- QT-6: plantilles DOCX de plataforma (cos complet quote/delivery_note).
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
  ('74000000-0000-0000-0000-000000000001', NULL, 'Pressupost genèric (DOCX)', 'Plantilla DOCX de pressupost de cos complet (punt de partida; no és assessorament jurídic).', 'quote', 'docx', true, true, NULL, NULL),
  ('74000000-0000-0000-0000-000000000002', NULL, 'Pressupost servei de camp (DOCX)', 'Pressupost DOCX per a serveis a domicili o en ruta, amb clàusula de desplaçaments/urgències com a línia pròpia.', 'quote', 'docx', true, true, NULL, ARRAY['field_service']::text[]),
  ('74000000-0000-0000-0000-000000000003', NULL, 'Pressupost taller / maker (DOCX)', 'Pressupost DOCX per a taller o maker, amb avís informatiu de validesa mínima (RD 1457/1986) quan aplica.', 'quote', 'docx', true, true, NULL, ARRAY['workshop_maker']::text[]),
  ('74000000-0000-0000-0000-000000000004', NULL, 'Pressupost consulta / pràctica (DOCX)', 'Pressupost DOCX per a consulta o pràctica, amb avís de resguard independent si hi ha dipòsit de béns.', 'quote', 'docx', true, true, NULL, ARRAY['practice']::text[]),
  ('74000000-0000-0000-0000-000000000005', NULL, 'Pressupost hostaleria (DOCX)', 'Pressupost DOCX per a hostaleria (mateixa base genèrica; clàusules sectorials pendents).', 'quote', 'docx', true, true, NULL, ARRAY['hospitality']::text[]),
  ('75000000-0000-0000-0000-000000000001', NULL, 'Albarà genèric (DOCX)', 'Albarà DOCX de cos complet (no és factura fiscal). Punt de partida; no és assessorament jurídic.', 'delivery_note', 'docx', true, true, NULL, NULL)
ON CONFLICT DO NOTHING;

INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
(
  '74800000-0000-0000-0000-000000000001', '74000000-0000-0000-0000-000000000001', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/quote-generic-ca.docx',
  NULL,
  '{}'::jsonb,
  '{"client_accept":{"entity_type":"contact","label":"Accepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Refuso","order":1,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74900000-0000-0000-0000-000000000001', '74000000-0000-0000-0000-000000000001', 'es',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/quote-generic-es.docx',
  NULL,
  '{}'::jsonb,
  '{"client_accept":{"entity_type":"contact","label":"Acepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Rechazo","order":1,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74800000-0000-0000-0000-000000000002', '74000000-0000-0000-0000-000000000002', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/quote-field-service-ca.docx',
  NULL,
  '{}'::jsonb,
  '{"client_accept":{"entity_type":"contact","label":"Accepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Refuso","order":1,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74900000-0000-0000-0000-000000000002', '74000000-0000-0000-0000-000000000002', 'es',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/quote-field-service-es.docx',
  NULL,
  '{}'::jsonb,
  '{"client_accept":{"entity_type":"contact","label":"Acepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Rechazo","order":1,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74800000-0000-0000-0000-000000000003', '74000000-0000-0000-0000-000000000003', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/quote-workshop-maker-ca.docx',
  NULL,
  '{}'::jsonb,
  '{"client_accept":{"entity_type":"contact","label":"Accepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Refuso","order":1,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74900000-0000-0000-0000-000000000003', '74000000-0000-0000-0000-000000000003', 'es',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/quote-workshop-maker-es.docx',
  NULL,
  '{}'::jsonb,
  '{"client_accept":{"entity_type":"contact","label":"Acepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Rechazo","order":1,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74800000-0000-0000-0000-000000000004', '74000000-0000-0000-0000-000000000004', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/quote-practice-ca.docx',
  NULL,
  '{}'::jsonb,
  '{"client_accept":{"entity_type":"contact","label":"Accepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Refuso","order":1,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74900000-0000-0000-0000-000000000004', '74000000-0000-0000-0000-000000000004', 'es',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/quote-practice-es.docx',
  NULL,
  '{}'::jsonb,
  '{"client_accept":{"entity_type":"contact","label":"Acepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Rechazo","order":1,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74800000-0000-0000-0000-000000000005', '74000000-0000-0000-0000-000000000005', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/quote-hospitality-ca.docx',
  NULL,
  '{}'::jsonb,
  '{"client_accept":{"entity_type":"contact","label":"Accepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Refuso","order":1,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74900000-0000-0000-0000-000000000005', '74000000-0000-0000-0000-000000000005', 'es',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/quote-hospitality-es.docx',
  NULL,
  '{}'::jsonb,
  '{"client_accept":{"entity_type":"contact","label":"Acepto","order":0,"for_signing":true},"client_reject":{"entity_type":"contact","label":"Rechazo","order":1,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"quote","doc_number":"PRE-2026-0008","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":"2026-10-17","created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":null,"show_prices":true,"terms_text":"30 dies"},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74800000-0000-0000-0000-000000000006', '75000000-0000-0000-0000-000000000001', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/delivery-generic-ca.docx',
  NULL,
  '{}'::jsonb,
  '{"client_delivery":{"entity_type":"contact","label":"Conformitat","order":0,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"delivery_note","doc_number":"ALB-2026-0003","status":"issued","locale":"ca","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":null,"created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":"PRE-2026-0008","show_prices":true,"terms_text":null},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
),
(
  '74900000-0000-0000-0000-000000000006', '75000000-0000-0000-0000-000000000001', 'es',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/commercial/delivery-generic-es.docx',
  NULL,
  '{}'::jsonb,
  '{"client_delivery":{"entity_type":"contact","label":"Conformidad","order":0,"for_signing":true}}'::jsonb,
  '{"globals":{"today":"2026-09-17","date":"2026-09-17","year":"2026","now":"2026-09-17T10:00:00.000Z"},"tenant":{"name":"Volt Serveis SL","tax_id":"B00000000","address":"Carrer Indústria 10, Vic","phone":"938000000","email":"hola@volt.example","logo_url":"https://cdn.example/logo.png"},"document":{"doc_type":"delivery_note","doc_number":"ALB-2026-0003","status":"issued","locale":"es","currency":"EUR","issued_at":"2026-09-17T10:00:00.000Z","valid_until":null,"created_at":"2026-09-17T09:00:00.000Z","issued_at_display":"17/09/2026 12:00","valid_until_display":"17/10/2026","created_at_display":"17/09/2026 11:00","is_amendment":false,"parent_doc_number":"PRE-2026-0008","show_prices":true,"terms_text":null},"seller":{"display_name":"Volt Serveis SL","tax_id":"B00000000","email":"hola@volt.example","phone":"938000000","address_line1":"Carrer Indústria 10","address_line2":null,"city":"Vic","postal_code":"08500"},"buyer":{"display_name":"Client Exemple SL","tax_id":"B12345678","email":"facturacio@client-exemple.example","phone":"934000000","address_line1":"Carrer Major 1","address_line2":null,"city":"Vic","postal_code":"08500"},"service_address":{"label":"Nau 2","line1":"Carrer del Pont 4","line2":null,"city":"Manlleu","postal_code":"08560","region":"Barcelona","country":"ES"},"lines":[{"name":"Visita tècnica","description":"Diagnosi in situ","unit":"h","quantity":2,"unit_price":45,"discount_pct":0,"tax_rate":21,"line_total":90,"kind":"service"},{"name":"Recanvi","description":"Peça de catàleg","unit":"u","quantity":1,"unit_price":80,"discount_pct":10,"tax_rate":21,"line_total":72,"kind":"product"},{"name":"Desplaçament","description":null,"unit":"km","quantity":15,"unit_price":0.4,"discount_pct":0,"tax_rate":10,"line_total":6,"kind":"expense"}],"totals":{"subtotal":168,"tax_breakdown":[{"tax_rate":21,"tax_amount":34.02},{"tax_rate":10,"tax_amount":0.6}],"total":202.62},"legal":{"retention_days":180,"jurisdiction_text":""}}'::jsonb,
  true
)
ON CONFLICT DO NOTHING;
