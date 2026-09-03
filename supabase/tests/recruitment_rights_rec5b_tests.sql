-- =============================================================================
-- REC-5b tests — rights inbox Art. 15 / Art. 17
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

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_ps uuid;
  v_posting uuid;
  v_app_id uuid;
  v_app2 uuid;
  v_applicant uuid;
  v_req uuid;
  v_req2 uuid;
  v_req3 uuid;
  v_result jsonb;
  v_ok boolean;
  v_err text;
  v_status text;
  v_path text;
  v_count int;
  v_log int;
  v_token text;
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
    VALUES (v_tenant, 'rec5b-site', 'REC5b', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC5b Job', 'rec5b-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  -- Unverified applicant
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5b-idem-uv',
    'Unverified', 'unverified.rec5b@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  v_ok := false;
  BEGIN
    PERFORM api.submit_applicant_data_request(
      v_ps, 'unverified.rec5b@example.com', 'access', NULL
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%email_not_verified%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('submit_requires_verify', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('submit_requires_verify', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Verified access request
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5b-idem-access',
    'Access Cand', 'access.rec5b@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  UPDATE data.applicants SET email_verified_at = now()
  WHERE tenant_id = v_tenant AND email = 'access.rec5b@example.com';

  SELECT a.id, a.applicant_id INTO v_app_id, v_applicant
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting AND ap.email = 'access.rec5b@example.com';

  v_result := api.submit_applicant_data_request(
    v_ps, 'access.rec5b@example.com', 'access', 'Vull les meves dades'
  );
  IF (v_result->>'ok')::boolean AND (v_result->>'queued')::boolean THEN
    INSERT INTO test_results VALUES ('submit_access_ok', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('submit_access_ok', 'FAIL', v_result::text);
  END IF;

  SELECT id INTO v_req FROM data.applicant_data_requests
  WHERE tenant_id = v_tenant AND requester_email = 'access.rec5b@example.com'
  ORDER BY created_at DESC LIMIT 1;

  -- Permission gate: view-only cannot list
  PERFORM pg_temp.set_view_only_jwt();
  v_ok := false;
  BEGIN
    PERFORM api.list_applicant_data_requests(NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('list_requires_rights', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('list_requires_rights', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Approve access
  PERFORM pg_temp.set_owner_jwt();
  v_result := api.resolve_applicant_data_request(
    v_req, 'approve', NULL, 'https://portal.example'
  );
  SELECT status, export_storage_path, export_token_hash
  INTO v_status, v_path, v_token
  FROM data.applicant_data_requests WHERE id = v_req;

  IF v_status = 'fulfilled'
     AND (v_result->>'fulfilled_via') = 'email_export'
     AND v_path IS NOT NULL
     AND v_token IS NOT NULL
  THEN
    INSERT INTO test_results VALUES ('approve_access_export', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'approve_access_export', 'FAIL',
      format('status=%s path=%s result=%s', v_status, v_path, v_result)
    );
  END IF;

  -- Reject flow
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5b-idem-reject',
    'Reject Cand', 'reject.rec5b@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  UPDATE data.applicants SET email_verified_at = now()
  WHERE tenant_id = v_tenant AND email = 'reject.rec5b@example.com';

  PERFORM api.submit_applicant_data_request(
    v_ps, 'reject.rec5b@example.com', 'access', NULL
  );
  SELECT id INTO v_req2 FROM data.applicant_data_requests
  WHERE requester_email = 'reject.rec5b@example.com' ORDER BY created_at DESC LIMIT 1;

  PERFORM pg_temp.set_owner_jwt();
  PERFORM api.resolve_applicant_data_request(v_req2, 'reject', 'Sense base legal aplicable', NULL);
  SELECT status, fulfilled_via INTO v_status, v_path
  FROM data.applicant_data_requests WHERE id = v_req2;
  IF v_status = 'rejected' AND v_path = 'rejected_with_reason' THEN
    INSERT INTO test_results VALUES ('reject_ok', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('reject_ok', 'FAIL', format('%s / %s', v_status, v_path));
  END IF;

  -- Erasure approve
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5b-idem-erase',
    'Erase Cand', 'erase.rec5b@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  UPDATE data.applicants SET email_verified_at = now()
  WHERE tenant_id = v_tenant AND email = 'erase.rec5b@example.com';

  SELECT a.id INTO v_app2
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'erase.rec5b@example.com';

  PERFORM api.submit_applicant_data_request(
    v_ps, 'erase.rec5b@example.com', 'erasure', NULL
  );
  SELECT id INTO v_req3 FROM data.applicant_data_requests
  WHERE requester_email = 'erase.rec5b@example.com' ORDER BY created_at DESC LIMIT 1;

  PERFORM pg_temp.set_owner_jwt();
  v_result := api.resolve_applicant_data_request(v_req3, 'approve', NULL, NULL);

  SELECT count(*)::int INTO v_count
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'erase.rec5b@example.com';
  -- applicant may be gone; also check by app id
  IF v_count = 0 AND NOT EXISTS (SELECT 1 FROM data.applications WHERE id = v_app2) THEN
    v_ok := true;
  ELSE
    v_ok := false;
  END IF;

  SELECT count(*)::int INTO v_log
  FROM data.applicant_erasure_log
  WHERE tenant_id = v_tenant AND reason = 'user_request';

  IF v_ok AND v_log >= 1 AND (v_result->>'fulfilled_via') = 'purge' THEN
    INSERT INTO test_results VALUES ('approve_erasure_purge', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'approve_erasure_purge', 'FAIL',
      format('ok=%s log=%s result=%s', v_ok, v_log, v_result)
    );
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
    RAISE EXCEPTION 'REC-5b tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
