-- =============================================================================
-- REC-6 P2 tests — locale + hire gate sense bypass de rol
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

-- global_role=manager però sense employees.manage al JWT (bypass antic)
CREATE OR REPLACE FUNCTION pg_temp.set_manager_role_only_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["recruitment.manage"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_ps uuid;
  v_posting uuid;
  v_job_pos uuid;
  v_app uuid;
  v_app2 uuid;
  v_applicant uuid;
  v_result jsonb;
  v_locale text;
  v_ok boolean;
  v_err text;
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
    VALUES (v_tenant, 'rec6p2-site', 'REC6P2', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_positions (tenant_id, code, name, is_active)
  VALUES (v_tenant, 'REC6P2-POS', 'Pos REC6P2', true)
  RETURNING id INTO v_job_pos;

  INSERT INTO data.job_postings (
    tenant_id, title, public_slug, status, created_by, job_position_id
  )
  VALUES (
    v_tenant, 'REC6P2 Job', 'rec6p2-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner, v_job_pos
  )
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  -- Locale persistit a apply (es)
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec6p2-idem-es',
    'Locale ES', 'locale.es.rec6p2@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'es', NULL
  );
  SELECT a.id, a.applicant_id, ap.preferred_locale
  INTO v_app, v_applicant, v_locale
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'locale.es.rec6p2@example.com' AND a.job_posting_id = v_posting;

  IF v_locale = 'es' THEN
    INSERT INTO test_results VALUES ('submit_persists_preferred_locale', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('submit_persists_preferred_locale', 'FAIL', v_locale);
  END IF;

  PERFORM pg_temp.set_owner_jwt();
  v_result := api.hire_application(v_app, NULL, NULL, CURRENT_DATE, v_job_pos);
  IF v_result->>'email_locale' = 'es'
     AND (v_result->>'already_hired')::boolean = false
  THEN
    INSERT INTO test_results VALUES ('hire_uses_applicant_locale', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('hire_uses_applicant_locale', 'FAIL', v_result::text);
  END IF;

  -- Communicate locale (nova candidatura)
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec6p2-idem-en',
    'Locale EN', 'locale.en.rec6p2@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'en', NULL
  );
  SELECT a.id INTO v_app2
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'locale.en.rec6p2@example.com';

  PERFORM pg_temp.set_owner_jwt();
  v_result := api.communicate_application_outcome(v_app2, 'rejected', NULL);
  IF v_result->>'email_locale' = 'en'
     AND (v_result->>'already_communicated')::boolean = false
  THEN
    INSERT INTO test_results VALUES ('communicate_uses_applicant_locale', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('communicate_uses_applicant_locale', 'FAIL', v_result::text);
  END IF;

  -- Manager role sense employees.manage → forbidden
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec6p2-idem-gate',
    'Gate Mgr', 'gate.mgr.rec6p2@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  SELECT a.id INTO v_app
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'gate.mgr.rec6p2@example.com';

  PERFORM pg_temp.set_manager_role_only_jwt();
  v_ok := false;
  v_err := NULL;
  BEGIN
    PERFORM api.hire_application(v_app, NULL, NULL, CURRENT_DATE, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('hire_no_manager_role_bypass', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('hire_no_manager_role_bypass', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'REC-6 P2 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
