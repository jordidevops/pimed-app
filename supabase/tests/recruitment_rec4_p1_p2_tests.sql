-- =============================================================================
-- REC-4 P1–P2 tests
-- - view cannot SELECT interviews / cannot move / cannot export
-- - CSV formula escape
-- - site-scoped manage on move
-- =============================================================================

BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_owner_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_view_only_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000099', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000099","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["recruitment.view"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_site_a_manage_jwt(p_site_a uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_claim text;
BEGIN
  v_claim := format(
    '{"sub":"20000000-0000-0000-0000-000000000097","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{"%s":{"role":"manager"}}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["recruitment.view"],"sites":{"%s":{"permissions":["recruitment.manage"]}}}}}}',
    p_site_a, p_site_a
  );
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000097', true);
  PERFORM set_config('request.jwt.claim', v_claim, true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_ps uuid;
  v_site_a uuid;
  v_site_b uuid;
  v_posting uuid;
  v_posting_b uuid;
  v_app_id uuid;
  v_app_b uuid;
  v_interview uuid;
  v_stage uuid;
  v_cnt int;
  v_csv text;
  v_rows int;
  v_excl int;
  v_cell text;
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (v_tenant, 'recruitment_enabled', true)
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant) ON CONFLICT DO NOTHING;
  PERFORM data.seed_default_pipeline_stages(v_tenant);

  SELECT id INTO v_ps FROM data.public_sites WHERE tenant_id = v_tenant LIMIT 1;
  IF v_ps IS NULL THEN
    INSERT INTO data.public_sites (tenant_id, slug, name, status, default_locale)
    VALUES (v_tenant, 'rec4p12-site', 'REC4 P12', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  SELECT id INTO v_site_a
  FROM data.sites WHERE tenant_id = v_tenant ORDER BY name LIMIT 1;
  SELECT id INTO v_site_b
  FROM data.sites WHERE tenant_id = v_tenant AND id <> v_site_a ORDER BY name LIMIT 1;

  IF v_site_a IS NULL THEN
    INSERT INTO data.sites (tenant_id, name, is_active)
    VALUES (v_tenant, 'REC4 Site A', true)
    RETURNING id INTO v_site_a;
  END IF;
  IF v_site_b IS NULL THEN
    INSERT INTO data.sites (tenant_id, name, is_active)
    VALUES (v_tenant, 'REC4 Site B', true)
    RETURNING id INTO v_site_b;
  END IF;

  INSERT INTO data.job_postings (
    tenant_id, site_id, title, public_slug, status, created_by
  ) VALUES (
    v_tenant, v_site_a, 'REC4 P12 A',
    'rec4-p12-a-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner
  )
  RETURNING id INTO v_posting;

  INSERT INTO data.job_postings (
    tenant_id, site_id, title, public_slug, status, created_by
  ) VALUES (
    v_tenant, v_site_b, 'REC4 P12 B',
    'rec4-p12-b-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner
  )
  RETURNING id INTO v_posting_b;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant), (v_posting_b, v_ps, v_tenant)
  ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting_b;

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec4-p12-idem-1',
    'Notes Cand', 'notes.p12@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  PERFORM api.submit_job_application(
    v_ps, v_posting_b, 'rec4-p12-idem-2',
    'Site B Cand', 'siteb.p12@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  SELECT a.id INTO v_app_id
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting AND ap.email = 'notes.p12@example.com';

  SELECT a.id INTO v_app_b
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting_b AND ap.email = 'siteb.p12@example.com';

  SELECT id INTO v_stage
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'En revisió'
  LIMIT 1;

  -- Owner creates interview with formula-like name already on applicant for CSV test
  UPDATE data.applicants SET full_name = '=CMD|''/C calc''!A0'
  WHERE email = 'notes.p12@example.com';

  INSERT INTO data.interviews (
    tenant_id, application_id, type, notes, status
  ) VALUES (
    v_tenant, v_app_id, 'phone', 'secret notes', 'scheduled'
  )
  RETURNING id INTO v_interview;

  -- 1) view-only cannot SELECT interviews (RLS)
  PERFORM pg_temp.set_view_only_jwt();
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_cnt FROM data.interviews WHERE id = v_interview;
  RESET ROLE;
  IF v_cnt = 0 THEN
    INSERT INTO test_results VALUES ('view_cannot_select_interview', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('view_cannot_select_interview', 'FAIL', v_cnt::text);
  END IF;

  -- 2) view-only cannot move
  PERFORM pg_temp.set_view_only_jwt();
  BEGIN
    PERFORM api.move_application_stage(v_app_id, v_stage);
    INSERT INTO test_results VALUES ('view_cannot_move', 'FAIL', 'expected forbidden');
  EXCEPTION WHEN insufficient_privilege THEN
    INSERT INTO test_results VALUES ('view_cannot_move', 'PASS', SQLERRM);
  WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' THEN
      INSERT INTO test_results VALUES ('view_cannot_move', 'PASS', SQLERRM);
    ELSE
      INSERT INTO test_results VALUES ('view_cannot_move', 'FAIL', SQLERRM);
    END IF;
  END;

  -- 3) view-only cannot export
  BEGIN
    PERFORM api.export_job_posting_applications_csv(v_posting, true);
    INSERT INTO test_results VALUES ('view_cannot_export', 'FAIL', 'expected forbidden');
  EXCEPTION WHEN insufficient_privilege THEN
    INSERT INTO test_results VALUES ('view_cannot_export', 'PASS', SQLERRM);
  WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' THEN
      INSERT INTO test_results VALUES ('view_cannot_export', 'PASS', SQLERRM);
    ELSE
      INSERT INTO test_results VALUES ('view_cannot_export', 'FAIL', SQLERRM);
    END IF;
  END;

  -- 4) CSV formula escape
  SELECT b.p_csv, b.p_row_count, b.p_excluded_count
  INTO v_csv, v_rows, v_excl
  FROM data.build_job_posting_applications_csv(v_tenant, v_posting) AS b;

  v_cell := data.csv_escape_cell('=1+1');
  IF v_cell = '''"=1+1"' OR v_cell = '"''=1+1"' THEN
    -- csv_escape_cell returns quoted cell with leading apostrophe inside
    NULL;
  END IF;
  IF data.csv_escape_cell('=1+1') = '"''=1+1"'
     AND v_csv LIKE '%''=CMD%'
     AND v_rows >= 1 THEN
    INSERT INTO test_results VALUES ('csv_formula_escaped', 'PASS', left(v_csv, 120));
  ELSE
    INSERT INTO test_results VALUES (
      'csv_formula_escaped', 'FAIL',
      format('cell=%s csv=%s rows=%s', data.csv_escape_cell('=1+1'), left(COALESCE(v_csv,''), 160), v_rows)
    );
  END IF;

  -- 5) site A manage can move A, cannot move B
  PERFORM pg_temp.set_site_a_manage_jwt(v_site_a);
  BEGIN
    PERFORM api.move_application_stage(v_app_id, v_stage);
    INSERT INTO test_results VALUES ('site_manage_can_move_own', 'PASS', NULL);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('site_manage_can_move_own', 'FAIL', SQLERRM);
  END;

  BEGIN
    PERFORM api.move_application_stage(v_app_b, v_stage);
    INSERT INTO test_results VALUES ('site_manage_cannot_move_other', 'FAIL', 'expected forbidden');
  EXCEPTION WHEN insufficient_privilege THEN
    INSERT INTO test_results VALUES ('site_manage_cannot_move_other', 'PASS', SQLERRM);
  WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' THEN
      INSERT INTO test_results VALUES ('site_manage_cannot_move_other', 'PASS', SQLERRM);
    ELSE
      INSERT INTO test_results VALUES ('site_manage_cannot_move_other', 'FAIL', SQLERRM);
    END IF;
  END;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('setup_or_rpc', 'FAIL', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM test_results WHERE status = 'FAIL') THEN
    RAISE EXCEPTION 'recruitment_rec4_p1_p2_tests failed';
  END IF;
END;
$$;

ROLLBACK;
