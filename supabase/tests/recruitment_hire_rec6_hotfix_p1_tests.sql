-- =============================================================================
-- REC-6 hotfix P1 tests
-- communicate rejects hire; future starts_on → onboarding; purge skips hired;
-- site-scoped hire + FK validation
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

CREATE OR REPLACE FUNCTION pg_temp.set_site_a_hire_jwt(p_site_a uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_claim text;
BEGIN
  -- Seed profile Charlie (manager at Acme Gràcia) — must exist for lifecycle FK
  v_claim := format(
    '{"sub":"20000000-0000-0000-0000-000000000004","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{"%s":{"role":"manager"}}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{"%s":{"permissions":["recruitment.manage","employees.manage"]}}}}}}',
    p_site_a, p_site_a
  );
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config('request.jwt.claim', v_claim, true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_site_b_hire_jwt(p_site_b uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_claim text;
BEGIN
  v_claim := format(
    '{"sub":"20000000-0000-0000-0000-000000000096","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{"%s":{"role":"manager"}}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{"%s":{"permissions":["recruitment.manage","employees.manage"]}}}}}}',
    p_site_b, p_site_b
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
  v_site_a uuid := '30000000-0000-0000-0000-000000000001';
  v_site_b uuid := '30000000-0000-0000-0000-000000000002';
  v_ps uuid;
  v_posting uuid;
  v_job_pos uuid;
  v_app uuid;
  v_app2 uuid;
  v_app3 uuid;
  v_result jsonb;
  v_emp uuid;
  v_life text;
  v_starts date;
  v_eff date;
  v_ok boolean;
  v_err text;
  v_purged int;
  v_still int;
  v_future date := CURRENT_DATE + 45;
  v_other_tenant uuid := '10000000-0000-0000-0000-000000000002';
  v_foreign_site uuid := '30000000-0000-0000-0000-000000000003';
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
    VALUES (v_tenant, 'rec6p1-site', 'REC6P1', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_positions (tenant_id, code, name, is_active)
  VALUES (v_tenant, 'REC6P1-POS', 'Pos REC6P1', true)
  RETURNING id INTO v_job_pos;

  INSERT INTO data.job_postings (
    tenant_id, title, public_slug, status, created_by, job_position_id, site_id
  )
  VALUES (
    v_tenant, 'REC6P1 Job', 'rec6p1-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner, v_job_pos, v_site_a
  )
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  -- App 1: communicate hired_next_steps blocked
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec6p1-idem-comm',
    'Comm Block', 'comm.block.rec6p1@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  SELECT a.id INTO v_app
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'comm.block.rec6p1@example.com' AND a.job_posting_id = v_posting;

  PERFORM pg_temp.set_owner_jwt();
  v_ok := false;
  BEGIN
    PERFORM api.communicate_application_outcome(v_app, 'hired_next_steps', NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%use_hire_application%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok
     AND NOT EXISTS (
       SELECT 1 FROM data.applications
       WHERE id = v_app AND outcome_communicated_at IS NOT NULL
     )
  THEN
    INSERT INTO test_results VALUES ('communicate_rejects_hired_next_steps', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'communicate_rejects_hired_next_steps', 'FAIL', COALESCE(v_err, 'leaked')
    );
  END IF;

  -- App 2: future starts_on → onboarding today
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec6p1-idem-future',
    'Future Start', 'future.start.rec6p1@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  SELECT a.id INTO v_app2
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'future.start.rec6p1@example.com';

  PERFORM pg_temp.set_owner_jwt();
  v_result := api.hire_application(v_app2, NULL, NULL, v_future, v_job_pos);
  v_emp := (v_result->>'employee_id')::uuid;

  SELECT lifecycle_state, starts_on INTO v_life, v_starts
  FROM data.employees WHERE id = v_emp;
  SELECT effective_on INTO v_eff
  FROM data.employee_lifecycle_events
  WHERE employee_id = v_emp AND to_state = 'onboarding'
  ORDER BY created_at DESC LIMIT 1;

  IF v_life = 'onboarding'
     AND v_starts = v_future
     AND v_eff = CURRENT_DATE
  THEN
    INSERT INTO test_results VALUES ('hire_future_starts_on_onboarding_now', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'hire_future_starts_on_onboarding_now', 'FAIL',
      format('life=%s starts=%s eff=%s', v_life, v_starts, v_eff)
    );
  END IF;

  -- Purge must not delete hired application
  UPDATE data.applications
  SET purge_at = now() - interval '1 day'
  WHERE id = v_app2;

  v_purged := data.purge_expired_applications();
  SELECT count(*)::int INTO v_still FROM data.applications WHERE id = v_app2;

  IF v_still = 1 THEN
    INSERT INTO test_results VALUES ('purge_skips_hired_employee', 'PASS', format('purged=%s', v_purged));
  ELSE
    INSERT INTO test_results VALUES ('purge_skips_hired_employee', 'FAIL', 'hired app deleted');
  END IF;

  -- Site scope: site_b JWT cannot hire posting on site_a
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec6p1-idem-site',
    'Site Scope', 'site.scope.rec6p1@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  SELECT a.id INTO v_app3
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'site.scope.rec6p1@example.com';

  PERFORM pg_temp.set_site_b_hire_jwt(v_site_b);
  v_ok := false;
  v_err := NULL;
  BEGIN
    PERFORM api.hire_application(v_app3, NULL, NULL, CURRENT_DATE, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('hire_denied_wrong_site', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('hire_denied_wrong_site', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Site scope: site_a JWT can hire
  PERFORM pg_temp.set_site_a_hire_jwt(v_site_a);
  v_result := api.hire_application(v_app3, NULL, NULL, CURRENT_DATE, v_job_pos);
  IF (v_result->>'employee_id') IS NOT NULL
     AND (v_result->>'already_hired')::boolean = false
  THEN
    INSERT INTO test_results VALUES ('hire_allowed_posting_site', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('hire_allowed_posting_site', 'FAIL', v_result::text);
  END IF;

  -- FK validation: foreign site rejected
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec6p1-idem-fk',
    'FK Check', 'fk.check.rec6p1@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  SELECT a.id INTO v_app
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'fk.check.rec6p1@example.com';

  PERFORM pg_temp.set_owner_jwt();
  v_ok := false;
  v_err := NULL;
  BEGIN
    PERFORM api.hire_application(v_app, v_foreign_site, NULL, CURRENT_DATE, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%invalid_site%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('hire_rejects_foreign_site', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('hire_rejects_foreign_site', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Silence unused
  PERFORM 1 FROM data.tenants WHERE id = v_other_tenant;
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'REC-6 hotfix P1 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
