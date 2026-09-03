-- =============================================================================
-- REC-0…3 hotfix P0+P1 tests
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

CREATE OR REPLACE FUNCTION pg_temp.set_site_a_view_jwt(p_site uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_claim text;
BEGIN
  v_claim := format(
    '{"sub":"20000000-0000-0000-0000-000000000096","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{"%s":{"role":"member"}}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{"%s":{"permissions":["recruitment.view"]}}}}}}',
    p_site, p_site
  );
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000096', true);
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
  v_posting_a uuid;
  v_posting_b uuid;
  v_app jsonb;
  v_app_id uuid;
  v_cnt int;
  v_vars jsonb;
  v_opts jsonb;
  v_max int;
  v_src text;
  v_ok boolean;
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
    VALUES (v_tenant, 'rec03-hf-site', 'REC03 HF', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  SELECT id INTO v_site_a FROM data.sites WHERE tenant_id = v_tenant ORDER BY name LIMIT 1;
  SELECT id INTO v_site_b FROM data.sites WHERE tenant_id = v_tenant AND id <> v_site_a ORDER BY name LIMIT 1;
  IF v_site_a IS NULL THEN
    INSERT INTO data.sites (tenant_id, name, is_active)
    VALUES (v_tenant, 'REC03 Site A', true) RETURNING id INTO v_site_a;
  END IF;
  IF v_site_b IS NULL THEN
    INSERT INTO data.sites (tenant_id, name, is_active)
    VALUES (v_tenant, 'REC03 Site B', true) RETURNING id INTO v_site_b;
  END IF;

  INSERT INTO data.job_postings (tenant_id, site_id, title, public_slug, status, created_by)
  VALUES (
    v_tenant, v_site_a, 'REC03 A',
    'rec03-a-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner
  ) RETURNING id INTO v_posting_a;

  INSERT INTO data.job_postings (tenant_id, site_id, title, public_slug, status, created_by)
  VALUES (
    v_tenant, v_site_b, 'REC03 B',
    'rec03-b-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner
  ) RETURNING id INTO v_posting_b;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting_a, v_ps, v_tenant), (v_posting_b, v_ps, v_tenant)
  ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting_a;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting_b;

  -- 1) anon cannot execute submit
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM api.submit_job_application(
      v_ps, v_posting_a, 'anon-abuse',
      'Hacker', 'hack@example.com', NULL, NULL,
      'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca',
      'https://evil.example'
    );
    RESET ROLE;
    INSERT INTO test_results VALUES ('anon_cannot_submit', 'FAIL', 'expected forbidden');
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    INSERT INTO test_results VALUES ('anon_cannot_submit', 'PASS', SQLERRM);
  WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' OR SQLERRM ILIKE '%permission denied%' THEN
      INSERT INTO test_results VALUES ('anon_cannot_submit', 'PASS', SQLERRM);
    ELSE
      INSERT INTO test_results VALUES ('anon_cannot_submit', 'FAIL', SQLERRM);
    END IF;
  END;

  -- 2) template_variables in function body (no bare 'variables' key for enqueue)
  SELECT pg_get_functiondef('api.submit_job_application(uuid,uuid,text,text,text,text,text,text,text,int,text,text,boolean,text,text)'::regprocedure)
  INTO v_src;
  IF v_src ILIKE '%template_variables%'
     AND v_src NOT LIKE '%''variables'', jsonb_build_object%' THEN
    INSERT INTO test_results VALUES ('submit_uses_template_variables', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('submit_uses_template_variables', 'FAIL', left(v_src, 200));
  END IF;

  -- 3) postgres submit + email_logs template_variables (owner JWT for enqueue ACL)
  PERFORM pg_temp.set_owner_jwt();
  v_app := api.submit_job_application(
    v_ps, v_posting_a, 'rec03-hf-1',
    'Verify Cand', 'verify.rec03@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, 'orphan-path-should-stay', 'v1', true, 'ca',
    'https://portal.example'
  );

  SELECT template_variables INTO v_vars
  FROM data.email_logs
  WHERE tenant_id = v_tenant
    AND idempotency_key = 'recruitment-verify-' || (v_app->>'application_id')
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_vars IS NOT NULL
     AND v_vars ? 'verify_url'
     AND (v_vars->>'verify_url') LIKE 'https://portal.example/recruitment/verify?token=%' THEN
    INSERT INTO test_results VALUES ('email_template_variables_ok', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'email_template_variables_ok', 'FAIL',
      COALESCE(v_vars::text, 'no email_logs row')
    );
  END IF;

  -- 4) duplicate cleans orphan CV path (storage may not have object; RPC must not error)
  v_app := api.submit_job_application(
    v_ps, v_posting_a, 'rec03-hf-dup',
    'Verify Cand', 'verify.rec03@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, 'orphan-new-path-' || gen_random_uuid()::text, 'v1', true, 'ca',
    'https://portal.example'
  );
  IF COALESCE((v_app->>'duplicate')::boolean, false) THEN
    INSERT INTO test_results VALUES ('duplicate_orphan_cv_handled', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('duplicate_orphan_cv_handled', 'FAIL', v_app::text);
  END IF;

  -- 5) site A view sees A apps, not B
  v_app := api.submit_job_application(
    v_ps, v_posting_b, 'rec03-hf-b',
    'Site B Cand', 'siteb.rec03@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  SELECT id INTO v_app_id
  FROM data.applications
  WHERE job_posting_id = v_posting_a
  ORDER BY created_at DESC LIMIT 1;

  PERFORM pg_temp.set_site_a_view_jwt(v_site_a);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_cnt
  FROM data.applications
  WHERE id = v_app_id;
  RESET ROLE;
  IF v_cnt = 1 THEN
    INSERT INTO test_results VALUES ('site_view_sees_own_apps', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('site_view_sees_own_apps', 'FAIL', v_cnt::text);
  END IF;

  PERFORM pg_temp.set_site_a_view_jwt(v_site_a);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_cnt
  FROM data.applications
  WHERE job_posting_id = v_posting_b;
  RESET ROLE;
  IF v_cnt = 0 THEN
    INSERT INTO test_results VALUES ('site_view_hides_other_site', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('site_view_hides_other_site', 'FAIL', v_cnt::text);
  END IF;

  -- 6) retention options ≤ ceiling
  UPDATE data.recruitment_settings
  SET default_max_retention_months = 3
  WHERE tenant_id = v_tenant;

  SELECT (api.get_public_job_posting(v_ps, (
    SELECT public_slug FROM data.job_postings WHERE id = v_posting_a
  )))->'retention_options_months',
         (api.get_public_job_posting(v_ps, (
    SELECT public_slug FROM data.job_postings WHERE id = v_posting_a
  )))->>'default_max_retention_months'
  INTO v_opts, v_max;

  IF v_opts = '[3]'::jsonb AND v_max::int = 3 THEN
    INSERT INTO test_results VALUES ('retention_options_clamped', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'retention_options_clamped', 'FAIL',
      format('opts=%s max=%s', v_opts, v_max)
    );
  END IF;

  UPDATE data.recruitment_settings
  SET default_max_retention_months = 12
  WHERE tenant_id = v_tenant;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('setup_or_rpc', 'FAIL', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM test_results WHERE status = 'FAIL') THEN
    RAISE EXCEPTION 'recruitment_rec03_hotfix_p0_p1_tests failed';
  END IF;
END;
$$;

ROLLBACK;
