-- =============================================================================
-- Seed — dades de prova (NOMÉS local)
-- =============================================================================
-- Aplicat automàticament per `supabase db reset` (local).
-- NO s'aplica amb `supabase db push` — és dades de test.
--
-- Crea:
--   Plans:   free, pro, enterprise
--   Tenants: acme-corp (pro, sense sector), beta-startup (free),
--            volt-serveis (pro, archetype field_service, autònom),
--            riera-instal (pro, archetype field_service, PIME oficina + tècnics)
--   Usuaris:
--     · 1 superadmin (app_metadata.role = 'admin') per al admin-portal
--     · perfils globals i locals per validar jerarquia de rols multi-tenant/site
--     · Gina (owner oficina) + Hèctor/Inés (members tècnics) a Riera Instal·lacions
--
-- Passwords de tots els usuaris de prova: Test1234!
-- UUIDs fixes perquè les dades de seed siguin reproducibles.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Plans
-- ---------------------------------------------------------------------------
INSERT INTO data.plans (id, name, display_name, max_members, max_storage_mb, price_monthly, max_sites, max_portal_pages, portal_field_limits, max_html_template_size_kb, portal_entitlements)
VALUES
  ('00000000-0000-0000-0000-000000000001', 'free',       'Free',        3,   100,   0.00,    1,  3, '{"page_title_max_chars":120,"page_seo_title_max_chars":70,"page_seo_description_max_chars":160,"page_html_max_chars":10000,"footer_text_max_chars":150,"header_cta_label_max_chars":50}',  200, '{"employee_portal":{"included":true,"cms_tier":"basic"},"public_portal":{"included":true,"cms_tier":"basic","max_pages":3}}'),
  ('00000000-0000-0000-0000-000000000002', 'pro',        'Pro',        20,  5000,  29.00,    5, 20, '{"page_title_max_chars":120,"page_seo_title_max_chars":70,"page_seo_description_max_chars":160,"page_html_max_chars":50000,"footer_text_max_chars":300,"header_cta_label_max_chars":50}',  500, '{"employee_portal":{"included":true,"cms_tier":"basic"},"public_portal":{"included":true,"cms_tier":"basic","max_pages":20}}'),
  ('00000000-0000-0000-0000-000000000003', 'enterprise', 'Enterprise', 999, 50000, 199.00, 999,  0, '{"page_title_max_chars":0,"page_seo_title_max_chars":0,"page_seo_description_max_chars":0,"page_html_max_chars":0,"footer_text_max_chars":0,"header_cta_label_max_chars":0}',             0, '{"employee_portal":{"included":true,"cms_tier":"advanced"},"public_portal":{"included":true,"cms_tier":"advanced","max_pages":0}}')
ON CONFLICT (id) DO UPDATE
  SET max_sites                 = EXCLUDED.max_sites,
      max_portal_pages          = EXCLUDED.max_portal_pages,
      portal_field_limits       = EXCLUDED.portal_field_limits,
      max_html_template_size_kb = EXCLUDED.max_html_template_size_kb,
      portal_entitlements       = EXCLUDED.portal_entitlements;

-- Mark the default plan (used by self-signup / public-onboarding Edge Function).
UPDATE data.plans SET is_default = true WHERE name = 'free';

-- ---------------------------------------------------------------------------
-- Tenants
-- ---------------------------------------------------------------------------
-- Acme / Beta: sense sector_profile (onboarding + E2E Bob).
-- Volt Serveis: field_service autònom (Alice ho fa tot).
-- Riera Instal·lacions: field_service PIME (oficina + tècnics member).
INSERT INTO data.tenants (id, name, slug, plan_id)
VALUES
  ('10000000-0000-0000-0000-000000000001', 'Acme Corp',     'acme-corp',     '00000000-0000-0000-0000-000000000002'),
  ('10000000-0000-0000-0000-000000000002', 'Beta Startup',  'beta-startup',  '00000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000003', 'Volt Serveis',  'volt-serveis',  '00000000-0000-0000-0000-000000000002'),
  ('10000000-0000-0000-0000-000000000004', 'Riera Instal·lacions', 'riera-instal', '00000000-0000-0000-0000-000000000002')
ON CONFLICT (id) DO NOTHING;

UPDATE data.tenants t
SET sector_profile_id = sp.id,
    updated_at = now()
FROM data.sector_profiles sp
WHERE t.id IN (
    '10000000-0000-0000-0000-000000000003',
    '10000000-0000-0000-0000-000000000004'
  )
  AND sp.archetype = 'field_service'
  AND sp.vertical IS NULL;

-- ---------------------------------------------------------------------------
-- Subscripcions
-- ---------------------------------------------------------------------------
INSERT INTO data.subscriptions (tenant_id, plan_id, status)
VALUES
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'active'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'trial'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000002', 'active'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000002', 'active')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Usuaris auth + profiles
-- Supabase Local: podem insertar directament a auth.users en seed.
-- ---------------------------------------------------------------------------

-- Superadmin (accedeix a admin-portal — app_metadata.role = 'admin')
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change,
  raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '20000000-0000-0000-0000-000000000001',
  'superadmin@example.com',
  crypt('Test1234!', gen_salt('bf')),
  now(),
  '', '', '', '',
  '',
  '{"provider":"email","providers":["email"],"role":"admin"}',
  '{"full_name":"Super Admin","email_verified":true}',
  'authenticated', 'authenticated', now(), now()
) ON CONFLICT (id) DO NOTHING;

-- Alice — owner global (multi-tenant)
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change,
  raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '20000000-0000-0000-0000-000000000002',
  'alice@acme-corp.com',
  crypt('Test1234!', gen_salt('bf')),
  now(),
  '', '', '', '',
  '',
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Alice Owner","email_verified":true}',
  'authenticated', 'authenticated', now(), now()
) ON CONFLICT (id) DO NOTHING;

-- Bob — owner global d'Acme
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change,
  raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '20000000-0000-0000-0000-000000000003',
  'bob@acme-corp.com',
  crypt('Test1234!', gen_salt('bf')),
  now(),
  '', '', '', '',
  '',
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Bob Owner","email_verified":true}',
  'authenticated', 'authenticated', now(), now()
) ON CONFLICT (id) DO NOTHING;

-- Charlie — manager local d'Acme Gràcia
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change,
  raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '20000000-0000-0000-0000-000000000004',
  'charlie@acme-corp.com',
  crypt('Test1234!', gen_salt('bf')),
  now(),
  '', '', '', '',
  '',
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Charlie Manager","email_verified":true}',
  'authenticated', 'authenticated', now(), now()
) ON CONFLICT (id) DO NOTHING;

-- Dave — member local d'Acme Gràcia
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change,
  raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '20000000-0000-0000-0000-000000000005',
  'dave@acme-corp.com',
  crypt('Test1234!', gen_salt('bf')),
  now(),
  '', '', '', '',
  '',
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Dave Member","email_verified":true}',
  'authenticated', 'authenticated', now(), now()
) ON CONFLICT (id) DO NOTHING;

-- Eve — viewer local d'Acme Gràcia
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change,
  raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '20000000-0000-0000-0000-000000000006',
  'eve@acme-corp.com',
  crypt('Test1234!', gen_salt('bf')),
  now(),
  '', '', '', '',
  '',
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Eve Viewer","email_verified":true}',
  'authenticated', 'authenticated', now(), now()
) ON CONFLICT (id) DO NOTHING;

-- Frank — manager local de Beta Workshop
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change,
  raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '20000000-0000-0000-0000-000000000007',
  'frank@beta-startup.com',
  crypt('Test1234!', gen_salt('bf')),
  now(),
  '', '', '', '',
  '',
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Frank Manager","email_verified":true}',
  'authenticated', 'authenticated', now(), now()
) ON CONFLICT (id) DO NOTHING;

-- Gina — owner oficina de Riera Instal·lacions (PIME field_service)
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change,
  raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '20000000-0000-0000-0000-000000000008',
  'gina@riera-instal.com',
  crypt('Test1234!', gen_salt('bf')),
  now(),
  '', '', '', '',
  '',
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Gina Riera","email_verified":true}',
  'authenticated', 'authenticated', now(), now()
) ON CONFLICT (id) DO NOTHING;

-- Hèctor — tècnic de camp (member) de Riera Instal·lacions
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change,
  raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '20000000-0000-0000-0000-000000000009',
  'hector@riera-instal.com',
  crypt('Test1234!', gen_salt('bf')),
  now(),
  '', '', '', '',
  '',
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Hèctor Soler","email_verified":true}',
  'authenticated', 'authenticated', now(), now()
) ON CONFLICT (id) DO NOTHING;

-- Inés — tècnica de camp (member) de Riera Instal·lacions
INSERT INTO auth.users (
  instance_id, id, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
  email_change,
  raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '20000000-0000-0000-0000-000000000010',
  'ines@riera-instal.com',
  crypt('Test1234!', gen_salt('bf')),
  now(),
  '', '', '', '',
  '',
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Inés Vidal","email_verified":true}',
  'authenticated', 'authenticated', now(), now()
) ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Identities — necessàries perquè GoTrue pugui autenticar per email/password.
-- Sense auth.identities, auth.users existeix però el login falla silenciosament.
-- ---------------------------------------------------------------------------
INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
VALUES
  (
    '20000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001',
    '{"sub":"20000000-0000-0000-0000-000000000001","email":"superadmin@example.com","email_verified":true}',
    'email', now(), now(), now()
  ),
  (
    '20000000-0000-0000-0000-000000000002',
    '20000000-0000-0000-0000-000000000002',
    '{"sub":"20000000-0000-0000-0000-000000000002","email":"alice@acme-corp.com","email_verified":true}',
    'email', now(), now(), now()
  ),
  (
    '20000000-0000-0000-0000-000000000003',
    '20000000-0000-0000-0000-000000000003',
    '{"sub":"20000000-0000-0000-0000-000000000003","email":"bob@acme-corp.com","email_verified":true}',
    'email', now(), now(), now()
  ),
  (
    '20000000-0000-0000-0000-000000000004',
    '20000000-0000-0000-0000-000000000004',
    '{"sub":"20000000-0000-0000-0000-000000000004","email":"charlie@acme-corp.com","email_verified":true}',
    'email', now(), now(), now()
  ),
  (
    '20000000-0000-0000-0000-000000000005',
    '20000000-0000-0000-0000-000000000005',
    '{"sub":"20000000-0000-0000-0000-000000000005","email":"dave@acme-corp.com","email_verified":true}',
    'email', now(), now(), now()
  ),
  (
    '20000000-0000-0000-0000-000000000006',
    '20000000-0000-0000-0000-000000000006',
    '{"sub":"20000000-0000-0000-0000-000000000006","email":"eve@acme-corp.com","email_verified":true}',
    'email', now(), now(), now()
  ),
  (
    '20000000-0000-0000-0000-000000000007',
    '20000000-0000-0000-0000-000000000007',
    '{"sub":"20000000-0000-0000-0000-000000000007","email":"frank@beta-startup.com","email_verified":true}',
    'email', now(), now(), now()
  ),
  (
    '20000000-0000-0000-0000-000000000008',
    '20000000-0000-0000-0000-000000000008',
    '{"sub":"20000000-0000-0000-0000-000000000008","email":"gina@riera-instal.com","email_verified":true}',
    'email', now(), now(), now()
  ),
  (
    '20000000-0000-0000-0000-000000000009',
    '20000000-0000-0000-0000-000000000009',
    '{"sub":"20000000-0000-0000-0000-000000000009","email":"hector@riera-instal.com","email_verified":true}',
    'email', now(), now(), now()
  ),
  (
    '20000000-0000-0000-0000-000000000010',
    '20000000-0000-0000-0000-000000000010',
    '{"sub":"20000000-0000-0000-0000-000000000010","email":"ines@riera-instal.com","email_verified":true}',
    'email', now(), now(), now()
  )
ON CONFLICT (provider_id, provider) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Profiles (el trigger handle_new_user ja els crea, però el seed ho fa
-- directament perquè el trigger no s'executa en inserts de seed a auth.users)
-- first_login_at backfilled from email_confirmed_at (users were confirmed at seed time)
-- ---------------------------------------------------------------------------
INSERT INTO data.profiles (id, email, full_name, first_login_at, last_login_at)
VALUES
  ('20000000-0000-0000-0000-000000000001', 'superadmin@example.com',  'Super Admin', now() - INTERVAL '20 days', now() - INTERVAL '1 day'),
  ('20000000-0000-0000-0000-000000000002', 'alice@acme-corp.com',     'Alice Owner',      now() - INTERVAL '18 days', now() - INTERVAL '20 days'),
  ('20000000-0000-0000-0000-000000000003', 'bob@acme-corp.com',       'Bob Owner',        now() - INTERVAL '17 days', now() - INTERVAL '4 hours'),
  ('20000000-0000-0000-0000-000000000004', 'charlie@acme-corp.com',   'Charlie Manager',  now() - INTERVAL '10 days', now() - INTERVAL '2 hours'),
  ('20000000-0000-0000-0000-000000000005', 'dave@acme-corp.com',      'Dave Member',      now() - INTERVAL '9 days',  now() - INTERVAL '30 minutes'),
  ('20000000-0000-0000-0000-000000000006', 'eve@acme-corp.com',       'Eve Viewer',       now() - INTERVAL '8 days',  now() - INTERVAL '12 hours'),
  ('20000000-0000-0000-0000-000000000007', 'frank@beta-startup.com',  'Frank Manager',    now() - INTERVAL '6 days',  now() - INTERVAL '6 days'),
  ('20000000-0000-0000-0000-000000000008', 'gina@riera-instal.com',   'Gina Riera',       now() - INTERVAL '5 days',  now() - INTERVAL '1 hour'),
  ('20000000-0000-0000-0000-000000000009', 'hector@riera-instal.com', 'Hèctor Soler',     now() - INTERVAL '5 days',  now() - INTERVAL '2 hours'),
  ('20000000-0000-0000-0000-000000000010', 'ines@riera-instal.com',   'Inés Vidal',       now() - INTERVAL '4 days',  now() - INTERVAL '3 hours')
ON CONFLICT (id) DO UPDATE
  SET first_login_at = EXCLUDED.first_login_at,
      last_login_at  = EXCLUDED.last_login_at
  WHERE data.profiles.first_login_at IS NULL;

-- ---------------------------------------------------------------------------
-- Sites de prova
-- ---------------------------------------------------------------------------
-- Inserits ABANS de les membreses per site perquè la FK ho requereix.
-- Acme Corp (pla Pro, max_sites=5) → 2 sites
-- Beta Startup (pla Free, max_sites=1) → 1 site
-- UUIDs fixes per reproductibilitat. El nom del site inicial coincideix amb
-- el nom del Tenant, tal com fa provision_tenant() a producció.
INSERT INTO data.sites (id, tenant_id, name, address)
VALUES
  -- Acme Corp
  ('30000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001',
   'Acme Gràcia', 'Carrer de Verdi, 42, 08012 Barcelona'),
  ('30000000-0000-0000-0000-000000000002',
   '10000000-0000-0000-0000-000000000001',
   'Acme Sants', 'Carrer de Sants, 118, 08028 Barcelona'),
  -- Beta Startup
  ('30000000-0000-0000-0000-000000000003',
   '10000000-0000-0000-0000-000000000002',
   'Beta Workshop', 'Carrer de la Indústria, 77, 08960 Sant Just Desvern'),
  -- Volt Serveis (field_service autònom)
  ('30000000-0000-0000-0000-000000000004',
   '10000000-0000-0000-0000-000000000003',
   'Volt Serveis', 'Carrer de Provença, 200, 08036 Barcelona'),
  -- Riera Instal·lacions (field_service PIME)
  ('30000000-0000-0000-0000-000000000005',
   '10000000-0000-0000-0000-000000000004',
   'Riera Instal·lacions', 'Carrer de la Riera de Sant Miquel, 18, 08006 Barcelona')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Membresies
-- ---------------------------------------------------------------------------
-- Escenaris de prova:
--   Alice Owner (20000000-...002)
--     · Acme Corp    → owner GLOBAL
--     · Beta Startup → owner GLOBAL (perfil multi-tenant)
--     · Volt Serveis → owner GLOBAL (field_service)
--   Bob (20000000-...003)
--     · Acme Corp    → owner GLOBAL
--   Charlie (20000000-...004)
--     · Acme Gràcia  → manager local
--   Dave (20000000-...005)
--     · Acme Gràcia  → member local
--   Eve (20000000-...006)
--     · Acme Gràcia  → viewer local
--   Frank (20000000-...007)
--     · Beta Workshop → manager local
--   Gina (20000000-...008)
--     · Riera Instal·lacions → owner GLOBAL (oficina PIME)
--   Hèctor (20000000-...009)
--     · Riera Instal·lacions → member GLOBAL (tècnic de camp)
--   Inés (20000000-...010)
--     · Riera Instal·lacions → member GLOBAL (tècnica de camp)

-- Rols globals (site_id IS NULL)
INSERT INTO data.tenant_members (tenant_id, user_id, role)
VALUES
  -- Acme Corp globals
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'owner'),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'owner'),
  -- Beta Startup globals
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'owner'),
  -- Volt Serveis (field_service autònom)
  ('10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'owner'),
  -- Riera Instal·lacions (field_service PIME)
  ('10000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000008', 'owner'),
  ('10000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000009', 'member'),
  ('10000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000010', 'member')
ON CONFLICT (tenant_id, user_id) WHERE site_id IS NULL DO NOTHING;

-- Rols limitats per site (site_id IS NOT NULL)
INSERT INTO data.tenant_members (tenant_id, user_id, role, site_id)
VALUES
  -- Acme Gràcia
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004', 'manager',
   '30000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'member',
   '30000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006', 'viewer',
   '30000000-0000-0000-0000-000000000001'),
  -- Beta Workshop
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000007', 'manager',
   '30000000-0000-0000-0000-000000000003')
ON CONFLICT (tenant_id, user_id, site_id) WHERE site_id IS NOT NULL DO NOTHING;

-- ---------------------------------------------------------------------------
-- Settings de prova (motor de configuracio en cascada + ACL per clau)
-- ---------------------------------------------------------------------------
-- Objectiu dels valors seed:
--   1) Tenir overrides reals a nivell tenant/site/user per validar herencia.
--   2) Poder provar permisos per clau amb usuaris owner/manager/member/viewer.
--
-- Flux esperat de prova:
--   - Owner (Alice/Bob) pot editar claus owner_only (ex: storage_hard_quota_gb).
--   - Manager local (Charlie/Frank) pot editar claus site amb permisos adequats
--     (ex: email_from_name, calendar_slot_minutes) pero no owner_only.
--   - Member/Viewer no poden editar settings de tenant/site.
--   - Cada usuari pot editar les seves preferencies de nivell user.

-- Tenant-level settings
UPDATE data.tenants
SET settings = COALESCE(settings, '{}') || '{
  "default_event_start_time": "08:30",
  "default_event_duration_minutes": 45,
  "week_starts_on": 1,
  "default_language": "ca",
  "default_calendar_timezone": "Europe/Madrid",
  "rbac_customization_enabled": true,
  "storage_hard_quota_gb": 50,
  "attendance_location_consent_required": true
}'::jsonb
WHERE id = '10000000-0000-0000-0000-000000000001';

UPDATE data.tenants
SET settings = COALESCE(settings, '{}') || '{
  "default_event_start_time": "09:00",
  "default_event_duration_minutes": 60,
  "week_starts_on": 1,
  "default_language": "en",
  "default_calendar_timezone": "Europe/Madrid",
  "member_invites_enabled": false
}'::jsonb
WHERE id = '10000000-0000-0000-0000-000000000002';

-- Site-level settings
UPDATE data.sites
SET settings = COALESCE(settings, '{}') || '{
  "email_from_name": "Acme Gracia Team",
  "email_reply_to": "gracia@acme-corp.com",
  "site_timezone": "Europe/Madrid",
  "calendar_slot_minutes": 30,
  "calendar_allow_overlap": false
}'::jsonb
WHERE id = '30000000-0000-0000-0000-000000000001';

UPDATE data.sites
SET settings = COALESCE(settings, '{}') || '{
  "email_from_name": "Acme Sants Team",
  "email_reply_to": "sants@acme-corp.com",
  "site_timezone": "Europe/Madrid",
  "calendar_slot_minutes": 15,
  "calendar_allow_overlap": true
}'::jsonb
WHERE id = '30000000-0000-0000-0000-000000000002';

UPDATE data.sites
SET settings = COALESCE(settings, '{}') || '{
  "email_from_name": "Beta Workshop",
  "email_reply_to": "ops@beta-startup.com",
  "site_timezone": "Europe/Madrid",
  "calendar_slot_minutes": 20,
  "calendar_allow_overlap": false
}'::jsonb
WHERE id = '30000000-0000-0000-0000-000000000003';

-- User-level settings (guardats a data.tenant_members.settings)
-- Alice (owner global Acme)
UPDATE data.tenant_members
SET settings = COALESCE(settings, '{}') || '{
  "theme": "dark",
  "calendar_default_view": "week",
  "timezone": "Europe/Madrid",
  "notifications_email_enabled": true
}'::jsonb
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND user_id   = '20000000-0000-0000-0000-000000000002'
  AND site_id IS NULL;

-- Charlie (manager local Acme Gracia)
UPDATE data.tenant_members
SET settings = COALESCE(settings, '{}') || '{
  "theme": "light",
  "calendar_default_view": "day",
  "timezone": "Europe/Madrid",
  "table_density": "compact"
}'::jsonb
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND user_id   = '20000000-0000-0000-0000-000000000004'
  AND site_id   = '30000000-0000-0000-0000-000000000001';

-- Frank (manager local Beta Workshop)
UPDATE data.tenant_members
SET settings = COALESCE(settings, '{}') || '{
  "theme": "system",
  "calendar_default_view": "month",
  "notifications_in_app_enabled": true
}'::jsonb
WHERE tenant_id = '10000000-0000-0000-0000-000000000002'
  AND user_id   = '20000000-0000-0000-0000-000000000007'
  AND site_id   = '30000000-0000-0000-0000-000000000003';

-- ---------------------------------------------------------------------------
-- Notes de prova (per provar aïllament de tenant i de site)
-- ---------------------------------------------------------------------------
-- Distribució:
--   Acme:
--     · Nota global de tenant
--     · Nota de Gràcia
--     · Nota de Sants
--   Beta:
--     · Nota global de tenant
--     · Nota de Beta Workshop
-- Totes les notes d'Acme han de ser invisibles des de Beta Startup i viceversa.
INSERT INTO data.notes (tenant_id, created_by, title, content, site_id)
VALUES
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
  'Acme Global Policy',
  'Nota global d''Acme. Visible des de vista global del tenant.',
   NULL),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
  'Acme Gràcia Daily Ops',
  'Nota operativa del site Acme Gràcia.',
   '30000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
  'Acme Sants Maintenance',
  'Nota operativa del site Acme Sants.',
   '30000000-0000-0000-0000-000000000002'),
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002',
  'Beta Global Policy',
  'Nota global de Beta Startup. Visible a nivell tenant.',
  NULL),
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000007',
  'Beta Workshop Checklist',
  'Nota operativa del site Beta Workshop. No visible a Acme Corp.',
   '30000000-0000-0000-0000-000000000003')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Locations + Assets + Projects + Work Logs (escenaris operatius)
-- ---------------------------------------------------------------------------
-- Objectiu:
--   · Provar jerarquia interna del site (planta/zona/sala)
--   · Provar ubicacions externes amb GPS
--   · Provar projectes vinculats a location_id
--   · Provar fitxatges (work_logs) sobre aquests projectes

-- Locations (Acme Gracia)
INSERT INTO data.locations (id, tenant_id, site_id, parent_id, name, type, status, geo_coordinates, metadata)
VALUES
  (
    '41000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    NULL,
    'Taller',
    'zone',
    'active',
    NULL,
    '{"map_position":{"x":18,"y":32},"capacity":20}'::jsonb
  ),
  (
    '41000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    'Magatzem electric',
    'room',
    'active',
    NULL,
    '{"map_position":{"x":30,"y":40},"capacity":6}'::jsonb
  ),
  (
    '41000000-0000-0000-0000-000000000003',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    'Zona de muntatge',
    'zone',
    'active',
    NULL,
    '{"map_position":{"x":58,"y":48},"capacity":14}'::jsonb
  ),
  (
    '41000000-0000-0000-0000-000000000004',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    NULL,
    'Obra externa Muntaner',
    'outdoor',
    'active',
    '{"lat":41.39081,"lng":2.15446}'::jsonb,
    '{"capacity":4,"external":true}'::jsonb
  ),
  (
    '41000000-0000-0000-0000-000000000005',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000002',
    NULL,
    'Cuina Sants',
    'room',
    'active',
    NULL,
    '{"map_position":{"x":44,"y":28},"capacity":10}'::jsonb
  )
ON CONFLICT (id) DO NOTHING;

-- Assets vinculats a locations
INSERT INTO data.assets (id, tenant_id, site_id, location_id, name, asset_tag, status, metadata)
VALUES
  (
    '42000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000002',
    'Quadre electric principal',
    'ACME-ELEC-001',
    'down',
    '{"priority":"critical"}'::jsonb
  ),
  (
    '42000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    'Carret elevador',
    'ACME-MOV-001',
    'operational',
    '{"battery":"ok"}'::jsonb
  ),
  (
    '42000000-0000-0000-0000-000000000003',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000003',
    'Taladre industrial',
    'ACME-TOOL-011',
    'repairing',
    '{"repair_eta":"2d"}'::jsonb
  ),
  (
    '42000000-0000-0000-0000-000000000004',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000004',
    'Generador mobil',
    'ACME-EXT-004',
    'operational',
    '{"fuel":"diesel"}'::jsonb
  )
ON CONFLICT (id) DO NOTHING;

-- Projects assignats a locations
INSERT INTO data.projects (
  id, tenant_id, type, name, description, status, visibility,
  site_id, location_id, created_by, planned_start, planned_end
)
VALUES
  (
    '51000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    'maintenance',
    'Revisio del quadre electric',
    'Revisio preventiva del quadre principal del magatzem.',
    'in_progress',
    'company',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000002',
    '20000000-0000-0000-0000-000000000004',
    now() - interval '1 day',
    now() + interval '2 days'
  ),
  (
    '51000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001',
    'work_order',
    'Cablejat obra externa Muntaner',
    'Execucio de cablejat en ubicacio externa.',
    'in_progress',
    'company',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000004',
    '20000000-0000-0000-0000-000000000004',
    now() - interval '6 hours',
    now() + interval '3 days'
  )
ON CONFLICT (id) DO NOTHING;

-- Missatges seed a la cua project_events per provar el worker via curl.
-- S'encuen en format legacy (camp `event`) per validar el fallback defaultTask.
DO $$
BEGIN
  IF to_regclass('pgmq.q_project_events') IS NULL THEN
    RAISE NOTICE 'Seed: pgmq.q_project_events no existeix encara; s''omet l''encuat de proves.';
    RETURN;
  END IF;

  PERFORM pgmq.send(
    'project_events',
    jsonb_build_object(
      'event',         'PROJECT_CREATED',
      'project_id',    '51000000-0000-0000-0000-000000000001'::uuid,
      'tenant_id',     '10000000-0000-0000-0000-000000000001'::uuid,
      'name',          'Revisio del quadre electric',
      'type',          'maintenance',
      'planned_start', (SELECT planned_start FROM data.projects WHERE id = '51000000-0000-0000-0000-000000000001'::uuid),
      'created_by',    '20000000-0000-0000-0000-000000000004'::uuid
    )
  );

  PERFORM pgmq.send(
    'project_events',
    jsonb_build_object(
      'event',         'PROJECT_CREATED',
      'project_id',    '51000000-0000-0000-0000-000000000002'::uuid,
      'tenant_id',     '10000000-0000-0000-0000-000000000001'::uuid,
      'name',          'Cablejat obra externa Muntaner',
      'type',          'work_order',
      'planned_start', (SELECT planned_start FROM data.projects WHERE id = '51000000-0000-0000-0000-000000000002'::uuid),
      'created_by',    '20000000-0000-0000-0000-000000000004'::uuid
    )
  );
END;
$$;

-- Work logs de prova sobre projectes vinculats a locations
INSERT INTO data.work_logs (
  id, tenant_id, site_id, project_id, worker_id, client_op_id,
  status, check_in, check_out, check_in_geo, check_out_geo,
  location_permission, anomaly_codes, notes
)
VALUES
  (
    '61000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '51000000-0000-0000-0000-000000000002',
    '20000000-0000-0000-0000-000000000004',
    '61000000-0000-0000-0000-000000000101',
    'open',
    now() - interval '1 hour',
    NULL,
    '{"latitude":41.39081,"longitude":2.15446,"accuracy_meters":12}'::jsonb,
    NULL,
    'granted',
    '{}'::text[],
    'Treball en curs a la ubicacio externa.'
  ),
  (
    '61000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '51000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000005',
    '61000000-0000-0000-0000-000000000102',
    'closed',
    now() - interval '5 hours',
    now() - interval '3 hours',
    '{"latitude":41.40210,"longitude":2.16120,"accuracy_meters":20}'::jsonb,
    '{"latitude":41.40208,"longitude":2.16118,"accuracy_meters":18}'::jsonb,
    'granted',
    '{}'::text[],
    'Revisio finalitzada al magatzem electric.'
  )
ON CONFLICT (id) DO NOTHING;

-- ─── Catàleg job_positions (Acme + Beta) ─────────────────────────────────────
-- Prefix 41000000 (mateix prefix que locations; PK per taula, sense col·lisió).
INSERT INTO data.job_positions (id, tenant_id, code, name, is_active)
VALUES
  ('41000000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000001', 'MANAGER',        'Manager',          true),
  ('41000000-0000-0000-0000-000000000102', '10000000-0000-0000-0000-000000000001', 'TECNIC',         'Tècnic',           true),
  ('41000000-0000-0000-0000-000000000103', '10000000-0000-0000-0000-000000000001', 'TECNICA',        'Tècnica',          true),
  ('41000000-0000-0000-0000-000000000104', '10000000-0000-0000-0000-000000000001', 'ELECTRICISTA',   'Electricista',     true),
  ('41000000-0000-0000-0000-000000000105', '10000000-0000-0000-0000-000000000001', 'CAP_OBRA',       'Cap d''obra',      true),
  ('41000000-0000-0000-0000-000000000106', '10000000-0000-0000-0000-000000000001', 'ENCARGADA',      'Encarregada',      true),
  ('41000000-0000-0000-0000-000000000107', '10000000-0000-0000-0000-000000000001', 'ADMIN',          'Administratiu/va', true),
  ('41000000-0000-0000-0000-000000000108', '10000000-0000-0000-0000-000000000001', 'MECANIC',        'Mecànic',          true),
  ('41000000-0000-0000-0000-000000000109', '10000000-0000-0000-0000-000000000001', 'OFICIAL_1A',     'Oficial de 1a',    true),
  ('41000000-0000-0000-0000-000000000110', '10000000-0000-0000-0000-000000000001', 'OFICIAL_2A',     'Oficial de 2a',    true),
  ('41000000-0000-0000-0000-000000000111', '10000000-0000-0000-0000-000000000001', 'PEO',            'Peó',              true),
  ('41000000-0000-0000-0000-000000000112', '10000000-0000-0000-0000-000000000001', 'MAGATZEM',       'Magatzem',         true),
  ('41000000-0000-0000-0000-000000000113', '10000000-0000-0000-0000-000000000001', 'OPERARI',        'Operari',          true),
  ('41000000-0000-0000-0000-000000000114', '10000000-0000-0000-0000-000000000001', 'PROVADOR',       'Provador',         true),
  ('41000000-0000-0000-0000-000000000115', '10000000-0000-0000-0000-000000000001', 'TESTER',         'Tester',           true),
  ('41000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000002', 'OWNER',          'Owner',            true)
ON CONFLICT (id) DO NOTHING;

-- ─── Empleats de prova (attendance module) ────────────────────────────────────
-- site_id és obligatori per a record_time_punch i, si hi ha user_id, ha de coincidir
-- amb el site_id de tenant_members (p. ex. Dave → Acme Gràcia, no Sants).
INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, email, job_position_id, status, weekly_hours)
VALUES
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'Alice (Acme)',   'alice@acme-corp.com',   '41000000-0000-0000-0000-000000000101', 'active', 40),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004', 'Charlie (Acme)', 'charlie@acme-corp.com', '41000000-0000-0000-0000-000000000102', 'active', 40),
  ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'Dave (Acme)',    'dave@acme-corp.com',    '41000000-0000-0000-0000-000000000102', 'active', 40),
  ('40000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'Alice (Beta)',   'alice@acme-corp.com',   '41000000-0000-0000-0000-000000000201', 'active', 40)
ON CONFLICT DO NOTHING;

-- ─── Fase B: Signing + plantilles + empleats addicionals ──────────────────────

-- ─── B1. Feature flag i signing config ───────────────────────────────────────
INSERT INTO data.feature_flags (key, description, is_enabled, rollout_percentage)
VALUES ('tenant_signing_enabled', 'Mòdul de signatura electrònica per tenants', true, 100)
ON CONFLICT (key) DO UPDATE SET is_enabled = true, rollout_percentage = 100;

-- tenant_signing_config per Acme Corp (mode platform, 200 crèdits inicials)
INSERT INTO data.tenant_signing_config (tenant_id, mode, signing_credits, is_active)
VALUES ('10000000-0000-0000-0000-000000000001', 'platform', 200, true)
ON CONFLICT (tenant_id) DO NOTHING;

-- ─── B2. Empleats addicionals Acme Corp (fins a 50 total) ────────────────────
-- Site Gràcia (30000000-...001): empleats 005-030
-- Site Sants  (30000000-...002): empleats 031-050
INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, email, job_position_id, status, weekly_hours)
VALUES
  ('40000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Montserrat Puig Ferrer',  'montserrat.puig@acme-corp.com',   '41000000-0000-0000-0000-000000000104', 'active', 40),
  ('40000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Jordi Soler Mas',         'jordi.soler@acme-corp.com',        '41000000-0000-0000-0000-000000000104', 'active', 40),
  ('40000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Pau Roca Vidal',          'pau.roca@acme-corp.com',           '41000000-0000-0000-0000-000000000108', 'active', 40),
  ('40000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Laia Torres Serra',       'laia.torres@acme-corp.com',        '41000000-0000-0000-0000-000000000107', 'active', 37),
  ('40000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Marc Vila Bosch',         'marc.vila@acme-corp.com',          '41000000-0000-0000-0000-000000000109', 'active', 40),
  ('40000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Núria Font Palau',        'nuria.font@acme-corp.com',         '41000000-0000-0000-0000-000000000107', 'active', 37),
  ('40000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Gerard Sala Coll',        'gerard.sala@acme-corp.com',        '41000000-0000-0000-0000-000000000102', 'active', 40),
  ('40000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Marta Rovira Figueras',   'marta.rovira@acme-corp.com',       '41000000-0000-0000-0000-000000000105', 'active', 40),
  ('40000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Sergi Costa Ribas',       'sergi.costa@acme-corp.com',        '41000000-0000-0000-0000-000000000113', 'active', 40),
  ('40000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Arnau Esteve Carreras',   'arnau.esteve@acme-corp.com',       '41000000-0000-0000-0000-000000000110', 'active', 40),
  ('40000000-0000-0000-0000-000000000015', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Júlia Montalba Safont',   'julia.montalba@acme-corp.com',     '41000000-0000-0000-0000-000000000106', 'active', 40),
  ('40000000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Guillem Vilarrasa Codina','guillem.vilarrasa@acme-corp.com',  '41000000-0000-0000-0000-000000000104', 'active', 40),
  ('40000000-0000-0000-0000-000000000017', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Oriol Gironès Canals',    'oriol.girones@acme-corp.com',      '41000000-0000-0000-0000-000000000108', 'active', 40),
  ('40000000-0000-0000-0000-000000000018', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Anna Ferrer Mas',         'anna.ferrer@acme-corp.com',         '41000000-0000-0000-0000-000000000103', 'active', 40),
  ('40000000-0000-0000-0000-000000000019', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Miquel Puig Torres',      'miquel.puig@acme-corp.com',        '41000000-0000-0000-0000-000000000111', 'active', 40),
  ('40000000-0000-0000-0000-000000000020', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Joan Sala Roca',          'joan.sala@acme-corp.com',          '41000000-0000-0000-0000-000000000109', 'active', 40),
  ('40000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Albert Font Serra',       'albert.font@acme-corp.com',        '41000000-0000-0000-0000-000000000102', 'active', 40),
  ('40000000-0000-0000-0000-000000000022', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Carme Vila Bosch',        'carme.vila@acme-corp.com',         '41000000-0000-0000-0000-000000000112', 'active', 40),
  ('40000000-0000-0000-0000-000000000023', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Ferran Coll Palau',       'ferran.coll@acme-corp.com',        '41000000-0000-0000-0000-000000000104', 'active', 40),
  ('40000000-0000-0000-0000-000000000024', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Teresa Rovira Esteve',    'teresa.rovira@acme-corp.com',      '41000000-0000-0000-0000-000000000107', 'active', 37),
  ('40000000-0000-0000-0000-000000000025', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Josep Figueras Costa',    'josep.figueras@acme-corp.com',     '41000000-0000-0000-0000-000000000105', 'active', 40),
  ('40000000-0000-0000-0000-000000000026', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Susanna Ribas Carreras',  'susanna.ribas@acme-corp.com',      '41000000-0000-0000-0000-000000000106', 'active', 40),
  ('40000000-0000-0000-0000-000000000027', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Antoni Montalba Vidal',   'antoni.montalba@acme-corp.com',    '41000000-0000-0000-0000-000000000108', 'active', 40),
  ('40000000-0000-0000-0000-000000000028', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Isabel Safont Mas',       'isabel.safont@acme-corp.com',      '41000000-0000-0000-0000-000000000103', 'active', 40),
  ('40000000-0000-0000-0000-000000000029', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Enric Codina Soler',      'enric.codina@acme-corp.com',       '41000000-0000-0000-0000-000000000110', 'active', 40),
  ('40000000-0000-0000-0000-000000000030', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', NULL, 'Mercè Gironès Font',      'merce.girones@acme-corp.com',      '41000000-0000-0000-0000-000000000111', 'active', 40),
  -- Site Sants
  ('40000000-0000-0000-0000-000000000031', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Rafel Canals Vila',       'rafel.canals@acme-corp.com',       '41000000-0000-0000-0000-000000000104', 'active', 40),
  ('40000000-0000-0000-0000-000000000032', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Glòria Serra Roca',       'gloria.serra@acme-corp.com',       '41000000-0000-0000-0000-000000000107', 'active', 37),
  ('40000000-0000-0000-0000-000000000033', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Pere Torres Ferrer',      'pere.torres@acme-corp.com',        '41000000-0000-0000-0000-000000000108', 'active', 40),
  ('40000000-0000-0000-0000-000000000034', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Caterina Bosch Sala',     'caterina.bosch@acme-corp.com',     '41000000-0000-0000-0000-000000000105', 'active', 40),
  ('40000000-0000-0000-0000-000000000035', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Carles Vidal Puig',       'carles.vidal@acme-corp.com',       '41000000-0000-0000-0000-000000000109', 'active', 40),
  ('40000000-0000-0000-0000-000000000036', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Rosa Mas Soler',          'rosa.mas@acme-corp.com',           '41000000-0000-0000-0000-000000000103', 'active', 40),
  ('40000000-0000-0000-0000-000000000037', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Ricard Palau Coll',       'ricard.palau@acme-corp.com',       '41000000-0000-0000-0000-000000000104', 'active', 40),
  ('40000000-0000-0000-0000-000000000038', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Elena Rovira Costa',      'elena.rovira@acme-corp.com',       '41000000-0000-0000-0000-000000000112', 'active', 40),
  ('40000000-0000-0000-0000-000000000039', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Vicenç Esteve Ribas',     'vicenc.esteve@acme-corp.com',      '41000000-0000-0000-0000-000000000111', 'active', 40),
  ('40000000-0000-0000-0000-000000000040', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Àngels Figueras Carreras','angels.figueras@acme-corp.com',    '41000000-0000-0000-0000-000000000106', 'active', 40),
  ('40000000-0000-0000-0000-000000000041', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Xavier Montalba Safont',  'xavier.montalba@acme-corp.com',    '41000000-0000-0000-0000-000000000108', 'active', 40),
  ('40000000-0000-0000-0000-000000000042', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Lluís Vilarrasa Codina',  'lluis.vilarrasa@acme-corp.com',    '41000000-0000-0000-0000-000000000110', 'active', 40),
  ('40000000-0000-0000-0000-000000000043', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Bartomeu Gironès Canals', 'bartomeu.girones@acme-corp.com',   '41000000-0000-0000-0000-000000000102', 'active', 40),
  ('40000000-0000-0000-0000-000000000044', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Ignasi Soler Vila',       'ignasi.soler@acme-corp.com',       '41000000-0000-0000-0000-000000000104', 'active', 40),
  ('40000000-0000-0000-0000-000000000045', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Ramon Serra Bosch',       'ramon.serra@acme-corp.com',        '41000000-0000-0000-0000-000000000113', 'active', 40),
  ('40000000-0000-0000-0000-000000000046', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Narcís Font Palau',       'narcis.font@acme-corp.com',        '41000000-0000-0000-0000-000000000109', 'active', 40),
  ('40000000-0000-0000-0000-000000000047', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Elies Roca Coll',         'elies.roca@acme-corp.com',         '41000000-0000-0000-0000-000000000108', 'inactive', 40),
  ('40000000-0000-0000-0000-000000000048', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Maria Sala Rovira',       'maria.sala@acme-corp.com',         '41000000-0000-0000-0000-000000000107', 'active', 37),
  ('40000000-0000-0000-0000-000000000049', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Pau Torres Ferrer',       'pau.torres@acme-corp.com',         '41000000-0000-0000-0000-000000000111', 'active', 40),
  ('40000000-0000-0000-0000-000000000050', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Núria Vidal Mas',         'nuria.vidal@acme-corp.com',        '41000000-0000-0000-0000-000000000105', 'active', 40),
  ('40000000-0000-0000-0000-100000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Test User 1',              'jordi.devops@gmail.com',           '41000000-0000-0000-0000-000000000114', 'active', 40),
  ('40000000-0000-0000-0000-100000000002', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', NULL, 'Test User 2',              'jordi.cavalle@gmail.com',          '41000000-0000-0000-0000-000000000114', 'active', 40)
ON CONFLICT DO NOTHING;

-- ─── Jerarquia de reporting Acme (demo organigrama) ───────────────────────────
-- Reexecutable: scripts/seed-acme-org-hierarchy.sql
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_marta uuid := '40000000-0000-0000-0000-000000000012';
  v_julia uuid := '40000000-0000-0000-0000-000000000015';
  v_josep uuid := '40000000-0000-0000-0000-000000000025';
  v_laia uuid := '40000000-0000-0000-0000-000000000008';
  v_caterina uuid := '40000000-0000-0000-0000-000000000034';
  v_angels uuid := '40000000-0000-0000-0000-000000000040';
  v_gloria uuid := '40000000-0000-0000-0000-000000000032';
BEGIN
  UPDATE data.employees
  SET manager_employee_id = NULL
  WHERE tenant_id = v_tenant
    AND id::text LIKE '40000000-0000-0000-0000-%';

  UPDATE data.employees SET manager_employee_id = v_alice
  WHERE id IN (
    '40000000-0000-0000-0000-000000000002',
    '40000000-0000-0000-0000-000000000003',
    v_marta, v_julia, v_josep, v_laia
  );

  UPDATE data.employees SET manager_employee_id = v_marta
  WHERE id IN (
    '40000000-0000-0000-0000-000000000009',
    '40000000-0000-0000-0000-000000000011',
    '40000000-0000-0000-0000-000000000013',
    '40000000-0000-0000-0000-000000000014',
    '40000000-0000-0000-0000-000000000016',
    '40000000-0000-0000-0000-000000000023'
  );

  UPDATE data.employees SET manager_employee_id = v_julia
  WHERE id IN (
    '40000000-0000-0000-0000-000000000005',
    '40000000-0000-0000-0000-000000000006',
    '40000000-0000-0000-0000-000000000007',
    '40000000-0000-0000-0000-000000000017',
    '40000000-0000-0000-0000-000000000019',
    '40000000-0000-0000-0000-000000000020'
  );

  UPDATE data.employees SET manager_employee_id = v_josep
  WHERE id IN (
    '40000000-0000-0000-0000-000000000021',
    '40000000-0000-0000-0000-000000000027',
    '40000000-0000-0000-0000-000000000028',
    '40000000-0000-0000-0000-000000000029',
    '40000000-0000-0000-0000-000000000030'
  );

  UPDATE data.employees SET manager_employee_id = v_laia
  WHERE id IN (
    '40000000-0000-0000-0000-000000000010',
    '40000000-0000-0000-0000-000000000018',
    '40000000-0000-0000-0000-000000000022',
    '40000000-0000-0000-0000-000000000024',
    '40000000-0000-0000-0000-000000000026'
  );

  UPDATE data.employees SET manager_employee_id = v_caterina
  WHERE id IN (
    v_angels,
    v_gloria,
    '40000000-0000-0000-0000-000000000031',
    '40000000-0000-0000-0000-000000000033',
    '40000000-0000-0000-0000-000000000035',
    '40000000-0000-0000-0000-000000000043',
    '40000000-0000-0000-0000-000000000047'
  );

  UPDATE data.employees SET manager_employee_id = v_angels
  WHERE id IN (
    '40000000-0000-0000-0000-000000000037',
    '40000000-0000-0000-0000-000000000039',
    '40000000-0000-0000-0000-000000000041',
    '40000000-0000-0000-0000-000000000042',
    '40000000-0000-0000-0000-000000000044',
    '40000000-0000-0000-0000-000000000045',
    '40000000-0000-0000-0000-000000000046',
    '40000000-0000-0000-0000-000000000049'
  );

  UPDATE data.employees SET manager_employee_id = v_gloria
  WHERE id IN (
    '40000000-0000-0000-0000-000000000036',
    '40000000-0000-0000-0000-000000000038',
    '40000000-0000-0000-0000-000000000048'
  );
END $$;

-- ─── Skills de talent (catàleg + assignacions demo) ───────────────────────────
-- Acme: oficis industrials / gestió. Beta: producte lleuger.
-- Nivells per tipus: Bàsic(1) · Intermedi(2, default) · Avançat(3) · Expert(4)

INSERT INTO data.skill_types (id, tenant_id, name, is_certification_type, is_active)
VALUES
  -- Acme Corp
  ('42000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Oficis tècnics', false, true),
  ('42000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Gestió i lideratge', false, true),
  ('42000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Transversals', false, true),
  -- Beta Startup
  ('42000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000002', 'Producte i tecnologia', false, true),
  ('42000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000002', 'Soft skills', false, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.skill_levels (id, skill_type_id, name, rank, progress_pct, is_default)
VALUES
  -- Acme · Oficis tècnics
  ('42200000-0000-0000-0000-000000000011', '42000000-0000-0000-0000-000000000001', 'Bàsic',     1, 25,  false),
  ('42200000-0000-0000-0000-000000000012', '42000000-0000-0000-0000-000000000001', 'Intermedi', 2, 50,  true),
  ('42200000-0000-0000-0000-000000000013', '42000000-0000-0000-0000-000000000001', 'Avançat',   3, 75,  false),
  ('42200000-0000-0000-0000-000000000014', '42000000-0000-0000-0000-000000000001', 'Expert',    4, 100, false),
  -- Acme · Gestió i lideratge
  ('42200000-0000-0000-0000-000000000021', '42000000-0000-0000-0000-000000000002', 'Bàsic',     1, 25,  false),
  ('42200000-0000-0000-0000-000000000022', '42000000-0000-0000-0000-000000000002', 'Intermedi', 2, 50,  true),
  ('42200000-0000-0000-0000-000000000023', '42000000-0000-0000-0000-000000000002', 'Avançat',   3, 75,  false),
  ('42200000-0000-0000-0000-000000000024', '42000000-0000-0000-0000-000000000002', 'Expert',    4, 100, false),
  -- Acme · Transversals
  ('42200000-0000-0000-0000-000000000031', '42000000-0000-0000-0000-000000000003', 'Bàsic',     1, 25,  false),
  ('42200000-0000-0000-0000-000000000032', '42000000-0000-0000-0000-000000000003', 'Intermedi', 2, 50,  true),
  ('42200000-0000-0000-0000-000000000033', '42000000-0000-0000-0000-000000000003', 'Avançat',   3, 75,  false),
  ('42200000-0000-0000-0000-000000000034', '42000000-0000-0000-0000-000000000003', 'Expert',    4, 100, false),
  -- Beta · Producte i tecnologia
  ('42200000-0000-0000-0000-000000000111', '42000000-0000-0000-0000-000000000011', 'Bàsic',     1, 25,  false),
  ('42200000-0000-0000-0000-000000000112', '42000000-0000-0000-0000-000000000011', 'Intermedi', 2, 50,  true),
  ('42200000-0000-0000-0000-000000000113', '42000000-0000-0000-0000-000000000011', 'Avançat',   3, 75,  false),
  ('42200000-0000-0000-0000-000000000114', '42000000-0000-0000-0000-000000000011', 'Expert',    4, 100, false),
  -- Beta · Soft skills
  ('42200000-0000-0000-0000-000000000121', '42000000-0000-0000-0000-000000000012', 'Bàsic',     1, 25,  false),
  ('42200000-0000-0000-0000-000000000122', '42000000-0000-0000-0000-000000000012', 'Intermedi', 2, 50,  true),
  ('42200000-0000-0000-0000-000000000123', '42000000-0000-0000-0000-000000000012', 'Avançat',   3, 75,  false),
  ('42200000-0000-0000-0000-000000000124', '42000000-0000-0000-0000-000000000012', 'Expert',    4, 100, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.skills (id, tenant_id, skill_type_id, name, description, is_active)
VALUES
  -- Acme · Oficis
  ('42100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000001', 'Electricitat BT',
   'Instal·lacions i manteniment en baixa tensió', true),
  ('42100000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000001', 'Mecànica industrial',
   'Manteniment mecànic d''equips i línies', true),
  ('42100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000001', 'Soldadura',
   'Soldadura TIG/MIG i estructures metàl·liques', true),
  ('42100000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000001', 'Lectura de plànols',
   'Interpretació de plànols elèctrics i mecànics', true),
  ('42100000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000001', 'PLC / automatismes',
   'Programació i diagnòstic de PLC', true),
  ('42100000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000001', 'Instal·lacions HVAC',
   'Climatització i ventilació industrial', true),
  -- Acme · Gestió
  ('42100000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000002', 'Planificació d''obra',
   'Planificació de tasques, materials i terminis', true),
  ('42100000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000002', 'Gestió d''equips',
   'Coordinació i seguiment d''equips de camp', true),
  ('42100000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000002', 'Control de costos',
   'Seguiment de pressupost i desviacions', true),
  -- Acme · Transversals
  ('42100000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000003', 'Català tècnic',
   'Comunicació tècnica en català', true),
  ('42100000-0000-0000-0000-000000000022', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000003', 'Anglès tècnic',
   'Documentació i proveïdors en anglès', true),
  ('42100000-0000-0000-0000-000000000023', '10000000-0000-0000-0000-000000000001',
   '42000000-0000-0000-0000-000000000003', 'Formació de companys',
   'Capacitat d''ensenyar i acompanyar nous perfils', true),
  -- Beta
  ('42100000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000002',
   '42000000-0000-0000-0000-000000000011', 'TypeScript',
   'Desenvolupament frontend/backend amb TypeScript', true),
  ('42100000-0000-0000-0000-000000000102', '10000000-0000-0000-0000-000000000002',
   '42000000-0000-0000-0000-000000000011', 'SQL / dades',
   'Consultes i modelatge de dades', true),
  ('42100000-0000-0000-0000-000000000103', '10000000-0000-0000-0000-000000000002',
   '42000000-0000-0000-0000-000000000011', 'Product discovery',
   'Recerca d''usuari i priorització de backlog', true),
  ('42100000-0000-0000-0000-000000000111', '10000000-0000-0000-0000-000000000002',
   '42000000-0000-0000-0000-000000000012', 'Comunicació',
   'Comunicació clara amb stakeholders', true),
  ('42100000-0000-0000-0000-000000000112', '10000000-0000-0000-0000-000000000002',
   '42000000-0000-0000-0000-000000000012', 'Facilitació de reunions',
   'Moderació d''esprints i workshops', true)
ON CONFLICT (id) DO NOTHING;

-- Assignacions Acme (mostra representativa per oficis / managers)
INSERT INTO data.employee_skills (
  id, tenant_id, employee_id, skill_id, level_id, acquired_on, last_assessed_on, notes
)
VALUES
  -- Alice (Manager) — lideratge + transversals
  ('42300000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000001', '42100000-0000-0000-0000-000000000012',
   '42200000-0000-0000-0000-000000000024', '2022-03-01', '2026-01-15', 'Manager global Acme'),
  ('42300000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000001', '42100000-0000-0000-0000-000000000011',
   '42200000-0000-0000-0000-000000000023', '2021-06-01', '2025-11-20', NULL),
  ('42300000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000001', '42100000-0000-0000-0000-000000000022',
   '42200000-0000-0000-0000-000000000033', '2020-01-01', '2025-09-01', NULL),
  -- Charlie / Dave (Tècnics)
  ('42300000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000002', '42100000-0000-0000-0000-000000000005',
   '42200000-0000-0000-0000-000000000013', '2023-02-10', '2026-02-01', 'PLC Siemens'),
  ('42300000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000002', '42100000-0000-0000-0000-000000000004',
   '42200000-0000-0000-0000-000000000012', '2023-02-10', '2025-10-12', NULL),
  ('42300000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000003', '42100000-0000-0000-0000-000000000001',
   '42200000-0000-0000-0000-000000000012', '2024-01-08', '2025-12-01', NULL),
  ('42300000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000003', '42100000-0000-0000-0000-000000000004',
   '42200000-0000-0000-0000-000000000011', '2024-01-08', '2025-08-15', NULL),
  -- Electricistes
  ('42300000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000005', '42100000-0000-0000-0000-000000000001',
   '42200000-0000-0000-0000-000000000014', '2018-05-01', '2026-03-01', 'Referent elèctric Gràcia'),
  ('42300000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000005', '42100000-0000-0000-0000-000000000004',
   '42200000-0000-0000-0000-000000000013', '2019-01-01', '2025-11-01', NULL),
  ('42300000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000006', '42100000-0000-0000-0000-000000000001',
   '42200000-0000-0000-0000-000000000013', '2020-09-15', '2026-01-20', NULL),
  ('42300000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000016', '42100000-0000-0000-0000-000000000001',
   '42200000-0000-0000-0000-000000000012', '2022-04-01', '2025-09-30', NULL),
  ('42300000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000031', '42100000-0000-0000-0000-000000000001',
   '42200000-0000-0000-0000-000000000013', '2019-11-01', '2026-02-10', 'Referent elèctric Sants'),
  -- Mecànics / soldadura
  ('42300000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000007', '42100000-0000-0000-0000-000000000002',
   '42200000-0000-0000-0000-000000000013', '2021-03-01', '2025-12-15', NULL),
  ('42300000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000007', '42100000-0000-0000-0000-000000000003',
   '42200000-0000-0000-0000-000000000012', '2021-03-01', '2025-10-01', NULL),
  ('42300000-0000-0000-0000-000000000015', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000017', '42100000-0000-0000-0000-000000000002',
   '42200000-0000-0000-0000-000000000012', '2023-07-01', '2026-01-05', NULL),
  ('42300000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000033', '42100000-0000-0000-0000-000000000002',
   '42200000-0000-0000-0000-000000000014', '2017-02-01', '2026-02-20', 'Mecànic senior Sants'),
  ('42300000-0000-0000-0000-000000000017', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000033', '42100000-0000-0000-0000-000000000003',
   '42200000-0000-0000-0000-000000000013', '2018-06-01', '2025-11-18', NULL),
  -- Caps d'obra / encarregades
  ('42300000-0000-0000-0000-000000000018', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000012', '42100000-0000-0000-0000-000000000011',
   '42200000-0000-0000-0000-000000000023', '2019-04-01', '2026-01-10', NULL),
  ('42300000-0000-0000-0000-000000000019', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000012', '42100000-0000-0000-0000-000000000012',
   '42200000-0000-0000-0000-000000000023', '2019-04-01', '2026-01-10', NULL),
  ('42300000-0000-0000-0000-000000000020', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000015', '42100000-0000-0000-0000-000000000012',
   '42200000-0000-0000-0000-000000000022', '2021-08-01', '2025-12-01', NULL),
  ('42300000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000015', '42100000-0000-0000-0000-000000000023',
   '42200000-0000-0000-0000-000000000033', '2022-01-15', '2025-09-01', NULL),
  ('42300000-0000-0000-0000-000000000022', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000025', '42100000-0000-0000-0000-000000000011',
   '42200000-0000-0000-0000-000000000022', '2020-05-01', '2025-10-20', NULL),
  ('42300000-0000-0000-0000-000000000023', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000034', '42100000-0000-0000-0000-000000000011',
   '42200000-0000-0000-0000-000000000023', '2018-09-01', '2026-02-01', 'Cap d''obra Sants'),
  ('42300000-0000-0000-0000-000000000024', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000034', '42100000-0000-0000-0000-000000000013',
   '42200000-0000-0000-0000-000000000022', '2019-01-01', '2025-11-05', NULL),
  ('42300000-0000-0000-0000-000000000025', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000040', '42100000-0000-0000-0000-000000000012',
   '42200000-0000-0000-0000-000000000023', '2020-02-01', '2026-01-28', NULL),
  -- Admin / magatzem / HVAC
  ('42300000-0000-0000-0000-000000000026', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000008', '42100000-0000-0000-0000-000000000013',
   '42200000-0000-0000-0000-000000000022', '2022-11-01', '2025-12-10', NULL),
  ('42300000-0000-0000-0000-000000000027', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000008', '42100000-0000-0000-0000-000000000021',
   '42200000-0000-0000-0000-000000000034', '2015-01-01', '2025-06-01', NULL),
  ('42300000-0000-0000-0000-000000000028', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000022', '42100000-0000-0000-0000-000000000006',
   '42200000-0000-0000-0000-000000000012', '2023-05-01', '2025-10-08', 'Magatzem + suport HVAC'),
  ('42300000-0000-0000-0000-000000000029', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000023', '42100000-0000-0000-0000-000000000006',
   '42200000-0000-0000-0000-000000000013', '2021-10-01', '2026-01-12', NULL),
  ('42300000-0000-0000-0000-000000000030', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000011', '42100000-0000-0000-0000-000000000005',
   '42200000-0000-0000-0000-000000000012', '2024-03-01', '2025-11-22', NULL),
  ('42300000-0000-0000-0000-000000000031', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000018', '42100000-0000-0000-0000-000000000005',
   '42200000-0000-0000-0000-000000000011', '2024-09-01', '2025-12-20', 'Junior PLC'),
  ('42300000-0000-0000-0000-000000000032', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000036', '42100000-0000-0000-0000-000000000022',
   '42200000-0000-0000-0000-000000000032', '2022-06-01', '2025-08-01', NULL),
  -- Beta · Alice
  ('42300000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000004', '42100000-0000-0000-0000-000000000101',
   '42200000-0000-0000-0000-000000000113', '2023-01-15', '2026-01-10', NULL),
  ('42300000-0000-0000-0000-000000000102', '10000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000004', '42100000-0000-0000-0000-000000000103',
   '42200000-0000-0000-0000-000000000112', '2023-01-15', '2025-12-01', NULL),
  ('42300000-0000-0000-0000-000000000103', '10000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000004', '42100000-0000-0000-0000-000000000111',
   '42200000-0000-0000-0000-000000000123', '2022-05-01', '2025-10-15', NULL)
ON CONFLICT (id) DO NOTHING;

-- ─── Employee portal dev tokens (EP0/EP2 spike) ───────────────────────────────
-- Secrets: ep0-dev-acme-montserrat, ep0-dev-beta-alice (see employee-portal constants)
INSERT INTO data.employee_portal_tokens (
  id,
  tenant_id,
  employee_id,
  token_hash,
  label,
  is_active
)
VALUES
  (
    '50000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000005',
    digest('ep0-dev-acme-montserrat', 'sha256'),
    'Spike dev Acme',
    true
  ),
  (
    '50000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000002',
    '40000000-0000-0000-0000-000000000004',
    digest('ep0-dev-beta-alice', 'sha256'),
    'Spike dev Beta',
    true
  )
ON CONFLICT (id) DO NOTHING;

-- ─── B3. Contactes Acme Corp ──────────────────────────────────────────────────
-- Prefix 80: 80000000-0000-0000-0000-000000000001 → 000000000015
INSERT INTO data.contacts (id, tenant_id, site_id, kind, display_name, given_name, family_name, legal_name, tax_id, email, phone, tags, source)
VALUES
  -- Empreses clients / proveïdors
  ('80000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', NULL, 'company', 'Constructora Meridian S.L.',  NULL,          NULL,           'Constructora Meridian S.L.',  'B-12345678', 'info@meridian.cat',         '+34931234567', '{"client","construccio"}',    'manual'),
  ('80000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', NULL, 'company', 'Elèctrica Llevant S.A.',      NULL,          NULL,           'Elèctrica Llevant S.A.',      'A-87654321', 'contacte@llevant.es',        '+34934567890', '{"proveidor","electric"}',    'manual'),
  ('80000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', NULL, 'company', 'Logística Tramuntana S.L.',   NULL,          NULL,           'Logística Tramuntana S.L.',   'B-11223344', 'ops@tramuntana.cat',         '+34935551234', '{"proveidor","logistica"}',   'manual'),
  ('80000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', NULL, 'company', 'Manteniment Ponent S.C.P.',   NULL,          NULL,           'Manteniment Ponent S.C.P.',   'J-44556677', 'info@ponent-mant.cat',       '+34936669900', '{"client","manteniment"}',    'import'),
  ('80000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', NULL, 'company', 'Seguretat Garriga S.A.',      NULL,          NULL,           'Seguretat Garriga S.A.',      'A-99887766', 'comercial@garriga.es',       '+34932223344', '{"proveidor","seguretat"}',   'manual'),
  -- Persones de contacte (interlocutors)
  ('80000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', NULL, 'person',  'Tomàs Aguilera Blanes',       'Tomàs',       'Aguilera Blanes', NULL,                       NULL,         'taguilera@meridian.cat',     '+34617111222', '{"client","interlocutor"}',   'manual'),
  ('80000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', NULL, 'person',  'Cristina Nadal Pons',         'Cristina',    'Nadal Pons',      NULL,                       NULL,         'cnadal@llevant.es',          '+34618333444', '{"proveidor"}',               'manual'),
  ('80000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', NULL, 'person',  'Francesc Oliva Martí',        'Francesc',    'Oliva Martí',     NULL,                       NULL,         'foliva@tramuntana.cat',       '+34619555666', '{"proveidor","logistica"}',   'web'),
  ('80000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'person', 'Laura Campins Verd', 'Laura', 'Campins Verd',              NULL,          NULL,         'lcampins@acme-corp.com',     '+34620777888', '{"intern","rrhh"}',           'manual'),
  ('80000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'person', 'David Espinosa Tort', 'David','Espinosa Tort',              NULL,          NULL,         'despinosa@acme-corp.com',    '+34621999000', '{"intern","prl"}',            'manual'),
  ('80000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', 'person', 'Sílvia Quer Pujades','Sílvia','Quer Pujades',               NULL,          NULL,         'squer@acme-corp.com',        '+34622001122', '{"intern","rrhh"}',           'manual'),
  ('80000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001', NULL, 'person',  'Miquel Cabot Llull',          'Miquel',      'Cabot Llull',     NULL,                       NULL,         'mcabot@ponent-mant.cat',     '+34623112233', '{"client"}',                  'referral'),
  ('80000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001', NULL, 'person',  'Joana Garau Florit',          'Joana',       'Garau Florit',    NULL,                       NULL,         'jgarau@garriga.es',          '+34624223344', '{"proveidor","seguretat"}',   'manual'),
  ('80000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001', NULL, 'company', 'Assessoria Jurídica Illes S.L.',NULL,         NULL,            'Assessoria Jurídica Illes S.L.','B-55443322','info@aijilles.cat',          '+34971334455', '{"assessoria","legal"}',      'manual'),
  ('80000000-0000-0000-0000-000000000015', '10000000-0000-0000-0000-000000000001', NULL, 'person',  'Bernat Pons Riutord',         'Bernat',      'Pons Riutord',    NULL,                       NULL,         'bpons@aijilles.cat',         '+34625334455', '{"assessoria","legal"}',      'manual')
ON CONFLICT DO NOTHING;

-- ─── B4/B5. Plantilles de documents ─────────────────────────────────────────
-- Les plantilles de plataforma (HTML + DOCX) viuen a les migracions:
--   20260617000001_seed_extra_document_templates.sql  (RRHH/legal/… HTML+DOCX)
--   20261164000001_commercial_templates_seed_html.sql (pressupost/albarà HTML)
--   20261168000001_commercial_templates_seed_docx.sql (pressupost/albarà DOCX)
-- Els fitxers DOCX (RRHH i comercials) es pugen amb:
--   cd scripts && node generate-docx-seed.mjs
-- Com i quan: scripts/README.md. db reset no puja binaris a Storage.

-- ─── B4b. Plantilles documentals demo (Acme Corp, 008-014) ─────────────────
-- No són plantilles de plataforma; requereix tenant i perfils creats abans (B1-B3).

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by)
VALUES
('70000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', 'Annexe revisió salarial anual',        'Comunicació formal de revisió de salari.',                    'hr',         'html', false, true, '20000000-0000-0000-0000-000000000002'),
('70000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001', 'Cessió temporal d''equipament',        'Acta de cessió d''eines o dispositius.',                      'operations', 'html', false, true, '20000000-0000-0000-0000-000000000002'),
('70000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', 'Autorització accés a instal·lació',    'Autorització per treballar a instal·lacions de client.',      'operations', 'html', false, true, '20000000-0000-0000-0000-000000000002'),
('70000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001', 'Informe d''incident tècnic',           'Registre intern d''incidents (generar i arxivar).',           'safety',     'html', false, true, '20000000-0000-0000-0000-000000000002'),
('70000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001', 'Acta de traspàs de funcions',          'Formalitza el traspàs de funcions entre dos treballadors.',   'hr',         'html', false, true, '20000000-0000-0000-0000-000000000002'),
('70000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001', 'Nota informativa RGPD',                'Informació al treballador sobre tractament de dades.',        'legal',      'html', false, true, '20000000-0000-0000-0000-000000000002'),
('70000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001', 'Informe de seguiment setmanal',        'Resum d''activitats setmanals per a direcció.',               'operations', 'html', false, true, '20000000-0000-0000-0000-000000000002')
ON CONFLICT DO NOTHING;

-- ─── Plantilles HTML: variables_schema i sintaxi de variables ───────────────
-- Dos enfocaments conviuen:
--   A) Schema-based: clau = camp DB (full_name, document_id, job_position_id) + "role" → l'usuari veu el camp pre-omplert i pot editar-lo.
--   B) Path-based:  {{Rol.camp}} directament a l'HTML → resolt automàticament des del role assignment, l'usuari no veu cap camp de formulari.
-- Plantilles 1-3, 8-10, 12 → enfocament A.  Plantilles 4, 5, 6, 13 → enfocament B.


INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
(
  '71000000-0000-0000-0000-000000000008','70000000-0000-0000-0000-000000000008','ca','text/html',NULL,
  '<h1>Annexe: Revisió Salarial Anual</h1><p>S''informa a <strong>{{full_name}}</strong> que des del <strong>{{data_efecte}}</strong> el salari brut anual passa de <strong>{{salari_actual}} EUR</strong> a <strong>{{nou_salari}} EUR</strong> (increment del <strong>{{percentatge}}%</strong>). La present comunicació constitueix un annex al contracte vigent.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"salari_actual":{"type":"number","label":"Salari actual (EUR/any)","required":true,"order":1},"nou_salari":{"type":"number","label":"Nou salari (EUR/any)","required":true,"order":2},"percentatge":{"type":"number","label":"Increment (%)","required":true,"order":3},"data_efecte":{"type":"date","label":"Data d''efecte","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"manager":{"entity_type":"employee","label":"Director/a","order":1,"for_signing":true}}',
  '{"full_name":"Marta Rovira Figueras","salari_actual":"28000","nou_salari":"29400","percentatge":"5","data_efecte":"2026-01-01"}',
  true
),
(
  '71000000-0000-0000-0000-000000000009','70000000-0000-0000-0000-000000000009','ca','text/html',NULL,
  '<h1>Acta de Cessió Temporal d''Equipament</h1><p>Es cedeix temporalment al/a la treballador/a <strong>{{full_name}}</strong> l''equipament <strong>{{nom_equip}}</strong> (num. serie: <strong>{{num_serie}}</strong>), del <strong>{{data_cessio}}</strong> fins al <strong>{{data_retorn_prevista}}</strong>. El treballador/a n''és responsable i el retornarà en bon estat.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nom_equip":{"type":"string","label":"Nom de l''equip","required":true,"order":1},"num_serie":{"type":"string","label":"Numero de serie","required":false,"order":2},"data_cessio":{"type":"date","label":"Data de cessió","required":true,"order":3},"data_retorn_prevista":{"type":"date","label":"Data retorn prevista","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"warehouse_manager":{"entity_type":"employee","label":"Responsable de magatzem","order":1,"for_signing":true}}',
  '{"full_name":"Sergi Costa Ribas","nom_equip":"Tauleta de camp ruggeditzada","num_serie":"SN-2024-0042","data_cessio":"2025-07-01","data_retorn_prevista":"2025-12-31"}',
  true
),
(
  '71000000-0000-0000-0000-000000000010','70000000-0000-0000-0000-000000000010','ca','text/html',NULL,
  '<h1>Autorització d''Acces a Instal·lació de Client</h1><p>S''autoritza al/a la treballador/a <strong>{{full_name}}</strong> per accedir a les instal·lacions de <strong>{{nom_client}}</strong> (adreca: <strong>{{adreca_client}}</strong>) el dia <strong>{{data_acces}}</strong>. L''accés es limita a les activitats del servei contractat.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nom_client":{"type":"string","label":"Nom del client","required":true,"order":1},"adreca_client":{"type":"string","label":"Adreca del client","required":true,"order":2},"data_acces":{"type":"date","label":"Data d''acces","required":true,"order":3}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"site_manager":{"entity_type":"employee","label":"Cap d''obra","order":1,"for_signing":true}}',
  '{"full_name":"Jordi Soler Mas","nom_client":"Constructora Meridian S.L.","adreca_client":"Carrer de la Industria 45, Barcelona","data_acces":"2025-07-10"}',
  true
),
(
  '71000000-0000-0000-0000-000000000011','70000000-0000-0000-0000-000000000011','ca','text/html',NULL,
  '<h1>Informe d''Incident Tecnic</h1><table><tr><th>Camp</th><th>Detall</th></tr><tr><td>Data</td><td>{{data_incident}}</td></tr><tr><td>Lloc</td><td>{{lloc}}</td></tr><tr><td>Descripcio</td><td>{{descripcio_incident}}</td></tr><tr><td>Mesures adoptades</td><td>{{mesures_adoptades}}</td></tr></table>',
  '{"data_incident":{"type":"date","label":"Data de l''incident","required":true,"order":0},"lloc":{"type":"string","label":"Lloc de l''incident","required":true,"order":1},"descripcio_incident":{"type":"string","label":"Descripcio de l''incident","required":true,"order":2},"mesures_adoptades":{"type":"string","label":"Mesures adoptades","required":true,"order":3}}',
  '{}',
  '{"data_incident":"2025-06-20","lloc":"Sala quadres electrics, planta 2","descripcio_incident":"Curtcircuit menor. Sense ferits.","mesures_adoptades":"Substitucio fusibles. Notificacio al responsable."}',
  true
),
(
  '71000000-0000-0000-0000-000000000012','70000000-0000-0000-0000-000000000012','ca','text/html',NULL,
  '<h1>Acta de Traspass de Funcions</h1><p><strong>{{nom_cedent}}</strong> fa traspass formal de funcions a <strong>{{nom_receptor}}</strong> amb efectes des del <strong>{{data_traspas}}</strong>. Funcions traspassades: <strong>{{funcions_traspassades}}</strong>. Ambdues parts confirmen que el traspass s''ha efectuat de manera completa.</p>',
  '{"nom_cedent":{"type":"string","label":"Nom del cedent","required":true,"role":"transferor","order":0},"nom_receptor":{"type":"string","label":"Nom del receptor","required":true,"role":"recipient","order":1},"funcions_traspassades":{"type":"string","label":"Funcions traspassades","required":true,"order":2},"data_traspas":{"type":"date","label":"Data de traspass","required":true,"order":3}}',
  '{"transferor":{"entity_type":"employee","label":"Cedent","order":0,"for_signing":true},"recipient":{"entity_type":"employee","label":"Receptor","order":1,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":2,"for_signing":true}}',
  '{"nom_cedent":"Susanna Ribas Carreras","nom_receptor":"Julia Montalba Safont","funcions_traspassades":"Coordinacio equip Gracia, gestio comandes i control magatzem","data_traspas":"2025-09-15"}',
  true
),
(
  '71000000-0000-0000-0000-000000000013','70000000-0000-0000-0000-000000000013','ca','text/html',NULL,
  '<h1>Nota Informativa sobre Proteccio de Dades (RGPD)</h1><p>En compliment del Reglament (UE) 2016/679, s''informa a <strong>{{worker.full_name}}</strong> que les seves dades personals seran tractades per Acme Corp S.A. per gestionar la relacio laboral. Pot exercir els drets d''acces, rectificacio, supressio i portabilitat a rrhh@acme-corp.com.</p><p>Confirmo haver rebut la present informacio. Data: <strong>{{data}}</strong>.</p>',
  '{"data":{"type":"date","label":"Data","required":true,"order":0}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a (confirmacio recepcio)","order":0,"for_signing":true}}',
  '{"data":"2025-07-01"}',
  true
),
(
  '71000000-0000-0000-0000-000000000014','70000000-0000-0000-0000-000000000014','ca','text/html',NULL,
  '<h1>Informe de Seguiment Setmanal</h1><table><tr><th>Camp</th><th>Detall</th></tr><tr><td>Setmana</td><td>{{setmana}}</td></tr><tr><td>Responsable</td><td>{{responsable}}</td></tr><tr><td>Activitats</td><td>{{activitats}}</td></tr><tr><td>Observacions</td><td>{{observacions}}</td></tr></table>',
  '{"setmana":{"type":"string","label":"Setmana (ex: 2025-W28)","required":true,"order":0},"responsable":{"type":"string","label":"Responsable","required":true,"order":1},"activitats":{"type":"string","label":"Activitats realitzades","required":true,"order":2},"observacions":{"type":"string","label":"Observacions","required":false,"order":3}}',
  '{}',
  '{"setmana":"2025-W28","responsable":"Marta Rovira Figueras","activitats":"Revisio quadres electrics edifici A i B. Manteniment preventiu de equips.","observacions":"Pendent reposicio peces quadre B."}',
  true
)
ON CONFLICT DO NOTHING;


-- ─── B5. Plantilles de documents DOCX ─────────────────────────────────────
-- Prefix 72: document_templates  (001-007 plataforma, 008-014 Acme Corp, 015 Test de firmes)
-- Prefix 73: document_template_locales (001-015, locale='ca', mime=docx)
-- Generat amb: cd scripts && SUPABASE_SERVICE_ROLE_KEY=<key> node generate-docx-seed.mjs



INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by)
VALUES
('72000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', 'Annexe revisió salarial anual', 'Comunicació formal de revisió de salari.', 'hr', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
('72000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001', 'Cessió temporal d''equipament', 'Acta de cessió d''eines o dispositius.', 'operations', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
('72000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', 'Autorització accés a instal·lació', 'Autorització per treballar a instal·lacions de client.', 'operations', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
('72000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001', 'Informe d''incident tècnic', 'Registre intern d''incidents (generar i arxivar).', 'safety', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
('72000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001', 'Acta de traspàs de funcions', 'Formalitza el traspàs de funcions entre dos treballadors.', 'hr', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
('72000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001', 'Nota informativa RGPD', 'Informació al treballador sobre tractament de dades.', 'legal', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
('72000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001', 'Informe de seguiment setmanal', 'Resum d''activitats setmanals per a direcció.', 'operations', 'docx', false, true, '20000000-0000-0000-0000-000000000002')
ON CONFLICT DO NOTHING;



INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
(
  '73000000-0000-0000-0000-000000000008', '72000000-0000-0000-0000-000000000008', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/08-revisio-salarial-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"salari_actual":{"type":"number","label":"Salari actual (EUR/any)","required":true,"order":1},"nou_salari":{"type":"number","label":"Nou salari (EUR/any)","required":true,"order":2},"percentatge":{"type":"number","label":"Increment (%)","required":true,"order":3},"data_efecte":{"type":"date","label":"Data d''efecte","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"manager":{"entity_type":"employee","label":"Director/a","order":1,"for_signing":true}}',
  '{"full_name":"Marta Rovira Figueras","salari_actual":"28000","nou_salari":"29400","percentatge":"5","data_efecte":"2026-01-01"}',
  true
),
(
  '73000000-0000-0000-0000-000000000009', '72000000-0000-0000-0000-000000000009', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/09-cessio-equipament-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nom_equip":{"type":"string","label":"Nom de l''equip","required":true,"order":1},"num_serie":{"type":"string","label":"Número de sèrie","required":false,"order":2},"data_cessio":{"type":"date","label":"Data de cessió","required":true,"order":3},"data_retorn_prevista":{"type":"date","label":"Data retorn prevista","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"warehouse_manager":{"entity_type":"employee","label":"Responsable magatzem","order":1,"for_signing":true}}',
  '{"full_name":"Sergi Costa Ribas","nom_equip":"Tauleta de camp ruggeditzada","num_serie":"SN-2024-0042","data_cessio":"2025-07-01","data_retorn_prevista":"2025-12-31"}',
  true
),
(
  '73000000-0000-0000-0000-000000000010', '72000000-0000-0000-0000-000000000010', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/10-autoritzacio-acces-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nom_client":{"type":"string","label":"Nom del client","required":true,"order":1},"adreca_client":{"type":"string","label":"Adreça del client","required":true,"order":2},"data_acces":{"type":"date","label":"Data d''accés","required":true,"order":3}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"site_manager":{"entity_type":"user","label":"Cap d''obra","order":1,"for_signing":true}}',
  '{"full_name":"Jordi Soler Mas","nom_client":"Constructora Meridian S.L.","adreca_client":"Carrer de la Indústria 45, Barcelona","data_acces":"2025-07-10"}',
  true
),
(
  '73000000-0000-0000-0000-000000000011', '72000000-0000-0000-0000-000000000011', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/11-informe-incident-tecnic-ca.docx', NULL,
  '{"data_incident":{"type":"date","label":"Data de l''incident","required":true,"order":0},"lloc":{"type":"string","label":"Lloc de l''incident","required":true,"order":1},"descripcio_incident":{"type":"string","label":"Descripció de l''incident","required":true,"order":2},"mesures_adoptades":{"type":"string","label":"Mesures adoptades","required":true,"order":3}}',
  '{}',
  '{"data_incident":"2025-06-20","lloc":"Sala quadres elèctrics, planta 2","descripcio_incident":"Curtcircuit menor. Sense ferits.","mesures_adoptades":"Substitució fusibles. Notificació al responsable."}',
  true
),
(
  '73000000-0000-0000-0000-000000000012', '72000000-0000-0000-0000-000000000012', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/12-traspas-funcions-ca.docx', NULL,
  '{"nom_cedent":{"type":"string","label":"Nom del cedent","required":true,"role":"transferor","order":0},"nom_receptor":{"type":"string","label":"Nom del receptor","required":true,"role":"recipient","order":1},"funcions_traspassades":{"type":"string","label":"Funcions traspassades","required":true,"order":2},"data_traspas":{"type":"date","label":"Data de traspàs","required":true,"order":3}}',
  '{"transferor":{"entity_type":"employee","label":"Cedent","order":0,"for_signing":true},"recipient":{"entity_type":"employee","label":"Receptor","order":1,"for_signing":true},"manager":{"entity_type":"employee","label":"Responsable RRHH","order":2,"for_signing":true}}',
  '{"nom_cedent":"Susanna Ribas Carreras","nom_receptor":"Júlia Montalba Safont","funcions_traspassades":"Coordinació equip Gràcia, gestió comandes i control magatzem","data_traspas":"2025-09-15"}',
  true
),
(
  '73000000-0000-0000-0000-000000000013', '72000000-0000-0000-0000-000000000013', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/13-nota-rgpd-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"data":{"type":"date","label":"Data","required":true,"order":1}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a (confirmació recepció)","order":0,"for_signing":true}}',
  '{"full_name":"Marta Rovira Figueras","data":"2025-07-01"}',
  true
),
(
  '73000000-0000-0000-0000-000000000014', '72000000-0000-0000-0000-000000000014', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/14-informe-seguiment-setmanal-ca.docx', NULL,
  '{"setmana":{"type":"string","label":"Setmana (ex: 2025-W28)","required":true,"order":0},"responsable":{"type":"string","label":"Responsable","required":true,"order":1},"activitats":{"type":"string","label":"Activitats realitzades","required":true,"order":2},"observacions":{"type":"string","label":"Observacions","required":false,"order":3}}',
  '{}',
  '{"setmana":"2025-W28","responsable":"Marta Rovira Figueras","activitats":"Revisió quadres elèctrics edifici A i B. Manteniment preventiu de equips.","observacions":"Pendent reposició peces quadre B."}',
  true
)
ON CONFLICT DO NOTHING;

-- ─── B5b. Archetype tagging — platform templates (F16) ──────────────────────
-- NULL = universal; array = sectors on té sentit per defecte.
-- HTML series (70-prefix)
UPDATE data.document_templates SET target_archetypes = ARRAY['hospitality','workshop_maker','practice','generic'] WHERE id IN ('70000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000002','70000000-0000-0000-0000-000000000003','70000000-0000-0000-0000-000000000006','70000000-0000-0000-0000-000000000007','70000000-0000-0000-0000-000000000015');
UPDATE data.document_templates SET target_archetypes = ARRAY['field_service','workshop_maker','hospitality'] WHERE id = '70000000-0000-0000-0000-000000000004';
-- 005 (confidencialitat) + 013 (RGPD) → NULL (universal, no cal UPDATE)
-- DOCX series (72-prefix)
UPDATE data.document_templates SET target_archetypes = ARRAY['hospitality','workshop_maker','practice','generic'] WHERE id IN ('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-000000000002','72000000-0000-0000-0000-000000000003','72000000-0000-0000-0000-000000000006','72000000-0000-0000-0000-000000000007','72000000-0000-0000-0000-000000000015');
UPDATE data.document_templates SET target_archetypes = ARRAY['field_service','workshop_maker','hospitality'] WHERE id = '72000000-0000-0000-0000-000000000004';

-- ─── B6. Departaments (Acme Corp) ────────────────────────────────────────────
-- Prefix 43: departments (001-006)
-- Empresa d'instal·lacions elèctriques i manteniment industrial.
-- Estructura:
--   Direcció (001)
--   ├── Recursos Humans (002)
--   ├── Operacions (003) → manager: Charlie
--   │   ├── Taller (004)
--   │   └── Obres Externes (005)
--   └── Administració (006)
--
-- manager_id referencia data.profiles(id):
--   Alice  = 20000000-0000-0000-0000-000000000002
--   Charlie = 20000000-0000-0000-0000-000000000004
-- Cal insertar pare abans dels fills (FK auto-referencial).

INSERT INTO data.departments (id, tenant_id, parent_id, name, code, manager_id, is_active)
VALUES
  -- Nivell arrel
  ('43000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001',
   NULL,
   'Direcció', 'DIR',
   '20000000-0000-0000-0000-000000000002',
   true),
  ('43000000-0000-0000-0000-000000000002',
   '10000000-0000-0000-0000-000000000001',
   '43000000-0000-0000-0000-000000000001',
   'Recursos Humans', 'RRHH',
   NULL,
   true),
  ('43000000-0000-0000-0000-000000000003',
   '10000000-0000-0000-0000-000000000001',
   '43000000-0000-0000-0000-000000000001',
   'Operacions', 'OPS',
   '20000000-0000-0000-0000-000000000004',
   true),
  ('43000000-0000-0000-0000-000000000006',
   '10000000-0000-0000-0000-000000000001',
   '43000000-0000-0000-0000-000000000001',
   'Administració', 'ADM',
   '20000000-0000-0000-0000-000000000002',
   true),
  -- Fills d'Operacions
  ('43000000-0000-0000-0000-000000000004',
   '10000000-0000-0000-0000-000000000001',
   '43000000-0000-0000-0000-000000000003',
   'Taller', 'TAL',
   '20000000-0000-0000-0000-000000000004',
   true),
  ('43000000-0000-0000-0000-000000000005',
   '10000000-0000-0000-0000-000000000001',
   '43000000-0000-0000-0000-000000000003',
   'Obres Externes', 'OBR',
   NULL,
   true)
ON CONFLICT (id) DO NOTHING;

-- Assignar membres del tenant al seu departament
-- (camp department_id afegit per 20260502000001_departments_projects_tasks.sql)
UPDATE data.tenant_members
SET department_id = '43000000-0000-0000-0000-000000000001'  -- Direcció
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND user_id   = '20000000-0000-0000-0000-000000000002'   -- Alice (owner global)
  AND site_id IS NULL;

UPDATE data.tenant_members
SET department_id = '43000000-0000-0000-0000-000000000001'  -- Direcció
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND user_id   = '20000000-0000-0000-0000-000000000003'   -- Bob (owner global)
  AND site_id IS NULL;

UPDATE data.tenant_members
SET department_id = '43000000-0000-0000-0000-000000000004'  -- Taller
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND user_id   = '20000000-0000-0000-0000-000000000004'   -- Charlie (manager Gràcia)
  AND site_id   = '30000000-0000-0000-0000-000000000001';

UPDATE data.tenant_members
SET department_id = '43000000-0000-0000-0000-000000000004'  -- Taller
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND user_id   = '20000000-0000-0000-0000-000000000005'   -- Dave (member Gràcia)
  AND site_id   = '30000000-0000-0000-0000-000000000001';

UPDATE data.tenant_members
SET department_id = '43000000-0000-0000-0000-000000000004'  -- Taller
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND user_id   = '20000000-0000-0000-0000-000000000006'   -- Eve (viewer Gràcia)
  AND site_id   = '30000000-0000-0000-0000-000000000001';

-- Empleats vinculats a usuari: mateix departament que tenant_members
UPDATE data.employees e
SET department_id = tm.department_id
FROM data.tenant_members tm
WHERE e.user_id IS NOT NULL
  AND e.user_id = tm.user_id
  AND e.tenant_id = tm.tenant_id
  AND tm.department_id IS NOT NULL
  AND (tm.site_id IS NULL OR tm.site_id = e.site_id);

-- Empleats sense usuari (Acme Gràcia) → Taller
UPDATE data.employees
SET department_id = '43000000-0000-0000-0000-000000000004'
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND site_id = '30000000-0000-0000-0000-000000000001'
  AND department_id IS NULL;

-- Empleats sense usuari (Acme Sants) → Obres Externes
UPDATE data.employees
SET department_id = '43000000-0000-0000-0000-000000000005'
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND site_id = '30000000-0000-0000-0000-000000000002'
  AND department_id IS NULL;

-- Vincular projectes existents al departament corresponent
UPDATE data.projects
SET department_id = '43000000-0000-0000-0000-000000000004'  -- Taller
WHERE id = '51000000-0000-0000-0000-000000000001';          -- Revisio del quadre electric

UPDATE data.projects
SET department_id = '43000000-0000-0000-0000-000000000005'  -- Obres Externes
WHERE id = '51000000-0000-0000-0000-000000000002';          -- Cablejat obra externa Muntaner

-- ─── B7. Ubicacions addicionals + assets (Acme Sants) ────────────────────────
-- Prefix 41: locations (006-012) — Site Acme Sants (30000000-...-002)
-- El seed base ja té locations 001-005 (Taller i zones de Gràcia + Cuina Sants).
-- Afegim l'estructura completa de l'oficina de Sants:
--   Planta Baixa (floor)  → Recepció, Sala reunions, Oficines
--   Planta Primera (floor) → Despatx gerència, Magatzem material

INSERT INTO data.locations (id, tenant_id, site_id, parent_id, name, type, status, metadata)
VALUES
  -- Planta Baixa (arrel)
  ('41000000-0000-0000-0000-000000000006',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   NULL,
   'Planta Baixa', 'floor', 'active',
   '{"floor":0,"surface_m2":280}'::jsonb),
  -- Fills de Planta Baixa
  ('41000000-0000-0000-0000-000000000007',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000006',
   'Recepció', 'room', 'active',
   '{"surface_m2":18,"capacity":6}'::jsonb),
  ('41000000-0000-0000-0000-000000000008',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000006',
   'Sala de reunions', 'room', 'active',
   '{"surface_m2":32,"capacity":12}'::jsonb),
  ('41000000-0000-0000-0000-000000000009',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000006',
   'Oficines', 'room', 'active',
   '{"surface_m2":95,"capacity":20}'::jsonb),
  -- Planta Primera (arrel)
  ('41000000-0000-0000-0000-000000000010',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   NULL,
   'Planta Primera', 'floor', 'active',
   '{"floor":1,"surface_m2":200}'::jsonb),
  -- Fills de Planta Primera
  ('41000000-0000-0000-0000-000000000011',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000010',
   'Despatx gerència', 'room', 'active',
   '{"surface_m2":28,"capacity":4}'::jsonb),
  ('41000000-0000-0000-0000-000000000012',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000010',
   'Magatzem material', 'room', 'active',
   '{"surface_m2":55,"capacity":2}'::jsonb)
ON CONFLICT (id) DO NOTHING;

-- Assets addicionals (Acme Sants) — prefix 42 (005-007)
INSERT INTO data.assets (id, tenant_id, site_id, location_id, name, serial_number, asset_tag, status, metadata)
VALUES
  ('42000000-0000-0000-0000-000000000005',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000009',  -- Oficines
   'Servidor NAS Synology DS923+', 'SN-NAS-2024-01', 'ACME-IT-001',
   'operational',
   '{"brand":"Synology","model":"DS923+","capacity_tb":32,"ip":"192.168.1.10"}'::jsonb),
  ('42000000-0000-0000-0000-000000000006',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000008',  -- Sala de reunions
   'Aire condicionat Daikin FTXM50R', 'SN-HVAC-2023-03', 'ACME-HVAC-001',
   'operational',
   '{"brand":"Daikin","model":"FTXM50R","power_kw":5}'::jsonb),
  ('42000000-0000-0000-0000-000000000007',
   '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000009',  -- Oficines
   'Impressora multifunció Konica Minolta C368', 'SN-PRINT-2024-02', 'ACME-OFFI-001',
   'operational',
   '{"brand":"Konica Minolta","model":"bizhub C368","color":true}'::jsonb)
ON CONFLICT (id) DO NOTHING;

-- ─── B8. Catàleg de serveis i productes (Acme Corp) ─────────────────────────
-- Prefix 44: catalog_items (001-020)
-- Empresa d'instal·lacions elèctriques i manteniment industrial.
--   Serveis  (kind='service'):  001-010
--   Productes (kind='product'): 011-020
-- SKUs únics per tenant → uq_catalog_items_tenant_sku (WHERE sku IS NOT NULL)

INSERT INTO data.catalog_items
  (id, tenant_id, kind, name, description, sku, unit, unit_price, tax_rate, currency, category, is_active)
VALUES
  -- ── Serveis ──────────────────────────────────────────────────────────────
  ('44000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001',
   'service', 'Hora tècnic electricista',
   'Hora de treball d''un tècnic electricista (tarifa estàndard horari laboral).',
   'SRV-HOUR-BASE', 'h', 45.00, 21.00, 'EUR', 'Mà d''obra', true),

  ('44000000-0000-0000-0000-000000000002',
   '10000000-0000-0000-0000-000000000001',
   'service', 'Hora tècnic sènior',
   'Hora de treball d''un tècnic electricista sènior amb certificació BT.',
   'SRV-HOUR-SR', 'h', 65.00, 21.00, 'EUR', 'Mà d''obra', true),

  ('44000000-0000-0000-0000-000000000003',
   '10000000-0000-0000-0000-000000000001',
   'service', 'Visita de diagnosi',
   'Desplaçament i anàlisi diagnòstic d''instal·lació o avaria. Inclou informe escrit.',
   'SRV-DIAG-01', 'visita', 85.00, 21.00, 'EUR', 'Assistència tècnica', true),

  ('44000000-0000-0000-0000-000000000004',
   '10000000-0000-0000-0000-000000000001',
   'service', 'Manteniment preventiu mensual',
   'Revisió periòdica de la instal·lació elèctrica: mesures, proteccions i resum de certificació.',
   'SRV-MANT-MES', 'visita', 120.00, 21.00, 'EUR', 'Manteniment', true),

  ('44000000-0000-0000-0000-000000000005',
   '10000000-0000-0000-0000-000000000001',
   'service', 'Instal·lació quadre elèctric petit (≤40A)',
   'Subministrament i instal·lació de quadre de distribució fins a 40A. IGA inclòs.',
   'SRV-QE-S', 'u', 350.00, 21.00, 'EUR', 'Instal·lació', true),

  ('44000000-0000-0000-0000-000000000006',
   '10000000-0000-0000-0000-000000000001',
   'service', 'Instal·lació quadre elèctric gran (>40A)',
   'Subministrament i instal·lació de quadre de distribució >40A. IGA, diferencial i magnetotèrmics inclosos.',
   'SRV-QE-L', 'u', 680.00, 21.00, 'EUR', 'Instal·lació', true),

  ('44000000-0000-0000-0000-000000000007',
   '10000000-0000-0000-0000-000000000001',
   'service', 'Certificació elèctrica BT (boletín)',
   'Tràmit i emissió del certificat d''instal·lació elèctrica de baixa tensió (boletín).',
   'SRV-CERT-BT', 'u', 95.00, 21.00, 'EUR', 'Certificació', true),

  ('44000000-0000-0000-0000-000000000008',
   '10000000-0000-0000-0000-000000000001',
   'service', 'Hora urgència fora d''horari',
   'Assistència urgent fora d''horari laboral, caps de setmana i festius (increment ×1.5).',
   'SRV-URG-OT', 'h', 90.00, 21.00, 'EUR', 'Mà d''obra', true),

  ('44000000-0000-0000-0000-000000000009',
   '10000000-0000-0000-0000-000000000001',
   'service', 'Gestió i coordinació de projecte',
   'Planificació, coordinació i seguiment de projectes elèctrics complexos.',
   'SRV-MGMT-01', 'h', 75.00, 21.00, 'EUR', 'Gestió', true),

  ('44000000-0000-0000-0000-000000000010',
   '10000000-0000-0000-0000-000000000001',
   'service', 'Formació en seguretat elèctrica (PRL)',
   'Curs in-company de prevenció de riscos laborals en treballs elèctrics. Grup fins a 10 persones.',
   'SRV-FORM-PRL', 'u', 480.00, 21.00, 'EUR', 'Formació', true),

  -- ── Productes ────────────────────────────────────────────────────────────
  ('44000000-0000-0000-0000-000000000011',
   '10000000-0000-0000-0000-000000000001',
   'product', 'Cable RZ1-K 6mm² (per metre)',
   'Cable flexible de coure 6mm² amb aïllament XLPE per a instal·lacions industrials.',
   'MAT-CABLE-6', 'm', 2.80, 21.00, 'EUR', 'Cablejat', true),

  ('44000000-0000-0000-0000-000000000012',
   '10000000-0000-0000-0000-000000000001',
   'product', 'Cable RZ1-K 16mm² (per metre)',
   'Cable flexible de coure 16mm² amb aïllament XLPE per a quadres i connexions de potència.',
   'MAT-CABLE-16', 'm', 5.40, 21.00, 'EUR', 'Cablejat', true),

  ('44000000-0000-0000-0000-000000000013',
   '10000000-0000-0000-0000-000000000001',
   'product', 'Interruptor automàtic magnetotèrmic 25A',
   'IGA monofàsic Schneider Easy9 25A corba C — 6kA de poder de tall.',
   'MAT-IGA-25', 'u', 18.50, 21.00, 'EUR', 'Proteccions', true),

  ('44000000-0000-0000-0000-000000000014',
   '10000000-0000-0000-0000-000000000001',
   'product', 'Interruptor automàtic magnetotèrmic 63A',
   'IGA trifàsic Schneider iC60N 63A corba C — 10kA de poder de tall.',
   'MAT-IGA-63', 'u', 34.00, 21.00, 'EUR', 'Proteccions', true),

  ('44000000-0000-0000-0000-000000000015',
   '10000000-0000-0000-0000-000000000001',
   'product', 'Protector de sobretensions tipus 2',
   'Descàrregador de sobretensions Schneider Acti9 iPRD 40r tipus 2 per a quadre BT.',
   'MAT-SPD-T2', 'u', 78.00, 21.00, 'EUR', 'Proteccions', true),

  ('44000000-0000-0000-0000-000000000016',
   '10000000-0000-0000-0000-000000000001',
   'product', 'Caixa distribució estanca IP65 (300×220mm)',
   'Caixa plàstic ABS estanca IP65 amb brida per a instal·lació exterior o industrial.',
   'MAT-BOX-IP65-S', 'u', 42.00, 21.00, 'EUR', 'Caixes i suports', true),

  ('44000000-0000-0000-0000-000000000017',
   '10000000-0000-0000-0000-000000000001',
   'product', 'Endoll industrial 32A/380V (CEE 5P)',
   'Endoll encastat industrial IP44 32A 380V 5 pols (CEE 17) — Legrand.',
   'MAT-SKT-IND32', 'u', 28.00, 21.00, 'EUR', 'Endolls i connexions', true),

  ('44000000-0000-0000-0000-000000000018',
   '10000000-0000-0000-0000-000000000001',
   'product', 'Bornes connexió ràpida Legrand (caixa 100u)',
   'Borne de cargol Legrand Viking3 2.5mm² gris — caixa de 100 unitats.',
   'MAT-TERM-100', 'u', 15.00, 21.00, 'EUR', 'Connexions', true),

  ('44000000-0000-0000-0000-000000000019',
   '10000000-0000-0000-0000-000000000001',
   'product', 'Tub corrugat M20 doble capa (rodet 25m)',
   'Tub corrugat flexible M20 doble capa negre IP68 per a canalització soterrada.',
   'MAT-TUBE-M20', 'u', 8.50, 21.00, 'EUR', 'Canalitzacions', true),

  ('44000000-0000-0000-0000-000000000020',
   '10000000-0000-0000-0000-000000000001',
   'product', 'Cinta aïllant 3M Scotch 88 (pack 10u)',
   'Cinta aïllant de vinil 19mm×20m, resistència 600V — pack de 10 unitats.',
   'MAT-TAPE-SCT88', 'u', 6.00, 21.00, 'EUR', 'Consumibles', true)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Entity timeline Pro features — Beta Startup (free) sense features Pro
-- Acme Corp (pro) manté el default global (totes actives al dev seed)
-- ---------------------------------------------------------------------------
INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
VALUES
  ('10000000-0000-0000-0000-000000000002', 'entity_timeline_risk_detector', false),
  ('10000000-0000-0000-0000-000000000002', 'entity_timeline_playbooks', false),
  ('10000000-0000-0000-0000-000000000002', 'entity_timeline_webhooks', false),
  ('10000000-0000-0000-0000-000000000002', 'entity_timeline_export', false),
  ('10000000-0000-0000-0000-000000000002', 'entity_timeline_manager_feed', false),
  -- Local/demo EX-05.6: Acme amb station offline deferred punch activat
  ('10000000-0000-0000-0000-000000000001', 'station_offline_deferred_punch', true)
ON CONFLICT (tenant_id, feature_key) DO UPDATE
  SET override_status = EXCLUDED.override_status;

-- ---------------------------------------------------------------------------
-- Entity timeline — risk rules + playbooks (després que existeixin els tenants)
-- ---------------------------------------------------------------------------
SELECT data.seed_entity_risk_rules_for_tenant(t.id)
FROM data.tenants t;

SELECT data.seed_employee_termination_playbooks(t.id)
FROM data.tenants t;

-- ---------------------------------------------------------------------------
-- Public portal (dev) — necessari per EP-ACC-2a URL del portal d'empleat
-- ---------------------------------------------------------------------------
UPDATE data.tenants
SET public_portal_enabled = true,
    employee_portal_enabled = true
WHERE id = '10000000-0000-0000-0000-000000000001';

UPDATE data.tenants
SET employee_portal_enabled = true
WHERE id = '10000000-0000-0000-0000-000000000002';

INSERT INTO data.public_sites (id, tenant_id, site_id, slug, name, status)
VALUES
  (
    '80000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    NULL,
    'acme-corp',
    'Acme Corp Portal',
    'published'
  ),
  (
    '80000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000002',
    NULL,
    'beta-startup',
    'Beta Startup Portal',
    'published'
  )
ON CONFLICT (id) DO UPDATE SET
  status = EXCLUDED.status,
  slug = EXCLUDED.slug,
  name = EXCLUDED.name;

-- Portal d'empleat: URL base local quan no hi ha domini SSL (dev)
INSERT INTO data.system_settings (module, settings)
VALUES (
  'employee_portal',
  jsonb_build_object('dev_base_url', 'http://localhost:3002')
)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

-- Control horari: vegeu supabase/seeds/attendance_demo.sql (config [db.seed].sql_paths)

-- ─── Field Service: Acme CRM sites (sense forçar archetype) ───────────────────
INSERT INTO data.contact_sites (
  id, tenant_id, contact_id, name, address, city, postal_code, country_code, notes, is_active
)
VALUES
  (
    '81000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    '80000000-0000-0000-0000-000000000001',
    'Obra Muntaner',
    'Carrer de Muntaner 240',
    'Barcelona',
    '08021',
    'ES',
    'Canvi d''endolls i cablejat',
    true
  ),
  (
    '81000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001',
    '80000000-0000-0000-0000-000000000004',
    'Local Ponent',
    'Carrer del Comte Urgell 120',
    'Barcelona',
    '08015',
    'ES',
    NULL,
    true
  )
ON CONFLICT (id) DO NOTHING;

-- Bind client/site a la WO Acme (demo G2); NO força dates d''avui ni archetype.
UPDATE data.projects
SET
  client_id = '80000000-0000-0000-0000-000000000001',
  contact_site_id = '81000000-0000-0000-0000-000000000001'
WHERE id = '51000000-0000-0000-0000-000000000002';

-- ─── Field Service: Volt Serveis (tenant FS real) ─────────────────────────────
-- Settings mínims + catàleg/recepta + client/obra + WO d''avui per E2E.
UPDATE data.tenants
SET settings = COALESCE(settings, '{}') || '{
  "default_event_start_time": "08:00",
  "default_event_duration_minutes": 60,
  "week_starts_on": 1,
  "default_language": "ca",
  "default_calendar_timezone": "Europe/Madrid"
}'::jsonb
WHERE id = '10000000-0000-0000-0000-000000000003';

-- Tenant checklist examples for Volt Serveis (authoring without manual UUIDs in UI)
-- Response set propi del tenant (no lligar-se al de plataforma)
INSERT INTO data.checklist_response_sets (
  id, tenant_id, name, code, locale, category, vertical, metadata
)
VALUES (
  '83300000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000003',
  'Semàfor (Volt)',
  'traffic_light',
  'ca', 'general', 'generic',
  '{"source_response_set_id":"a1000000-0000-4000-8000-000000000001","source_catalog_version":1}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.checklist_response_options (
  id, response_set_id, label, semantics, position, blocks_closeout, requires_note, color_token
)
VALUES
  ('83310000-0000-0000-0000-000000000001', '83300000-0000-0000-0000-000000000001',
   'Correcte', 'pass', 0, false, false, 'green'),
  ('83310000-0000-0000-0000-000000000002', '83300000-0000-0000-0000-000000000001',
   'A vigilar', 'warning', 1, false, true, 'yellow'),
  ('83310000-0000-0000-0000-000000000003', '83300000-0000-0000-0000-000000000001',
   'Urgent', 'fail', 2, true, true, 'red'),
  ('83310000-0000-0000-0000-000000000004', '83300000-0000-0000-0000-000000000001',
   'N/A', 'na', 3, false, false, 'neutral')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.checklist_templates (
  id, tenant_id, name, description, kind, locale, category, vertical, archetype,
  is_default, is_active, created_by
)
VALUES
  (
    '83000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000003',
    'Visita estàndard (ToDo)',
    'Checklist ToDo d''exemple per ordres de treball',
    'todo', 'ca', 'visita', 'generic', 'field_service',
    true, true, '20000000-0000-0000-0000-000000000002'
  ),
  (
    '83000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000003',
    'Revisió bàsica (Review)',
    'Plantilla review d''exemple amb semàfor propi del tenant',
    'review', 'ca', 'revisio', 'generic', 'field_service',
    true, true, '20000000-0000-0000-0000-000000000002'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.checklist_template_versions (
  id, template_id, version_number, status, published_at, published_by, created_by,
  default_response_set_id
)
VALUES
  (
    '83100000-0000-0000-0000-000000000001',
    '83000000-0000-0000-0000-000000000001',
    1, 'draft', NULL, NULL,
    '20000000-0000-0000-0000-000000000002', NULL
  ),
  (
    '83100000-0000-0000-0000-000000000002',
    '83000000-0000-0000-0000-000000000002',
    1, 'draft', NULL, NULL,
    '20000000-0000-0000-0000-000000000002',
    '83300000-0000-0000-0000-000000000001'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.checklist_review_points (
  id, tenant_id, title, description, client_text, locale, category, vertical, archetype, created_by
)
VALUES
  (
    '83200000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000003',
    'Estat general de la instal·lació',
    'Comprovar aspecte, accessos i senyalització',
    'Estat general de la instal·lació',
    'ca', 'visita', 'generic', 'field_service',
    '20000000-0000-0000-0000-000000000002'
  ),
  (
    '83200000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000003',
    'Seguretat elèctrica visible',
    'Comprovar proteccions i connexions visibles',
    'Seguretat elèctrica',
    'ca', 'visita', 'generic', 'field_service',
    '20000000-0000-0000-0000-000000000002'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.checklist_template_items (
  version_id, position, review_point_id, title, description_internal, description_public,
  locale, category, include_in_report, is_required, response_type, response_set_id
)
VALUES
  (
    '83100000-0000-0000-0000-000000000001', 0, NULL,
    'Revisió inicial', 'Comprovar l''abast de la visita', 'Revisió inicial',
    'ca', 'visita', true, true, 'checkbox', NULL
  ),
  (
    '83100000-0000-0000-0000-000000000001', 1, NULL,
    'Fotos abans', 'Capturar estat previ', 'Fotos abans',
    'ca', 'visita', true, false, 'checkbox', NULL
  ),
  (
    '83100000-0000-0000-0000-000000000001', 2, NULL,
    'Treball realitzat', 'Detallar intervenció', 'Treballs realitzats',
    'ca', 'visita', true, true, 'checkbox', NULL
  ),
  (
    '83100000-0000-0000-0000-000000000001', 3, NULL,
    'Neteja', 'Deixar zona neta', 'Neteja',
    'ca', 'visita', false, false, 'checkbox', NULL
  ),
  (
    '83100000-0000-0000-0000-000000000001', 4, NULL,
    'Confirmació client', 'Confirmar amb el client', 'Confirmació client',
    'ca', 'visita', true, true, 'checkbox', NULL
  ),
  (
    '83100000-0000-0000-0000-000000000002', 0,
    '83200000-0000-0000-0000-000000000001',
    'Estat general de la instal·lació',
    'Comprovar aspecte, accessos i senyalització',
    'Estat general de la instal·lació',
    'ca', 'visita', true, true, 'single_choice', NULL
  ),
  (
    '83100000-0000-0000-0000-000000000002', 1,
    '83200000-0000-0000-0000-000000000002',
    'Seguretat elèctrica visible',
    'Comprovar proteccions i connexions visibles',
    'Seguretat elèctrica',
    'ca', 'visita', true, true, 'single_choice', NULL
  );

UPDATE data.checklist_template_versions
SET status = 'published',
    published_at = now(),
    published_by = '20000000-0000-0000-0000-000000000002',
    updated_at = now()
WHERE id IN (
  '83100000-0000-0000-0000-000000000001',
  '83100000-0000-0000-0000-000000000002'
)
  AND status = 'draft';

INSERT INTO data.departments (id, tenant_id, parent_id, name, code, manager_id, is_active)
VALUES
  (
    '43000000-0000-0000-0000-000000000101',
    '10000000-0000-0000-0000-000000000003',
    NULL,
    'Operacions de camp',
    'CAMP',
    NULL,
    true
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.job_positions (id, tenant_id, code, name, is_active)
VALUES
  (
    '41000000-0000-0000-0000-000000000301',
    '10000000-0000-0000-0000-000000000003',
    'TECNIC',
    'Tècnic de camp',
    true
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, email, job_position_id, status, weekly_hours, department_id)
VALUES
  (
    '40000000-0000-0000-0000-000000000101',
    '10000000-0000-0000-0000-000000000003',
    '30000000-0000-0000-0000-000000000004',
    '20000000-0000-0000-0000-000000000002',
    'Alice (Volt)',
    'alice@acme-corp.com',
    '41000000-0000-0000-0000-000000000301',
    'active',
    40,
    '43000000-0000-0000-0000-000000000101'
  )
ON CONFLICT (id) DO NOTHING;

-- Catàleg de la recepta field_service (sense JWT / apply_sector_recipe)
INSERT INTO data.catalog_items (id, tenant_id, kind, name, unit, unit_price, tax_rate, is_active)
SELECT
  v.id,
  '10000000-0000-0000-0000-000000000003',
  (v.item->>'kind')::data.catalog_item_kind,
  v.item->>'name',
  COALESCE(v.item->>'unit', 'u'),
  COALESCE((v.item->>'unit_price')::numeric, 0),
  COALESCE((v.item->>'tax_rate')::numeric, 21),
  true
FROM data.sector_profiles sp
CROSS JOIN LATERAL (
  SELECT
    ('82000000-0000-0000-0000-00000000000' || gs.i)::uuid AS id,
    jsonb_array_element(sp.catalog_seed, gs.i - 1) AS item
  FROM generate_series(1, LEAST(jsonb_array_length(sp.catalog_seed), 4)) AS gs(i)
) v
WHERE sp.archetype = 'field_service'
  AND sp.vertical IS NULL
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.contacts (
  id, tenant_id, site_id, kind, display_name, given_name, family_name, legal_name,
  tax_id, email, phone, tags, source
)
VALUES
  (
    '80000000-0000-0000-0000-000000000101',
    '10000000-0000-0000-0000-000000000003',
    NULL,
    'company',
    'Constructora Meridian S.L.',
    NULL,
    NULL,
    'Constructora Meridian S.L.',
    'B-12345678',
    'info@meridian.cat',
    '+34931234567',
    '{"client","construccio"}',
    'manual'
  )
ON CONFLICT (id) DO NOTHING;

-- Persona relacionada (CP-A0.1): destinatària per Meridian
INSERT INTO data.contacts (
  id, tenant_id, site_id, kind, display_name, given_name, family_name, legal_name,
  tax_id, email, phone, tags, source
)
VALUES
  (
    '80000000-0000-0000-0000-000000000102',
    '10000000-0000-0000-0000-000000000003',
    NULL,
    'person',
    'Laura Puig',
    'Laura',
    'Puig',
    NULL,
    NULL,
    'laura.puig@meridian.cat',
    '+34611222333',
    '{"client","portal"}',
    'manual'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.contact_relationships (
  id, tenant_id, organization_contact_id, person_contact_id, role, source, created_by
)
VALUES
  (
    '82000000-0000-0000-0000-000000000101',
    '10000000-0000-0000-0000-000000000003',
    '80000000-0000-0000-0000-000000000101',
    '80000000-0000-0000-0000-000000000102',
    'operations',
    'seed',
    '20000000-0000-0000-0000-000000000002'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.contact_delivery_channels (
  id, tenant_id, contact_id, channel_type, value_raw, value_normalized,
  verified_at, verification_method, created_by
)
VALUES
  (
    '83000000-0000-0000-0000-000000000101',
    '10000000-0000-0000-0000-000000000003',
    '80000000-0000-0000-0000-000000000102',
    'email',
    'laura.puig@meridian.cat',
    'laura.puig@meridian.cat',
    now(),
    'staff_confirmed',
    '20000000-0000-0000-0000-000000000002'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.contact_sites (
  id, tenant_id, contact_id, name, address, city, postal_code, country_code, notes, is_active
)
VALUES
  (
    '81000000-0000-0000-0000-000000000101',
    '10000000-0000-0000-0000-000000000003',
    '80000000-0000-0000-0000-000000000101',
    'Obra Muntaner',
    'Carrer de Muntaner 240',
    'Barcelona',
    '08021',
    'ES',
    'Canvi d''endolls i cablejat',
    true
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.projects (
  id, tenant_id, type, name, description, status, visibility,
  site_id, department_id, client_id, contact_site_id,
  created_by, planned_start, planned_end
)
VALUES
  (
    '51000000-0000-0000-0000-000000000101',
    '10000000-0000-0000-0000-000000000003',
    'work_order',
    'Canvi d''endolls — Carrer Muntaner',
    'Ordre de servei demo per Avui (Volt Serveis).',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000004',
    '43000000-0000-0000-0000-000000000101',
    '80000000-0000-0000-0000-000000000101',
    '81000000-0000-0000-0000-000000000101',
    '20000000-0000-0000-0000-000000000002',
    -- Always "today 09:00–12:00" Europe/Madrid so Avui works after any reset day
    (timezone('Europe/Madrid', now()))::date + time '09:00'
      AT TIME ZONE 'Europe/Madrid',
    (timezone('Europe/Madrid', now()))::date + time '12:00'
      AT TIME ZONE 'Europe/Madrid'
  )
ON CONFLICT (id) DO UPDATE SET
  status = EXCLUDED.status,
  planned_start = EXCLUDED.planned_start,
  planned_end = EXCLUDED.planned_end,
  client_id = EXCLUDED.client_id,
  contact_site_id = EXCLUDED.contact_site_id,
  department_id = EXCLUDED.department_id,
  site_id = EXCLUDED.site_id,
  updated_at = now();

-- ─── Field Service: Riera Instal·lacions (PIME oficina + tècnics) ─────────────
-- Gina owner (oficina). Hèctor i Inés members (UI limitada, sempre /field/today).
UPDATE data.tenants
SET settings = COALESCE(settings, '{}') || '{
  "default_event_start_time": "08:00",
  "default_event_duration_minutes": 60,
  "week_starts_on": 1,
  "default_language": "ca",
  "default_calendar_timezone": "Europe/Madrid"
}'::jsonb
WHERE id = '10000000-0000-0000-0000-000000000004';

INSERT INTO data.departments (id, tenant_id, parent_id, name, code, manager_id, is_active)
VALUES
  (
    '43000000-0000-0000-0000-000000000201',
    '10000000-0000-0000-0000-000000000004',
    NULL,
    'Oficina',
    'OFI',
    NULL,
    true
  ),
  (
    '43000000-0000-0000-0000-000000000202',
    '10000000-0000-0000-0000-000000000004',
    NULL,
    'Operacions de camp',
    'CAMP',
    NULL,
    true
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.job_positions (id, tenant_id, code, name, is_active)
VALUES
  (
    '41000000-0000-0000-0000-000000000401',
    '10000000-0000-0000-0000-000000000004',
    'ADMIN',
    'Administració',
    true
  ),
  (
    '41000000-0000-0000-0000-000000000402',
    '10000000-0000-0000-0000-000000000004',
    'TECNIC',
    'Tècnic de camp',
    true
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, email, job_position_id, status, weekly_hours, department_id)
VALUES
  (
    '40000000-0000-0000-0000-000000000201',
    '10000000-0000-0000-0000-000000000004',
    '30000000-0000-0000-0000-000000000005',
    '20000000-0000-0000-0000-000000000008',
    'Gina Riera',
    'gina@riera-instal.com',
    '41000000-0000-0000-0000-000000000401',
    'active',
    40,
    '43000000-0000-0000-0000-000000000201'
  ),
  (
    '40000000-0000-0000-0000-000000000202',
    '10000000-0000-0000-0000-000000000004',
    '30000000-0000-0000-0000-000000000005',
    '20000000-0000-0000-0000-000000000009',
    'Hèctor Soler',
    'hector@riera-instal.com',
    '41000000-0000-0000-0000-000000000402',
    'active',
    40,
    '43000000-0000-0000-0000-000000000202'
  ),
  (
    '40000000-0000-0000-0000-000000000203',
    '10000000-0000-0000-0000-000000000004',
    '30000000-0000-0000-0000-000000000005',
    '20000000-0000-0000-0000-000000000010',
    'Inés Vidal',
    'ines@riera-instal.com',
    '41000000-0000-0000-0000-000000000402',
    'active',
    40,
    '43000000-0000-0000-0000-000000000202'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.catalog_items (id, tenant_id, kind, name, unit, unit_price, tax_rate, is_active)
SELECT
  v.id,
  '10000000-0000-0000-0000-000000000004',
  (v.item->>'kind')::data.catalog_item_kind,
  v.item->>'name',
  COALESCE(v.item->>'unit', 'u'),
  COALESCE((v.item->>'unit_price')::numeric, 0),
  COALESCE((v.item->>'tax_rate')::numeric, 21),
  true
FROM data.sector_profiles sp
CROSS JOIN LATERAL (
  SELECT
    ('82000000-0000-0000-0000-00000000001' || gs.i)::uuid AS id,
    jsonb_array_element(sp.catalog_seed, gs.i - 1) AS item
  FROM generate_series(1, LEAST(jsonb_array_length(sp.catalog_seed), 4)) AS gs(i)
) v
WHERE sp.archetype = 'field_service'
  AND sp.vertical IS NULL
ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
  PERFORM data.ensure_visita_estandard_pricing_template('10000000-0000-0000-0000-000000000004');
END $$;

INSERT INTO data.contacts (
  id, tenant_id, site_id, kind, display_name, given_name, family_name, legal_name,
  tax_id, email, phone, tags, source
)
VALUES
  (
    '80000000-0000-0000-0000-000000000201',
    '10000000-0000-0000-0000-000000000004',
    NULL,
    'company',
    'Comunitat Propietaris Clot',
    NULL,
    NULL,
    'Comunitat Propietaris Clot',
    'B-87654321',
    'junta@clot.cat',
    '+34933445566',
    '{"client","comunitat"}',
    'manual'
  ),
  (
    '80000000-0000-0000-0000-000000000202',
    '10000000-0000-0000-0000-000000000004',
    NULL,
    'person',
    'Marta Roca',
    'Marta',
    'Roca',
    NULL,
    NULL,
    'marta.roca@clot.cat',
    '+34611222999',
    '{"client","portal"}',
    'manual'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.contact_sites (
  id, tenant_id, contact_id, name, address, city, postal_code, country_code, notes, is_active
)
VALUES
  (
    '81000000-0000-0000-0000-000000000201',
    '10000000-0000-0000-0000-000000000004',
    '80000000-0000-0000-0000-000000000201',
    'Edifici Clot 12',
    'Carrer del Clot 12',
    'Barcelona',
    '08018',
    'ES',
    'Revisió de caldera comunitària',
    true
  ),
  (
    '81000000-0000-0000-0000-000000000202',
    '10000000-0000-0000-0000-000000000004',
    '80000000-0000-0000-0000-000000000201',
    'Local comercial Rogent',
    'Carrer de Rogent 45',
    'Barcelona',
    '08026',
    'ES',
    'Avària de climatització',
    true
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.projects (
  id, tenant_id, type, name, description, status, visibility,
  site_id, department_id, client_id, contact_site_id,
  created_by, planned_start, planned_end
)
VALUES
  (
    '51000000-0000-0000-0000-000000000201',
    '10000000-0000-0000-0000-000000000004',
    'work_order',
    'Revisió caldera — Edifici Clot',
    'Ordre assignada a Hèctor (tècnic de camp).',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000005',
    '43000000-0000-0000-0000-000000000202',
    '80000000-0000-0000-0000-000000000201',
    '81000000-0000-0000-0000-000000000201',
    '20000000-0000-0000-0000-000000000008',
    (timezone('Europe/Madrid', now()))::date + time '09:00'
      AT TIME ZONE 'Europe/Madrid',
    (timezone('Europe/Madrid', now()))::date + time '12:00'
      AT TIME ZONE 'Europe/Madrid'
  ),
  (
    '51000000-0000-0000-0000-000000000202',
    '10000000-0000-0000-0000-000000000004',
    'work_order',
    'Avària clima — Local Rogent',
    'Ordre assignada a Inés (tècnica de camp).',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000005',
    '43000000-0000-0000-0000-000000000202',
    '80000000-0000-0000-0000-000000000201',
    '81000000-0000-0000-0000-000000000202',
    '20000000-0000-0000-0000-000000000008',
    (timezone('Europe/Madrid', now()))::date + time '14:00'
      AT TIME ZONE 'Europe/Madrid',
    (timezone('Europe/Madrid', now()))::date + time '17:00'
      AT TIME ZONE 'Europe/Madrid'
  )
ON CONFLICT (id) DO UPDATE SET
  status = EXCLUDED.status,
  planned_start = EXCLUDED.planned_start,
  planned_end = EXCLUDED.planned_end,
  client_id = EXCLUDED.client_id,
  contact_site_id = EXCLUDED.contact_site_id,
  department_id = EXCLUDED.department_id,
  site_id = EXCLUDED.site_id,
  updated_at = now();

INSERT INTO data.project_members (project_id, user_id, role)
VALUES
  ('51000000-0000-0000-0000-000000000201', '20000000-0000-0000-0000-000000000009', 'contributor'),
  ('51000000-0000-0000-0000-000000000202', '20000000-0000-0000-0000-000000000010', 'contributor')
ON CONFLICT (project_id, user_id) DO NOTHING;
