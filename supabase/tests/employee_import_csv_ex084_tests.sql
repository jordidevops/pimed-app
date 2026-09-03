-- =============================================================================
-- employee_import_csv_ex084_tests.sql
-- EX-08.4 — Import CSV + external_entity_mappings (match, dry_run, idempotència)
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ex084_results (test_name text, status text, details text) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0840000-0000-0000-0000-000000000001', 'EX084 Tenant', 'ex084-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0840000-0000-0000-0000-000000000001', 'a0840000-0000-0000-0000-000000000001', 'EX084 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES ('c0840000-0000-0000-0000-000000000002', 'mgr@ex084.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('c0840000-0000-0000-0000-000000000002', 'mgr@ex084.test', 'Mgr EX084')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (gen_random_uuid(), 'a0840000-0000-0000-0000-000000000001', 'c0840000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, full_name, document_id, email, status)
VALUES (
  'd0840000-0000-0000-0000-000000000001',
  'a0840000-0000-0000-0000-000000000001',
  'b0840000-0000-0000-0000-000000000001',
  'Exist EX084', '12345678A', 'exist@ex084.test', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.job_positions (id, tenant_id, code, name, is_active)
VALUES (
  'e0840000-0000-0000-0000-000000000001',
  'a0840000-0000-0000-0000-000000000001',
  'EX084-CUIN',
  'Cuiner',
  true
)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0840000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0840000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0840000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0840000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true);
END;
$$;

-- T1 normalize helpers
DO $$
BEGIN
  IF data.normalize_document_id(' 12.345.678-a ') = '12345678A'
     AND data.normalize_email('  Foo@Ex084.TEST ') = 'foo@ex084.test' THEN
    INSERT INTO ex084_results VALUES ('T1 normalize_helpers', 'PASS', 'ok');
  ELSE
    INSERT INTO ex084_results VALUES ('T1 normalize_helpers', 'FAIL',
      format('doc=%s email=%s',
        data.normalize_document_id(' 12.345.678-a '),
        data.normalize_email('  Foo@Ex084.TEST ')));
  END IF;
END;
$$;

-- T2 dry_run create + update preview (no writes for create path counts)
DO $$
DECLARE
  v jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'Exist EX084 Updated',
        'document_id', '12345678A',
        'email', 'exist@ex084.test',
        'external_id', 'CSV-EXIST-1'
      ),
      jsonb_build_object(
        'full_name', 'Nou EX084',
        'document_id', '87654321B',
        'email', 'nou@ex084.test',
        'external_id', 'CSV-NEW-1'
      )
    ),
    jsonb_build_object('dry_run', true, 'default_provider', 'csv')
  );

  RESET ROLE;

  IF (v->>'ok')::boolean
     AND (v->>'dry_run')::boolean
     AND (v->>'updated')::int = 1
     AND (v->>'created')::int = 1
     AND NOT EXISTS (
       SELECT 1 FROM data.employees e
       WHERE e.tenant_id = 'a0840000-0000-0000-0000-000000000001'
         AND data.normalize_document_id(e.document_id) = '87654321B'
     ) THEN
    INSERT INTO ex084_results VALUES ('T2 dry_run_preview', 'PASS', v::text);
  ELSE
    INSERT INTO ex084_results VALUES ('T2 dry_run_preview', 'FAIL', v::text);
  END IF;
END;
$$;

-- T3 real import: create + mapping + match by NIF update
DO $$
DECLARE
  v jsonb;
  v2 jsonb;
  v_map uuid;
  v_emp uuid;
  v_name text;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'Nou EX084',
        'document_id', '87654321B',
        'email', 'nou@ex084.test',
        'job_position_ref', 'EX084-CUIN',
        'status', 'active',
        'weekly_hours', 40,
        'external_id', 'CSV-NEW-1',
        'provider', 'csv'
      ),
      jsonb_build_object(
        'full_name', 'Exist EX084 Sync',
        'document_id', '12345678A',
        'email', 'exist@ex084.test',
        'external_id', 'CSV-EXIST-1'
      )
    ),
    jsonb_build_object(
      'dry_run', false,
      'default_site_id', 'b0840000-0000-0000-0000-000000000001'
    )
  );

  RESET ROLE;

  SELECT e.id, e.full_name INTO v_emp, v_name
  FROM data.employees e
  WHERE e.tenant_id = 'a0840000-0000-0000-0000-000000000001'
    AND data.normalize_document_id(e.document_id) = '87654321B';

  SELECT m.id INTO v_map
  FROM data.external_entity_mappings m
  WHERE m.tenant_id = 'a0840000-0000-0000-0000-000000000001'
    AND m.provider = 'csv'
    AND m.external_id = 'CSV-NEW-1'
    AND m.internal_id = v_emp;

  -- re-import idempotent
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v2 := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'Nou EX084 Bis',
        'document_id', '87654321B',
        'email', 'nou@ex084.test',
        'external_id', 'CSV-NEW-1'
      )
    ),
    '{}'::jsonb
  );
  RESET ROLE;

  IF (v->>'created')::int = 1
     AND (v->>'updated')::int = 1
     AND v_map IS NOT NULL
     AND (v2->>'created')::int = 0
     AND (v2->>'updated')::int = 1
     AND (SELECT full_name FROM data.employees WHERE id = v_emp) = 'Nou EX084 Bis' THEN
    INSERT INTO ex084_results VALUES ('T3 import_create_update_idempotent', 'PASS',
      format('created=%s updated=%s re_updated=%s', v->>'created', v->>'updated', v2->>'updated'));
  ELSE
    INSERT INTO ex084_results VALUES ('T3 import_create_update_idempotent', 'FAIL',
      format('v=%s v2=%s map=%s name=%s', v, v2, v_map, v_name));
  END IF;
END;
$$;

-- T4 match by mapping external_id
DO $$
DECLARE
  v jsonb;
  v_emp uuid;
BEGIN
  SELECT internal_id INTO v_emp
  FROM data.external_entity_mappings
  WHERE tenant_id = 'a0840000-0000-0000-0000-000000000001'
    AND provider = 'csv' AND external_id = 'CSV-NEW-1';

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'Via Mapping',
        'document_id', '99999999Z',
        'email', 'mapping@ex084.test',
        'external_id', 'CSV-NEW-1',
        'provider', 'csv'
      )
    ),
    '{}'::jsonb
  );
  RESET ROLE;

  IF (v->>'updated')::int = 1
     AND (v->'results'->0->>'matched_by') = 'mapping'
     AND (SELECT full_name FROM data.employees WHERE id = v_emp) = 'Via Mapping' THEN
    INSERT INTO ex084_results VALUES ('T4 match_by_mapping', 'PASS', v::text);
  ELSE
    INSERT INTO ex084_results VALUES ('T4 match_by_mapping', 'FAIL', v::text);
  END IF;
END;
$$;

-- T5 email/NIF mismatch skips without force
DO $$
DECLARE
  v jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'Conflict',
        'document_id', '11111111H',
        'email', 'exist@ex084.test'
      )
    ),
    jsonb_build_object('force_email_match', false)
  );
  RESET ROLE;

  IF (v->>'skipped')::int = 1
     AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(v->'errors') e
       WHERE e->>'code' = 'EMAIL_NIF_MISMATCH'
     ) THEN
    INSERT INTO ex084_results VALUES ('T5 email_nif_mismatch', 'PASS', v::text);
  ELSE
    INSERT INTO ex084_results VALUES ('T5 email_nif_mismatch', 'FAIL', v::text);
  END IF;
END;
$$;

SELECT test_name, status, details FROM ex084_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex084_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-08.4 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
