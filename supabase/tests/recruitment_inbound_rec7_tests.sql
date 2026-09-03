-- =============================================================================
-- REC-7 tests — inbound inbox ingest / assign / discard
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

CREATE OR REPLACE FUNCTION pg_temp.set_service_role() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM set_config('request.jwt.claim', '{"role":"service_role"}', true);
END;
$$;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_ps uuid;
  v_posting uuid;
  v_result jsonb;
  v_inbox uuid;
  v_inbox2 uuid;
  v_app uuid;
  v_ok boolean;
  v_err text;
  v_status text;
  v_source text;
  v_art14 timestamptz;
  v_count int;
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (v_tenant, 'recruitment_enabled', true)
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant) ON CONFLICT DO NOTHING;

  UPDATE data.recruitment_settings
  SET import_legal_basis = 'legitimate_interest',
      import_legal_basis_note = NULL,
      inbound_enabled = true
  WHERE tenant_id = v_tenant;

  PERFORM data.seed_default_pipeline_stages(v_tenant);

  SELECT id INTO v_ps FROM data.public_sites WHERE tenant_id = v_tenant LIMIT 1;
  IF v_ps IS NULL THEN
    INSERT INTO data.public_sites (tenant_id, slug, name, status, default_locale)
    VALUES (v_tenant, 'rec7-site', 'REC7', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_postings (
    tenant_id, title, public_slug, status, created_by
  )
  VALUES (
    v_tenant, 'REC7 Job', 'rec7-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner
  )
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  -- Flag off → ingest forbidden (module_not_enabled)
  UPDATE data.tenant_feature_overrides
  SET override_status = false
  WHERE tenant_id = v_tenant AND feature_key = 'recruitment_enabled';

  PERFORM pg_temp.set_service_role();
  v_ok := false;
  BEGIN
    PERFORM api.ingest_recruitment_inbound_email(jsonb_build_object(
      'tenant_id', v_tenant,
      'from_email', 'a@example.com',
      'subject', 'Hi'
    ));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%module_not_enabled%' OR SQLERRM ILIKE '%forbidden%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('inbound_flag_off_forbidden', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('inbound_flag_off_forbidden', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  UPDATE data.tenant_feature_overrides
  SET override_status = true
  WHERE tenant_id = v_tenant AND feature_key = 'recruitment_enabled';

  -- Ingest without tag → unassigned
  PERFORM pg_temp.set_service_role();
  v_result := api.ingest_recruitment_inbound_email(jsonb_build_object(
    'tenant_id', v_tenant,
    'from_email', 'candidate.rec7@example.com',
    'from_name', 'Cand Rec7',
    'subject', 'CV for chef role',
    'body_text', 'Please find my CV',
    'resend_email_id', 'resend-rec7-1'
  ));
  v_inbox := (v_result->>'inbox_id')::uuid;
  v_status := v_result->>'status';

  IF v_inbox IS NOT NULL AND v_status = 'unassigned' AND (v_result->>'duplicate')::boolean = false THEN
    INSERT INTO test_results VALUES ('inbound_ingest_unassigned', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('inbound_ingest_unassigned', 'FAIL', v_result::text);
  END IF;

  -- Ingest with posting tag → assigned + source=email
  v_result := api.ingest_recruitment_inbound_email(jsonb_build_object(
    'tenant_id', v_tenant,
    'from_email', 'tagged.rec7@example.com',
    'from_name', 'Tagged',
    'subject', format('Apply [posting:%s]', v_posting),
    'body_text', 'Auto',
    'resend_email_id', 'resend-rec7-2'
  ));
  v_inbox2 := (v_result->>'inbox_id')::uuid;
  v_app := (v_result->'application'->>'application_id')::uuid;

  SELECT source INTO v_source FROM data.applications WHERE id = v_app;

  IF v_result->>'status' = 'assigned'
     AND v_app IS NOT NULL
     AND v_source = 'email'
  THEN
    INSERT INTO test_results VALUES ('inbound_auto_assign_tag', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'inbound_auto_assign_tag', 'FAIL',
      format('status=%s app=%s source=%s result=%s', v_result->>'status', v_app, v_source, v_result)
    );
  END IF;

  -- Manual assign + Art.14
  PERFORM pg_temp.set_owner_jwt();
  v_result := api.assign_recruitment_inbox_item(v_inbox, v_posting);
  v_app := (v_result->'application'->>'application_id')::uuid;

  SELECT art14_notice_sent_at INTO v_art14
  FROM data.applicants
  WHERE email = 'candidate.rec7@example.com' AND tenant_id = v_tenant;

  SELECT source INTO v_source FROM data.applications WHERE id = v_app;

  IF v_app IS NOT NULL AND v_source = 'email' AND v_art14 IS NOT NULL THEN
    INSERT INTO test_results VALUES ('inbound_manual_assign_art14', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'inbound_manual_assign_art14', 'FAIL',
      format('app=%s source=%s art14=%s result=%s', v_app, v_source, v_art14, v_result)
    );
  END IF;

  -- Discard unassigned only
  v_result := api.ingest_recruitment_inbound_email(jsonb_build_object(
    'tenant_id', v_tenant,
    'from_email', 'discard.rec7@example.com',
    'subject', 'Spam',
    'resend_email_id', 'resend-rec7-3'
  ));
  v_inbox := (v_result->>'inbox_id')::uuid;

  PERFORM pg_temp.set_owner_jwt();
  v_result := api.discard_recruitment_inbox_item(v_inbox, 'not relevant');
  SELECT status INTO v_status FROM data.recruitment_email_inbox WHERE id = v_inbox;

  IF v_status = 'discarded' AND (v_result->>'already_discarded')::boolean = false THEN
    INSERT INTO test_results VALUES ('inbound_discard', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('inbound_discard', 'FAIL', format('%s %s', v_status, v_result));
  END IF;

  -- Discard of assigned item must fail
  v_ok := false;
  v_err := NULL;
  BEGIN
    PERFORM api.discard_recruitment_inbox_item(v_inbox2, 'should fail');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%already_assigned%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('inbound_discard_assigned_blocked', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'inbound_discard_assigned_blocked', 'FAIL', COALESCE(v_err, 'no error')
    );
  END IF;

  -- Dedupe resend id
  PERFORM pg_temp.set_service_role();
  v_result := api.ingest_recruitment_inbound_email(jsonb_build_object(
    'tenant_id', v_tenant,
    'from_email', 'tagged.rec7@example.com',
    'subject', format('Apply [posting:%s]', v_posting),
    'resend_email_id', 'resend-rec7-2'
  ));
  IF (v_result->>'duplicate')::boolean = true THEN
    INSERT INTO test_results VALUES ('inbound_dedupe_resend_id', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('inbound_dedupe_resend_id', 'FAIL', v_result::text);
  END IF;

  -- No double application for same email+posting on re-assign
  PERFORM pg_temp.set_owner_jwt();
  SELECT count(*)::int INTO v_count
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting AND ap.email = 'candidate.rec7@example.com';

  v_result := api.assign_recruitment_inbox_item(
    (SELECT id FROM data.recruitment_email_inbox
     WHERE tenant_id = v_tenant AND from_email = 'candidate.rec7@example.com'
     ORDER BY created_at DESC LIMIT 1),
    v_posting
  );

  IF v_count = 1
     AND (
       (v_result->>'already_assigned')::boolean = true
       OR (v_result->'application'->>'already_exists')::boolean = true
       OR (v_result->'application'->>'application_id') IS NOT NULL
     )
  THEN
    SELECT count(*)::int INTO v_count
    FROM data.applications a
    JOIN data.applicants ap ON ap.id = a.applicant_id
    WHERE a.job_posting_id = v_posting AND ap.email = 'candidate.rec7@example.com';
    IF v_count = 1 THEN
      INSERT INTO test_results VALUES ('inbound_no_double_application', 'PASS', NULL);
    ELSE
      INSERT INTO test_results VALUES ('inbound_no_double_application', 'FAIL', v_count::text);
    END IF;
  ELSE
    INSERT INTO test_results VALUES (
      'inbound_no_double_application', 'FAIL',
      format('before=%s result=%s', v_count, v_result)
    );
  END IF;
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*)::int INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'REC-7 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
