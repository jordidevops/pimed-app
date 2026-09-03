-- =============================================================================
-- employee_portal_access_overview_tests.sql — EP-ACC-8a (H-T1…H-T7)
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ep_hub_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active, public_portal_enabled)
VALUES ('a1000000-0000-0000-0000-000000000001', 'EP Hub Tenant', 'ep-hub', true, true)
ON CONFLICT (id) DO UPDATE SET public_portal_enabled = EXCLUDED.public_portal_enabled;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES
  ('a2000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'Hub Site A', true),
  ('a2000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'Hub Site B', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('a3000000-0000-0000-0000-000000000001', 'ep-hub-global@test.com', 'authenticated', 'authenticated'),
  ('a3000000-0000-0000-0000-000000000002', 'ep-hub-site-a@test.com', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('a3000000-0000-0000-0000-000000000001', 'ep-hub-global@test.com', 'EP Hub Global Manager'),
  ('a3000000-0000-0000-0000-000000000002', 'ep-hub-site-a@test.com', 'EP Hub Site A Manager')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  ('a4000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'manager', true),
  ('a4000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, document_id, status)
VALUES
  ('a5000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', NULL, 'Hub Emp A1', 'HUBDOC001', 'active'),
  ('a5000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', NULL, 'Hub Emp A2', 'HUBDOC002', 'active'),
  ('a5000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', NULL, 'Hub Emp B1', 'HUBDOC003', 'active'),
  ('a5000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', NULL, 'Hub Emp No Doc', NULL, 'active'),
  ('a5000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', NULL, 'Hub Emp Inactive', 'HUBDOC005', 'inactive')
ON CONFLICT (id) DO UPDATE
SET document_id = EXCLUDED.document_id,
    status = EXCLUDED.status,
    site_id = EXCLUDED.site_id;

INSERT INTO data.public_sites (id, tenant_id, site_id, slug, name, status)
VALUES ('a6000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'ep-hub-site-a', 'EP Hub Portal A', 'published')
ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status;

INSERT INTO data.employee_portal_tokens (
  id, tenant_id, employee_id, token_hash, is_active, first_accessed_at, pin_must_set, pin_hash
)
VALUES
  (
    'a7000000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000001',
    'a5000000-0000-0000-0000-000000000001',
    decode('aa0000000000000000000000000000000000000000000000000000000000000001', 'hex'),
    true,
    now() - interval '1 day',
    false,
    'sha256:configured'
  ),
  (
    'a7000000-0000-0000-0000-000000000002',
    'a1000000-0000-0000-0000-000000000001',
    'a5000000-0000-0000-0000-000000000002',
    decode('aa0000000000000000000000000000000000000000000000000000000000000002', 'hex'),
    true,
    NULL,
    true,
    NULL
  )
ON CONFLICT (id) DO UPDATE
SET is_active = EXCLUDED.is_active,
    revoked_at = NULL,
    first_accessed_at = EXCLUDED.first_accessed_at,
    pin_must_set = EXCLUDED.pin_must_set,
    pin_hash = EXCLUDED.pin_hash;

CREATE OR REPLACE FUNCTION pg_temp.ep_hub_set_global_manager_jwt()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"a3000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a1000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"a1000000-0000-0000-0000-000000000001"}', true);
  SET LOCAL ROLE authenticated;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.ep_hub_set_site_a_manager_jwt()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"a3000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{"a2000000-0000-0000-0000-000000000001":{"role":"manager"}}}},"user_permissions":{"a1000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{"a2000000-0000-0000-0000-000000000001":{"permissions":["attendance.manage"]}}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"a1000000-0000-0000-0000-000000000001"}', true);
  SET LOCAL ROLE authenticated;
END;
$$;

DO $$
DECLARE
  v_result jsonb;
  v_rows jsonb;
  v_summary jsonb;
  v_total int;
BEGIN
  -- H-T1: 3 actius visibles, 2 amb enllaç personal actiu
  PERFORM pg_temp.ep_hub_set_global_manager_jwt();
  v_result := api.list_employee_portal_access_overview(
    p_employee_status => 'active'
  );
  v_rows := v_result -> 'rows';
  v_summary := v_result -> 'summary';

  IF jsonb_array_length(v_rows) = 4
     AND (v_summary ->> 'total_employees')::int = 4
     AND (
       SELECT count(*)::int
       FROM jsonb_array_elements(v_rows) r
       WHERE COALESCE(r -> 'personal' ->> 'has_active', 'false')::boolean = true
     ) = 2 THEN
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T1 overview summary', 'PASS', v_summary::text);
  ELSE
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T1 overview summary', 'FAIL', v_result::text);
  END IF;

  -- H-T2: never_opened → només A2
  v_result := api.list_employee_portal_access_overview(
    p_employee_status => 'active',
    p_portal_filter => 'never_opened'
  );
  v_rows := v_result -> 'rows';

  IF jsonb_array_length(v_rows) = 1
     AND (v_rows -> 0 ->> 'employee_id') = 'a5000000-0000-0000-0000-000000000002' THEN
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T2 never_opened filter', 'PASS', v_rows -> 0 ->> 'full_name');
  ELSE
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T2 never_opened filter', 'FAIL', v_result::text);
  END IF;

  -- H-T3 / H-T7: manager només site A
  PERFORM pg_temp.ep_hub_set_site_a_manager_jwt();
  v_result := api.list_employee_portal_access_overview(
    p_employee_status => 'active'
  );
  v_rows := v_result -> 'rows';
  v_summary := v_result -> 'summary';

  IF jsonb_array_length(v_rows) = 3
     AND (v_summary ->> 'total_employees')::int = 3
     AND NOT EXISTS (
       SELECT 1
       FROM jsonb_array_elements(v_rows) r
       WHERE r ->> 'employee_id' = 'a5000000-0000-0000-0000-000000000003'
     ) THEN
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T3 site scoped rows', 'PASS', '3 rows site A');
    INSERT INTO ep_hub_results VALUES ('H-T7 site scoped summary', 'PASS', v_summary ->> 'total_employees');
  ELSE
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T3 site scoped rows', 'FAIL', v_result::text);
    INSERT INTO ep_hub_results VALUES ('H-T7 site scoped summary', 'FAIL', v_summary::text);
  END IF;

  -- H-T4: paginació
  PERFORM pg_temp.ep_hub_set_global_manager_jwt();
  v_result := api.list_employee_portal_access_overview(
    p_employee_status => 'active',
    p_limit => 2,
    p_offset => 0
  );
  v_total := (v_result ->> 'total')::int;

  IF jsonb_array_length(v_result -> 'rows') = 2 AND v_total = 4 THEN
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T4 pagination page 1', 'PASS', v_total::text);
  ELSE
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T4 pagination page 1', 'FAIL', v_result::text);
  END IF;

  v_result := api.list_employee_portal_access_overview(
    p_employee_status => 'active',
    p_limit => 2,
    p_offset => 2
  );

  IF jsonb_array_length(v_result -> 'rows') = 2 AND (v_result ->> 'total')::int = 4 THEN
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T4 pagination page 2', 'PASS', (v_result ->> 'total'));
  ELSE
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T4 pagination page 2', 'FAIL', v_result::text);
  END IF;

  -- H-T5: summary coherents amb dades seed
  v_result := api.list_employee_portal_access_overview(p_employee_status => 'active');
  v_summary := v_result -> 'summary';

  IF (v_summary ->> 'without_personal_link')::int = 2
     AND (v_summary ->> 'never_opened')::int = 1
     AND (v_summary ->> 'missing_document_id')::int = 1 THEN
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T5 summary counts', 'PASS', v_summary::text);
  ELSE
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T5 summary counts', 'FAIL', v_summary::text);
  END IF;

  -- H-T6: missing_document_id flag
  v_result := api.list_employee_portal_access_overview(
    p_employee_status => 'active',
    p_portal_filter => 'missing_document_id'
  );
  v_rows := v_result -> 'rows';

  IF jsonb_array_length(v_rows) = 1
     AND COALESCE((v_rows -> 0 ->> 'missing_document_id')::boolean, false) = true
     AND (v_rows -> 0 ->> 'employee_id') = 'a5000000-0000-0000-0000-000000000004' THEN
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T6 missing document row', 'PASS', v_rows -> 0 ->> 'full_name');
  ELSE
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T6 missing document row', 'FAIL', v_result::text);
  END IF;

  -- H-T8: estat PIN (configurat després de setup vs pendent)
  v_result := api.list_employee_portal_access_overview(p_employee_status => 'active');
  v_rows := v_result -> 'rows';

  IF EXISTS (
       SELECT 1
       FROM jsonb_array_elements(v_rows) r
       WHERE r ->> 'employee_id' = 'a5000000-0000-0000-0000-000000000001'
         AND COALESCE(r -> 'personal' ->> 'pin_required', 'false')::boolean = true
         AND COALESCE(r -> 'personal' ->> 'pin_configured', 'false')::boolean = true
         AND COALESCE(r -> 'personal' ->> 'pin_must_set', 'true')::boolean = false
     )
     AND EXISTS (
       SELECT 1
       FROM jsonb_array_elements(v_rows) r
       WHERE r ->> 'employee_id' = 'a5000000-0000-0000-0000-000000000002'
         AND COALESCE(r -> 'personal' ->> 'pin_required', 'false')::boolean = true
         AND COALESCE(r -> 'personal' ->> 'pin_configured', 'false')::boolean = false
         AND COALESCE(r -> 'personal' ->> 'pin_must_set', 'false')::boolean = true
     ) THEN
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T8 pin status fields', 'PASS', 'configured + pending');
  ELSE
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T8 pin status fields', 'FAIL', v_result::text);
  END IF;

  -- H-T9: filtre pin_not_configured → només A2
  v_result := api.list_employee_portal_access_overview(
    p_employee_status => 'active',
    p_portal_filter => 'pin_not_configured'
  );
  v_rows := v_result -> 'rows';

  IF jsonb_array_length(v_rows) = 1
     AND (v_rows -> 0 ->> 'employee_id') = 'a5000000-0000-0000-0000-000000000002' THEN
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T9 pin_not_configured filter', 'PASS', v_rows -> 0 ->> 'full_name');
  ELSE
    SET LOCAL ROLE postgres;
    INSERT INTO ep_hub_results VALUES ('H-T9 pin_not_configured filter', 'FAIL', v_result::text);
  END IF;

EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ep_hub_results VALUES ('EP8a setup', 'ERROR', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM ep_hub_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ep_hub_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'employee_portal_access_overview_tests failed: % cases', v_fail;
  END IF;
END;
$$;

ROLLBACK;
