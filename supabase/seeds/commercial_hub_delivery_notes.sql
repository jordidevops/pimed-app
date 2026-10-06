-- Albarans amb línies per al hub CF-26 (després de cada db reset).
-- Números 91xx reservats: no toquen el comptador d'emissió (P/A-2026-0001…).
-- Ordres la setmana vinent i sense tècnic, perquè Avui (Alice/Hèctor/Inés) no canviï.
--
-- Volt  A-2026-9101  Meridian / OS «Hub albarans — UAT»  (2 línies)
-- Riera A-2026-9102  Clot / OS «Hub albarans — UAT»      (1 línia)
-- Riera A-2026-9001  ja existeix a riera_commercial_agreements.sql (1 línia)

-- ─── Volt Serveis ────────────────────────────────────────────────────────────
INSERT INTO data.projects (
  id, tenant_id, type, name, description, status, visibility,
  site_id, department_id, client_id, contact_site_id,
  created_by, planned_start, planned_end, authorized_total,
  commercial_regime, service_mode
)
VALUES (
  '51000000-0000-0000-0000-000000000110',
  '10000000-0000-0000-0000-000000000003',
  'work_order',
  'Hub albarans — UAT',
  'Fixture durable: pressupost acceptat + albarà amb línies per /sales/delivery-notes.',
  'active',
  'company',
  '30000000-0000-0000-0000-000000000004',
  '43000000-0000-0000-0000-000000000101',
  '80000000-0000-0000-0000-000000000101',
  '81000000-0000-0000-0000-000000000101',
  '20000000-0000-0000-0000-000000000002',
  (timezone('Europe/Madrid', now()))::date + 7 + time '09:00'
    AT TIME ZONE 'Europe/Madrid',
  (timezone('Europe/Madrid', now()))::date + 7 + time '12:00'
    AT TIME ZONE 'Europe/Madrid',
  121.00,
  'contractual',
  'execute'
)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  status = EXCLUDED.status,
  authorized_total = EXCLUDED.authorized_total,
  planned_start = EXCLUDED.planned_start,
  planned_end = EXCLUDED.planned_end,
  updated_at = now();

INSERT INTO data.project_lines (
  id, tenant_id, project_id, kind, name, description, unit,
  quantity, unit_price, discount_pct, tax_rate, position
)
VALUES
  (
    '51100000-0000-0000-0000-000000000110',
    '10000000-0000-0000-0000-000000000003',
    '51000000-0000-0000-0000-000000000110',
    'service',
    'Canvi d''endolls',
    'Mà d''obra.',
    'h', 2, 40, 0, 21, 0
  ),
  (
    '51100000-0000-0000-0000-000000000111',
    '10000000-0000-0000-0000-000000000003',
    '51000000-0000-0000-0000-000000000110',
    'product',
    'Mecanismes',
    'Material lliurat.',
    'u', 1, 20, 0, 21, 1
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.commercial_documents (
  id, tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
  parent_document_id, status, seller_snapshot, buyer_snapshot, service_address_snapshot,
  locale, currency, subtotal, tax_breakdown, total, show_prices, content_hash,
  full_body_template_id, formalization_mode, issued_at, issued_on, issued_by, created_by, created_at
)
VALUES
  (
    '52000000-0000-0000-0000-000000000110',
    '10000000-0000-0000-0000-000000000003',
    'quote', 'P-2026-9101',
    '80000000-0000-0000-0000-000000000101',
    '51000000-0000-0000-0000-000000000110',
    '81000000-0000-0000-0000-000000000101', NULL,
    'accepted',
    '{"display_name":"Volt Serveis","legal_name":"Volt Serveis"}'::jsonb,
    '{"display_name":"Constructora Meridian S.L.","legal_name":"Constructora Meridian S.L.","tax_id":"B-12345678","email":"info@meridian.cat"}'::jsonb,
    '{"name":"Obra Muntaner","address":"Carrer de Muntaner 240","city":"Barcelona","postal_code":"08021"}'::jsonb,
    'ca', 'EUR', 100.00, '[{"tax_rate":21,"tax_base":100,"tax_amount":21.00}]'::jsonb, 121.00, true,
    encode(extensions.digest('P-2026-9101|100.00', 'sha256'), 'hex'),
    NULL, 'signed_quote',
    timezone('Europe/Madrid', now()) - interval '3 days',
    (timezone('Europe/Madrid', now()) - interval '3 days')::date,
    '20000000-0000-0000-0000-000000000002',
    '20000000-0000-0000-0000-000000000002',
    timezone('Europe/Madrid', now()) - interval '3 days'
  ),
  (
    '52000000-0000-0000-0000-000000000111',
    '10000000-0000-0000-0000-000000000003',
    'delivery_note', 'A-2026-9101',
    '80000000-0000-0000-0000-000000000101',
    '51000000-0000-0000-0000-000000000110',
    '81000000-0000-0000-0000-000000000101',
    '52000000-0000-0000-0000-000000000110',
    'issued',
    '{"display_name":"Volt Serveis","legal_name":"Volt Serveis"}'::jsonb,
    '{"display_name":"Constructora Meridian S.L.","legal_name":"Constructora Meridian S.L.","tax_id":"B-12345678","email":"info@meridian.cat"}'::jsonb,
    '{"name":"Obra Muntaner","address":"Carrer de Muntaner 240","city":"Barcelona","postal_code":"08021"}'::jsonb,
    'ca', 'EUR', 100.00, '[{"tax_rate":21,"tax_base":100,"tax_amount":21.00}]'::jsonb, 121.00, true,
    encode(extensions.digest('A-2026-9101|100.00', 'sha256'), 'hex'),
    NULL, 'signed_quote',
    timezone('Europe/Madrid', now()) - interval '2 days',
    (timezone('Europe/Madrid', now()) - interval '2 days')::date,
    '20000000-0000-0000-0000-000000000002',
    '20000000-0000-0000-0000-000000000002',
    timezone('Europe/Madrid', now()) - interval '2 days'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.commercial_document_lines (
  id, tenant_id, document_id, source_project_line_id, kind, name, description, unit,
  quantity, unit_price, discount_pct, tax_rate,
  line_subtotal, line_tax, line_total, position
)
VALUES
  (
    '52100000-0000-0000-0000-000000000110',
    '10000000-0000-0000-0000-000000000003',
    '52000000-0000-0000-0000-000000000110',
    '51100000-0000-0000-0000-000000000110',
    'service', 'Canvi d''endolls', 'Mà d''obra.', 'h',
    2, 40, 0, 21, 80.00, 16.80, 96.80, 0
  ),
  (
    '52100000-0000-0000-0000-000000000111',
    '10000000-0000-0000-0000-000000000003',
    '52000000-0000-0000-0000-000000000110',
    '51100000-0000-0000-0000-000000000111',
    'product', 'Mecanismes', 'Material lliurat.', 'u',
    1, 20, 0, 21, 20.00, 4.20, 24.20, 1
  ),
  (
    '52100000-0000-0000-0000-000000000112',
    '10000000-0000-0000-0000-000000000003',
    '52000000-0000-0000-0000-000000000111',
    '51100000-0000-0000-0000-000000000110',
    'service', 'Canvi d''endolls', 'Mà d''obra.', 'h',
    2, 40, 0, 21, 80.00, 16.80, 96.80, 0
  ),
  (
    '52100000-0000-0000-0000-000000000113',
    '10000000-0000-0000-0000-000000000003',
    '52000000-0000-0000-0000-000000000111',
    '51100000-0000-0000-0000-000000000111',
    'product', 'Mecanismes', 'Material lliurat.', 'u',
    1, 20, 0, 21, 20.00, 4.20, 24.20, 1
  )
ON CONFLICT (id) DO NOTHING;

-- ─── Riera Instal·lacions ────────────────────────────────────────────────────
INSERT INTO data.projects (
  id, tenant_id, type, name, description, status, visibility,
  site_id, department_id, client_id, contact_site_id,
  created_by, planned_start, planned_end, authorized_total,
  commercial_regime, service_mode
)
VALUES (
  '51000000-0000-0000-0000-000000000210',
  '10000000-0000-0000-0000-000000000004',
  'work_order',
  'Hub albarans — UAT',
  'Fixture durable: pressupost acceptat + albarà amb línies per /sales/delivery-notes (Gina). A-2026-9001 ja cobreix l''OS de caldera.',
  'active',
  'company',
  '30000000-0000-0000-0000-000000000005',
  '43000000-0000-0000-0000-000000000202',
  '80000000-0000-0000-0000-000000000201',
  '81000000-0000-0000-0000-000000000201',
  '20000000-0000-0000-0000-000000000008',
  (timezone('Europe/Madrid', now()))::date + 10 + time '09:00'
    AT TIME ZONE 'Europe/Madrid',
  (timezone('Europe/Madrid', now()))::date + 10 + time '11:00'
    AT TIME ZONE 'Europe/Madrid',
  181.50,
  'contractual',
  'execute'
)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  status = EXCLUDED.status,
  authorized_total = EXCLUDED.authorized_total,
  planned_start = EXCLUDED.planned_start,
  planned_end = EXCLUDED.planned_end,
  updated_at = now();

INSERT INTO data.project_lines (
  id, tenant_id, project_id, kind, name, description, unit,
  quantity, unit_price, discount_pct, tax_rate, position
)
VALUES (
  '51100000-0000-0000-0000-000000000210',
  '10000000-0000-0000-0000-000000000004',
  '51000000-0000-0000-0000-000000000210',
  'service',
  'Revisió de bombes',
  'Línia per albarà de hub.',
  'u', 1, 150, 0, 21, 0
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.commercial_documents (
  id, tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
  parent_document_id, status, seller_snapshot, buyer_snapshot, service_address_snapshot,
  locale, currency, subtotal, tax_breakdown, total, show_prices, content_hash,
  full_body_template_id, formalization_mode, issued_at, issued_on, issued_by, created_by, created_at
)
VALUES
  (
    '52000000-0000-0000-0000-000000000210',
    '10000000-0000-0000-0000-000000000004',
    'quote', 'P-2026-9102',
    '80000000-0000-0000-0000-000000000201',
    '51000000-0000-0000-0000-000000000210',
    '81000000-0000-0000-0000-000000000201', NULL,
    'accepted',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Edifici Clot 12","address":"Carrer del Clot 12","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 150.00, '[{"tax_rate":21,"tax_base":150,"tax_amount":31.50}]'::jsonb, 181.50, true,
    encode(extensions.digest('P-2026-9102|150.00', 'sha256'), 'hex'),
    NULL, 'signed_quote',
    timezone('Europe/Madrid', now()) - interval '3 days',
    (timezone('Europe/Madrid', now()) - interval '3 days')::date,
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '3 days'
  ),
  (
    '52000000-0000-0000-0000-000000000211',
    '10000000-0000-0000-0000-000000000004',
    'delivery_note', 'A-2026-9102',
    '80000000-0000-0000-0000-000000000201',
    '51000000-0000-0000-0000-000000000210',
    '81000000-0000-0000-0000-000000000201',
    '52000000-0000-0000-0000-000000000210',
    'issued',
    '{"display_name":"Riera Instal·lacions","legal_name":"Riera Instal·lacions"}'::jsonb,
    '{"display_name":"Comunitat Propietaris Clot","legal_name":"Comunitat Propietaris Clot","email":"junta@clot.cat"}'::jsonb,
    '{"name":"Edifici Clot 12","address":"Carrer del Clot 12","city":"Barcelona"}'::jsonb,
    'ca', 'EUR', 150.00, '[{"tax_rate":21,"tax_base":150,"tax_amount":31.50}]'::jsonb, 181.50, true,
    encode(extensions.digest('A-2026-9102|150.00', 'sha256'), 'hex'),
    NULL, 'signed_quote',
    timezone('Europe/Madrid', now()) - interval '1 day',
    (timezone('Europe/Madrid', now()) - interval '1 day')::date,
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    timezone('Europe/Madrid', now()) - interval '1 day'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.commercial_document_lines (
  id, tenant_id, document_id, source_project_line_id, kind, name, description, unit,
  quantity, unit_price, discount_pct, tax_rate,
  line_subtotal, line_tax, line_total, position
)
VALUES
  (
    '52100000-0000-0000-0000-000000000210',
    '10000000-0000-0000-0000-000000000004',
    '52000000-0000-0000-0000-000000000210',
    '51100000-0000-0000-0000-000000000210',
    'service', 'Revisió de bombes', 'Línia per albarà de hub.', 'u',
    1, 150, 0, 21, 150.00, 31.50, 181.50, 0
  ),
  (
    '52100000-0000-0000-0000-000000000211',
    '10000000-0000-0000-0000-000000000004',
    '52000000-0000-0000-0000-000000000211',
    '51100000-0000-0000-0000-000000000210',
    'service', 'Revisió de bombes', 'Línia per albarà de hub.', 'u',
    1, 150, 0, 21, 150.00, 31.50, 181.50, 0
  )
ON CONFLICT (id) DO NOTHING;
