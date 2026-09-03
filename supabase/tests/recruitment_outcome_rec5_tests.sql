-- =============================================================================
-- REC-5 tests — communicate outcome / prefs / archive lot / verify gate
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

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_ps uuid;
  v_posting uuid;
  v_posting2 uuid;
  v_app_id uuid;
  v_app2 uuid;
  v_app3 uuid;
  v_stage_reject uuid;
  v_visible text;
  v_result jsonb;
  v_ok boolean;
  v_purge timestamptz;
  v_purge_before timestamptz;
  v_token text;
  v_talent timestamptz;
  v_choice text;
  v_count int;
  v_err text;
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (v_tenant, 'recruitment_enabled', true)
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.recruitment_settings
  SET rejection_notify_policy = 'on_decision',
      default_max_retention_months = 12
  WHERE tenant_id = v_tenant;

  PERFORM data.seed_default_pipeline_stages(v_tenant);

  SELECT id INTO v_ps FROM data.public_sites WHERE tenant_id = v_tenant LIMIT 1;
  IF v_ps IS NULL THEN
    INSERT INTO data.public_sites (tenant_id, slug, name, status, default_locale)
    VALUES (v_tenant, 'rec5-site', 'REC5', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC5 Job', 'rec5-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5-idem-1',
    'Outcome Cand', 'outcome.rec5@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  SELECT a.id INTO v_app_id
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting AND ap.email = 'outcome.rec5@example.com';

  SELECT id INTO v_stage_reject
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND is_terminal_reject
  LIMIT 1;

  PERFORM pg_temp.set_owner_jwt();

  -- 1) Move to reject does NOT close portal
  PERFORM api.move_application_stage(v_app_id, v_stage_reject);
  SELECT candidate_visible_status INTO v_visible FROM data.applications WHERE id = v_app_id;
  IF v_visible = 'open' THEN
    INSERT INTO test_results VALUES ('move_reject_stays_open', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('move_reject_stays_open', 'FAIL', v_visible);
  END IF;

  -- 2) Communicate → closed
  v_result := api.communicate_application_outcome(v_app_id, 'rejected', 'https://portal.example');
  SELECT candidate_visible_status INTO v_visible FROM data.applications WHERE id = v_app_id;
  IF v_visible = 'closed'
     AND (v_result->>'candidate_visible_status') = 'closed'
     AND (v_result->>'already_communicated')::boolean = false
  THEN
    INSERT INTO test_results VALUES ('communicate_closes_portal', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'communicate_closes_portal', 'FAIL',
      format('visible=%s result=%s', v_visible, v_result)
    );
  END IF;

  -- 3) Prefs without email verify → fail
  v_token := 'rec5-known-token-unverified';
  UPDATE data.applications SET
    post_rejection_token_hash = encode(digest(v_token, 'sha256'), 'hex'),
    post_rejection_token_expires_at = now() + interval '7 days',
    post_rejection_responded_at = NULL,
    post_rejection_choice = NULL
  WHERE id = v_app_id;

  v_ok := false;
  BEGIN
    PERFORM api.submit_post_rejection_preferences(v_token, 'talent_pool', 3);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err ILIKE '%email_not_verified%' THEN
      v_ok := true;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('prefs_require_verify', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('prefs_require_verify', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Verify email then talent_pool
  UPDATE data.applicants SET email_verified_at = now()
  WHERE id = (SELECT applicant_id FROM data.applications WHERE id = v_app_id);

  v_token := 'rec5-known-token-talent';
  UPDATE data.applications SET
    post_rejection_token_hash = encode(digest(v_token, 'sha256'), 'hex'),
    post_rejection_token_expires_at = now() + interval '7 days',
    post_rejection_responded_at = NULL,
    post_rejection_choice = NULL
  WHERE id = v_app_id;

  v_result := api.submit_post_rejection_preferences(v_token, 'talent_pool', 3);
  SELECT ap.talent_pool_until, a.post_rejection_choice
  INTO v_talent, v_choice
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.id = v_app_id;

  IF v_choice = 'talent_pool'
     AND v_talent IS NOT NULL
     AND v_talent > now() + interval '2 months'
     AND v_talent < now() + interval '4 months'
     AND (v_result->>'ok')::boolean
  THEN
    INSERT INTO test_results VALUES ('prefs_talent_pool', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'prefs_talent_pool', 'FAIL',
      format('choice=%s talent=%s result=%s', v_choice, v_talent, v_result)
    );
  END IF;

  -- 4) erase accelerates purge
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5-idem-erase',
    'Erase Cand', 'erase.rec5@example.com', NULL, NULL,
    'web', 'delete_after_months', 12, NULL, 'v1', true, 'ca', NULL
  );
  SELECT a.id, a.purge_at INTO v_app2, v_purge_before
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting AND ap.email = 'erase.rec5@example.com';

  UPDATE data.applicants SET email_verified_at = now()
  WHERE email = 'erase.rec5@example.com' AND tenant_id = v_tenant;

  PERFORM pg_temp.set_owner_jwt();
  PERFORM api.communicate_application_outcome(v_app2, 'rejected', NULL);

  v_token := 'rec5-known-token-erase';
  UPDATE data.applications SET
    post_rejection_token_hash = encode(digest(v_token, 'sha256'), 'hex'),
    post_rejection_token_expires_at = now() + interval '7 days',
    post_rejection_responded_at = NULL,
    post_rejection_choice = NULL
  WHERE id = v_app2;

  PERFORM api.submit_post_rejection_preferences(v_token, 'erase', NULL);
  SELECT purge_at, post_rejection_choice INTO v_purge, v_choice
  FROM data.applications WHERE id = v_app2;

  IF v_choice = 'erase' AND v_purge <= now() + interval '2 days' AND v_purge < v_purge_before THEN
    INSERT INTO test_results VALUES ('prefs_erase_accelerates_purge', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'prefs_erase_accelerates_purge', 'FAIL',
      format('choice=%s purge=%s before=%s', v_choice, v_purge, v_purge_before)
    );
  END IF;

  -- 5) Archive lot when on_posting_close
  UPDATE data.recruitment_settings
  SET rejection_notify_policy = 'on_posting_close'
  WHERE tenant_id = v_tenant;

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC5 Archive', 'rec5-arch-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting2;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting2, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting2;

  PERFORM api.submit_job_application(
    v_ps, v_posting2, 'rec5-idem-arch',
    'Archive Cand', 'archive.rec5@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  SELECT a.id INTO v_app3
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting2 AND ap.email = 'archive.rec5@example.com';

  UPDATE data.job_postings SET status = 'archived' WHERE id = v_posting2;

  SELECT candidate_visible_status, (outcome_communicated_at IS NOT NULL)
  INTO v_visible, v_ok
  FROM data.applications WHERE id = v_app3;

  SELECT count(*)::int INTO v_count
  FROM data.applications
  WHERE job_posting_id = v_posting2 AND outcome_communicated_at IS NOT NULL;

  IF v_visible = 'closed' AND v_ok AND v_count >= 1 THEN
    INSERT INTO test_results VALUES ('archive_lot_communicate', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'archive_lot_communicate', 'FAIL',
      format('visible=%s ok=%s count=%s', v_visible, v_ok, v_count)
    );
  END IF;

  -- restore policy
  UPDATE data.recruitment_settings
  SET rejection_notify_policy = 'on_decision'
  WHERE tenant_id = v_tenant;
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'REC-5 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
