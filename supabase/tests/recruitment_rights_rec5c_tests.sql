-- =============================================================================
-- REC-5c tests — rectification / restriction / portability / objection
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
  v_req uuid;
  v_result jsonb;
  v_ok boolean;
  v_err text;
  v_status text;
  v_via text;
  v_flag timestamptz;
  v_talent timestamptz;
  v_applicant uuid;
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (v_tenant, 'recruitment_enabled', true)
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant) ON CONFLICT DO NOTHING;

  SELECT id INTO v_ps FROM data.public_sites WHERE tenant_id = v_tenant LIMIT 1;
  IF v_ps IS NULL THEN
    INSERT INTO data.public_sites (tenant_id, slug, name, status, default_locale)
    VALUES (v_tenant, 'rec5c-site', 'REC5c', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC5c Job', 'rec5c-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  -- Helper: create verified applicant via submit
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5c-idem-r',
    'Restrict Cand', 'restrict.rec5c@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  UPDATE data.applicants SET email_verified_at = now()
  WHERE tenant_id = v_tenant AND email = 'restrict.rec5c@example.com';

  -- Restriction
  v_result := api.submit_applicant_data_request(
    v_ps, 'restrict.rec5c@example.com', 'restriction', NULL
  );
  SELECT id INTO v_req FROM data.applicant_data_requests
  WHERE requester_email = 'restrict.rec5c@example.com' ORDER BY created_at DESC LIMIT 1;

  PERFORM pg_temp.set_owner_jwt();
  v_result := api.resolve_applicant_data_request(v_req, 'approve', NULL, NULL, NULL);
  SELECT processing_restricted_at INTO v_flag
  FROM data.applicants WHERE email = 'restrict.rec5c@example.com' AND tenant_id = v_tenant;
  SELECT status, fulfilled_via INTO v_status, v_via
  FROM data.applicant_data_requests WHERE id = v_req;

  IF v_flag IS NOT NULL AND v_status = 'fulfilled' AND v_via = 'restriction_flag' THEN
    INSERT INTO test_results VALUES ('approve_restriction_flag', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'approve_restriction_flag', 'FAIL',
      format('flag=%s status=%s via=%s', v_flag, v_status, v_via)
    );
  END IF;

  -- Objection clears talent pool
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5c-idem-o',
    'Object Cand', 'object.rec5c@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  UPDATE data.applicants SET
    email_verified_at = now(),
    talent_pool_until = now() + interval '6 months'
  WHERE tenant_id = v_tenant AND email = 'object.rec5c@example.com'
  RETURNING id INTO v_applicant;

  PERFORM api.submit_applicant_data_request(
    v_ps, 'object.rec5c@example.com', 'objection', 'No contacteu'
  );
  SELECT id INTO v_req FROM data.applicant_data_requests
  WHERE requester_email = 'object.rec5c@example.com' ORDER BY created_at DESC LIMIT 1;

  PERFORM pg_temp.set_owner_jwt();
  v_result := api.resolve_applicant_data_request(
    v_req, 'approve', NULL, NULL, 'Registrat: sense contacte comercial'
  );
  SELECT objection_at, talent_pool_until INTO v_flag, v_talent
  FROM data.applicants WHERE id = v_applicant;

  IF v_flag IS NOT NULL AND v_talent IS NULL AND (v_result->>'fulfilled_via') = 'preference_update' THEN
    INSERT INTO test_results VALUES ('approve_objection_clears_talent', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'approve_objection_clears_talent', 'FAIL',
      format('obj=%s talent=%s result=%s', v_flag, v_talent, v_result)
    );
  END IF;

  -- Objection without notes fails
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5c-idem-o2',
    'Object2', 'object2.rec5c@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  UPDATE data.applicants SET email_verified_at = now()
  WHERE email = 'object2.rec5c@example.com';
  PERFORM api.submit_applicant_data_request(v_ps, 'object2.rec5c@example.com', 'objection', NULL);
  SELECT id INTO v_req FROM data.applicant_data_requests
  WHERE requester_email = 'object2.rec5c@example.com' ORDER BY created_at DESC LIMIT 1;

  PERFORM pg_temp.set_owner_jwt();
  v_ok := false;
  BEGIN
    PERFORM api.resolve_applicant_data_request(v_req, 'approve', NULL, NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%resolution_notes_required%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('objection_requires_notes', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('objection_requires_notes', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Portability export
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5c-idem-p',
    'Port Cand', 'port.rec5c@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  UPDATE data.applicants SET email_verified_at = now()
  WHERE email = 'port.rec5c@example.com';
  PERFORM api.submit_applicant_data_request(v_ps, 'port.rec5c@example.com', 'portability', NULL);
  SELECT id INTO v_req FROM data.applicant_data_requests
  WHERE requester_email = 'port.rec5c@example.com' ORDER BY created_at DESC LIMIT 1;

  PERFORM pg_temp.set_owner_jwt();
  v_result := api.resolve_applicant_data_request(
    v_req, 'approve', NULL, 'https://portal.example', NULL
  );
  IF (v_result->>'fulfilled_via') = 'email_export'
     AND (v_result->>'export_storage_path') IS NOT NULL
  THEN
    INSERT INTO test_results VALUES ('approve_portability_export', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('approve_portability_export', 'FAIL', v_result::text);
  END IF;

  -- Rectification requires notes
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5c-idem-x',
    'Rect Cand', 'rect.rec5c@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  UPDATE data.applicants SET email_verified_at = now()
  WHERE email = 'rect.rec5c@example.com';
  PERFORM api.submit_applicant_data_request(v_ps, 'rect.rec5c@example.com', 'rectification', 'Nom incorrecte');
  SELECT id INTO v_req FROM data.applicant_data_requests
  WHERE requester_email = 'rect.rec5c@example.com' ORDER BY created_at DESC LIMIT 1;

  PERFORM pg_temp.set_owner_jwt();
  v_ok := false;
  BEGIN
    PERFORM api.resolve_applicant_data_request(v_req, 'approve', NULL, NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%resolution_notes_required%' THEN
      v_ok := true;
    END IF;
  END;
  IF NOT v_ok THEN
    INSERT INTO test_results VALUES ('rectification_requires_notes', 'FAIL', 'expected notes required');
  ELSE
    v_result := api.resolve_applicant_data_request(
      v_req, 'approve', NULL, NULL, 'Corregit nom a fitxa manualment'
    );
    IF (v_result->>'fulfilled_via') = 'field_update' THEN
      INSERT INTO test_results VALUES ('rectification_requires_notes', 'PASS', NULL);
    ELSE
      INSERT INTO test_results VALUES ('rectification_requires_notes', 'FAIL', v_result::text);
    END IF;
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
    RAISE EXCEPTION 'REC-5c tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
