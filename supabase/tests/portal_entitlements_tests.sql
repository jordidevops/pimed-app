-- =============================================================================
-- portal_entitlements_tests.sql — TCMS-1 F1 + TCMS-1.1 snapshot
-- =============================================================================

BEGIN;

CREATE TEMP TABLE tcms_f1_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.plans (id, name, display_name, max_members, max_storage_mb, price_monthly, max_sites, max_portal_pages, portal_field_limits, portal_entitlements)
VALUES (
  'd1000000-0000-0000-0000-000000000001',
  'tcms-test-free',
  'TCMS Free',
  3, 100, 0, 1, 3,
  '{"page_html_max_chars":10000}'::jsonb,
  '{"employee_portal":{"included":true,"cms_tier":"basic"},"public_portal":{"included":true,"cms_tier":"basic","max_pages":3}}'::jsonb
)
ON CONFLICT (name) DO UPDATE SET portal_entitlements = EXCLUDED.portal_entitlements;

INSERT INTO data.plans (id, name, display_name, max_members, max_storage_mb, price_monthly, max_sites, max_portal_pages, portal_field_limits, portal_entitlements)
VALUES (
  'd1000000-0000-0000-0000-000000000002',
  'tcms-test-pro',
  'TCMS Pro',
  20, 5000, 29, 5, 20,
  '{"page_html_max_chars":50000}'::jsonb,
  '{"employee_portal":{"included":true,"cms_tier":"basic"},"public_portal":{"included":true,"cms_tier":"basic","max_pages":20}}'::jsonb
)
ON CONFLICT (name) DO UPDATE SET portal_entitlements = EXCLUDED.portal_entitlements;

INSERT INTO data.tenants (id, name, slug, plan_id, employee_portal_enabled, public_portal_enabled, tenant_portal_entitlements)
VALUES
  (
    'd2000000-0000-0000-0000-000000000001',
    'TCMS Free Tenant',
    'tcms-free',
    'd1000000-0000-0000-0000-000000000001',
    true,
    true,
    '{"employee_portal":{"included":true,"cms_tier":"basic"},"public_portal":{"included":true,"cms_tier":"basic","max_pages":3}}'::jsonb
  ),
  (
    'd2000000-0000-0000-0000-000000000002',
    'TCMS Pro Tenant',
    'tcms-pro',
    'd1000000-0000-0000-0000-000000000002',
    true,
    true,
    '{"employee_portal":{"included":true,"cms_tier":"basic"},"public_portal":{"included":true,"cms_tier":"basic","max_pages":20}}'::jsonb
  )
ON CONFLICT (id) DO UPDATE SET
  plan_id = EXCLUDED.plan_id,
  employee_portal_enabled = EXCLUDED.employee_portal_enabled,
  public_portal_enabled = EXCLUDED.public_portal_enabled,
  tenant_portal_entitlements = EXCLUDED.tenant_portal_entitlements;

-- T1: free tenant with granted public + flag → effective public
INSERT INTO tcms_f1_results
SELECT
  'T1_free_public_effective_when_granted',
  CASE WHEN (data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000001')->'public_portal'->>'effective')::boolean
       THEN 'PASS' ELSE 'FAIL' END,
  data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000001')::text;

-- T2: pro tenant both effective when flags on
INSERT INTO tcms_f1_results
SELECT
  'T2_pro_both_effective',
  CASE WHEN (data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000002')->'employee_portal'->>'effective')::boolean
        AND (data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000002')->'public_portal'->>'effective')::boolean
       THEN 'PASS' ELSE 'FAIL' END,
  data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000002')::text;

-- T3: can_publish_content public allowed on free when granted
INSERT INTO tcms_f1_results
SELECT
  'T3_free_public_publish_allowed',
  CASE WHEN (api.can_publish_content('d2000000-0000-0000-0000-000000000001', 'public', 'publish')->>'allowed')::boolean
       THEN 'PASS' ELSE 'FAIL' END,
  api.can_publish_content('d2000000-0000-0000-0000-000000000001', 'public', 'publish')::text;

-- T4: can_publish_content employee allowed on free
INSERT INTO tcms_f1_results
SELECT
  'T4_free_employee_publish_allowed',
  CASE WHEN (api.can_publish_content('d2000000-0000-0000-0000-000000000001', 'employee', 'publish')->>'allowed')::boolean
       THEN 'PASS' ELSE 'FAIL' END,
  api.can_publish_content('d2000000-0000-0000-0000-000000000001', 'employee', 'publish')::text;

-- T5: admin snapshot elevates cms tier
UPDATE data.tenants
SET tenant_portal_entitlements = jsonb_set(
  tenant_portal_entitlements,
  '{employee_portal,cms_tier}',
  '"advanced"'::jsonb,
  true
)
WHERE id = 'd2000000-0000-0000-0000-000000000002';

INSERT INTO tcms_f1_results
SELECT
  'T5_snapshot_elevates_tier',
  CASE WHEN data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000002')->'employee_portal'->>'cms_tier' = 'advanced'
       THEN 'PASS' ELSE 'FAIL' END,
  data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000002')->'employee_portal'->>'cms_tier';

-- T6: sync does NOT disable public flag on free (TCMS-1.1)
SELECT api.sync_portal_entitlements_with_plan('d2000000-0000-0000-0000-000000000001');

INSERT INTO tcms_f1_results
SELECT
  'T6_sync_keeps_public_flag',
  CASE WHEN (SELECT public_portal_enabled FROM data.tenants WHERE id = 'd2000000-0000-0000-0000-000000000001') = true
       THEN 'PASS' ELSE 'FAIL' END,
  (SELECT public_portal_enabled::text FROM data.tenants WHERE id = 'd2000000-0000-0000-0000-000000000001');

-- T7: plan downgrade max_pages does not reduce granted snapshot (20 stays 20)
UPDATE data.plans
SET portal_entitlements = jsonb_set(
  portal_entitlements,
  '{public_portal,max_pages}',
  '10'::jsonb,
  true
)
WHERE id = 'd1000000-0000-0000-0000-000000000002';

INSERT INTO tcms_f1_results
SELECT
  'T7_grandfather_max_pages',
  CASE WHEN (data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000002')->'public_portal'->>'max_pages')::integer = 20
       THEN 'PASS' ELSE 'FAIL' END,
  data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000002')->'public_portal'->>'max_pages';

-- T8: revoking included in snapshot blocks effective even if plan includes
UPDATE data.tenants
SET tenant_portal_entitlements = jsonb_set(
  tenant_portal_entitlements,
  '{public_portal,included}',
  'false'::jsonb,
  true
)
WHERE id = 'd2000000-0000-0000-0000-000000000001';

INSERT INTO tcms_f1_results
SELECT
  'T8_snapshot_revoke_blocks_effective',
  CASE WHEN (data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000001')->'public_portal'->>'effective')::boolean = false
       THEN 'PASS' ELSE 'FAIL' END,
  data.resolve_portal_entitlements('d2000000-0000-0000-0000-000000000001')::text;

DO $$
DECLARE
  v_fail integer;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM tcms_f1_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'TCMS F1 tests failed: %', v_fail;
  END IF;
  RAISE NOTICE 'TCMS F1: all tests passed';
END $$;

ROLLBACK;
