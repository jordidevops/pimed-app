-- BurgerVista seed.sql — veure docs/plans/seeds/guia-seed-burgervista.md


-- >>> BEGIN 00_readme.sql <<<
-- =============================================================================
-- BurgerVista / Gestió Ràpida BCN — Seed manual QSR (menjar ràpid)
-- =============================================================================
-- Pla (gaps / producte): docs/plans/seeds/plan-qsr-burgervista-seed.md
-- Guia (càrrega, logins, proves): docs/plans/seeds/guia-seed-burgervista.md
--
-- ÚS (SQL Editor de Supabase local, DESPRÉS de `supabase db reset`):
--   1) Enganxa i executa seed.sql (monòlit), O
--   2) Executa en ordre 01 → 11.
--
-- NO afegit a config.toml — no interfereix amb Acme.
-- Password tots els logins: Test1234!
-- PIN portal empleat (tokens seed): 1234
--
-- LOGINS APP (tenant-portal) — detall a la guia
--   marc@burgervista.demo     CEO / owner global
--   nuria@burgervista.demo    Admin corporativa (manager global)
--   jordi@burgervista.demo    Admin corporatiu (member global)
--   laura@burgervista.demo    Directora Eixample (manager site)
--   pau@burgervista.demo      Cap torn Eixample (member site)
--   elena@burgervista.demo    Directora Diagonal (manager site)
--   toni@burgervista.demo     Cap torn Diagonal (member site)
--
-- IDS FIXOS (prefix a1…)
--   tenant  a1000000-0000-0000-0000-000000000001
--   site E  a3000000-0000-0000-0000-000000000001  (Eixample)
--   site D  a3000000-0000-0000-0000-000000000002  (Diagonal)
-- =============================================================================

-- >>> END 00_readme.sql <<<

-- >>> BEGIN 01_org_users.sql <<<
-- =============================================================================
-- 01 — Org, users, sites, memberships (BurgerVista)
-- =============================================================================

-- Tenant + subscripció (pla Pro ja seedat per db reset)
INSERT INTO data.tenants (id, name, slug, plan_id)
VALUES (
  'a1000000-0000-0000-0000-000000000001',
  'Gestió Ràpida BCN SL',
  'burgervista-bcn',
  '00000000-0000-0000-0000-000000000002'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.subscriptions (tenant_id, plan_id, status)
VALUES (
  'a1000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  'active'
)
ON CONFLICT DO NOTHING;

UPDATE data.tenants
SET
  public_portal_enabled = true,
  employee_portal_enabled = true,
  sector_profile_id = (
    SELECT id FROM data.sector_profiles
    WHERE archetype = 'hospitality' AND vertical IS NULL
    LIMIT 1
  ),
  settings = coalesce(settings, '{}'::jsonb) || jsonb_build_object(
    'default_language', 'ca',
    'default_calendar_timezone', 'Europe/Madrid',
    'week_starts_on', 1,
    'punch_only_at_stations', false,
    'attendance_location_consent_required', true
  )
WHERE id = 'a1000000-0000-0000-0000-000000000001';

-- Sites
INSERT INTO data.sites (id, tenant_id, name, address)
VALUES
  (
    'a3000000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000001',
    'BurgerVista Eixample',
    'Carrer d''Aragó 200, 08011 Barcelona'
  ),
  (
    'a3000000-0000-0000-0000-000000000002',
    'a1000000-0000-0000-0000-000000000001',
    'BurgerVista Diagonal',
    'Avinguda Diagonal 450, 08006 Barcelona'
  )
ON CONFLICT (id) DO NOTHING;

-- Auth users (password Test1234!)
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change, raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES
  ('00000000-0000-0000-0000-000000000000', 'a2000000-0000-0000-0000-000000000001',
   'marc@burgervista.demo', crypt('Test1234!', gen_salt('bf')), now(),
   '', '', '', '', '',
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Marc Serra","email_verified":true}',
   'authenticated', 'authenticated', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a2000000-0000-0000-0000-000000000002',
   'nuria@burgervista.demo', crypt('Test1234!', gen_salt('bf')), now(),
   '', '', '', '', '',
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Núria Vila","email_verified":true}',
   'authenticated', 'authenticated', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a2000000-0000-0000-0000-000000000003',
   'jordi@burgervista.demo', crypt('Test1234!', gen_salt('bf')), now(),
   '', '', '', '', '',
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Jordi Pujol","email_verified":true}',
   'authenticated', 'authenticated', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a2000000-0000-0000-0000-000000000004',
   'laura@burgervista.demo', crypt('Test1234!', gen_salt('bf')), now(),
   '', '', '', '', '',
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Laura Roca","email_verified":true}',
   'authenticated', 'authenticated', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a2000000-0000-0000-0000-000000000005',
   'pau@burgervista.demo', crypt('Test1234!', gen_salt('bf')), now(),
   '', '', '', '', '',
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Pau Soler","email_verified":true}',
   'authenticated', 'authenticated', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a2000000-0000-0000-0000-000000000006',
   'elena@burgervista.demo', crypt('Test1234!', gen_salt('bf')), now(),
   '', '', '', '', '',
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Elena Martí","email_verified":true}',
   'authenticated', 'authenticated', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a2000000-0000-0000-0000-000000000007',
   'toni@burgervista.demo', crypt('Test1234!', gen_salt('bf')), now(),
   '', '', '', '', '',
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Toni Costa","email_verified":true}',
   'authenticated', 'authenticated', now(), now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
VALUES
  ('a2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001',
   '{"sub":"a2000000-0000-0000-0000-000000000001","email":"marc@burgervista.demo","email_verified":true}',
   'email', now(), now(), now()),
  ('a2000000-0000-0000-0000-000000000002', 'a2000000-0000-0000-0000-000000000002',
   '{"sub":"a2000000-0000-0000-0000-000000000002","email":"nuria@burgervista.demo","email_verified":true}',
   'email', now(), now(), now()),
  ('a2000000-0000-0000-0000-000000000003', 'a2000000-0000-0000-0000-000000000003',
   '{"sub":"a2000000-0000-0000-0000-000000000003","email":"jordi@burgervista.demo","email_verified":true}',
   'email', now(), now(), now()),
  ('a2000000-0000-0000-0000-000000000004', 'a2000000-0000-0000-0000-000000000004',
   '{"sub":"a2000000-0000-0000-0000-000000000004","email":"laura@burgervista.demo","email_verified":true}',
   'email', now(), now(), now()),
  ('a2000000-0000-0000-0000-000000000005', 'a2000000-0000-0000-0000-000000000005',
   '{"sub":"a2000000-0000-0000-0000-000000000005","email":"pau@burgervista.demo","email_verified":true}',
   'email', now(), now(), now()),
  ('a2000000-0000-0000-0000-000000000006', 'a2000000-0000-0000-0000-000000000006',
   '{"sub":"a2000000-0000-0000-0000-000000000006","email":"elena@burgervista.demo","email_verified":true}',
   'email', now(), now(), now()),
  ('a2000000-0000-0000-0000-000000000007', 'a2000000-0000-0000-0000-000000000007',
   '{"sub":"a2000000-0000-0000-0000-000000000007","email":"toni@burgervista.demo","email_verified":true}',
   'email', now(), now(), now())
ON CONFLICT (provider_id, provider) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name, first_login_at, last_login_at)
VALUES
  ('a2000000-0000-0000-0000-000000000001', 'marc@burgervista.demo', 'Marc Serra', now(), now()),
  ('a2000000-0000-0000-0000-000000000002', 'nuria@burgervista.demo', 'Núria Vila', now(), now()),
  ('a2000000-0000-0000-0000-000000000003', 'jordi@burgervista.demo', 'Jordi Pujol', now(), now()),
  ('a2000000-0000-0000-0000-000000000004', 'laura@burgervista.demo', 'Laura Roca', now(), now()),
  ('a2000000-0000-0000-0000-000000000005', 'pau@burgervista.demo', 'Pau Soler', now(), now()),
  ('a2000000-0000-0000-0000-000000000006', 'elena@burgervista.demo', 'Elena Martí', now(), now()),
  ('a2000000-0000-0000-0000-000000000007', 'toni@burgervista.demo', 'Toni Costa', now(), now())
ON CONFLICT (id) DO NOTHING;

-- Memberships
INSERT INTO data.tenant_members (tenant_id, user_id, role, site_id)
VALUES
  ('a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'owner', NULL),
  ('a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 'manager', NULL),
  ('a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000003', 'member', NULL),
  ('a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000004', 'manager',
   'a3000000-0000-0000-0000-000000000001'),
  ('a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000005', 'member',
   'a3000000-0000-0000-0000-000000000001'),
  ('a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000006', 'manager',
   'a3000000-0000-0000-0000-000000000002'),
  ('a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000007', 'member',
   'a3000000-0000-0000-0000-000000000002')
ON CONFLICT DO NOTHING;

-- Signing config + playbooks (si existeixen els helpers)
INSERT INTO data.tenant_signing_config (tenant_id, mode, signing_credits, is_active)
VALUES ('a1000000-0000-0000-0000-000000000001', 'platform', 200, true)
ON CONFLICT (tenant_id) DO NOTHING;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'data' AND p.proname = 'seed_entity_risk_rules_for_tenant'
  ) THEN
    PERFORM data.seed_entity_risk_rules_for_tenant('a1000000-0000-0000-0000-000000000001');
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'data' AND p.proname = 'seed_employee_termination_playbooks'
  ) THEN
    PERFORM data.seed_employee_termination_playbooks('a1000000-0000-0000-0000-000000000001');
  END IF;
END $$;

-- >>> END 01_org_users.sql <<<

-- >>> BEGIN 02_employees_roles.sql <<<
-- =============================================================================
-- 02 — Employees + work_roles QSR (≤10 / local + corporatiu)
-- =============================================================================

INSERT INTO data.work_roles (id, tenant_id, site_id, key, name, sort_order, is_active)
VALUES
  ('a4900000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', NULL, 'store_manager', 'Director/a de local', 10, true),
  ('a4900000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', NULL, 'shift_lead', 'Cap de torn', 20, true),
  ('a4900000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', NULL, 'grill', 'Cuina / grill', 30, true),
  ('a4900000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001', NULL, 'front_counter', 'Mostrador / caixa', 40, true),
  ('a4900000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001', NULL, 'expedicio', 'Expedició / domicili', 50, true),
  ('a4900000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001', NULL, 'floor', 'Sala', 60, true),
  ('a4900000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001', NULL, 'drive_thru', 'Servei amb auto', 70, true),
  ('a4900000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001', NULL, 'floater', 'Suport / floater', 80, true)
ON CONFLICT (id) DO NOTHING;

-- Catàleg job_positions (hospitality) — independent de work_roles
INSERT INTO data.job_positions (id, tenant_id, code, name, is_active)
VALUES
  ('a4100000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'CEO',           'CEO / Propietari',        true),
  ('a4100000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'HR_ADMIN',      'Administració RRHH',     true),
  ('a4100000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'OPS_ADMIN',     'Administració operativa', true),
  ('a4100000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001', 'STORE_DIR',     'Directora de local',     true),
  ('a4100000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001', 'SHIFT_AM',      'Cap de torn matí',       true),
  ('a4100000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001', 'SHIFT_PM',      'Cap de torn tarda',      true),
  ('a4100000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001', 'GRILL',         'Cuina / grill',          true),
  ('a4100000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001', 'PREP',          'Cuina / prep',           true),
  ('a4100000-0000-0000-0000-000000000009', 'a1000000-0000-0000-0000-000000000001', 'COUNTER',       'Mostrador / caixa',      true),
  ('a4100000-0000-0000-0000-000000000010', 'a1000000-0000-0000-0000-000000000001', 'DELIVERY',      'Expedició / domicili',   true),
  ('a4100000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001', 'FLOOR',         'Sala',                   true),
  ('a4100000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001', 'COUNTER_STUD',  'Mostrador (estudiant)',  true),
  ('a4100000-0000-0000-0000-000000000013', 'a1000000-0000-0000-0000-000000000001', 'FLOATER',       'Suport / floater',       true),
  ('a4100000-0000-0000-0000-000000000014', 'a1000000-0000-0000-0000-000000000001', 'DRIVE',         'Servei amb auto',        true)
ON CONFLICT (id) DO NOTHING;

-- Corporatiu (sense site o amb site null)
INSERT INTO data.employees (
  id, tenant_id, site_id, user_id, full_name, email, job_position_id, status, weekly_hours,
  attendance_work_profile, document_id
) VALUES
  ('a4000000-0000-0000-0000-000000000021', 'a1000000-0000-0000-0000-000000000001', NULL,
   'a2000000-0000-0000-0000-000000000001', 'Marc Serra', 'marc@burgervista.demo',
   'a4100000-0000-0000-0000-000000000001', 'active', 40, 'fixed_site', 'BV-CEO'),
  ('a4000000-0000-0000-0000-000000000022', 'a1000000-0000-0000-0000-000000000001', NULL,
   'a2000000-0000-0000-0000-000000000002', 'Núria Vila', 'nuria@burgervista.demo',
   'a4100000-0000-0000-0000-000000000002', 'active', 40, 'fixed_site', 'BV-ADM1'),
  ('a4000000-0000-0000-0000-000000000023', 'a1000000-0000-0000-0000-000000000001', NULL,
   'a2000000-0000-0000-0000-000000000003', 'Jordi Pujol', 'jordi@burgervista.demo',
   'a4100000-0000-0000-0000-000000000003', 'active', 40, 'fixed_site', 'BV-ADM2')
ON CONFLICT (id) DO NOTHING;

-- Eixample (10)
INSERT INTO data.employees (
  id, tenant_id, site_id, user_id, full_name, email, job_position_id, status, weekly_hours,
  attendance_work_profile, document_id
) VALUES
  ('a4000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000004',
   'Laura Roca', 'laura@burgervista.demo', 'a4100000-0000-0000-0000-000000000004', 'active', 40, 'fixed_site', 'BV-E01'),
  ('a4000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000005',
   'Pau Soler', 'pau@burgervista.demo', 'a4100000-0000-0000-0000-000000000005', 'active', 40, 'fixed_site', 'BV-E02'),
  ('a4000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', NULL,
   'Anna Bosch', 'anna.bosch@burgervista.demo', 'a4100000-0000-0000-0000-000000000006', 'active', 40, 'fixed_site', 'BV-E03'),
  ('a4000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', NULL,
   'Marc Vidal', 'marc.vidal@burgervista.demo', 'a4100000-0000-0000-0000-000000000007', 'active', 40, 'fixed_site', 'BV-E04'),
  ('a4000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', NULL,
   'Sara López', 'sara.lopez@burgervista.demo', 'a4100000-0000-0000-0000-000000000008', 'active', 40, 'fixed_site', 'BV-E05'),
  ('a4000000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', NULL,
   'David Ruiz', 'david.ruiz@burgervista.demo', 'a4100000-0000-0000-0000-000000000009', 'active', 40, 'fixed_site', 'BV-E06'),
  ('a4000000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', NULL,
   'Irene Gómez', 'irene.gomez@burgervista.demo', 'a4100000-0000-0000-0000-000000000010', 'active', 40, 'fixed_site', 'BV-E07'),
  ('a4000000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', NULL,
   'Carla Ferrer', 'carla.ferrer@burgervista.demo', 'a4100000-0000-0000-0000-000000000011', 'active', 30, 'fixed_site', 'BV-E08'),
  ('a4000000-0000-0000-0000-000000000009', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', NULL,
   'Alex Muñoz', 'alex.munoz@burgervista.demo', 'a4100000-0000-0000-0000-000000000012', 'active', 20, 'fixed_site', 'BV-E09'),
  ('a4000000-0000-0000-0000-000000000010', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', NULL,
   'Mireia Sanz', 'mireia.sanz@burgervista.demo', 'a4100000-0000-0000-0000-000000000013', 'active', 30, 'fixed_site', 'BV-E10')
ON CONFLICT (id) DO NOTHING;

-- Diagonal (10)
INSERT INTO data.employees (
  id, tenant_id, site_id, user_id, full_name, email, job_position_id, status, weekly_hours,
  attendance_work_profile, document_id
) VALUES
  ('a4000000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'a2000000-0000-0000-0000-000000000006',
   'Elena Martí', 'elena@burgervista.demo', 'a4100000-0000-0000-0000-000000000004', 'active', 40, 'fixed_site', 'BV-D01'),
  ('a4000000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'a2000000-0000-0000-0000-000000000007',
   'Toni Costa', 'toni@burgervista.demo', 'a4100000-0000-0000-0000-000000000005', 'active', 40, 'fixed_site', 'BV-D02'),
  ('a4000000-0000-0000-0000-000000000013', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', NULL,
   'Joan Navarro', 'joan.navarro@burgervista.demo', 'a4100000-0000-0000-0000-000000000006', 'active', 40, 'fixed_site', 'BV-D03'),
  ('a4000000-0000-0000-0000-000000000014', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', NULL,
   'Patricia Gil', 'patricia.gil@burgervista.demo', 'a4100000-0000-0000-0000-000000000007', 'active', 40, 'fixed_site', 'BV-D04'),
  ('a4000000-0000-0000-0000-000000000015', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', NULL,
   'Hugo Torres', 'hugo.torres@burgervista.demo', 'a4100000-0000-0000-0000-000000000008', 'active', 40, 'fixed_site', 'BV-D05'),
  ('a4000000-0000-0000-0000-000000000016', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', NULL,
   'Marina Puig', 'marina.puig@burgervista.demo', 'a4100000-0000-0000-0000-000000000009', 'active', 40, 'fixed_site', 'BV-D06'),
  ('a4000000-0000-0000-0000-000000000017', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', NULL,
   'Oriol Font', 'oriol.font@burgervista.demo', 'a4100000-0000-0000-0000-000000000010', 'active', 40, 'fixed_site', 'BV-D07'),
  ('a4000000-0000-0000-0000-000000000018', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', NULL,
   'Adrià Serra', 'adria.serra@burgervista.demo', 'a4100000-0000-0000-0000-000000000014', 'active', 40, 'fixed_site', 'BV-D08'),
  ('a4000000-0000-0000-0000-000000000019', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', NULL,
   'Laia Roman', 'laia.roman@burgervista.demo', 'a4100000-0000-0000-0000-000000000012', 'active', 20, 'fixed_site', 'BV-D09'),
  ('a4000000-0000-0000-0000-000000000020', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', NULL,
   'Quim Vidal', 'quim.vidal@burgervista.demo', 'a4100000-0000-0000-0000-000000000013', 'active', 30, 'fixed_site', 'BV-D10')
ON CONFLICT (id) DO NOTHING;

-- Role assignments (primary)
INSERT INTO data.employee_role_assignments (id, tenant_id, employee_id, role_id, level, is_primary, is_active)
VALUES
  ('a4910000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000001', 'a4900000-0000-0000-0000-000000000001', 3, true, true),
  ('a4910000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000002', 'a4900000-0000-0000-0000-000000000002', 2, true, true),
  ('a4910000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000003', 'a4900000-0000-0000-0000-000000000002', 2, true, true),
  ('a4910000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000004', 'a4900000-0000-0000-0000-000000000003', 2, true, true),
  ('a4910000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000005', 'a4900000-0000-0000-0000-000000000003', 1, true, true),
  ('a4910000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000006', 'a4900000-0000-0000-0000-000000000004', 2, true, true),
  ('a4910000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000007', 'a4900000-0000-0000-0000-000000000005', 2, true, true),
  ('a4910000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000008', 'a4900000-0000-0000-0000-000000000006', 1, true, true),
  ('a4910000-0000-0000-0000-000000000009', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000009', 'a4900000-0000-0000-0000-000000000004', 1, true, true),
  ('a4910000-0000-0000-0000-000000000010', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000010', 'a4900000-0000-0000-0000-000000000008', 1, true, true),
  ('a4910000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000011', 'a4900000-0000-0000-0000-000000000001', 3, true, true),
  ('a4910000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000012', 'a4900000-0000-0000-0000-000000000002', 2, true, true),
  ('a4910000-0000-0000-0000-000000000013', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000013', 'a4900000-0000-0000-0000-000000000002', 2, true, true),
  ('a4910000-0000-0000-0000-000000000014', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000014', 'a4900000-0000-0000-0000-000000000003', 2, true, true),
  ('a4910000-0000-0000-0000-000000000015', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000015', 'a4900000-0000-0000-0000-000000000003', 1, true, true),
  ('a4910000-0000-0000-0000-000000000016', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000016', 'a4900000-0000-0000-0000-000000000004', 2, true, true),
  ('a4910000-0000-0000-0000-000000000017', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000017', 'a4900000-0000-0000-0000-000000000005', 2, true, true),
  ('a4910000-0000-0000-0000-000000000018', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000018', 'a4900000-0000-0000-0000-000000000007', 2, true, true),
  ('a4910000-0000-0000-0000-000000000019', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000019', 'a4900000-0000-0000-0000-000000000004', 1, true, true),
  ('a4910000-0000-0000-0000-000000000020', 'a1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000020', 'a4900000-0000-0000-0000-000000000008', 1, true, true)
ON CONFLICT (id) DO NOTHING;

-- Qualificacions higiene (mostra cuina + expedició)
INSERT INTO data.employee_qualifications (id, tenant_id, employee_id, key, label, issued_at, is_active)
VALUES
  ('a4920000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000004', 'higiene_alimentaria', 'Formació higiene alimentària', '2026-01-15', true),
  ('a4920000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000005', 'higiene_alimentaria', 'Formació higiene alimentària', '2026-01-15', true),
  ('a4920000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000007', 'higiene_alimentaria', 'Formació higiene alimentària', '2026-01-15', true),
  ('a4920000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000014', 'higiene_alimentaria', 'Formació higiene alimentària', '2026-01-15', true),
  ('a4920000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000015', 'higiene_alimentaria', 'Formació higiene alimentària', '2026-01-15', true),
  ('a4920000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000017', 'higiene_alimentaria', 'Formació higiene alimentària', '2026-01-15', true)
ON CONFLICT (id) DO NOTHING;

-- >>> END 02_employees_roles.sql <<<

-- >>> BEGIN 03_calendars_pauses_holidays.sql <<<
-- =============================================================================
-- 03 — Pauses hospitality, calendaris 7d, festius CAT, overrides individuals
-- =============================================================================

INSERT INTO data.tenant_pause_configs (
  tenant_id, key, label_i18n, counts_as_work,
  default_duration_min, max_duration_minutes, is_active, sort_order
)
SELECT
  'a1000000-0000-0000-0000-000000000001',
  tpl.key, tpl.label_i18n, tpl.counts_as_work,
  tpl.default_duration_min, tpl.max_duration_minutes, true, tpl.sort_order
FROM data.system_pause_config_templates tpl
WHERE tpl.archetype_key = 'hospitality'
ON CONFLICT (tenant_id, key) DO NOTHING;

INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, description, sort_order)
VALUES
  ('a4600000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', NULL,
   'Administració', '#3b82f6', 'Central i oficines', 1),
  ('a4600000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001',
   'Equip Eixample', '#f97316', 'Plantilla operatiu Eixample (7 dies)', 2),
  ('a4600000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002',
   'Equip Diagonal', '#10b981', 'Plantilla operatiu Diagonal (7 dies)', 3)
ON CONFLICT (id) DO NOTHING;

-- Admin: Dl–Dv partida 09–14 + 15–18
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
SELECT
  'a1000000-0000-0000-0000-000000000001',
  'a4600000-0000-0000-0000-000000000001',
  d.dow, 'work', '09:00'::time, '18:00'::time,
  '[{"start":"09:00","end":"14:00"},{"start":"15:00","end":"18:00"}]'::jsonb,
  '2020-01-01'::date
FROM generate_series(1, 5) AS d(dow)
ON CONFLICT DO NOTHING;

INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES
  ('a1000000-0000-0000-0000-000000000001', 'a4600000-0000-0000-0000-000000000001',
   0, 'non_working', NULL, NULL, NULL, '2020-01-01'),
  ('a1000000-0000-0000-0000-000000000001', 'a4600000-0000-0000-0000-000000000001',
   6, 'non_working', NULL, NULL, NULL, '2020-01-01')
ON CONFLICT DO NOTHING;

-- Equip locals: 7 dies, franja tipica 10:00–15:00 + 18:00–23:00 (dinar+sopar)
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
SELECT
  'a1000000-0000-0000-0000-000000000001',
  g.id,
  d.dow,
  'work',
  '10:00'::time,
  '23:00'::time,
  '[{"start":"10:00","end":"15:00"},{"start":"18:00","end":"23:00"}]'::jsonb,
  '2020-01-01'::date
FROM (VALUES
  ('a4600000-0000-0000-0000-000000000002'::uuid),
  ('a4600000-0000-0000-0000-000000000003'::uuid)
) AS g(id)
CROSS JOIN generate_series(0, 6) AS d(dow)
ON CONFLICT DO NOTHING;

-- Assign calendar groups
UPDATE data.employees SET calendar_group_id = 'a4600000-0000-0000-0000-000000000001'
WHERE id IN (
  'a4000000-0000-0000-0000-000000000021',
  'a4000000-0000-0000-0000-000000000022',
  'a4000000-0000-0000-0000-000000000023'
);

UPDATE data.employees SET calendar_group_id = 'a4600000-0000-0000-0000-000000000002'
WHERE site_id = 'a3000000-0000-0000-0000-000000000001';

UPDATE data.employees SET calendar_group_id = 'a4600000-0000-0000-0000-000000000003'
WHERE site_id = 'a3000000-0000-0000-0000-000000000002';

-- Overrides individuals: estudiants (caps de setmana / vespre)
INSERT INTO data.employee_weekly_intervals (
  tenant_id, employee_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
SELECT
  'a1000000-0000-0000-0000-000000000001',
  e.id,
  d.dow,
  CASE WHEN d.dow IN (5, 6, 0) THEN 'work' ELSE 'non_working' END,
  CASE WHEN d.dow IN (5, 6, 0) THEN '18:00'::time ELSE NULL END,
  CASE WHEN d.dow IN (5, 6, 0) THEN '23:00'::time ELSE NULL END,
  CASE WHEN d.dow IN (5, 6, 0)
    THEN '[{"start":"18:00","end":"23:00"}]'::jsonb
    ELSE NULL END,
  '2026-01-01'::date
FROM (VALUES
  ('a4000000-0000-0000-0000-000000000009'::uuid),
  ('a4000000-0000-0000-0000-000000000019'::uuid)
) AS e(id)
CROSS JOIN generate_series(0, 6) AS d(dow)
ON CONFLICT DO NOTHING;

-- Cap torn tarda: només tarda/sopar
INSERT INTO data.employee_weekly_intervals (
  tenant_id, employee_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
SELECT
  'a1000000-0000-0000-0000-000000000001',
  e.id,
  d.dow,
  'work',
  '15:30'::time,
  '23:30'::time,
  '[{"start":"15:30","end":"23:30"}]'::jsonb,
  '2026-01-01'::date
FROM (VALUES
  ('a4000000-0000-0000-0000-000000000003'::uuid),
  ('a4000000-0000-0000-0000-000000000013'::uuid)
) AS e(id)
CROSS JOIN generate_series(0, 6) AS d(dow)
ON CONFLICT DO NOTHING;

-- Festius Catalunya 2026
INSERT INTO data.holiday_calendars (id, tenant_id, name, country_code, region_code, year, is_active)
VALUES (
  'a4700000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001',
  'Festius Catalunya BurgerVista 2026',
  'ES', 'ES-CAT', 2026, true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.holidays (calendar_id, date, name, holiday_type)
VALUES
  ('a4700000-0000-0000-0000-000000000001', '2026-01-01', 'Cap d''Any', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-01-06', 'Reis', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-04-03', 'Divendres Sant', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-04-06', 'Dilluns de Pasqua', 'regional'),
  ('a4700000-0000-0000-0000-000000000001', '2026-05-01', 'Festa del Treball', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-06-24', 'Sant Joan', 'regional'),
  ('a4700000-0000-0000-0000-000000000001', '2026-09-11', 'Diada Nacional de Catalunya', 'regional'),
  ('a4700000-0000-0000-0000-000000000001', '2026-10-12', 'Festa Nacional d''Espanya', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-11-01', 'Tots Sants', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-12-06', 'Dia de la Constitució', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-12-08', 'Immaculada Concepció', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-12-25', 'Nadal', 'national'),
  ('a4700000-0000-0000-0000-000000000001', '2026-12-26', 'Sant Esteve', 'regional')
ON CONFLICT (calendar_id, date) DO NOTHING;

INSERT INTO data.tenant_holiday_calendar_assignments (tenant_id, calendar_id, priority)
VALUES ('a1000000-0000-0000-0000-000000000001', 'a4700000-0000-0000-0000-000000000001', 10)
ON CONFLICT DO NOTHING;

INSERT INTO data.site_holiday_calendar_assignments (site_id, calendar_id, priority)
VALUES
  ('a3000000-0000-0000-0000-000000000001', 'a4700000-0000-0000-0000-000000000001', 10),
  ('a3000000-0000-0000-0000-000000000002', 'a4700000-0000-0000-0000-000000000001', 10)
ON CONFLICT DO NOTHING;

-- >>> END 03_calendars_pauses_holidays.sql <<<

-- >>> BEGIN 04_locations_stations.sql <<<
-- =============================================================================
-- 04 — Locations (zones), stations, ALA per especialitat
-- Expedició/domicili prioritari; DT residual només Diagonal
-- =============================================================================

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status, geo_coordinates, metadata)
VALUES
  -- Eixample (~41.391, 2.165)
  ('a5000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Cuina', 'zone', 'active',
   '{"lat":41.3912,"lng":2.1651}'::jsonb, '{"channel":"kitchen"}'::jsonb),
  ('a5000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Mostrador / recollida', 'zone', 'active',
   '{"lat":41.3912,"lng":2.1651}'::jsonb, '{"channel":"counter"}'::jsonb),
  ('a5000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Sala', 'zone', 'active',
   '{"lat":41.3912,"lng":2.1651}'::jsonb, '{"channel":"dine_in"}'::jsonb),
  ('a5000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Expedició / domicili', 'zone', 'active',
   '{"lat":41.3912,"lng":2.1651}'::jsonb, '{"channel":"delivery","note":"capa laboral; sense integració Glovo"}'::jsonb),
  ('a5000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Magatzem', 'room', 'active',
   NULL, '{"channel":"storage"}'::jsonb),
  -- Diagonal (~41.396, 2.140)
  ('a5000000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Cuina', 'zone', 'active',
   '{"lat":41.3965,"lng":2.1402}'::jsonb, '{"channel":"kitchen"}'::jsonb),
  ('a5000000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Mostrador / recollida', 'zone', 'active',
   '{"lat":41.3965,"lng":2.1402}'::jsonb, '{"channel":"counter"}'::jsonb),
  ('a5000000-0000-0000-0000-000000000013', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Sala', 'zone', 'active',
   '{"lat":41.3965,"lng":2.1402}'::jsonb, '{"channel":"dine_in"}'::jsonb),
  ('a5000000-0000-0000-0000-000000000014', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Expedició / domicili', 'zone', 'active',
   '{"lat":41.3965,"lng":2.1402}'::jsonb, '{"channel":"delivery"}'::jsonb),
  ('a5000000-0000-0000-0000-000000000015', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Magatzem', 'room', 'active',
   NULL, '{"channel":"storage"}'::jsonb),
  ('a5000000-0000-0000-0000-000000000016', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Servei amb auto', 'outdoor', 'active',
   '{"lat":41.3966,"lng":2.1398}'::jsonb,
   '{"channel":"drive_thru","note":"simulat; enum locations sense drive_thru"}'::jsonb)
ON CONFLICT (id) DO NOTHING;

-- Estacions de fitxatge (1 per local, al mostrador)
INSERT INTO data.attendance_devices (
  id, tenant_id, site_id, location_id, name, type, status,
  device_public_id, device_secret_hash, local_pin_hash, allowed_methods
)
VALUES
  (
    'a5100000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000001',
    'a5000000-0000-0000-0000-000000000002',
    'Estació Eixample',
    'station',
    'active',
    'bv-eixample-station-01',
    data.hash_attendance_device_secret('bv-eixample-secret-dev'),
    data.hash_attendance_station_pin('4321'),
    ARRAY['qr', 'manual']
  ),
  (
    'a5100000-0000-0000-0000-000000000002',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000002',
    'a5000000-0000-0000-0000-000000000012',
    'Estació Diagonal',
    'station',
    'active',
    'bv-diagonal-station-01',
    data.hash_attendance_device_secret('bv-diagonal-secret-dev'),
    data.hash_attendance_station_pin('4321'),
    ARRAY['qr', 'manual']
  )
ON CONFLICT (id) DO NOTHING;

-- ALA: zona principal per especialitat
INSERT INTO data.attendance_location_assignments (id, tenant_id, employee_id, location_id, starts_on)
VALUES
  -- Eixample
  ('a5200000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000002', 'a5000000-0000-0000-0000-000000000002', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000003', 'a5000000-0000-0000-0000-000000000002', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000004', 'a5000000-0000-0000-0000-000000000001', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000005', 'a5000000-0000-0000-0000-000000000001', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000006', 'a5000000-0000-0000-0000-000000000002', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000007', 'a5000000-0000-0000-0000-000000000004', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000008', 'a5000000-0000-0000-0000-000000000003', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000009', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000009', 'a5000000-0000-0000-0000-000000000002', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000010', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000010', 'a5000000-0000-0000-0000-000000000001', '2026-01-01'),
  -- Diagonal
  ('a5200000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000011', 'a5000000-0000-0000-0000-000000000012', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000012', 'a5000000-0000-0000-0000-000000000012', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000013', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000013', 'a5000000-0000-0000-0000-000000000012', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000014', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000014', 'a5000000-0000-0000-0000-000000000011', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000015', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000015', 'a5000000-0000-0000-0000-000000000011', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000016', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000016', 'a5000000-0000-0000-0000-000000000012', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000017', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000017', 'a5000000-0000-0000-0000-000000000014', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000018', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000018', 'a5000000-0000-0000-0000-000000000016', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000019', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000019', 'a5000000-0000-0000-0000-000000000012', '2026-01-01'),
  ('a5200000-0000-0000-0000-000000000020', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000020', 'a5000000-0000-0000-0000-000000000011', '2026-01-01')
ON CONFLICT (id) DO NOTHING;

-- >>> END 04_locations_stations.sql <<<

-- >>> BEGIN 05_shifts_planning.sql <<<
-- =============================================================================
-- 05 — Torns Obertura→Tancament, coverage pic domicili, slots 2 setmanes
-- =============================================================================

-- Plantilles de torn per seu
INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, default_location_id, is_active)
VALUES
  -- Eixample
  ('a6000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Obertura', '#64748b', '06:30', '10:00',
   'a5000000-0000-0000-0000-000000000001', true),
  ('a6000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Esmorzar', '#94a3b8', '08:00', '12:00',
   'a5000000-0000-0000-0000-000000000002', true),
  ('a6000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Dinar', '#f97316', '11:30', '16:00',
   'a5000000-0000-0000-0000-000000000001', true),
  ('a6000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Tarda', '#eab308', '15:30', '19:00',
   'a5000000-0000-0000-0000-000000000002', true),
  ('a6000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Sopar', '#0ea5e9', '18:30', '23:00',
   'a5000000-0000-0000-0000-000000000004', true),
  ('a6000000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Tancament', '#334155', '22:00', '00:30',
   'a5000000-0000-0000-0000-000000000001', true),
  -- Diagonal
  ('a6000000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Obertura', '#64748b', '06:30', '10:00',
   'a5000000-0000-0000-0000-000000000011', true),
  ('a6000000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Esmorzar', '#94a3b8', '08:00', '12:00',
   'a5000000-0000-0000-0000-000000000012', true),
  ('a6000000-0000-0000-0000-000000000013', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Dinar', '#f97316', '11:30', '16:00',
   'a5000000-0000-0000-0000-000000000011', true),
  ('a6000000-0000-0000-0000-000000000014', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Tarda', '#eab308', '15:30', '19:00',
   'a5000000-0000-0000-0000-000000000012', true),
  ('a6000000-0000-0000-0000-000000000015', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Sopar', '#0ea5e9', '18:30', '23:00',
   'a5000000-0000-0000-0000-000000000014', true),
  ('a6000000-0000-0000-0000-000000000016', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Tancament', '#334155', '22:00', '00:30',
   'a5000000-0000-0000-0000-000000000011', true)
ON CONFLICT (id) DO NOTHING;

-- Coverage: sopar + cap de setmana — cuina + expedició (pic domicili)
INSERT INTO data.coverage_demands (
  id, tenant_id, site_id, role_id, kind, day_of_week, demand_date,
  start_time, end_time, required_min, required_target, required_max,
  priority, source, name, effective_from, is_active
)
SELECT
  ('a6100000-0000-0000-0000-' || lpad(to_hex(1000 + row_number() OVER ()), 12, '0'))::uuid,
  'a1000000-0000-0000-0000-000000000001',
  s.site_id,
  r.role_id,
  'recurring',
  d.dow,
  NULL,
  '18:30'::time,
  '23:00'::time,
  r.rmin, r.rtarget, r.rmax,
  80,
  'manual',
  'Pic sopar / domicili — ' || r.rname,
  '2026-01-01'::date,
  true
FROM (VALUES
  ('a3000000-0000-0000-0000-000000000001'::uuid),
  ('a3000000-0000-0000-0000-000000000002'::uuid)
) AS s(site_id)
CROSS JOIN (VALUES
  ('a4900000-0000-0000-0000-000000000003'::uuid, 'cuina', 1, 2, 3),
  ('a4900000-0000-0000-0000-000000000005'::uuid, 'expedicio', 1, 1, 2)
) AS r(role_id, rname, rmin, rtarget, rmax)
CROSS JOIN (VALUES (5), (6), (0), (1), (2), (3), (4)) AS d(dow)
ON CONFLICT DO NOTHING;

-- Slots published: 2 setmanes ISO (dilluns actual ±)
DO $$
DECLARE
  v_monday date := date_trunc('week', (now() AT TIME ZONE 'Europe/Madrid')::date)::date;
  -- PG date_trunc('week') = Monday when DateStyle ISO
  v_d date;
  v_i int;
  v_seq int := 0;
  v_slot_id uuid;
BEGIN
  FOR v_i IN 0..13 LOOP
    v_d := v_monday + v_i;

    -- Eixample: director obertura (dl–dv), cap matí dinar, cap tarda sopar, cuina+expedició sopar
    IF EXTRACT(DOW FROM v_d) BETWEEN 1 AND 5 THEN
      v_seq := v_seq + 1;
      v_slot_id := ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid;
      INSERT INTO data.shift_slots (
        id, tenant_id, site_id, shift_id, employee_id, slot_date,
        start_time, end_time, location_id, role_id, status
      ) VALUES (
        v_slot_id, 'a1000000-0000-0000-0000-000000000001',
        'a3000000-0000-0000-0000-000000000001',
        'a6000000-0000-0000-0000-000000000001',
        'a4000000-0000-0000-0000-000000000001', v_d,
        '06:30', '10:00', 'a5000000-0000-0000-0000-000000000001',
        'a4900000-0000-0000-0000-000000000001', 'published'
      ) ON CONFLICT DO NOTHING;
    END IF;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000001',
      'a6000000-0000-0000-0000-000000000003',
      'a4000000-0000-0000-0000-000000000002', v_d,
      '11:30', '16:00', 'a5000000-0000-0000-0000-000000000002',
      'a4900000-0000-0000-0000-000000000002', 'published'
    ) ON CONFLICT DO NOTHING;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000001',
      'a6000000-0000-0000-0000-000000000005',
      'a4000000-0000-0000-0000-000000000003', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000002',
      'a4900000-0000-0000-0000-000000000002', 'published'
    ) ON CONFLICT DO NOTHING;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000001',
      'a6000000-0000-0000-0000-000000000005',
      'a4000000-0000-0000-0000-000000000004', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000001',
      'a4900000-0000-0000-0000-000000000003', 'published'
    ) ON CONFLICT DO NOTHING;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000001',
      'a6000000-0000-0000-0000-000000000005',
      'a4000000-0000-0000-0000-000000000007', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000004',
      'a4900000-0000-0000-0000-000000000005', 'published'
    ) ON CONFLICT DO NOTHING;

    -- Diagonal mirror (director + cap + cuina + expedició + DT al sopar)
    IF EXTRACT(DOW FROM v_d) BETWEEN 1 AND 5 THEN
      v_seq := v_seq + 1;
      INSERT INTO data.shift_slots (
        id, tenant_id, site_id, shift_id, employee_id, slot_date,
        start_time, end_time, location_id, role_id, status
      ) VALUES (
        ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
        'a1000000-0000-0000-0000-000000000001',
        'a3000000-0000-0000-0000-000000000002',
        'a6000000-0000-0000-0000-000000000011',
        'a4000000-0000-0000-0000-000000000011', v_d,
        '06:30', '10:00', 'a5000000-0000-0000-0000-000000000011',
        'a4900000-0000-0000-0000-000000000001', 'published'
      ) ON CONFLICT DO NOTHING;
    END IF;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000002',
      'a6000000-0000-0000-0000-000000000015',
      'a4000000-0000-0000-0000-000000000013', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000012',
      'a4900000-0000-0000-0000-000000000002', 'published'
    ) ON CONFLICT DO NOTHING;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000002',
      'a6000000-0000-0000-0000-000000000015',
      'a4000000-0000-0000-0000-000000000017', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000014',
      'a4900000-0000-0000-0000-000000000005', 'published'
    ) ON CONFLICT DO NOTHING;

    v_seq := v_seq + 1;
    INSERT INTO data.shift_slots (
      id, tenant_id, site_id, shift_id, employee_id, slot_date,
      start_time, end_time, location_id, role_id, status
    ) VALUES (
      ('a6200000-0000-4000-8000-' || lpad(to_hex(v_seq), 12, '0'))::uuid,
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000002',
      'a6000000-0000-0000-0000-000000000015',
      'a4000000-0000-0000-0000-000000000018', v_d,
      '18:30', '23:00', 'a5000000-0000-0000-0000-000000000016',
      'a4900000-0000-0000-0000-000000000007', 'published'
    ) ON CONFLICT DO NOTHING;
  END LOOP;
END $$;

-- Opening mostra (Eixample sopar expedició)
INSERT INTO data.shift_openings (
  id, tenant_id, site_id, location_id, role_id, shift_id, opening_date,
  start_time, end_time, places_total, places_filled, claim_policy, status, title
)
VALUES (
  'a6300000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001',
  'a3000000-0000-0000-0000-000000000001',
  'a5000000-0000-0000-0000-000000000004',
  'a4900000-0000-0000-0000-000000000005',
  'a6000000-0000-0000-0000-000000000005',
  (date_trunc('week', (now() AT TIME ZONE 'Europe/Madrid')::date)::date + 5),
  '18:30', '23:00', 1, 0, 'manager_approval', 'open',
  'Reforç expedició divendres (pic apps)'
)
ON CONFLICT (id) DO NOTHING;

-- >>> END 05_shifts_planning.sql <<<

-- >>> BEGIN 06_absences.sql <<<
-- =============================================================================
-- 06 — Vacances / absències 2026
-- =============================================================================

INSERT INTO data.vacation_entitlements (
  tenant_id, scope, department_id, employee_id, year, leave_type, days_allocated, days_used
)
VALUES (
  'a1000000-0000-0000-0000-000000000001',
  'tenant', NULL, NULL, 2026, 'vacation', 30, 0
)
ON CONFLICT DO NOTHING;

INSERT INTO data.employee_absences (
  id, tenant_id, site_id, employee_id, absence_type, start_date, end_date, status, is_paid, notes
)
VALUES
  (
    'a6400000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000001',
    'a4000000-0000-0000-0000-000000000004',
    'vacation', '2026-03-10', '2026-03-16', 'approved', true,
    'Vacances primavera cuina Eixample'
  ),
  (
    'a6400000-0000-0000-0000-000000000002',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000001',
    'a4000000-0000-0000-0000-000000000006',
    'sick_leave', '2026-05-12', '2026-05-13', 'approved', true,
    'Baixa curta'
  ),
  (
    'a6400000-0000-0000-0000-000000000003',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000002',
    'a4000000-0000-0000-0000-000000000017',
    'vacation', '2026-08-01', '2026-08-15', 'requested', true,
    'Vacances estiu expedició — pendent'
  ),
  (
    'a6400000-0000-0000-0000-000000000004',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000002',
    'a4000000-0000-0000-0000-000000000014',
    'personal', '2026-06-18', '2026-06-18', 'approved', false,
    'Assumptes propis'
  ),
  (
    'a6400000-0000-0000-0000-000000000005',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000001',
    'a4000000-0000-0000-0000-000000000009',
    'vacation', '2026-07-20', '2026-07-26', 'approved', true,
    'Vacances estudiant'
  )
ON CONFLICT (id) DO NOTHING;

-- >>> END 06_absences.sql <<<

-- >>> BEGIN 07_attendance_punches.sql <<<
-- =============================================================================
-- 07 — Fitxatges YTD mostrejats (caps 100%, crew ~40%)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.seed_burgervista_attendance_punches()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id   uuid := 'a1000000-0000-0000-0000-000000000001';
  v_tz          text := 'Europe/Madrid';
  v_today       date := (now() AT TIME ZONE v_tz)::date;
  v_year_start  date := date_trunc('year', v_today)::date;
  v_day         date;
  v_emp         record;
  v_labor       record;
  v_hash        int;
  v_scenario    int;
  v_margin_in   int;
  v_margin_out  int;
  v_now         timestamptz := now();
  v_geo         jsonb;
  v_punch_seq   bigint := 0;
  v_punch_id    uuid;
  v_client_op   uuid;
  v_ts          timestamptz;
  v_first_start time;
  v_first_end   time;
  v_last_start  time;
  v_last_end    time;
  v_has_split   boolean;
  v_skip_day    boolean;
  v_missing_out boolean;
  v_open_break  boolean;
  v_do_break    boolean;
  v_days_done   int := 0;
  v_punches     int := 0;
  v_recomputes  int := 0;
  v_iv_count    int;
  v_is_lead     boolean;
  v_sample_ok   boolean;
BEGIN
  DELETE FROM data.time_daily_summaries
  WHERE tenant_id = v_tenant_id AND work_date >= v_year_start AND work_date <= v_today;
  DELETE FROM data.time_entries
  WHERE tenant_id = v_tenant_id AND work_date >= v_year_start AND work_date <= v_today;
  DELETE FROM data.time_punches
  WHERE tenant_id = v_tenant_id
    AND (occurred_at AT TIME ZONE v_tz)::date >= v_year_start
    AND (occurred_at AT TIME ZONE v_tz)::date <= v_today;

  FOR v_emp IN
    SELECT e.id, e.site_id, e.full_name,
           EXISTS (
             SELECT 1 FROM data.employee_role_assignments a
             WHERE a.employee_id = e.id AND a.is_active
               AND a.role_id IN (
                 'a4900000-0000-0000-0000-000000000001',
                 'a4900000-0000-0000-0000-000000000002'
               )
           ) AS is_lead
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id
      AND e.status = 'active'
      AND e.site_id IS NOT NULL
    ORDER BY e.id
  LOOP
    v_is_lead := v_emp.is_lead;
    v_geo := CASE v_emp.site_id
      WHEN 'a3000000-0000-0000-0000-000000000001'
        THEN '{"latitude":41.39120,"longitude":2.16510,"accuracy_meters":15}'::jsonb
      ELSE '{"latitude":41.39650,"longitude":2.14020,"accuracy_meters":15}'::jsonb
    END;

    v_day := v_year_start;
    WHILE v_day <= v_today LOOP
      v_hash := abs(hashtext(v_emp.id::text || v_day::text));
      v_scenario := v_hash % 100;
      v_margin_in  := v_hash % 21;
      v_margin_out := (v_hash / 21) % 21;
      IF (v_hash / 441) % 2 = 1 THEN v_margin_in  := -v_margin_in;  END IF;
      IF (v_hash / 882) % 2 = 1 THEN v_margin_out := -v_margin_out; END IF;

      -- Mostreig: leads 100%; crew ~40%
      v_sample_ok := v_is_lead OR (v_hash % 100 < 40);

      v_skip_day    := NOT v_sample_ok;
      v_missing_out := false;
      v_open_break  := false;

      IF v_sample_ok THEN
        IF v_emp.id = 'a4000000-0000-0000-0000-000000000004' AND v_day = v_today - 1 THEN
          v_open_break := true;
        ELSIF v_emp.id = 'a4000000-0000-0000-0000-000000000007' AND v_day = v_today - 2 THEN
          v_missing_out := true;
        ELSIF v_scenario < 3 THEN
          v_skip_day := true;
        ELSIF v_scenario BETWEEN 3 AND 4 THEN
          v_missing_out := true;
        ELSIF v_scenario = 5 THEN
          v_open_break := true;
        END IF;
      END IF;

      SELECT * INTO v_labor
      FROM data.resolve_labor_calendar_for_employee(
        v_tenant_id, v_emp.site_id, v_emp.id, v_day, false
      );

      IF v_labor.labor_day_type IS DISTINCT FROM 'work'
         OR v_labor.work_intervals IS NULL
         OR jsonb_typeof(v_labor.work_intervals) <> 'array'
         OR jsonb_array_length(v_labor.work_intervals) = 0 THEN
        v_skip_day := true;
      END IF;

      IF NOT v_skip_day THEN
        v_iv_count := jsonb_array_length(v_labor.work_intervals);
        v_first_start := (split_part(v_labor.work_intervals->0->>'start', ':', 1)
                          || ':' || split_part(v_labor.work_intervals->0->>'start', ':', 2))::time;
        v_first_end   := (split_part(v_labor.work_intervals->0->>'end', ':', 1)
                          || ':' || split_part(v_labor.work_intervals->0->>'end', ':', 2))::time;

        IF v_iv_count > 1 THEN
          v_last_start := (split_part(v_labor.work_intervals->(v_iv_count - 1)->>'start', ':', 1)
                           || ':' || split_part(v_labor.work_intervals->(v_iv_count - 1)->>'start', ':', 2))::time;
          v_last_end   := (split_part(v_labor.work_intervals->(v_iv_count - 1)->>'end', ':', 1)
                           || ':' || split_part(v_labor.work_intervals->(v_iv_count - 1)->>'end', ':', 2))::time;
        ELSE
          v_last_start := v_first_start;
          v_last_end   := v_first_end;
        END IF;
        v_has_split := v_iv_count > 1;

        v_ts := timezone(v_tz, v_day + v_first_start + (v_margin_in || ' minutes')::interval);
        IF v_day <> v_today OR v_ts <= v_now THEN
          v_punch_seq := v_punch_seq + 1;
          v_punch_id  := ('a6500000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
          v_client_op := ('a6600000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
          INSERT INTO data.time_punches (
            id, tenant_id, site_id, employee_id, client_op_id, punch_type,
            occurred_at, received_at, geo, location_permission, source
          ) VALUES (
            v_punch_id, v_tenant_id, v_emp.site_id, v_emp.id, v_client_op, 'in',
            v_ts, v_ts + interval '2 seconds', v_geo, 'granted', 'mobile'
          );
          v_punches := v_punches + 1;

          v_do_break := v_has_split OR (v_hash % 4 = 0 AND NOT v_open_break);
          IF v_do_break AND NOT v_open_break THEN
            IF v_has_split THEN
              v_ts := timezone(v_tz, v_day + v_first_end - interval '2 minutes');
            ELSE
              v_ts := timezone(v_tz, v_day + time '14:00' + ((v_hash % 15) || ' minutes')::interval);
            END IF;
            IF v_day <> v_today OR v_ts <= v_now THEN
              v_punch_seq := v_punch_seq + 1;
              v_punch_id  := ('a6500000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              v_client_op := ('a6600000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              INSERT INTO data.time_punches (
                id, tenant_id, site_id, employee_id, client_op_id, punch_type,
                occurred_at, received_at, geo, location_permission, source
              ) VALUES (
                v_punch_id, v_tenant_id, v_emp.site_id, v_emp.id, v_client_op, 'break_start',
                v_ts, v_ts + interval '2 seconds', v_geo, 'granted', 'mobile'
              );
              v_punches := v_punches + 1;

              IF v_has_split THEN
                v_ts := timezone(v_tz, v_day + v_last_start + interval '3 minutes');
              ELSE
                v_ts := v_ts + interval '20 minutes';
              END IF;
              IF v_day <> v_today OR v_ts <= v_now THEN
                v_punch_seq := v_punch_seq + 1;
                v_punch_id  := ('a6500000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
                v_client_op := ('a6600000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
                INSERT INTO data.time_punches (
                  id, tenant_id, site_id, employee_id, client_op_id, punch_type,
                  occurred_at, received_at, geo, location_permission, source
                ) VALUES (
                  v_punch_id, v_tenant_id, v_emp.site_id, v_emp.id, v_client_op, 'break_end',
                  v_ts, v_ts + interval '2 seconds', v_geo, 'granted', 'mobile'
                );
                v_punches := v_punches + 1;
              END IF;
            END IF;
          ELSIF v_open_break THEN
            v_ts := timezone(v_tz, v_day + COALESCE(v_first_end, time '14:00') - interval '2 minutes');
            IF v_day <> v_today OR v_ts <= v_now THEN
              v_punch_seq := v_punch_seq + 1;
              v_punch_id  := ('a6500000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              v_client_op := ('a6600000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              INSERT INTO data.time_punches (
                id, tenant_id, site_id, employee_id, client_op_id, punch_type,
                occurred_at, received_at, geo, location_permission, source
              ) VALUES (
                v_punch_id, v_tenant_id, v_emp.site_id, v_emp.id, v_client_op, 'break_start',
                v_ts, v_ts + interval '2 seconds', v_geo, 'granted', 'mobile'
              );
              v_punches := v_punches + 1;
            END IF;
          END IF;

          IF NOT v_missing_out THEN
            v_ts := timezone(v_tz, v_day + v_last_end + (v_margin_out || ' minutes')::interval);
            IF v_day <> v_today OR v_ts <= v_now THEN
              v_punch_seq := v_punch_seq + 1;
              v_punch_id  := ('a6500000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              v_client_op := ('a6600000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              INSERT INTO data.time_punches (
                id, tenant_id, site_id, employee_id, client_op_id, punch_type,
                occurred_at, received_at, geo, location_permission, source
              ) VALUES (
                v_punch_id, v_tenant_id, v_emp.site_id, v_emp.id, v_client_op, 'out',
                v_ts, v_ts + interval '2 seconds', v_geo, 'granted', 'mobile'
              );
              v_punches := v_punches + 1;
            END IF;
          END IF;

          v_days_done := v_days_done + 1;
        END IF;
      END IF;

      v_day := v_day + 1;
    END LOOP;
  END LOOP;

  WITH day_agg AS (
    SELECT
      tp.employee_id,
      (tp.occurred_at AT TIME ZONE v_tz)::date AS work_date,
      e.tenant_id,
      e.site_id,
      COUNT(*)::int AS punch_count,
      COUNT(*) FILTER (WHERE tp.punch_type = 'in')::int AS in_c,
      COUNT(*) FILTER (WHERE tp.punch_type = 'out')::int AS out_c,
      COUNT(*) FILTER (WHERE tp.punch_type = 'break_start')::int AS bs_c,
      COUNT(*) FILTER (WHERE tp.punch_type = 'break_end')::int AS be_c,
      MIN(tp.occurred_at) FILTER (WHERE tp.punch_type = 'in') AS first_in_at,
      MAX(tp.occurred_at) FILTER (WHERE tp.punch_type = 'out') AS last_out_at
    FROM data.time_punches tp
    JOIN data.employees e ON e.id = tp.employee_id
    WHERE tp.tenant_id = v_tenant_id
      AND (tp.occurred_at AT TIME ZONE v_tz)::date BETWEEN v_year_start AND v_today
    GROUP BY tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date, e.tenant_id, e.site_id
  ),
  first_in AS (
    SELECT DISTINCT ON (tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date)
      tp.employee_id,
      (tp.occurred_at AT TIME ZONE v_tz)::date AS work_date,
      tp.id AS punch_in_id
    FROM data.time_punches tp
    WHERE tp.tenant_id = v_tenant_id AND tp.punch_type = 'in'
      AND (tp.occurred_at AT TIME ZONE v_tz)::date BETWEEN v_year_start AND v_today
    ORDER BY tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date, tp.occurred_at ASC
  ),
  last_out AS (
    SELECT DISTINCT ON (tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date)
      tp.employee_id,
      (tp.occurred_at AT TIME ZONE v_tz)::date AS work_date,
      tp.id AS punch_out_id
    FROM data.time_punches tp
    WHERE tp.tenant_id = v_tenant_id AND tp.punch_type = 'out'
      AND (tp.occurred_at AT TIME ZONE v_tz)::date BETWEEN v_year_start AND v_today
    ORDER BY tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date, tp.occurred_at DESC
  ),
  computed AS (
    SELECT
      da.*,
      fi.punch_in_id,
      lo.punch_out_id,
      CASE
        WHEN da.first_in_at IS NOT NULL AND da.last_out_at IS NOT NULL
          THEN ROUND(EXTRACT(EPOCH FROM (da.last_out_at - da.first_in_at)) / 60)::int
        ELSE NULL
      END AS gross_min,
      CASE
        WHEN da.first_in_at IS NOT NULL AND da.last_out_at IS NOT NULL THEN 'closed'
        WHEN da.first_in_at IS NOT NULL THEN 'open'
        WHEN da.punch_count = 0 THEN 'missing'
        ELSE 'open'
      END AS entry_status,
      ARRAY_REMOVE(ARRAY[
        CASE WHEN da.punch_count > 0 AND da.in_c = 0 THEN 'MISSING_IN' END,
        CASE WHEN da.in_c > da.out_c AND da.out_c > 0 THEN 'EXTRA_IN' END,
        CASE WHEN da.out_c > da.in_c THEN 'EXTRA_OUT' END,
        CASE WHEN da.bs_c != da.be_c THEN 'BREAK_MISMATCH' END
      ], NULL) AS anomaly_codes
    FROM day_agg da
    LEFT JOIN first_in fi ON fi.employee_id = da.employee_id AND fi.work_date = da.work_date
    LEFT JOIN last_out lo ON lo.employee_id = da.employee_id AND lo.work_date = da.work_date
  ),
  upsert_entries AS (
    INSERT INTO data.time_entries (
      tenant_id, site_id, employee_id, work_date,
      starts_at, ends_at, punch_in_id, punch_out_id,
      gross_minutes, break_minutes, net_minutes,
      regular_minutes, overtime_minutes, status, updated_at
    )
    SELECT
      c.tenant_id, c.site_id, c.employee_id, c.work_date,
      c.first_in_at, c.last_out_at, c.punch_in_id, c.punch_out_id,
      c.gross_min, 0,
      CASE WHEN c.gross_min IS NOT NULL THEN c.gross_min ELSE NULL END,
      CASE WHEN c.gross_min IS NOT NULL THEN c.gross_min ELSE NULL END,
      0, c.entry_status, now()
    FROM computed c
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      starts_at = EXCLUDED.starts_at,
      ends_at = EXCLUDED.ends_at,
      punch_in_id = EXCLUDED.punch_in_id,
      punch_out_id = EXCLUDED.punch_out_id,
      gross_minutes = EXCLUDED.gross_minutes,
      net_minutes = EXCLUDED.net_minutes,
      regular_minutes = EXCLUDED.regular_minutes,
      status = EXCLUDED.status,
      updated_at = EXCLUDED.updated_at
    WHERE data.time_entries.status != 'adjusted'
    RETURNING 1
  ),
  upsert_summaries AS (
    INSERT INTO data.time_daily_summaries (
      tenant_id, site_id, employee_id, work_date,
      day_type, expected_minutes, worked_minutes, break_minutes,
      overtime_minutes, absence_minutes, punch_count,
      anomaly_codes, needs_review, recomputed_at, updated_at
    )
    SELECT
      c.tenant_id, c.site_id, c.employee_id, c.work_date,
      CASE COALESCE(r.resolve->>'day_type', 'unknown')
        WHEN 'working' THEN 'work'
        WHEN 'half_holiday' THEN 'holiday'
        WHEN 'non_working' THEN 'weekend'
        ELSE COALESCE(r.resolve->>'day_type', 'unknown')
      END,
      COALESCE((r.resolve->>'expected_minutes')::int, 0),
      COALESCE(c.gross_min, 0),
      0, 0, 0, c.punch_count,
      c.anomaly_codes,
      (cardinality(c.anomaly_codes) > 0 OR c.entry_status IN ('missing', 'open')),
      now(), now()
    FROM computed c
    CROSS JOIN LATERAL (
      SELECT api.resolve_work_day(c.employee_id, c.work_date) AS resolve
    ) r
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      day_type = EXCLUDED.day_type,
      expected_minutes = EXCLUDED.expected_minutes,
      worked_minutes = EXCLUDED.worked_minutes,
      punch_count = EXCLUDED.punch_count,
      anomaly_codes = EXCLUDED.anomaly_codes,
      needs_review = EXCLUDED.needs_review,
      recomputed_at = EXCLUDED.recomputed_at,
      updated_at = EXCLUDED.updated_at
    WHERE data.time_daily_summaries.status = 'draft'
    RETURNING 1
  )
  SELECT COUNT(*)::int INTO v_recomputes FROM computed;

  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'range_from', v_year_start,
    'range_to', v_today,
    'punches', v_punches,
    'employee_days', v_days_done,
    'recomputes', v_recomputes,
    'sampling', 'leads_100_crew_40',
    'interval_source', 'labor_calendar'
  );
END;
$$;

SELECT data.seed_burgervista_attendance_punches();

-- >>> END 07_attendance_punches.sql <<<

-- >>> BEGIN 08_templates_qsr.sql <<<
-- =============================================================================
-- 08 — Plantilles tenant QSR (uniformes, formació, checklists, protocol)
-- =============================================================================

INSERT INTO data.document_templates (
  id, tenant_id, name, description, category, template_type,
  is_platform_default, is_active, created_by, target_archetypes
)
VALUES
  ('a7000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'Protocol de registre horari BurgerVista', 'Protocol intern de fitxatge per locals BurgerVista.',
   'attendance', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'Entrega d''uniforme', 'Document d''entrega d''uniforme i material al personal.',
   'hr', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'Retorn d''uniforme', 'Document de retorn d''uniforme en baixa o canvi.',
   'hr', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'Formació higiene i al·lèrgens', 'Certificat de formació obligatòria d''higiene alimentària.',
   'safety', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'Checklist d''obertura de local', 'Tasques d''obertura (cuina, mostrador, apps).',
   'operations', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'Checklist de tancament de local', 'Tasques de tancament i neteja.',
   'operations', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001',
   'Checklist expedició / tancament apps', 'Tancament de torn d''expedició (sense integrar Glovo).',
   'operations', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001',
   'Acollida nou empleat BurgerVista', 'Butlletí d''acollida primer dia.',
   'hr', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality'])
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_template_locales (
  id, template_id, locale, mime_type, storage_path, html_content,
  variables_schema, signing_roles_schema, sample_values, is_active
)
VALUES
  ('a7100000-0000-0000-0000-000000000001', 'a7000000-0000-0000-0000-000000000001', 'ca', 'text/html', NULL,
   '<h1>Protocol de registre horari — BurgerVista</h1><p>Empleat/da: {{full_name}}</p><p>Local: {{site_name}}</p><p>Cal fitxar entrada, pauses i sortida a l''estació del local o portal autoritzat.</p>',
   '{"full_name":{"type":"string"},"site_name":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Treballador/a"}}'::jsonb,
   '{"full_name":"Laura Roca","site_name":"BurgerVista Eixample"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000002', 'ca', 'text/html', NULL,
   '<h1>Entrega d''uniforme</h1><p>Jo, {{full_name}}, confirmo la recepció de: {{items}}.</p><p>Data: {{date}}</p>',
   '{"full_name":{"type":"string"},"items":{"type":"string"},"date":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Treballador/a"},"manager":{"label":"Responsable"}}'::jsonb,
   '{"full_name":"Irene Gómez","items":"2 polos, 1 davantal, 1 gorra","date":"2026-01-20"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000003', 'a7000000-0000-0000-0000-000000000003', 'ca', 'text/html', NULL,
   '<h1>Retorn d''uniforme</h1><p>{{full_name}} retorna: {{items}}.</p><p>Estat: {{condition}}</p>',
   '{"full_name":{"type":"string"},"items":{"type":"string"},"condition":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Treballador/a"},"manager":{"label":"Responsable"}}'::jsonb,
   '{"full_name":"Exemple","items":"1 polo","condition":"Bo"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000004', 'a7000000-0000-0000-0000-000000000004', 'ca', 'text/html', NULL,
   '<h1>Formació higiene i al·lèrgens</h1><p>{{full_name}} ha completat la formació el {{date}}.</p><ul><li>Higiene de mans</li><li>Temperatures</li><li>Al·lèrgens</li></ul>',
   '{"full_name":{"type":"string"},"date":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Treballador/a"}}'::jsonb,
   '{"full_name":"Marc Vidal","date":"2026-01-15"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000005', 'a7000000-0000-0000-0000-000000000005', 'ca', 'text/html', NULL,
   '<h1>Checklist d''obertura</h1><p>Local: {{site_name}} — Cap de torn: {{full_name}}</p><ol><li>Encesa equips cuina</li><li>Revisió neveres</li><li>Caixa / TPV</li><li>Apps delivery en línia (Partner)</li><li>Zona expedició preparada</li></ol>',
   '{"site_name":{"type":"string"},"full_name":{"type":"string"}}'::jsonb,
   '{"manager":{"label":"Cap de torn"}}'::jsonb,
   '{"site_name":"BurgerVista Eixample","full_name":"Pau Soler"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000006', 'a7000000-0000-0000-0000-000000000006', 'ca', 'text/html', NULL,
   '<h1>Checklist de tancament</h1><p>Local: {{site_name}} — {{full_name}}</p><ol><li>Neteja cuina</li><li>Tancament caixa</li><li>Residus</li><li>Alarmes</li></ol>',
   '{"site_name":{"type":"string"},"full_name":{"type":"string"}}'::jsonb,
   '{"manager":{"label":"Cap de torn"}}'::jsonb,
   '{"site_name":"BurgerVista Diagonal","full_name":"Joan Navarro"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000007', 'a7000000-0000-0000-0000-000000000007', 'ca', 'text/html', NULL,
   '<h1>Checklist expedició / apps</h1><p>{{full_name}} — {{site_name}}</p><p>Nota: PiMed no gestiona comandes Glovo; això és només checklist laboral.</p><ol><li>Bosses i material</li><li>Temps d''espera riders</li><li>Tancament pantalles Partner</li></ol>',
   '{"full_name":{"type":"string"},"site_name":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Expedició"}}'::jsonb,
   '{"full_name":"Irene Gómez","site_name":"BurgerVista Eixample"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000008', 'a7000000-0000-0000-0000-000000000008', 'ca', 'text/html', NULL,
   '<h1>Benvinguda a BurgerVista</h1><p>Hola {{full_name}},</p><p>Benvingut/da a l''equip. Recorda: uniforme, higiene, fitxatge i zones (cuina / mostrador / expedició).</p>',
   '{"full_name":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Nou empleat"}}'::jsonb,
   '{"full_name":"Alex Muñoz"}'::jsonb, true)
ON CONFLICT (id) DO NOTHING;

-- >>> END 08_templates_qsr.sql <<<

-- >>> BEGIN 09_documents_generated.sql <<<
-- =============================================================================
-- 09 — Documents generats des de plantilles + assignacions portal
-- =============================================================================

INSERT INTO data.documents (
  id, tenant_id, site_id, title, entity_type, entity_id, required_permissions
)
VALUES
  -- Entregues uniforme
  ('a7200000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Entrega uniforme — Irene Gómez',
   'employee', 'a4000000-0000-0000-0000-000000000007', '{}'),
  ('a7200000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Entrega uniforme — Marc Vidal',
   'employee', 'a4000000-0000-0000-0000-000000000004', '{}'),
  ('a7200000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Entrega uniforme — Oriol Font',
   'employee', 'a4000000-0000-0000-0000-000000000017', '{}'),
  ('a7200000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Entrega uniforme — Adrià Serra',
   'employee', 'a4000000-0000-0000-0000-000000000018', '{}'),
  -- Formacions
  ('a7200000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Formació higiene — Marc Vidal',
   'employee', 'a4000000-0000-0000-0000-000000000004', '{}'),
  ('a7200000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Formació higiene — Irene Gómez',
   'employee', 'a4000000-0000-0000-0000-000000000007', '{}'),
  ('a7200000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Formació higiene — Patricia Gil',
   'employee', 'a4000000-0000-0000-0000-000000000014', '{}'),
  -- Protocol (tenant-wide doc)
  ('a7200000-0000-0000-0000-000000000010', 'a1000000-0000-0000-0000-000000000001',
   NULL, 'Protocol registre horari BurgerVista 2026',
   NULL, NULL, '{}'),
  -- Checklists setmana
  ('a7200000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Checklist obertura — Eixample (setmana actual)',
   'site', 'a3000000-0000-0000-0000-000000000001', '{}'),
  ('a7200000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000002', 'Checklist tancament — Diagonal (setmana actual)',
   'site', 'a3000000-0000-0000-0000-000000000002', '{}'),
  ('a7200000-0000-0000-0000-000000000013', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Checklist expedició — Eixample',
   'site', 'a3000000-0000-0000-0000-000000000001', '{}'),
  -- Acollida
  ('a7200000-0000-0000-0000-000000000014', 'a1000000-0000-0000-0000-000000000001',
   'a3000000-0000-0000-0000-000000000001', 'Acollida — Alex Muñoz',
   'employee', 'a4000000-0000-0000-0000-000000000009', '{}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_versions (
  id, document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes, created_by
)
VALUES
  ('a7300000-0000-0000-0000-000000000001', 'a7200000-0000-0000-0000-000000000001', 1,
   'external_link', 'seed://burgervista/uniforme-irene.html', 'text/html', 1200,
   'a2000000-0000-0000-0000-000000000004'),
  ('a7300000-0000-0000-0000-000000000002', 'a7200000-0000-0000-0000-000000000002', 1,
   'external_link', 'seed://burgervista/uniforme-marc.html', 'text/html', 1100,
   'a2000000-0000-0000-0000-000000000004'),
  ('a7300000-0000-0000-0000-000000000003', 'a7200000-0000-0000-0000-000000000003', 1,
   'external_link', 'seed://burgervista/uniforme-oriol.html', 'text/html', 1100,
   'a2000000-0000-0000-0000-000000000006'),
  ('a7300000-0000-0000-0000-000000000004', 'a7200000-0000-0000-0000-000000000004', 1,
   'external_link', 'seed://burgervista/uniforme-adria.html', 'text/html', 1100,
   'a2000000-0000-0000-0000-000000000006'),
  ('a7300000-0000-0000-0000-000000000005', 'a7200000-0000-0000-0000-000000000005', 1,
   'external_link', 'seed://burgervista/formacio-marc.html', 'text/html', 900,
   'a2000000-0000-0000-0000-000000000004'),
  ('a7300000-0000-0000-0000-000000000006', 'a7200000-0000-0000-0000-000000000006', 1,
   'external_link', 'seed://burgervista/formacio-irene.html', 'text/html', 900,
   'a2000000-0000-0000-0000-000000000004'),
  ('a7300000-0000-0000-0000-000000000007', 'a7200000-0000-0000-0000-000000000007', 1,
   'external_link', 'seed://burgervista/formacio-patricia.html', 'text/html', 900,
   'a2000000-0000-0000-0000-000000000006'),
  ('a7300000-0000-0000-0000-000000000010', 'a7200000-0000-0000-0000-000000000010', 1,
   'external_link', 'seed://burgervista/protocol-horari-2026.html', 'text/html', 2000,
   'a2000000-0000-0000-0000-000000000001'),
  ('a7300000-0000-0000-0000-000000000011', 'a7200000-0000-0000-0000-000000000011', 1,
   'external_link', 'seed://burgervista/checklist-obertura-eixample.html', 'text/html', 800,
   'a2000000-0000-0000-0000-000000000005'),
  ('a7300000-0000-0000-0000-000000000012', 'a7200000-0000-0000-0000-000000000012', 1,
   'external_link', 'seed://burgervista/checklist-tancament-diagonal.html', 'text/html', 800,
   'a2000000-0000-0000-0000-000000000007'),
  ('a7300000-0000-0000-0000-000000000013', 'a7200000-0000-0000-0000-000000000013', 1,
   'external_link', 'seed://burgervista/checklist-expedicio.html', 'text/html', 700,
   'a2000000-0000-0000-0000-000000000005'),
  ('a7300000-0000-0000-0000-000000000014', 'a7200000-0000-0000-0000-000000000014', 1,
   'external_link', 'seed://burgervista/acollida-alex.html', 'text/html', 600,
   'a2000000-0000-0000-0000-000000000004')
ON CONFLICT (id) DO NOTHING;

-- Protocol assignat a empleats de local (mostra)
INSERT INTO data.employee_portal_document_assignments (
  id, tenant_id, employee_id, assignment_kind, document_version_id, published_at, published_by
)
SELECT
  ('a7400000-0000-0000-0000-' || lpad(to_hex(1000 + row_number() OVER (ORDER BY e.id)), 12, '0'))::uuid,
  'a1000000-0000-0000-0000-000000000001',
  e.id,
  'attendance_protocol',
  'a7300000-0000-0000-0000-000000000010',
  now() - interval '30 days',
  'a2000000-0000-0000-0000-000000000001'
FROM data.employees e
WHERE e.tenant_id = 'a1000000-0000-0000-0000-000000000001'
  AND e.site_id IS NOT NULL
  AND e.status = 'active'
ON CONFLICT (employee_id, document_version_id) DO NOTHING;

-- Formació assignada a cuina/expedició
INSERT INTO data.employee_portal_document_assignments (
  id, tenant_id, employee_id, assignment_kind, document_version_id, published_at, published_by, acknowledged_at
)
VALUES
  ('a7400000-0000-0000-0000-000000000201', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000004', 'onboarding',
   'a7300000-0000-0000-0000-000000000005', now() - interval '20 days',
   'a2000000-0000-0000-0000-000000000004', now() - interval '19 days'),
  ('a7400000-0000-0000-0000-000000000202', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000007', 'onboarding',
   'a7300000-0000-0000-0000-000000000006', now() - interval '20 days',
   'a2000000-0000-0000-0000-000000000004', now() - interval '18 days'),
  ('a7400000-0000-0000-0000-000000000203', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000014', 'onboarding',
   'a7300000-0000-0000-0000-000000000007', now() - interval '15 days',
   'a2000000-0000-0000-0000-000000000006', now() - interval '14 days')
ON CONFLICT (employee_id, document_version_id) DO NOTHING;

-- >>> END 09_documents_generated.sql <<<

-- >>> BEGIN 10_portals.sql <<<
-- =============================================================================
-- 10 — Portals públics per local + tokens portal empleat
-- =============================================================================

INSERT INTO data.public_sites (id, tenant_id, site_id, slug, name, status)
VALUES
  (
    'a8000000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000001',
    'burgervista-eixample',
    'BurgerVista Eixample — Portal',
    'published'
  ),
  (
    'a8000000-0000-0000-0000-000000000002',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000002',
    'burgervista-diagonal',
    'BurgerVista Diagonal — Portal',
    'published'
  )
ON CONFLICT (id) DO UPDATE SET
  status = EXCLUDED.status,
  slug = EXCLUDED.slug,
  name = EXCLUDED.name;

-- Tokens portal (hash SHA-256 del secret en clar documentat al README)
INSERT INTO data.employee_portal_tokens (
  id, tenant_id, employee_id, token_hash, label, is_active, pin_hash, pin_must_set
)
VALUES
  ('a8100000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000001', digest('ep0-dev-bv-laura', 'sha256'),
   'Dev Laura', true, data.hash_employee_portal_pin('1234'), false),
  ('a8100000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000002', digest('ep0-dev-bv-pau', 'sha256'),
   'Dev Pau', true, data.hash_employee_portal_pin('1234'), false),
  ('a8100000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000007', digest('ep0-dev-bv-irene', 'sha256'),
   'Dev Irene expedició', true, data.hash_employee_portal_pin('1234'), false),
  ('a8100000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000011', digest('ep0-dev-bv-elena', 'sha256'),
   'Dev Elena', true, data.hash_employee_portal_pin('1234'), false),
  ('a8100000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000017', digest('ep0-dev-bv-oriol', 'sha256'),
   'Dev Oriol expedició', true, data.hash_employee_portal_pin('1234'), false),
  ('a8100000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000004', digest('ep0-dev-bv-marc-vidal', 'sha256'),
   'Dev Marc cuina', true, data.hash_employee_portal_pin('1234'), false)
ON CONFLICT (id) DO NOTHING;

-- Sanity final
DO $$
DECLARE
  v_sites int;
  v_emps int;
  v_locs int;
BEGIN
  SELECT count(*) INTO v_sites FROM data.sites
  WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001';
  SELECT count(*) INTO v_emps FROM data.employees
  WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001' AND site_id IS NOT NULL;
  SELECT count(*) INTO v_locs FROM data.locations
  WHERE tenant_id = 'a1000000-0000-0000-0000-000000000001'
    AND metadata->>'channel' = 'delivery';

  RAISE NOTICE 'BurgerVista seed OK: sites=%, employees_local=%, delivery_zones=%',
    v_sites, v_emps, v_locs;

  IF v_sites < 2 OR v_emps < 20 OR v_locs < 2 THEN
    RAISE WARNING 'Seed BurgerVista incomplet (sites=%, emps=%, delivery_zones=%)',
      v_sites, v_emps, v_locs;
  END IF;
END $$;

-- >>> END 10_portals.sql <<<

-- >>> BEGIN 11_skills.sql <<<
-- =============================================================================
-- 11 — Skills de talent (catàleg QSR + assignacions)
-- =============================================================================

INSERT INTO data.skill_types (id, tenant_id, name, is_certification_type, is_active)
VALUES
  ('a4200000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'Operacions QSR', false, true),
  ('a4200000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'Hospitalitat', false, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.skill_levels (id, skill_type_id, name, rank, progress_pct, is_default)
VALUES
  -- Operacions QSR
  ('a4220000-0000-0000-0000-000000000011', 'a4200000-0000-0000-0000-000000000001', 'Bàsic',     1, 25,  false),
  ('a4220000-0000-0000-0000-000000000012', 'a4200000-0000-0000-0000-000000000001', 'Intermedi', 2, 50,  true),
  ('a4220000-0000-0000-0000-000000000013', 'a4200000-0000-0000-0000-000000000001', 'Avançat',   3, 75,  false),
  ('a4220000-0000-0000-0000-000000000014', 'a4200000-0000-0000-0000-000000000001', 'Expert',    4, 100, false),
  -- Hospitalitat
  ('a4220000-0000-0000-0000-000000000021', 'a4200000-0000-0000-0000-000000000002', 'Bàsic',     1, 25,  false),
  ('a4220000-0000-0000-0000-000000000022', 'a4200000-0000-0000-0000-000000000002', 'Intermedi', 2, 50,  true),
  ('a4220000-0000-0000-0000-000000000023', 'a4200000-0000-0000-0000-000000000002', 'Avançat',   3, 75,  false),
  ('a4220000-0000-0000-0000-000000000024', 'a4200000-0000-0000-0000-000000000002', 'Expert',    4, 100, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.skills (id, tenant_id, skill_type_id, name, description, is_active)
VALUES
  ('a4210000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a4200000-0000-0000-0000-000000000001', 'Grill',
   'Cuina a la brasa / planxa', true),
  ('a4210000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a4200000-0000-0000-0000-000000000001', 'Prep',
   'Preparació i mise en place', true),
  ('a4210000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a4200000-0000-0000-0000-000000000001', 'Caixa / POS',
   'Cobraments i tiquets', true),
  ('a4210000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a4200000-0000-0000-0000-000000000001', 'Drive-thru',
   'Servei amb auto', true),
  ('a4210000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a4200000-0000-0000-0000-000000000001', 'Expedició',
   'Muntatge i enviament a domicili', true),
  ('a4210000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a4200000-0000-0000-0000-000000000001', 'Lideratge de torn',
   'Coordinació de torn i ritme de servei', true),
  ('a4210000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001',
   'a4200000-0000-0000-0000-000000000002', 'Atenció al client',
   'Tracte amb clients al mostrador i sala', true),
  ('a4210000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001',
   'a4200000-0000-0000-0000-000000000002', 'Upselling',
   'Recomanacions i venda addicional', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_skills (
  id, tenant_id, employee_id, skill_id, level_id, acquired_on, last_assessed_on, notes
)
VALUES
  -- Corporatiu
  ('a4230000-0000-0000-0000-000000000021', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000021', 'a4210000-0000-0000-0000-000000000006',
   'a4220000-0000-0000-0000-000000000014', '2019-01-01', '2026-01-15', 'CEO — operacions'),
  ('a4230000-0000-0000-0000-000000000022', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000022', 'a4210000-0000-0000-0000-000000000011',
   'a4220000-0000-0000-0000-000000000023', '2021-03-01', '2025-11-01', NULL),
  -- Eixample — direcció / caps
  ('a4230000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000001', 'a4210000-0000-0000-0000-000000000006',
   'a4220000-0000-0000-0000-000000000014', '2020-06-01', '2026-02-01', 'Directora Eixample'),
  ('a4230000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000001', 'a4210000-0000-0000-0000-000000000011',
   'a4220000-0000-0000-0000-000000000024', '2020-06-01', '2026-02-01', NULL),
  ('a4230000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000002', 'a4210000-0000-0000-0000-000000000006',
   'a4220000-0000-0000-0000-000000000013', '2022-01-10', '2025-12-15', 'Cap torn matí'),
  ('a4230000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000002', 'a4210000-0000-0000-0000-000000000003',
   'a4220000-0000-0000-0000-000000000012', '2022-01-10', '2025-10-01', NULL),
  ('a4230000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000003', 'a4210000-0000-0000-0000-000000000006',
   'a4220000-0000-0000-0000-000000000012', '2023-04-01', '2025-11-20', 'Cap torn tarda'),
  -- Eixample — cuina / mostrador / expedició
  ('a4230000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000004', 'a4210000-0000-0000-0000-000000000001',
   'a4220000-0000-0000-0000-000000000013', '2022-08-01', '2026-01-08', 'Grill referent'),
  ('a4230000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000004', 'a4210000-0000-0000-0000-000000000002',
   'a4220000-0000-0000-0000-000000000012', '2022-08-01', '2025-09-15', NULL),
  ('a4230000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000005', 'a4210000-0000-0000-0000-000000000002',
   'a4220000-0000-0000-0000-000000000012', '2023-02-01', '2025-12-01', NULL),
  ('a4230000-0000-0000-0000-000000000009', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000006', 'a4210000-0000-0000-0000-000000000003',
   'a4220000-0000-0000-0000-000000000013', '2021-11-01', '2026-01-22', NULL),
  ('a4230000-0000-0000-0000-000000000010', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000006', 'a4210000-0000-0000-0000-000000000011',
   'a4220000-0000-0000-0000-000000000023', '2021-11-01', '2025-11-10', NULL),
  ('a4230000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000006', 'a4210000-0000-0000-0000-000000000012',
   'a4220000-0000-0000-0000-000000000022', '2022-05-01', '2025-08-20', NULL),
  ('a4230000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000007', 'a4210000-0000-0000-0000-000000000005',
   'a4220000-0000-0000-0000-000000000013', '2022-09-01', '2026-02-05', NULL),
  ('a4230000-0000-0000-0000-000000000013', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000008', 'a4210000-0000-0000-0000-000000000011',
   'a4220000-0000-0000-0000-000000000022', '2024-01-15', '2025-10-30', 'Sala'),
  ('a4230000-0000-0000-0000-000000000014', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000009', 'a4210000-0000-0000-0000-000000000003',
   'a4220000-0000-0000-0000-000000000011', '2025-09-01', '2026-01-05', 'Estudiant mostrador'),
  ('a4230000-0000-0000-0000-000000000015', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000010', 'a4210000-0000-0000-0000-000000000001',
   'a4220000-0000-0000-0000-000000000011', '2024-06-01', '2025-12-12', 'Floater cuina'),
  ('a4230000-0000-0000-0000-000000000016', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000010', 'a4210000-0000-0000-0000-000000000003',
   'a4220000-0000-0000-0000-000000000012', '2024-06-01', '2025-12-12', NULL),
  -- Diagonal
  ('a4230000-0000-0000-0000-000000000031', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000011', 'a4210000-0000-0000-0000-000000000006',
   'a4220000-0000-0000-0000-000000000014', '2021-02-01', '2026-01-18', 'Directora Diagonal'),
  ('a4230000-0000-0000-0000-000000000032', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000011', 'a4210000-0000-0000-0000-000000000011',
   'a4220000-0000-0000-0000-000000000023', '2021-02-01', '2025-12-01', NULL),
  ('a4230000-0000-0000-0000-000000000033', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000012', 'a4210000-0000-0000-0000-000000000006',
   'a4220000-0000-0000-0000-000000000013', '2022-05-01', '2025-11-28', NULL),
  ('a4230000-0000-0000-0000-000000000034', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000014', 'a4210000-0000-0000-0000-000000000001',
   'a4220000-0000-0000-0000-000000000013', '2022-03-01', '2026-02-08', NULL),
  ('a4230000-0000-0000-0000-000000000035', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000015', 'a4210000-0000-0000-0000-000000000002',
   'a4220000-0000-0000-0000-000000000012', '2023-07-01', '2025-10-18', NULL),
  ('a4230000-0000-0000-0000-000000000036', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000016', 'a4210000-0000-0000-0000-000000000003',
   'a4220000-0000-0000-0000-000000000012', '2023-01-01', '2025-09-22', NULL),
  ('a4230000-0000-0000-0000-000000000037', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000016', 'a4210000-0000-0000-0000-000000000012',
   'a4220000-0000-0000-0000-000000000023', '2023-06-01', '2025-12-05', 'Bon upselling'),
  ('a4230000-0000-0000-0000-000000000038', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000017', 'a4210000-0000-0000-0000-000000000005',
   'a4220000-0000-0000-0000-000000000013', '2022-11-01', '2026-01-30', NULL),
  ('a4230000-0000-0000-0000-000000000039', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000018', 'a4210000-0000-0000-0000-000000000004',
   'a4220000-0000-0000-0000-000000000013', '2021-09-01', '2025-11-15', 'Drive-thru referent'),
  ('a4230000-0000-0000-0000-000000000040', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000018', 'a4210000-0000-0000-0000-000000000003',
   'a4220000-0000-0000-0000-000000000012', '2021-09-01', '2025-11-15', NULL),
  ('a4230000-0000-0000-0000-000000000041', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000019', 'a4210000-0000-0000-0000-000000000003',
   'a4220000-0000-0000-0000-000000000011', '2025-10-01', '2026-01-12', 'Estudiant'),
  ('a4230000-0000-0000-0000-000000000042', 'a1000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000020', 'a4210000-0000-0000-0000-000000000004',
   'a4220000-0000-0000-0000-000000000011', '2024-04-01', '2025-12-20', 'Floater drive')
ON CONFLICT (id) DO NOTHING;

-- >>> END 11_skills.sql <<<

-- >>> BEGIN 12_recruitment.sql <<<
-- =============================================================================
-- 12 — Recruitment: feature flag, settings, postings, applicants, applications
-- =============================================================================
-- IDs: a82… (postings/apps), uses public_sites a800… and job_positions a410…
-- Tenant: a1000000-0000-0000-0000-000000000001 (BurgerVista)

INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
VALUES (
  'a1000000-0000-0000-0000-000000000001',
  'recruitment_enabled',
  true
)
ON CONFLICT (tenant_id, feature_key) DO UPDATE
SET override_status = EXCLUDED.override_status;

INSERT INTO data.recruitment_settings (
  tenant_id,
  default_max_retention_months,
  privacy_policy_url,
  rights_sla_days,
  rejection_notify_policy,
  import_legal_basis
)
VALUES (
  'a1000000-0000-0000-0000-000000000001',
  12,
  'https://burgervista.demo/privacitat',
  30,
  'on_decision',
  'legitimate_interest'
)
ON CONFLICT (tenant_id) DO UPDATE
SET
  privacy_policy_url = EXCLUDED.privacy_policy_url,
  updated_at = now();

SELECT data.seed_default_pipeline_stages('a1000000-0000-0000-0000-000000000001');

INSERT INTO data.job_postings (
  id, tenant_id, site_id, job_position_id, title, description, public_slug, status, created_by
)
VALUES
  (
    'a8200000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000001',
    'a4100000-0000-0000-0000-000000000007',
    'Cuiner/a grill — Eixample',
    'Busquem cuiner/a de grill per torns de migdia i vespre. Experiència en QSR valorada.',
    'cuiner-grill-eixample',
    'draft',
    'a2000000-0000-0000-0000-000000000001'
  ),
  (
    'a8200000-0000-0000-0000-000000000002',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000001',
    'a4100000-0000-0000-0000-000000000009',
    'Mostrador / caixa — Eixample',
    'Atenció al client, caixa i preparació de comandes. Horari flexible.',
    'mostrador-eixample',
    'draft',
    'a2000000-0000-0000-0000-000000000001'
  ),
  (
    'a8200000-0000-0000-0000-000000000003',
    'a1000000-0000-0000-0000-000000000001',
    'a3000000-0000-0000-0000-000000000002',
    'a4100000-0000-0000-0000-000000000010',
    'Expedició / domicili — Diagonal',
    'Preparació i entrega de comandes a domicili. Carnet B valorat.',
    'expedicio-diagonal',
    'draft',
    'a2000000-0000-0000-0000-000000000001'
  ),
  (
    'a8200000-0000-0000-0000-000000000004',
    'a1000000-0000-0000-0000-000000000001',
    NULL,
    'a4100000-0000-0000-0000-000000000013',
    'Suport floater (esborrany)',
    'Oferta en preparació — encara no publicada.',
    'floater-borrador',
    'draft',
    'a2000000-0000-0000-0000-000000000001'
  )
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  job_position_id = EXCLUDED.job_position_id;

INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
VALUES
  ('a8200000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001'),
  ('a8200000-0000-0000-0000-000000000002', 'a8000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001'),
  ('a8200000-0000-0000-0000-000000000003', 'a8000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001')
ON CONFLICT DO NOTHING;

UPDATE data.job_postings
SET status = 'published', updated_at = now()
WHERE id IN (
  'a8200000-0000-0000-0000-000000000001',
  'a8200000-0000-0000-0000-000000000002',
  'a8200000-0000-0000-0000-000000000003'
)
AND tenant_id = 'a1000000-0000-0000-0000-000000000001';

INSERT INTO data.applicants (
  id, tenant_id, email, full_name, phone, email_verified_at
)
VALUES
  ('a8210000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'aina.grill@example.com', 'Aina Martí', '+34611100001', now() - interval '5 days'),
  ('a8210000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'pol.cuina@example.com', 'Pol Serra', '+34611100002', now() - interval '4 days'),
  ('a8210000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'laia.counter@example.com', 'Laia Puig', '+34611100003', now() - interval '3 days'),
  ('a8210000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001', 'oriol.caixa@example.com', 'Oriol Domènech', NULL, now() - interval '2 days'),
  ('a8210000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001', 'marta.delivery@example.com', 'Marta Riera', '+34611100005', now() - interval '6 days'),
  ('a8210000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001', 'jan.bike@example.com', 'Jan Costa', '+34611100006', now() - interval '1 day'),
  ('a8210000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001', 'nina.sala@example.com', 'Nina Valls', '+34611100007', now() - interval '8 days'),
  ('a8210000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001', 'eric.prep@example.com', 'Èric Font', NULL, now() - interval '10 days'),
  ('a8210000-0000-0000-0000-000000000009', 'a1000000-0000-0000-0000-000000000001', 'sofia.wa@example.com', 'Sofia Navarro', '+34611100009', now() - interval '12 hours'),
  ('a8210000-0000-0000-0000-000000000010', 'a1000000-0000-0000-0000-000000000001', 'toni.qr@example.com', 'Toni Alsina', '+34611100010', now() - interval '7 days')
ON CONFLICT (id) DO NOTHING;

DO $$
DECLARE
  v_tenant uuid := 'a1000000-0000-0000-0000-000000000001';
  v_rebut uuid;
  v_revisio uuid;
  v_entrevista uuid;
  v_oferta uuid;
  v_descart uuid;
BEGIN
  SELECT id INTO v_rebut FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'Rebut' LIMIT 1;
  SELECT id INTO v_revisio FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'En revisió' LIMIT 1;
  SELECT id INTO v_entrevista FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'Entrevista' LIMIT 1;
  SELECT id INTO v_oferta FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'Oferta' LIMIT 1;
  SELECT id INTO v_descart FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'Descart' LIMIT 1;

  INSERT INTO data.applications (
    id, tenant_id, job_posting_id, applicant_id, stage_id,
    retention_preference, retention_months, purge_at, source, created_at
  )
  VALUES
    ('a8220000-0000-0000-0000-000000000001', v_tenant, 'a8200000-0000-0000-0000-000000000001',
     'a8210000-0000-0000-0000-000000000001', v_rebut,
     'delete_after_months', 6, now() + interval '6 months', 'web', now() - interval '5 days'),
    ('a8220000-0000-0000-0000-000000000002', v_tenant, 'a8200000-0000-0000-0000-000000000001',
     'a8210000-0000-0000-0000-000000000002', v_revisio,
     'delete_after_months', 6, now() + interval '6 months', 'qr', now() - interval '4 days'),
    ('a8220000-0000-0000-0000-000000000003', v_tenant, 'a8200000-0000-0000-0000-000000000001',
     'a8210000-0000-0000-0000-000000000008', v_entrevista,
     'delete_on_process_end', NULL, now() + interval '12 months', 'web', now() - interval '10 days'),
    ('a8220000-0000-0000-0000-000000000004', v_tenant, 'a8200000-0000-0000-0000-000000000002',
     'a8210000-0000-0000-0000-000000000003', v_rebut,
     'delete_after_months', 6, now() + interval '6 months', 'whatsapp', now() - interval '3 days'),
    ('a8220000-0000-0000-0000-000000000005', v_tenant, 'a8200000-0000-0000-0000-000000000002',
     'a8210000-0000-0000-0000-000000000004', v_entrevista,
     'delete_after_months', 6, now() + interval '6 months', 'web', now() - interval '2 days'),
    ('a8220000-0000-0000-0000-000000000006', v_tenant, 'a8200000-0000-0000-0000-000000000002',
     'a8210000-0000-0000-0000-000000000009', v_revisio,
     'delete_after_months', 6, now() + interval '6 months', 'whatsapp', now() - interval '12 hours'),
    ('a8220000-0000-0000-0000-000000000007', v_tenant, 'a8200000-0000-0000-0000-000000000003',
     'a8210000-0000-0000-0000-000000000005', v_oferta,
     'delete_after_months', 6, now() + interval '6 months', 'web', now() - interval '6 days'),
    ('a8220000-0000-0000-0000-000000000008', v_tenant, 'a8200000-0000-0000-0000-000000000003',
     'a8210000-0000-0000-0000-000000000006', v_rebut,
     'delete_after_months', 6, now() + interval '6 months', 'manual', now() - interval '1 day'),
    ('a8220000-0000-0000-0000-000000000009', v_tenant, 'a8200000-0000-0000-0000-000000000003',
     'a8210000-0000-0000-0000-000000000007', v_descart,
     'delete_on_process_end', NULL, now() + interval '30 days', 'web', now() - interval '8 days'),
    ('a8220000-0000-0000-0000-000000000010', v_tenant, 'a8200000-0000-0000-0000-000000000001',
     'a8210000-0000-0000-0000-000000000010', v_rebut,
     'delete_after_months', 6, now() + interval '6 months', 'qr', now() - interval '7 days')
  ON CONFLICT (id) DO NOTHING;
END $$;

DO $$
BEGIN
  RAISE NOTICE 'BurgerVista recruitment seed OK: 3 live postings + 1 draft, 10 applications';
END $$;

-- >>> END 12_recruitment.sql <<<
