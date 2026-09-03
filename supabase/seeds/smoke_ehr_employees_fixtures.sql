-- =============================================================================
-- Smoke / UAT fixtures — Mòdul Empleats / HR (Acme + Beta)
-- =============================================================================
-- Ús: enganxar a l'Editor SQL de Supabase (local o staging) DESPRÉS de
--      `supabase db reset` / seed base. No és una migració.
--
-- Guia: docs/plans/employees/ehr-uat-checklist.md
-- Cleanup: supabase/seeds/smoke_ehr_employees_fixtures_cleanup.sql
-- CSV import sample: supabase/seeds/smoke_ehr_import_sample.csv
--
-- Executar com a rol postgres (Studio SQL Editor / docker exec psql).
-- Idempotent: reexecutable (ON CONFLICT / IF NOT EXISTS).
--
-- IDs seed:
--   Acme tenant  10000000-0000-0000-0000-000000000001
--   Beta tenant  10000000-0000-0000-0000-000000000002
--   Acme Gràcia  30000000-0000-0000-0000-000000000001
--   Beta site    30000000-0000-0000-0000-000000000003
--   Alice emp    40000000-0000-0000-0000-000000000001
--   Charlie emp  40000000-0000-0000-0000-000000000002
--   Alice user   20000000-0000-0000-0000-000000000002
--
-- IDs fixture (prefix e1000000-… / e4100000-… posicions):
--   QA Smoke Employee (onboarding)     e1000000-0000-0000-0000-000000000001
--   QA Offboard Employee               e1000000-0000-0000-0000-000000000002
--   QA Beta Employee                   e1000000-0000-0000-0000-000000000003
--   Job pos QA Tester / Leaving / Beta e4100000-…001 / 002 / 003
--   Contract draft QA                  e1000000-0000-0000-0000-000000000011
--   Contract active Charlie (opt)      e1000000-0000-0000-0000-000000000012
--   Contract Beta                      e1000000-0000-0000-0000-000000000013
--   Asset EPI QA                       e1000000-0000-0000-0000-000000000021
--   Asset EPI Offboard                 e1000000-0000-0000-0000-000000000022
--   Assignment QA                      e1000000-0000-0000-0000-000000000031
--   Assignment Offboard                e1000000-0000-0000-0000-000000000032
--   Rule HEIGHT Acme                   e1000000-0000-0000-0000-000000000041
--   Rule MEDICAL Acme                  e1000000-0000-0000-0000-000000000042
--   Cert Alice HEIGHT                  e1000000-0000-0000-0000-000000000051
--   Cert Alice MEDICAL                 e1000000-0000-0000-0000-000000000052
-- =============================================================================

BEGIN;

-- ─── 0. Sanity ───────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_acme int;
  v_alice int;
  v_types int;
BEGIN
  SELECT count(*) INTO v_acme FROM data.tenants
  WHERE id = '10000000-0000-0000-0000-000000000001';
  SELECT count(*) INTO v_alice FROM data.employees
  WHERE id = '40000000-0000-0000-0000-000000000001';
  SELECT count(*) INTO v_types FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code IN ('HEIGHT_WORK', 'MEDICAL_FIT');

  IF v_acme < 1 OR v_alice < 1 OR v_types < 2 THEN
    RAISE EXCEPTION
      'Seed base incomplet (acme=%, alice_emp=%, platform_types=%). Executa db reset abans.',
      v_acme, v_alice, v_types;
  END IF;

  RAISE NOTICE 'OK seed base: Acme + Alice + compliance types presents';
END $$;

-- ─── 0b. Evita onboarding trap a Beta (Alice multi-tenant) ───────────────────

UPDATE data.tenants t
SET sector_profile_id = sp.id
FROM data.sector_profiles sp
WHERE t.id = '10000000-0000-0000-0000-000000000002'
  AND t.sector_profile_id IS NULL
  AND sp.archetype = 'generic';

UPDATE data.tenants t
SET sector_profile_id = sp.id
FROM data.sector_profiles sp
WHERE t.id = '10000000-0000-0000-0000-000000000001'
  AND t.sector_profile_id IS NULL
  AND sp.archetype = 'generic';

-- ─── 0c. Catàleg job_positions QA ────────────────────────────────────────────

INSERT INTO data.job_positions (id, tenant_id, code, name, is_active)
VALUES
  ('e4100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'QA_TESTER',  'QA Tester',  true),
  ('e4100000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'QA_LEAVING', 'QA Leaving', true),
  ('e4100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', 'QA_BETA',    'QA Beta',    true)
ON CONFLICT (id) DO NOTHING;

-- ─── 1. Empleats QA (Acme + Beta) ────────────────────────────────────────────
-- INSERT pot fixar lifecycle_state; UPDATE requereix data.lifecycle_state_write=1

INSERT INTO data.employees (
  id, tenant_id, site_id, full_name, email, job_position_id, status,
  lifecycle_state, lifecycle_since, weekly_hours, starts_on, employee_code
) VALUES (
  'e1000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  'QA Smoke Employee',
  'qa-smoke@acme-corp.example',
  'e4100000-0000-0000-0000-000000000001',
  'inactive',
  'onboarding',
  CURRENT_DATE,
  40,
  CURRENT_DATE,
  'QA-SMOKE-001'
)
ON CONFLICT (id) DO UPDATE SET
  full_name = EXCLUDED.full_name,
  email = EXCLUDED.email,
  employee_code = EXCLUDED.employee_code,
  job_position_id = COALESCE(EXCLUDED.job_position_id, data.employees.job_position_id),
  updated_at = now();

-- Force lifecycle onboarding if row already existed as active
SELECT set_config('data.lifecycle_state_write', '1', true);
UPDATE data.employees
SET lifecycle_state = 'onboarding',
    lifecycle_since = coalesce(lifecycle_since, CURRENT_DATE),
    lifecycle_updated_at = now(),
    status = 'inactive'
WHERE id = 'e1000000-0000-0000-0000-000000000001'
  AND lifecycle_state IS DISTINCT FROM 'onboarding';

INSERT INTO data.employees (
  id, tenant_id, site_id, full_name, email, job_position_id, status,
  lifecycle_state, lifecycle_since, weekly_hours, starts_on, employee_code
) VALUES (
  'e1000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  'QA Offboard Employee',
  'qa-offboard@acme-corp.example',
  'e4100000-0000-0000-0000-000000000002',
  'active',
  'offboarding',
  CURRENT_DATE,
  40,
  CURRENT_DATE - 365,
  'QA-OFF-001'
)
ON CONFLICT (id) DO UPDATE SET
  full_name = EXCLUDED.full_name,
  email = EXCLUDED.email,
  employee_code = EXCLUDED.employee_code,
  job_position_id = COALESCE(EXCLUDED.job_position_id, data.employees.job_position_id),
  updated_at = now();

SELECT set_config('data.lifecycle_state_write', '1', true);
UPDATE data.employees
SET lifecycle_state = 'offboarding',
    lifecycle_since = coalesce(lifecycle_since, CURRENT_DATE),
    lifecycle_updated_at = now(),
    status = 'active'
WHERE id = 'e1000000-0000-0000-0000-000000000002'
  AND lifecycle_state IS DISTINCT FROM 'offboarding';

INSERT INTO data.employees (
  id, tenant_id, site_id, full_name, email, job_position_id, status,
  lifecycle_state, lifecycle_since, weekly_hours, starts_on, employee_code
) VALUES (
  'e1000000-0000-0000-0000-000000000003',
  '10000000-0000-0000-0000-000000000002',
  '30000000-0000-0000-0000-000000000003',
  'QA Beta Employee',
  'qa-beta@beta-startup.example',
  'e4100000-0000-0000-0000-000000000003',
  'active',
  'active',
  CURRENT_DATE,
  40,
  CURRENT_DATE,
  'QA-BETA-001'
)
ON CONFLICT (id) DO UPDATE SET
  full_name = EXCLUDED.full_name,
  email = EXCLUDED.email,
  employee_code = EXCLUDED.employee_code,
  job_position_id = COALESCE(EXCLUDED.job_position_id, data.employees.job_position_id),
  updated_at = now();

-- ─── 2. Regles compliance Acme (tenant-scope, blocking) ──────────────────────

INSERT INTO data.compliance_requirement_rules (
  id, tenant_id, requirement_type_id, scope_type, scope_id,
  is_blocking, grace_period_days, is_active, created_by
)
SELECT
  'e1000000-0000-0000-0000-000000000041',
  '10000000-0000-0000-0000-000000000001',
  t.id,
  'tenant',
  NULL,
  true,
  0,
  true,
  '20000000-0000-0000-0000-000000000002'
FROM data.compliance_requirement_types t
WHERE t.tenant_id IS NULL AND t.code = 'HEIGHT_WORK'
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.compliance_requirement_rules (
  id, tenant_id, requirement_type_id, scope_type, scope_id,
  is_blocking, grace_period_days, is_active, created_by
)
SELECT
  'e1000000-0000-0000-0000-000000000042',
  '10000000-0000-0000-0000-000000000001',
  t.id,
  'tenant',
  NULL,
  true,
  0,
  true,
  '20000000-0000-0000-0000-000000000002'
FROM data.compliance_requirement_types t
WHERE t.tenant_id IS NULL AND t.code = 'MEDICAL_FIT'
ON CONFLICT (id) DO NOTHING;

-- ─── 3. Certificacions Alice (tech + medical) — Charlie només veu tech ───────

INSERT INTO data.employee_certifications (
  id, tenant_id, employee_id, requirement_type_id,
  issuer, credential_number, issued_on, valid_from, valid_until,
  notes, created_by
)
SELECT
  'e1000000-0000-0000-0000-000000000051',
  '10000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  t.id,
  'QA Fixture',
  'QA-HEIGHT-ALICE',
  CURRENT_DATE - 30,
  CURRENT_DATE - 30,
  CURRENT_DATE + 365,
  'Fixture tech per aïllament medical (Charlie)',
  '20000000-0000-0000-0000-000000000002'
FROM data.compliance_requirement_types t
WHERE t.tenant_id IS NULL AND t.code = 'HEIGHT_WORK'
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_certifications (
  id, tenant_id, employee_id, requirement_type_id,
  issuer, credential_number, issued_on, valid_from, valid_until,
  notes, created_by
)
SELECT
  'e1000000-0000-0000-0000-000000000052',
  '10000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  t.id,
  'QA Fixture Medical',
  'QA-MED-ALICE',
  CURRENT_DATE - 30,
  CURRENT_DATE - 30,
  CURRENT_DATE + 180,
  'Fixture medical — Charlie NO l''ha de veure',
  '20000000-0000-0000-0000-000000000002'
FROM data.compliance_requirement_types t
WHERE t.tenant_id IS NULL AND t.code = 'MEDICAL_FIT'
ON CONFLICT (id) DO NOTHING;

-- ─── 4. Contractes ───────────────────────────────────────────────────────────

INSERT INTO data.employment_contracts (
  id, tenant_id, employee_id, contract_number, source,
  lifecycle_status, approval_status, signature_requirement, signature_status,
  is_primary, starts_on, ends_on, weekly_hours, site_id, created_by
) VALUES (
  'e1000000-0000-0000-0000-000000000011',
  '10000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000001',
  'QA-SMOKE-DRAFT-001',
  'manual',
  'draft',
  'approved',
  'employee_and_employer',
  'pending',
  true,
  CURRENT_DATE,
  CURRENT_DATE + 365,
  40,
  '30000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000002'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employment_contracts (
  id, tenant_id, employee_id, contract_number, source,
  lifecycle_status, approval_status, signature_requirement, signature_status,
  is_primary, starts_on, ends_on, weekly_hours, site_id,
  activated_at, created_by
)
SELECT
  'e1000000-0000-0000-0000-000000000012',
  '10000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000002',
  'QA-CHARLIE-ACTIVE-001',
  'legacy_backfill',
  'active',
  'approved',
  'none',
  'not_required',
  true,
  CURRENT_DATE - 90,
  CURRENT_DATE + 275,
  40,
  '30000000-0000-0000-0000-000000000001',
  now() - interval '90 days',
  '20000000-0000-0000-0000-000000000002'
WHERE NOT EXISTS (
  SELECT 1 FROM data.employment_contracts c
  WHERE c.employee_id = '40000000-0000-0000-0000-000000000002'
    AND c.is_primary
    AND c.lifecycle_status IN ('active', 'scheduled', 'ended')
)
AND NOT EXISTS (
  SELECT 1 FROM data.employment_contracts c
  WHERE c.id = 'e1000000-0000-0000-0000-000000000012'
);

INSERT INTO data.employment_contracts (
  id, tenant_id, employee_id, contract_number, source,
  lifecycle_status, approval_status, signature_requirement, signature_status,
  is_primary, starts_on, ends_on, weekly_hours, site_id,
  activated_at, created_by
) VALUES (
  'e1000000-0000-0000-0000-000000000013',
  '10000000-0000-0000-0000-000000000002',
  'e1000000-0000-0000-0000-000000000003',
  'QA-BETA-ACTIVE-001',
  'manual',
  'active',
  'approved',
  'none',
  'not_required',
  true,
  CURRENT_DATE,
  CURRENT_DATE + 365,
  40,
  '30000000-0000-0000-0000-000000000003',
  now(),
  '20000000-0000-0000-0000-000000000002'
)
ON CONFLICT (id) DO NOTHING;

-- ─── 5. Actius + assignacions ────────────────────────────────────────────────

INSERT INTO data.assets (
  id, tenant_id, site_id, name, asset_tag, status, asset_type_id,
  blocks_dispatch_if_missing
)
SELECT
  'e1000000-0000-0000-0000-000000000021',
  '10000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  'QA EPI Casc Smoke',
  'QA-EPI-SMOKE-001',
  'operational',
  at.id,
  true
FROM data.asset_types at
WHERE at.tenant_id IS NULL AND at.code = 'EPI_CAT_III'
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.assets (
  id, tenant_id, site_id, name, asset_tag, status, asset_type_id,
  blocks_dispatch_if_missing
)
SELECT
  'e1000000-0000-0000-0000-000000000022',
  '10000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  'QA EPI Casc Offboard',
  'QA-EPI-OFF-001',
  'operational',
  at.id,
  true
FROM data.asset_types at
WHERE at.tenant_id IS NULL AND at.code = 'EPI_CAT_III'
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_asset_assignments (
  id, tenant_id, asset_id, employee_id, assigned_at, assigned_by
) VALUES (
  'e1000000-0000-0000-0000-000000000031',
  '10000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000021',
  'e1000000-0000-0000-0000-000000000001',
  now(),
  '20000000-0000-0000-0000-000000000002'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_asset_assignments (
  id, tenant_id, asset_id, employee_id, assigned_at, assigned_by
) VALUES (
  'e1000000-0000-0000-0000-000000000032',
  '10000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000022',
  'e1000000-0000-0000-0000-000000000002',
  now(),
  '20000000-0000-0000-0000-000000000002'
)
ON CONFLICT (id) DO NOTHING;

-- Checklist devolució per empleat offboarding (simula EA-4)
SELECT data.ensure_employee_asset_return_checklist(
  'e1000000-0000-0000-0000-000000000002'::uuid,
  NULL
);

-- ─── 6. Skill mínim a Alice (si catàleg buit, el creem) ──────────────────────

DO $$
DECLARE
  v_type_id uuid;
  v_skill_id uuid;
  v_level_id uuid;
BEGIN
  SELECT id INTO v_type_id
  FROM data.skill_types
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
    AND lower(btrim(name)) = 'qa fixture'
  LIMIT 1;

  IF v_type_id IS NULL THEN
    INSERT INTO data.skill_types (id, tenant_id, name)
    VALUES (
      'e1000000-0000-0000-0000-000000000061',
      '10000000-0000-0000-0000-000000000001',
      'QA Fixture'
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING id INTO v_type_id;
    v_type_id := coalesce(v_type_id, 'e1000000-0000-0000-0000-000000000061');
  END IF;

  SELECT id INTO v_skill_id
  FROM data.skills
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
    AND skill_type_id = v_type_id
    AND lower(btrim(name)) = 'smoke testing'
  LIMIT 1;

  IF v_skill_id IS NULL THEN
    INSERT INTO data.skills (id, tenant_id, skill_type_id, name, description)
    VALUES (
      'e1000000-0000-0000-0000-000000000062',
      '10000000-0000-0000-0000-000000000001',
      v_type_id,
      'Smoke Testing',
      'Skill fixture'
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING id INTO v_skill_id;
    v_skill_id := coalesce(v_skill_id, 'e1000000-0000-0000-0000-000000000062');
  END IF;

  SELECT id INTO v_level_id
  FROM data.skill_levels
  WHERE skill_type_id = v_type_id
  ORDER BY rank NULLS LAST, created_at
  LIMIT 1;

  IF v_level_id IS NULL THEN
    INSERT INTO data.skill_levels (id, skill_type_id, name, rank)
    VALUES (
      'e1000000-0000-0000-0000-000000000063',
      v_type_id,
      'Intermedi',
      2
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING id INTO v_level_id;
    v_level_id := coalesce(v_level_id, 'e1000000-0000-0000-0000-000000000063');
  END IF;

  INSERT INTO data.employee_skills (
    id, tenant_id, employee_id, skill_id, level_id
  ) VALUES (
    'e1000000-0000-0000-0000-000000000064',
    '10000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000001',
    v_skill_id,
    v_level_id
  )
  ON CONFLICT (id) DO NOTHING;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Skill fixture omitida: %', SQLERRM;
END $$;

-- ─── 7. Refresh readiness projection (si existeix) ───────────────────────────

DO $$
BEGIN
  PERFORM data.refresh_employee_readiness_projection(
    'e1000000-0000-0000-0000-000000000001'::uuid
  );
  PERFORM data.refresh_employee_readiness_projection(
    '40000000-0000-0000-0000-000000000001'::uuid
  );
  RAISE NOTICE 'Readiness projection refreshed for QA Smoke + Alice';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Readiness refresh omitit: %', SQLERRM;
END $$;

COMMIT;

-- ─── 8. Verificació (visible a l'Editor SQL) ─────────────────────────────────

SELECT 'alice_certs' AS check_name, count(*)::text AS value
FROM data.employee_certifications
WHERE id IN (
  'e1000000-0000-0000-0000-000000000051',
  'e1000000-0000-0000-0000-000000000052'
)
UNION ALL
SELECT 'qa_smoke_employee', count(*)::text
FROM data.employees WHERE id = 'e1000000-0000-0000-0000-000000000001'
UNION ALL
SELECT 'qa_offboard_employee', count(*)::text
FROM data.employees WHERE id = 'e1000000-0000-0000-0000-000000000002'
UNION ALL
SELECT 'qa_beta_employee', count(*)::text
FROM data.employees WHERE id = 'e1000000-0000-0000-0000-000000000003'
UNION ALL
SELECT 'acme_rules', count(*)::text
FROM data.compliance_requirement_rules
WHERE id IN (
  'e1000000-0000-0000-0000-000000000041',
  'e1000000-0000-0000-0000-000000000042'
)
UNION ALL
SELECT 'qa_draft_contract', count(*)::text
FROM data.employment_contracts WHERE id = 'e1000000-0000-0000-0000-000000000011'
UNION ALL
SELECT 'qa_assignments_open', count(*)::text
FROM data.employee_asset_assignments
WHERE id IN (
  'e1000000-0000-0000-0000-000000000031',
  'e1000000-0000-0000-0000-000000000032'
) AND returned_at IS NULL
UNION ALL
SELECT 'offboard_checklist_open', count(*)::text
FROM data.employee_asset_return_checklists
WHERE employee_id = 'e1000000-0000-0000-0000-000000000002' AND status = 'open'
ORDER BY 1;
