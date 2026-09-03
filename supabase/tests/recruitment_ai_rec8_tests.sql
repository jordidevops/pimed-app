-- =============================================================================
-- REC-8 tests — AI checklist / enable / save cv_structured
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
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
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
  v_applicant uuid;
  v_app uuid;
  v_result jsonb;
  v_ok boolean;
  v_err text;
  v_enabled boolean;
  v_structured jsonb;
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (v_tenant, 'recruitment_enabled', true)
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant) ON CONFLICT DO NOTHING;

  UPDATE data.recruitment_settings
  SET
    ai_assist_enabled = false,
    ai_dpa_accepted_at = NULL,
    ai_dpa_accepted_by = NULL,
    ai_transfer_accepted_at = NULL,
    ai_transfer_accepted_by = NULL,
    ai_checklist_version = NULL
  WHERE tenant_id = v_tenant;

  PERFORM data.seed_default_pipeline_stages(v_tenant);

  SELECT id INTO v_ps FROM data.public_sites WHERE tenant_id = v_tenant LIMIT 1;
  IF v_ps IS NULL THEN
    INSERT INTO data.public_sites (tenant_id, slug, name, status, default_locale)
    VALUES (v_tenant, 'rec8-site', 'REC8', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_postings (
    tenant_id, title, public_slug, status, created_by
  )
  VALUES (
    v_tenant, 'REC8 Job', 'rec8-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner
  )
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  INSERT INTO data.applicants (tenant_id, email, full_name)
  VALUES (v_tenant, 'rec8.cand@example.com', 'REC8 Candidate')
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_applicant;

  IF v_applicant IS NULL THEN
    SELECT id INTO v_applicant
    FROM data.applicants
    WHERE tenant_id = v_tenant AND email = 'rec8.cand@example.com';
  END IF;

  INSERT INTO data.applications (
    tenant_id, job_posting_id, applicant_id,
    retention_preference, retention_months, purge_at, source,
    cv_storage_path
  )
  VALUES (
    v_tenant, v_posting, v_applicant,
    'delete_after_months', 12, now() + interval '12 months', 'web',
    v_ps::text || '/' || v_posting::text || '/cv.pdf'
  )
  ON CONFLICT (job_posting_id, applicant_id) DO UPDATE
    SET cv_storage_path = EXCLUDED.cv_storage_path
  RETURNING id INTO v_app;

  PERFORM pg_temp.set_owner_jwt();

  -- Enable without checklist → checklist_incomplete
  v_ok := false;
  v_err := NULL;
  BEGIN
    PERFORM api.set_recruitment_ai_assist_enabled(v_tenant, true);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%checklist_incomplete%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('enable_without_checklist', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('enable_without_checklist', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Accept checklist incomplete flags → error
  v_ok := false;
  v_err := NULL;
  BEGIN
    PERFORM api.accept_recruitment_ai_checklist(v_tenant, true, false);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%checklist_incomplete%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('accept_partial_checklist', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('accept_partial_checklist', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Accept full checklist
  v_result := api.accept_recruitment_ai_checklist(v_tenant, true, true);
  IF (v_result->>'ok')::boolean
     AND v_result->>'ai_checklist_version' = 'rec8-v1' THEN
    INSERT INTO test_results VALUES ('accept_checklist_ok', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('accept_checklist_ok', 'FAIL', v_result::text);
  END IF;

  -- Enable without AI configured → ai_not_configured (unless seed already has AI)
  IF NOT data.tenant_ai_is_configured(v_tenant) THEN
    v_ok := false;
    v_err := NULL;
    BEGIN
      PERFORM api.set_recruitment_ai_assist_enabled(v_tenant, true);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM ILIKE '%ai_not_configured%' THEN
        v_ok := true;
      ELSE
        v_err := SQLERRM;
      END IF;
    END;
    IF v_ok THEN
      INSERT INTO test_results VALUES ('enable_without_ai', 'PASS', NULL);
    ELSE
      INSERT INTO test_results VALUES ('enable_without_ai', 'FAIL', COALESCE(v_err, 'no error'));
    END IF;

    -- Simulate configured AI for remaining tests
    INSERT INTO data.tenant_ai_provider_config (
      tenant_id, provider, model, base_url, ai_key_secret_id, key_verified_at
    )
    VALUES (
      v_tenant,
      'openai',
      'gpt-4o-mini',
      'https://api.openai.com/v1',
      gen_random_uuid(),
      now()
    )
    ON CONFLICT (tenant_id, provider) DO UPDATE
      SET ai_key_secret_id = COALESCE(data.tenant_ai_provider_config.ai_key_secret_id, EXCLUDED.ai_key_secret_id),
          key_verified_at = COALESCE(data.tenant_ai_provider_config.key_verified_at, EXCLUDED.key_verified_at);
  ELSE
    INSERT INTO test_results VALUES ('enable_without_ai', 'PASS', 'skipped: AI already configured');
  END IF;

  v_result := api.set_recruitment_ai_assist_enabled(v_tenant, true);
  v_enabled := (v_result->>'ai_assist_enabled')::boolean;
  IF (v_result->>'ok')::boolean AND v_enabled THEN
    INSERT INTO test_results VALUES ('enable_with_checklist_and_ai', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('enable_with_checklist_and_ai', 'FAIL', v_result::text);
  END IF;

  -- Save structured CV
  v_result := api.save_application_cv_structured(
    v_app,
    jsonb_build_object(
      'skills', jsonb_build_array('SQL', 'TypeScript'),
      'experience', jsonb_build_array(jsonb_build_object('title', 'Dev', 'company', 'Acme')),
      'education', jsonb_build_array(jsonb_build_object('degree', 'CS')),
      'languages', jsonb_build_array(jsonb_build_object('name', 'Catalan', 'level', 'C2'))
    )
  );
  IF (v_result->>'ok')::boolean
     AND jsonb_array_length(v_result->'cv_structured'->'skills') = 2 THEN
    INSERT INTO test_results VALUES ('save_cv_structured_ok', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('save_cv_structured_ok', 'FAIL', v_result::text);
  END IF;

  SELECT cv_structured INTO v_structured
  FROM data.applications WHERE id = v_app;
  IF v_structured IS NOT NULL
     AND jsonb_typeof(v_structured->'skills') = 'array'
     AND jsonb_array_length(v_structured->'skills') >= 2 THEN
    INSERT INTO test_results VALUES ('cv_structured_persisted', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('cv_structured_persisted', 'FAIL', COALESCE(v_structured::text, 'null'));
  END IF;

  -- Disable then save → ai_assist_disabled
  PERFORM api.set_recruitment_ai_assist_enabled(v_tenant, false);
  v_ok := false;
  v_err := NULL;
  BEGIN
    PERFORM api.save_application_cv_structured(
      v_app,
      jsonb_build_object('skills', jsonb_build_array('X'), 'experience', '[]'::jsonb,
        'education', '[]'::jsonb, 'languages', '[]'::jsonb)
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%ai_assist_disabled%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('save_when_disabled', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('save_when_disabled', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Tenant mismatch on set (header T1, p_tenant other) when active is set
  v_ok := false;
  v_err := NULL;
  BEGIN
    PERFORM api.set_recruitment_ai_assist_enabled(
      '10000000-0000-0000-0000-000000000099'::uuid,
      false
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLERRM ILIKE '%mismatch%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('set_tenant_mismatch', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('set_tenant_mismatch', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Re-enable and assert direct UPDATE without AI fails via trigger
  -- (first ensure checklist+AI still present from earlier enable path)
  UPDATE data.recruitment_settings
  SET
    ai_dpa_accepted_at = COALESCE(ai_dpa_accepted_at, now()),
    ai_transfer_accepted_at = COALESCE(ai_transfer_accepted_at, now()),
    ai_assist_enabled = false
  WHERE tenant_id = v_tenant;

  v_ok := false;
  v_err := NULL;
  BEGIN
    UPDATE data.applications
    SET cv_structured = '{"skills":["x"],"experience":[],"education":[],"languages":[]}'::jsonb
    WHERE id = v_app;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%ai_assist_disabled%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('direct_update_guard', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('direct_update_guard', 'FAIL', COALESCE(v_err, 'no error'));
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
    RAISE EXCEPTION 'REC-8 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
