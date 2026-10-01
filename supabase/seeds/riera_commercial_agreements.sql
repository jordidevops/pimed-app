-- Riera Instal·lacions: exemples de formalització i acords (CT-1…CT-5).
-- Els números 9xxx queden reservats al seed. El comptador d'emissió no es toca,
-- així un pressupost emès des de l'app surt com P-2026-0001 sense xocar.
--
-- P-2026-9001  esborrany, pressupost (sense ordre)
-- P-2026-9002  emès, pendent de resposta
-- P-2026-9003  acceptat, plantilla pressupost-contracte, sense acord
--              ordre: Revisió caldera — Edifici Clot
-- P-2026-9004  acceptat, contracte formal, encara sense acord (Preparar contracte)
--              ordre: Aerotèrmia — pendent de preparar
-- P-2026-9005  acceptat, acord en esborrany (filtre firma: Sense enviar)
--              ordre: Quadre elèctric — acord en esborrany
-- P-2026-9006  acceptat, acord pendent de firma i porta de feina
--              ordre: Instal·lació split — contracte pendent
-- P-2026-9007  acceptat, acord firmat i actiu, no bloqueja
--              ordre: Manteniment caldera — contracte actiu
--              també vinculat a la instal·lació split (dos acords al mateix projecte)
-- P-2026-9008  rebutjat, contracte formal, no es pot preparar
-- P-2026-9010  Marta Roca, feina petita acceptada (sense OS; immutable)
-- P-2026-9013  Marta Roca, emès pendent (ordre Revisió aires)
-- P-2026-9014  Marta Roca, esborrany sense OS (fixture d’estat)
-- AMP-2026-9001  ampliació acceptada del 9003
-- A-2026-9001    albarà del 9003, sense distintiu de relació
--
-- Marta Roca (800…202): habitatge 810…203; ordres 207 (sense pressupost + línies),
-- 208 (emès 9013), 209 (ordre oberta vinculable / canvi d’aixeta).
--
-- Les ordres noves es planifiquen la setmana vinent i sense tècnic assignat,
-- perquè Avui de Hèctor i Inés no canviï.

UPDATE data.tenants
SET settings = jsonb_set(
  COALESCE(settings, '{}'::jsonb),
  '{commercial}',
  COALESCE(settings -> 'commercial', '{}'::jsonb) || jsonb_build_object(
    'formalization_mode_default', 'signed_quote',
    'agreement_template_id', '76100000-0000-0000-0000-000000000001',
    'work_gate_default', 'none'
  ),
  true
)
WHERE id = '10000000-0000-0000-0000-000000000004';

INSERT INTO data.projects (
  id, tenant_id, type, name, description, status, visibility,
  site_id, department_id, client_id, contact_site_id,
  created_by, planned_start, planned_end
)
VALUES
  (
    '51000000-0000-0000-0000-000000000203',
    '10000000-0000-0000-0000-000000000004',
    'work_order',
    'Instal·lació split — contracte pendent',
    'Exemple: hi ha un acord que exigeix firma abans de començar. La feina queda bloquejada fins que estigui actiu. També hi ha un segon acord ja actiu que no desbloqueja.',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000005',
    '43000000-0000-0000-0000-000000000202',
    '80000000-0000-0000-0000-000000000201',
    '81000000-0000-0000-0000-000000000202',
    '20000000-0000-0000-0000-000000000008',
    (timezone('Europe/Madrid', now()))::date + 7 + time '09:00'
      AT TIME ZONE 'Europe/Madrid',
    (timezone('Europe/Madrid', now()))::date + 7 + time '13:00'
      AT TIME ZONE 'Europe/Madrid'
  ),
  (
    '51000000-0000-0000-0000-000000000204',
    '10000000-0000-0000-0000-000000000004',
    'work_order',
    'Quadre elèctric — acord en esborrany',
    'Exemple: el contracte ja està preparat i encara no s''ha enviat a firmar. No bloqueja la feina.',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000005',
    '43000000-0000-0000-0000-000000000202',
    '80000000-0000-0000-0000-000000000201',
    '81000000-0000-0000-0000-000000000201',
    '20000000-0000-0000-0000-000000000008',
    (timezone('Europe/Madrid', now()))::date + 8 + time '09:00'
      AT TIME ZONE 'Europe/Madrid',
    (timezone('Europe/Madrid', now()))::date + 8 + time '12:00'
      AT TIME ZONE 'Europe/Madrid'
  ),
  (
    '51000000-0000-0000-0000-000000000205',
    '10000000-0000-0000-0000-000000000004',
    'work_order',
    'Manteniment caldera — contracte actiu',
    'Exemple: el contracte està firmat i actiu. Es pot iniciar la feina.',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000005',
    '43000000-0000-0000-0000-000000000202',
    '80000000-0000-0000-0000-000000000201',
    '81000000-0000-0000-0000-000000000201',
    '20000000-0000-0000-0000-000000000008',
    (timezone('Europe/Madrid', now()))::date + 9 + time '09:00'
      AT TIME ZONE 'Europe/Madrid',
    (timezone('Europe/Madrid', now()))::date + 9 + time '11:00'
      AT TIME ZONE 'Europe/Madrid'
  ),
  (
    '51000000-0000-0000-0000-000000000206',
    '10000000-0000-0000-0000-000000000004',
    'work_order',
    'Aerotèrmia — pendent de preparar',
    'Exemple: el pressupost està acceptat amb contracte formal i encara no hi ha acord. L''oficina el prepara des del pressupost.',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000005',
    '43000000-0000-0000-0000-000000000202',
    '80000000-0000-0000-0000-000000000201',
    '81000000-0000-0000-0000-000000000202',
    '20000000-0000-0000-0000-000000000008',
    (timezone('Europe/Madrid', now()))::date + 10 + time '09:00'
      AT TIME ZONE 'Europe/Madrid',
    (timezone('Europe/Madrid', now()))::date + 10 + time '13:00'
      AT TIME ZONE 'Europe/Madrid'
  )
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  status = EXCLUDED.status,
  planned_start = EXCLUDED.planned_start,
  planned_end = EXCLUDED.planned_end,
  updated_at = now();

INSERT INTO data.commercial_documents (
  id, tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
  parent_document_id, status, seller_snapshot, buyer_snapshot, service_address_snapshot,
  locale, currency, subtotal, tax_breakdown, total, show_prices, content_hash,
  full_body_template_id, formalization_mode, issued_at, issued_by, created_by, created_at
)
VALUES
  (
    '52000000-0000-0000-0000-000000000901',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9001',
    '80000000-0000-0000-0000-000000000201',
    NULL, '81000000-0000-0000-0000-000000000201', NULL,
    'draft',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Edifici Clot 12","address":"Carrer del Clot 12","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 80.00, '[{"rate":21,"base":80,"tax":16.80}]'::jsonb, 96.80, true,
    encode(extensions.digest('P-2026-9001|80.00', 'sha256'), 'hex'),
    NULL, 'signed_quote', NULL, NULL,
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '6 days'
  ),
  (
    '52000000-0000-0000-0000-000000000902',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9002',
    '80000000-0000-0000-0000-000000000201',
    NULL, '81000000-0000-0000-0000-000000000201', NULL,
    'issued',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Edifici Clot 12","address":"Carrer del Clot 12","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 120.00, '[{"rate":21,"base":120,"tax":25.20}]'::jsonb, 145.20, true,
    encode(extensions.digest('P-2026-9002|120.00', 'sha256'), 'hex'),
    NULL, 'signed_quote',
    timezone('Europe/Madrid', now()) - interval '5 days',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '5 days'
  ),
  (
    '52000000-0000-0000-0000-000000000903',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9003',
    '80000000-0000-0000-0000-000000000201',
    '51000000-0000-0000-0000-000000000201',
    '81000000-0000-0000-0000-000000000201', NULL,
    'accepted',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Edifici Clot 12","address":"Carrer del Clot 12","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 180.00, '[{"rate":21,"base":180,"tax":37.80}]'::jsonb, 217.80, true,
    encode(extensions.digest('P-2026-9003|180.00', 'sha256'), 'hex'),
    '76000000-0000-0000-0000-000000000006',
    'signed_quote',
    timezone('Europe/Madrid', now()) - interval '4 days',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '4 days'
  ),
  (
    '52000000-0000-0000-0000-000000000904',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9004',
    '80000000-0000-0000-0000-000000000201',
    '51000000-0000-0000-0000-000000000206',
    '81000000-0000-0000-0000-000000000202', NULL,
    'accepted',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Local comercial Rogent","address":"Carrer de Rogent 45","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 2400.00, '[{"rate":21,"base":2400,"tax":504.00}]'::jsonb, 2904.00, true,
    encode(extensions.digest('P-2026-9004|2400.00', 'sha256'), 'hex'),
    NULL, 'separate_agreement',
    timezone('Europe/Madrid', now()) - interval '1 hour',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '1 hour'
  ),
  (
    '52000000-0000-0000-0000-000000000905',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9005',
    '80000000-0000-0000-0000-000000000201',
    '51000000-0000-0000-0000-000000000204',
    '81000000-0000-0000-0000-000000000201', NULL,
    'accepted',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Edifici Clot 12","address":"Carrer del Clot 12","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 640.00, '[{"rate":21,"base":640,"tax":134.40}]'::jsonb, 774.40, true,
    encode(extensions.digest('P-2026-9005|640.00', 'sha256'), 'hex'),
    NULL, 'separate_agreement',
    timezone('Europe/Madrid', now()) - interval '3 days',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '3 days'
  ),
  (
    '52000000-0000-0000-0000-000000000906',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9006',
    '80000000-0000-0000-0000-000000000201',
    '51000000-0000-0000-0000-000000000203',
    '81000000-0000-0000-0000-000000000202', NULL,
    'accepted',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Local comercial Rogent","address":"Carrer de Rogent 45","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 890.00, '[{"rate":21,"base":890,"tax":186.90}]'::jsonb, 1076.90, true,
    encode(extensions.digest('P-2026-9006|890.00', 'sha256'), 'hex'),
    NULL, 'separate_agreement',
    timezone('Europe/Madrid', now()) - interval '1 day',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '1 day'
  ),
  (
    '52000000-0000-0000-0000-000000000907',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9007',
    '80000000-0000-0000-0000-000000000201',
    '51000000-0000-0000-0000-000000000205',
    '81000000-0000-0000-0000-000000000201', NULL,
    'accepted',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Edifici Clot 12","address":"Carrer del Clot 12","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 4200.00, '[{"rate":21,"base":4200,"tax":882.00}]'::jsonb, 5082.00, true,
    encode(extensions.digest('P-2026-9007|4200.00', 'sha256'), 'hex'),
    NULL, 'separate_agreement',
    timezone('Europe/Madrid', now()) - interval '2 days',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '2 days'
  ),
  (
    '52000000-0000-0000-0000-000000000908',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9008',
    '80000000-0000-0000-0000-000000000201',
    NULL, '81000000-0000-0000-0000-000000000202', NULL,
    'rejected',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Local comercial Rogent","address":"Carrer de Rogent 45","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 1500.00, '[{"rate":21,"base":1500,"tax":315.00}]'::jsonb, 1815.00, true,
    encode(extensions.digest('P-2026-9008|1500.00', 'sha256'), 'hex'),
    NULL, 'separate_agreement',
    timezone('Europe/Madrid', now()) - interval '7 days',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '7 days'
  ),
  (
    '52000000-0000-0000-0000-000000000910',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9010',
    '80000000-0000-0000-0000-000000000202',
    NULL, NULL, NULL,
    'accepted',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Marta Roca","email":"marta.roca@clot.cat"}'::jsonb,
    '{}'::jsonb,
    'ca', 'EUR', 45.00, '[{"rate":21,"base":45,"tax":9.45}]'::jsonb, 54.45, true,
    encode(extensions.digest('P-2026-9010|45.00', 'sha256'), 'hex'),
    NULL, 'signed_quote',
    timezone('Europe/Madrid', now()) - interval '8 days',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '8 days'
  ),
  (
    '52000000-0000-0000-0000-000000000911',
    '10000000-0000-0000-0000-000000000004',
    'quote_amendment', 'AMP-2026-9001',
    '80000000-0000-0000-0000-000000000201',
    '51000000-0000-0000-0000-000000000201',
    '81000000-0000-0000-0000-000000000201',
    '52000000-0000-0000-0000-000000000903',
    'accepted',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Edifici Clot 12","address":"Carrer del Clot 12","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 60.00, '[{"rate":21,"base":60,"tax":12.60}]'::jsonb, 72.60, true,
    encode(extensions.digest('AMP-2026-9001|60.00', 'sha256'), 'hex'),
    '76000000-0000-0000-0000-000000000006',
    'signed_quote',
    timezone('Europe/Madrid', now()) - interval '4 days' + interval '1 hour',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '4 days' + interval '1 hour'
  ),
  (
    '52000000-0000-0000-0000-000000000912',
    '10000000-0000-0000-0000-000000000004',
    'delivery_note', 'A-2026-9001',
    '80000000-0000-0000-0000-000000000201',
    '51000000-0000-0000-0000-000000000201',
    '81000000-0000-0000-0000-000000000201',
    '52000000-0000-0000-0000-000000000903',
    'issued',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Edifici Clot 12","address":"Carrer del Clot 12","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 180.00, '[{"rate":21,"base":180,"tax":37.80}]'::jsonb, 217.80, true,
    encode(extensions.digest('A-2026-9001|180.00', 'sha256'), 'hex'),
    NULL, 'signed_quote',
    timezone('Europe/Madrid', now()) - interval '4 days' + interval '2 hours',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '4 days' + interval '2 hours'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.commercial_document_lines (
  id, tenant_id, document_id, kind, name, description, unit,
  quantity, unit_price, discount_pct, tax_rate,
  line_subtotal, line_tax, line_total, position
)
VALUES
  ('52100000-0000-0000-0000-000000000901', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000901', 'service', 'Substitució de termòstat', 'Esborrany. Si s''accepta, el pressupost és el contracte.', 'u', 1, 80, 0, 21, 80.00, 16.80, 96.80, 0),
  ('52100000-0000-0000-0000-000000000902', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000902', 'service', 'Manteniment puntual de bombes', 'Emès. Pendent de resposta del client.', 'u', 1, 120, 0, 21, 120.00, 25.20, 145.20, 0),
  ('52100000-0000-0000-0000-000000000903', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000903', 'service', 'Revisió de caldera', 'Acceptat amb la plantilla pressupost i contracte. No hi ha un segon document.', 'u', 1, 180, 0, 21, 180.00, 37.80, 217.80, 0),
  ('52100000-0000-0000-0000-000000000904', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000904', 'service', 'Instal·lació d''aerotèrmia', 'Acceptat. El contracte formal encara no s''ha preparat.', 'u', 1, 2400, 0, 21, 2400.00, 504.00, 2904.00, 0),
  ('52100000-0000-0000-0000-000000000905', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000905', 'service', 'Quadre elèctric de comunitat', 'Acceptat. L''acord està preparat i pendent d''enviar a firma.', 'u', 1, 640, 0, 21, 640.00, 134.40, 774.40, 0),
  ('52100000-0000-0000-0000-000000000906', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000906', 'service', 'Canonades de la instal·lació split', 'Acceptat. L''acord espera la firma i bloqueja l''inici de la feina.', 'u', 1, 890, 0, 21, 890.00, 186.90, 1076.90, 0),
  ('52100000-0000-0000-0000-000000000907', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000907', 'service', 'Manteniment anual de caldera', 'Acceptat. El contracte està firmat i actiu.', 'u', 1, 4200, 0, 21, 4200.00, 882.00, 5082.00, 0),
  ('52100000-0000-0000-0000-000000000908', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000908', 'service', 'Oferta de climatització descartada', 'Rebutjat. No es prepara contracte.', 'u', 1, 1500, 0, 21, 1500.00, 315.00, 1815.00, 0),
  ('52100000-0000-0000-0000-000000000910', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000910', 'service', 'Canvi d''aixeta', 'Feina petita. El pressupost acceptat és el contracte.', 'u', 1, 45, 0, 21, 45.00, 9.45, 54.45, 0),
  ('52100000-0000-0000-0000-000000000911', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000911', 'service', 'Purgador addicional', 'Ampliació acceptada del pressupost de la caldera.', 'u', 1, 60, 0, 21, 60.00, 12.60, 72.60, 0),
  ('52100000-0000-0000-0000-000000000912', '10000000-0000-0000-0000-000000000004', '52000000-0000-0000-0000-000000000912', 'service', 'Revisió de caldera executada', 'Albarà. No porta distintiu de contracte.', 'u', 1, 180, 0, 21, 180.00, 37.80, 217.80, 0)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.commercial_agreements (
  id, tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by, created_at
)
VALUES
  (
    '53000000-0000-0000-0000-000000000905',
    '10000000-0000-0000-0000-000000000004',
    '80000000-0000-0000-0000-000000000201',
    'specific', 'pending_start',
    '52000000-0000-0000-0000-000000000905',
    'none',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '3 days'
  ),
  (
    '53000000-0000-0000-0000-000000000906',
    '10000000-0000-0000-0000-000000000004',
    '80000000-0000-0000-0000-000000000201',
    'specific', 'pending_start',
    '52000000-0000-0000-0000-000000000906',
    'require_signed_agreement',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '1 day'
  ),
  (
    '53000000-0000-0000-0000-000000000907',
    '10000000-0000-0000-0000-000000000004',
    '80000000-0000-0000-0000-000000000201',
    'specific', 'active',
    '52000000-0000-0000-0000-000000000907',
    'none',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '2 days'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.commercial_agreement_versions (
  id, tenant_id, agreement_id, version_no, status, source_quote_id,
  source_quote_content_hash, full_body_template_id, content_hash, created_at
)
SELECT
  CASE q.id
    WHEN '52000000-0000-0000-0000-000000000905' THEN '53100000-0000-0000-0000-000000000905'::uuid
    WHEN '52000000-0000-0000-0000-000000000906' THEN '53100000-0000-0000-0000-000000000906'::uuid
    ELSE '53100000-0000-0000-0000-000000000907'::uuid
  END,
  q.tenant_id,
  CASE q.id
    WHEN '52000000-0000-0000-0000-000000000905' THEN '53000000-0000-0000-0000-000000000905'::uuid
    WHEN '52000000-0000-0000-0000-000000000906' THEN '53000000-0000-0000-0000-000000000906'::uuid
    ELSE '53000000-0000-0000-0000-000000000907'::uuid
  END,
  1,
  CASE q.id
    WHEN '52000000-0000-0000-0000-000000000905' THEN 'draft'
    WHEN '52000000-0000-0000-0000-000000000906' THEN 'pending_signature'
    ELSE 'signed'
  END,
  q.id,
  q.content_hash,
  '76100000-0000-0000-0000-000000000001'::uuid,
  encode(extensions.digest(
    q.content_hash || '|' || q.doc_number || '|76100000-0000-0000-0000-000000000001',
    'sha256'
  ), 'hex'),
  q.created_at
FROM data.commercial_documents q
WHERE q.id IN (
  '52000000-0000-0000-0000-000000000905',
  '52000000-0000-0000-0000-000000000906',
  '52000000-0000-0000-0000-000000000907'
)
ON CONFLICT (id) DO NOTHING;

UPDATE data.commercial_agreements a
SET active_version_id = v.id
FROM data.commercial_agreement_versions v
WHERE v.agreement_id = a.id
  AND a.id IN (
    '53000000-0000-0000-0000-000000000905',
    '53000000-0000-0000-0000-000000000906',
    '53000000-0000-0000-0000-000000000907'
  )
  AND a.active_version_id IS NULL;

INSERT INTO data.commercial_agreement_projects (
  id, tenant_id, agreement_id, project_id
)
VALUES
  ('53300000-0000-0000-0000-000000000951', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000905', '51000000-0000-0000-0000-000000000204'),
  ('53300000-0000-0000-0000-000000000952', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000906', '51000000-0000-0000-0000-000000000203'),
  ('53300000-0000-0000-0000-000000000953', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000907', '51000000-0000-0000-0000-000000000205'),
  ('53300000-0000-0000-0000-000000000954', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000907', '51000000-0000-0000-0000-000000000203')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.commercial_agreement_events (
  id, tenant_id, agreement_id, event_type, actor_id, occurred_at, payload
)
VALUES
  ('53200000-0000-0000-0000-000000000951', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000905', 'created', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '3 days', '{"doc_number":"P-2026-9005"}'::jsonb),
  ('53200000-0000-0000-0000-000000000952', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000905', 'prepared', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '3 days', '{"doc_number":"P-2026-9005"}'::jsonb),
  ('53200000-0000-0000-0000-000000000953', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000905', 'project_linked', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '3 days', '{"project_id":"51000000-0000-0000-0000-000000000204"}'::jsonb),
  ('53200000-0000-0000-0000-000000000961', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000906', 'created', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '1 day', '{"doc_number":"P-2026-9006"}'::jsonb),
  ('53200000-0000-0000-0000-000000000962', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000906', 'prepared', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '1 day', '{"doc_number":"P-2026-9006"}'::jsonb),
  ('53200000-0000-0000-0000-000000000963', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000906', 'sent', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '1 day', '{"signer_role":"client"}'::jsonb),
  ('53200000-0000-0000-0000-000000000964', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000906', 'project_linked', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '1 day', '{"project_id":"51000000-0000-0000-0000-000000000203"}'::jsonb),
  ('53200000-0000-0000-0000-000000000971', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000907', 'created', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '2 days', '{"doc_number":"P-2026-9007"}'::jsonb),
  ('53200000-0000-0000-0000-000000000972', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000907', 'prepared', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '2 days', '{"doc_number":"P-2026-9007"}'::jsonb),
  ('53200000-0000-0000-0000-000000000973', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000907', 'sent', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '2 days', '{"signer_role":"client"}'::jsonb),
  ('53200000-0000-0000-0000-000000000974', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000907', 'signed', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '2 days', '{"signer_role":"client"}'::jsonb),
  ('53200000-0000-0000-0000-000000000975', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000907', 'activated', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '2 days', '{}'::jsonb),
  ('53200000-0000-0000-0000-000000000976', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000907', 'project_linked', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '2 days', '{"project_id":"51000000-0000-0000-0000-000000000205"}'::jsonb),
  ('53200000-0000-0000-0000-000000000977', '10000000-0000-0000-0000-000000000004', '53000000-0000-0000-0000-000000000907', 'project_linked', '20000000-0000-0000-0000-000000000008', timezone('Europe/Madrid', now()) - interval '2 days', '{"project_id":"51000000-0000-0000-0000-000000000203"}'::jsonb)
ON CONFLICT (id) DO NOTHING;

-- ─── Marta Roca (persona): ordres + pressupostos per UAT del tab contacte ─────────

INSERT INTO data.projects (
  id, tenant_id, type, name, description, status, visibility,
  site_id, department_id, client_id, contact_site_id,
  created_by, planned_start, planned_end, authorized_total
)
VALUES
  (
    '51000000-0000-0000-0000-000000000207',
    '10000000-0000-0000-0000-000000000004',
    'work_order',
    'Reparació termo — Marta Roca',
    'Ordre oberta sense pressupost. Serveix per provar «Nou pressupost» des del contacte.',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000005',
    '43000000-0000-0000-0000-000000000202',
    '80000000-0000-0000-0000-000000000202',
    '81000000-0000-0000-0000-000000000203',
    '20000000-0000-0000-0000-000000000008',
    (timezone('Europe/Madrid', now()))::date + 7 + time '10:00'
      AT TIME ZONE 'Europe/Madrid',
    (timezone('Europe/Madrid', now()))::date + 7 + time '12:00'
      AT TIME ZONE 'Europe/Madrid',
    0
  ),
  (
    '51000000-0000-0000-0000-000000000208',
    '10000000-0000-0000-0000-000000000004',
    'work_order',
    'Revisió aires — Marta Roca',
    'Ordre amb pressupost emès pendent de resposta (P-2026-9013).',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000005',
    '43000000-0000-0000-0000-000000000202',
    '80000000-0000-0000-0000-000000000202',
    '81000000-0000-0000-0000-000000000203',
    '20000000-0000-0000-0000-000000000008',
    (timezone('Europe/Madrid', now()))::date + 8 + time '10:00'
      AT TIME ZONE 'Europe/Madrid',
    (timezone('Europe/Madrid', now()))::date + 8 + time '12:00'
      AT TIME ZONE 'Europe/Madrid',
    0
  ),
  (
    '51000000-0000-0000-0000-000000000209',
    '10000000-0000-0000-0000-000000000004',
    'work_order',
    'Canvi d''aixeta — Marta Roca',
    'Ordre vinculada al pressupost acceptat P-2026-9010 (pressupost = contracte).',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000005',
    '43000000-0000-0000-0000-000000000202',
    '80000000-0000-0000-0000-000000000202',
    '81000000-0000-0000-0000-000000000203',
    '20000000-0000-0000-0000-000000000008',
    (timezone('Europe/Madrid', now()))::date + 9 + time '09:00'
      AT TIME ZONE 'Europe/Madrid',
    (timezone('Europe/Madrid', now()))::date + 9 + time '10:30'
      AT TIME ZONE 'Europe/Madrid',
    54.45
  )
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  status = EXCLUDED.status,
  client_id = EXCLUDED.client_id,
  contact_site_id = EXCLUDED.contact_site_id,
  planned_start = EXCLUDED.planned_start,
  planned_end = EXCLUDED.planned_end,
  authorized_total = EXCLUDED.authorized_total,
  updated_at = now();

INSERT INTO data.project_lines (
  id, tenant_id, project_id, kind, name, description, unit,
  quantity, unit_price, discount_pct, tax_rate, position
)
VALUES
  (
    '51100000-0000-0000-0000-000000000207',
    '10000000-0000-0000-0000-000000000004',
    '51000000-0000-0000-0000-000000000207',
    'service',
    'Diagnosi i reparació de termo',
    'Línia per poder emetre pressupost des de l''app.',
    'u', 1, 95, 0, 21, 0
  ),
  (
    '51100000-0000-0000-0000-000000000208',
    '10000000-0000-0000-0000-000000000004',
    '51000000-0000-0000-0000-000000000208',
    'service',
    'Revisió i neteja d''aparells d''aire',
    'Dos splits al habitatge.',
    'u', 2, 55, 0, 21, 0
  ),
  (
    '51100000-0000-0000-0000-000000000209',
    '10000000-0000-0000-0000-000000000004',
    '51000000-0000-0000-0000-000000000209',
    'service',
    'Canvi d''aixeta',
    'Feina petita ja pressupostada.',
    'u', 1, 45, 0, 21, 0
  )
ON CONFLICT (id) DO NOTHING;

-- P-2026-9010 (acceptat) és immutable: no el relliguem a OS. La història Marta
-- amb ordre vinculada és P-2026-9013 (emès) i l’OS 209 (canvi d’aixeta) sense
-- presupost addicional, o el 9010 com a fixture orphan acceptat.

INSERT INTO data.commercial_documents (
  id, tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
  parent_document_id, status, seller_snapshot, buyer_snapshot, service_address_snapshot,
  locale, currency, subtotal, tax_breakdown, total, show_prices, content_hash,
  full_body_template_id, formalization_mode, issued_at, issued_by, created_by, created_at
)
VALUES
  (
    '52000000-0000-0000-0000-000000000913',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9013',
    '80000000-0000-0000-0000-000000000202',
    '51000000-0000-0000-0000-000000000208',
    '81000000-0000-0000-0000-000000000203', NULL,
    'issued',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Marta Roca","email":"marta.roca@clot.cat","phone":"+34611222999"}'::jsonb,
    '{"name":"Habitatge Marta Roca","address":"Carrer de la Independència 88, 3r 2a","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 110.00, '[{"rate":21,"base":110,"tax":23.10}]'::jsonb, 133.10, true,
    encode(extensions.digest('P-2026-9013|110.00', 'sha256'), 'hex'),
    NULL, 'signed_quote',
    timezone('Europe/Madrid', now()) - interval '2 days',
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '2 days'
  ),
  (
    '52000000-0000-0000-0000-000000000914',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9014',
    '80000000-0000-0000-0000-000000000202',
    NULL,
    '81000000-0000-0000-0000-000000000203', NULL,
    'draft',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Marta Roca","email":"marta.roca@clot.cat","phone":"+34611222999"}'::jsonb,
    '{"name":"Habitatge Marta Roca","address":"Carrer de la Independència 88, 3r 2a","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 95.00, '[{"rate":21,"base":95,"tax":19.95}]'::jsonb, 114.95, true,
    encode(extensions.digest('P-2026-9014|95.00', 'sha256'), 'hex'),
    NULL, 'signed_quote', NULL, NULL,
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '1 day'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.commercial_document_lines (
  id, tenant_id, document_id, kind, name, description, unit,
  quantity, unit_price, discount_pct, tax_rate,
  line_subtotal, line_tax, line_total, position
)
VALUES
  (
    '52100000-0000-0000-0000-000000000913',
    '10000000-0000-0000-0000-000000000004',
    '52000000-0000-0000-0000-000000000913',
    'service',
    'Revisió i neteja d''aparells d''aire',
    'Emès. Pendent de resposta de Marta.',
    'u', 2, 55, 0, 21, 110.00, 23.10, 133.10, 0
  ),
  (
    '52100000-0000-0000-0000-000000000914',
    '10000000-0000-0000-0000-000000000004',
    '52000000-0000-0000-0000-000000000914',
    'service',
    'Diagnosi i reparació de termo',
    'Esborrany al client Marta.',
    'u', 1, 95, 0, 21, 95.00, 19.95, 114.95, 0
  )
ON CONFLICT (id) DO NOTHING;
