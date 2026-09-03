-- =============================================================================
-- REC-5 P1–P2 tests
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
  v_app_id uuid;
  v_applicant uuid;
  v_req uuid;
  v_stage uuid;
  v_result jsonb;
  v_items jsonb;
  v_err text;
  v_token text;
  v_hash text;
  v_count int;
  v_name text;
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
    VALUES (v_tenant, 'rec5p12-site', 'REC5p12', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC5 P12', 'rec5p12-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5p12-idem-1',
    'P12 Cand', 'p12.rights@example.com', '600111222', NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  SELECT a.id, a.applicant_id INTO v_app_id, v_applicant
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'p12.rights@example.com' AND a.job_posting_id = v_posting;

  UPDATE data.applicants SET email_verified_at = now() WHERE id = v_applicant;

  SELECT id INTO v_stage
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND NOT is_terminal_hire AND NOT is_terminal_reject
  ORDER BY position LIMIT 1;

  PERFORM pg_temp.set_owner_jwt();

  -- 1) list has masked only (no requester_email key)
  INSERT INTO data.applicant_data_requests (
    tenant_id, applicant_id, request_type, requester_email, due_at, status
  ) VALUES (
    v_tenant, v_applicant, 'access', 'p12.rights@example.com',
    now() + interval '10 days', 'pending_review'
  ) RETURNING id INTO v_req;

  v_result := api.list_applicant_data_requests('pending_review');
  v_items := v_result -> 'items';
  SELECT NOT (elem ? 'requester_email')
       AND (elem ? 'requester_email_masked')
  INTO v_ok
  FROM jsonb_array_elements(v_items) elem
  WHERE (elem ->> 'id')::uuid = v_req
  LIMIT 1;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('list_masked_only', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('list_masked_only', 'FAIL', v_items::text);
  END IF;

  -- 2) reveal returns full email
  v_result := api.reveal_applicant_data_request_email(v_req);
  IF v_result ->> 'requester_email' = 'p12.rights@example.com' THEN
    INSERT INTO test_results VALUES ('reveal_email', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('reveal_email', 'FAIL', v_result::text);
  END IF;

  -- 3) restriction blocks communicate / move
  UPDATE data.applicants SET processing_restricted_at = now() WHERE id = v_applicant;

  BEGIN
    PERFORM api.communicate_application_outcome(v_app_id, 'rejected', 'http://localhost:3002');
    INSERT INTO test_results VALUES ('restrict_blocks_communicate', 'FAIL', 'expected raise');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%processing_restricted%' THEN
      INSERT INTO test_results VALUES ('restrict_blocks_communicate', 'PASS', NULL);
    ELSE
      INSERT INTO test_results VALUES ('restrict_blocks_communicate', 'FAIL', SQLERRM);
    END IF;
  END;

  BEGIN
    PERFORM api.move_application_stage(v_app_id, v_stage);
    INSERT INTO test_results VALUES ('restrict_blocks_move', 'FAIL', 'expected raise');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%processing_restricted%' THEN
      INSERT INTO test_results VALUES ('restrict_blocks_move', 'PASS', NULL);
    ELSE
      INSERT INTO test_results VALUES ('restrict_blocks_move', 'FAIL', SQLERRM);
    END IF;
  END;

  UPDATE data.applicants SET processing_restricted_at = NULL WHERE id = v_applicant;

  -- 4) rectification updates name
  INSERT INTO data.applicant_data_requests (
    tenant_id, applicant_id, request_type, requester_email, due_at, status
  ) VALUES (
    v_tenant, v_applicant, 'rectification', 'p12.rights@example.com',
    now() + interval '10 days', 'pending_review'
  ) RETURNING id INTO v_req;

  PERFORM api.resolve_applicant_data_request(
    v_req, 'approve', NULL, NULL, 'Corregit nom', 'P12 Corrected', NULL
  );

  SELECT full_name INTO v_name FROM data.applicants WHERE id = v_applicant;
  IF v_name = 'P12 Corrected' THEN
    INSERT INTO test_results VALUES ('rectification_updates_name', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('rectification_updates_name', 'FAIL', v_name);
  END IF;

  -- 5) export multi-download: 2 fetches keep token; 5th clears
  INSERT INTO data.applicant_data_requests (
    tenant_id, applicant_id, request_type, requester_email, due_at, status
  ) VALUES (
    v_tenant, v_applicant, 'access', 'p12.rights@example.com',
    now() + interval '10 days', 'pending_review'
  ) RETURNING id INTO v_req;

  PERFORM api.resolve_applicant_data_request(
    v_req, 'approve', NULL, 'http://localhost:3002', NULL, NULL, NULL
  );

  SELECT export_token_hash INTO v_hash
  FROM data.applicant_data_requests WHERE id = v_req;

  -- craft token by resetting with known plaintext
  v_token := encode(gen_random_bytes(24), 'hex');
  v_hash := encode(digest(v_token, 'sha256'), 'hex');
  UPDATE data.applicant_data_requests SET
    export_token_hash = v_hash,
    export_token_expires_at = now() + interval '1 day',
    export_json = '{"ok":true}'::jsonb,
    export_download_count = 0,
    export_max_downloads = 3,
    status = 'fulfilled',
    fulfilled_via = 'email_export'
  WHERE id = v_req;

  PERFORM api.fetch_rights_export(v_token);
  PERFORM api.fetch_rights_export(v_token);

  SELECT export_download_count, export_json IS NOT NULL
  INTO v_count, v_ok
  FROM data.applicant_data_requests WHERE id = v_req;

  IF v_count = 2 AND v_ok THEN
    INSERT INTO test_results VALUES ('export_multi_keeps_payload', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'export_multi_keeps_payload', 'FAIL',
      format('count=%s has_json=%s', v_count, v_ok)
    );
  END IF;

  PERFORM api.fetch_rights_export(v_token); -- 3rd = max → clear

  SELECT export_token_hash IS NULL AND export_json IS NULL INTO v_ok
  FROM data.applicant_data_requests WHERE id = v_req;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('export_max_clears_token', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('export_max_clears_token', 'FAIL', NULL);
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
    RAISE EXCEPTION 'REC-5 P1-P2 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
