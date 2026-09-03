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
