-- =============================================================================
-- employee_portal_resolve_public_site_tests.sql — EP-ACC-2a
--
-- Executar:
--   Get-Content supabase/tests/employee_portal_resolve_public_site_tests.sql -Raw |
--     docker exec -i supabase_db_<project> psql -U postgres -d postgres
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ep2a_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active, public_portal_enabled)
VALUES ('c1000000-0000-0000-0000-000000000001', 'EP2A Tenant', 'ep2a-test', true, true)
ON CONFLICT (id) DO UPDATE SET public_portal_enabled = EXCLUDED.public_portal_enabled;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES
  ('c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'Barcelona', true),
  ('c2000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001', 'Madrid', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES ('c3000000-0000-0000-0000-000000000001', 'ep2a-mgr@test.com', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('c3000000-0000-0000-0000-000000000001', 'ep2a-mgr@test.com', 'EP2A Manager')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (
  'c4000000-0000-0000-0000-000000000001',
  'c1000000-0000-0000-0000-000000000001',
  'c3000000-0000-0000-0000-000000000001',
  'manager',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES
  ('c5000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', NULL, 'BCN Employee', 'active'),
  ('c5000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000002', NULL, 'MAD Employee', 'active'),
  ('c5000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000001', NULL, NULL, 'Global Employee', 'active')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.public_sites (id, tenant_id, site_id, slug, name, status)
VALUES
  ('c6000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', NULL, 'ep2a-global', 'Global Portal', 'published'),
  ('c6000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', 'ep2a-bcn', 'Barcelona Portal', 'published'),
  ('c6000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000002', 'ep2a-mad-draft', 'Madrid Draft', 'draft')
ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, slug = EXCLUDED.slug;

INSERT INTO data.public_domains (id, public_site_id, tenant_id, domain, status)
VALUES
  ('c7000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001', 'bcn.ep2a.test', 'ssl_active'),
  ('c7000000-0000-0000-0000-000000000002', 'c6000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001', 'secondary.bcn.ep2a.test', 'ssl_active')
ON CONFLICT (id) DO NOTHING;

UPDATE data.public_sites
SET primary_domain_id = 'c7000000-0000-0000-0000-000000000001'
WHERE id = 'c6000000-0000-0000-0000-000000000002';

-- Helper: set manager JWT
CREATE OR REPLACE FUNCTION pg_temp.ep2a_set_manager_jwt()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"c3000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"c1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"c1000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"c1000000-0000-0000-0000-000000000001"}', true);
  SET LOCAL ROLE authenticated;
END;
$$;

-- EP2A-T1: empleat Barcelona → portal Barcelona
DO $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM pg_temp.ep2a_set_manager_jwt();
  v_result := api.resolve_public_site_for_employee('c5000000-0000-0000-0000-000000000001');
  SET LOCAL ROLE postgres;

  IF (v_result ->> 'slug') = 'ep2a-bcn'
     AND COALESCE((v_result ->> 'fallback_used')::boolean, true) = false
     AND (v_result ->> 'canonical_domain') = 'bcn.ep2a.test'
     AND (v_result ->> 'portal_base_url') = 'https://bcn.ep2a.test' THEN
    INSERT INTO ep2a_test_results VALUES ('EP2A-T1 site portal', 'PASS', NULL);
  ELSE
    INSERT INTO ep2a_test_results VALUES ('EP2A-T1 site portal', 'FAIL', v_result::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ep2a_test_results VALUES ('EP2A-T1 site portal', 'ERROR', SQLERRM);
END;
$$;

-- EP2A-T2: empleat Madrid sense portal publicat → global + fallback
DO $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM pg_temp.ep2a_set_manager_jwt();
  v_result := api.resolve_public_site_for_employee('c5000000-0000-0000-0000-000000000002');
  SET LOCAL ROLE postgres;

  IF (v_result ->> 'slug') = 'ep2a-global'
     AND COALESCE((v_result ->> 'fallback_used')::boolean, false) = true THEN
    INSERT INTO ep2a_test_results VALUES ('EP2A-T2 madrid fallback global', 'PASS', NULL);
  ELSE
    INSERT INTO ep2a_test_results VALUES ('EP2A-T2 madrid fallback global', 'FAIL', v_result::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ep2a_test_results VALUES ('EP2A-T2 madrid fallback global', 'ERROR', SQLERRM);
END;
$$;

-- EP2A-T3: empleat sense site → global
DO $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM pg_temp.ep2a_set_manager_jwt();
  v_result := api.resolve_public_site_for_employee('c5000000-0000-0000-0000-000000000003');
  SET LOCAL ROLE postgres;

  IF (v_result ->> 'slug') = 'ep2a-global'
     AND COALESCE((v_result ->> 'fallback_used')::boolean, true) = false THEN
    INSERT INTO ep2a_test_results VALUES ('EP2A-T3 no site global', 'PASS', NULL);
  ELSE
    INSERT INTO ep2a_test_results VALUES ('EP2A-T3 no site global', 'FAIL', v_result::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ep2a_test_results VALUES ('EP2A-T3 no site global', 'ERROR', SQLERRM);
END;
$$;

-- EP2A-T4: primary_domain_id ssl_active guanya sobre altres dominis
DO $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM pg_temp.ep2a_set_manager_jwt();
  v_result := api.resolve_public_site_for_employee('c5000000-0000-0000-0000-000000000001');
  SET LOCAL ROLE postgres;

  IF (v_result ->> 'canonical_domain') = 'bcn.ep2a.test' THEN
    INSERT INTO ep2a_test_results VALUES ('EP2A-T4 primary domain', 'PASS', NULL);
  ELSE
    INSERT INTO ep2a_test_results VALUES ('EP2A-T4 primary domain', 'FAIL', v_result::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ep2a_test_results VALUES ('EP2A-T4 primary domain', 'ERROR', SQLERRM);
END;
$$;

-- EP2A-T5: sense cap portal → site_configured=false (no error)
DO $$
DECLARE
  v_result jsonb;
BEGIN
  DELETE FROM data.public_sites
  WHERE tenant_id = 'c1000000-0000-0000-0000-000000000001';

  PERFORM pg_temp.ep2a_set_manager_jwt();
  v_result := api.resolve_public_site_for_employee('c5000000-0000-0000-0000-000000000003');
  SET LOCAL ROLE postgres;

  IF COALESCE((v_result ->> 'site_configured')::boolean, true) = false
     AND (v_result ->> 'tenant_slug') = 'ep2a-test' THEN
    INSERT INTO ep2a_test_results VALUES ('EP2A-T5 no portal site', 'PASS', NULL);
  ELSE
    INSERT INTO ep2a_test_results VALUES ('EP2A-T5 no portal site', 'FAIL', v_result::text);
  END IF;
END;
$$;

SELECT test_name, status, details FROM ep2a_test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ep2a_test_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'employee_portal_resolve_public_site_tests: % failing test(s)', v_fail;
  END IF;
END;
$$;

ROLLBACK;
