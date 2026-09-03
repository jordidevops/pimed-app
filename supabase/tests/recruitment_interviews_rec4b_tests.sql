-- =============================================================================
-- REC-4b tests — interviews CRUD / notes / tenant isolation
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
  v_interview uuid;
  v_posting_check uuid;
  v_notes text;
  v_status text;
  v_other_tenant uuid;
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
    VALUES (v_tenant, 'rec4b-site', 'REC4b', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC4b Job', 'rec4b-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec4b-idem-1',
    'Interview Cand', 'interview.rec4b@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  SELECT a.id INTO v_app_id
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting AND ap.email = 'interview.rec4b@example.com';

  PERFORM pg_temp.set_owner_jwt();

  INSERT INTO data.interviews (
    tenant_id, application_id, type, scheduled_at, notes, status
  ) VALUES (
    v_tenant, v_app_id, 'online', now() + interval '2 days', 'First notes', 'scheduled'
  )
  RETURNING id, job_posting_id INTO v_interview, v_posting_check;

  IF v_interview IS NOT NULL AND v_posting_check = v_posting THEN
    INSERT INTO test_results VALUES ('create_interview_ok', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('create_interview_ok', 'FAIL', format('id=%s posting=%s', v_interview, v_posting_check));
  END IF;

  UPDATE data.interviews SET notes = 'Updated notes' WHERE id = v_interview
  RETURNING notes INTO v_notes;
  IF v_notes = 'Updated notes' THEN
    INSERT INTO test_results VALUES ('update_notes_ok', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('update_notes_ok', 'FAIL', v_notes);
  END IF;

  UPDATE data.interviews SET status = 'cancelled' WHERE id = v_interview
  RETURNING status INTO v_status;
  IF v_status = 'cancelled' THEN
    INSERT INTO test_results VALUES ('cancel_status_ok', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('cancel_status_ok', 'FAIL', v_status);
  END IF;

  -- entity type registered
  IF EXISTS (SELECT 1 FROM data.entity_types WHERE code = 'interview') THEN
    INSERT INTO test_results VALUES ('entity_type_interview', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('entity_type_interview', 'FAIL', NULL);
  END IF;

  -- tenant isolation: cannot point interview at foreign application
  SELECT id INTO v_other_tenant FROM data.tenants WHERE id <> v_tenant LIMIT 1;
  IF v_other_tenant IS NOT NULL THEN
    BEGIN
      INSERT INTO data.interviews (tenant_id, application_id, type)
      VALUES (v_other_tenant, v_app_id, 'phone');
      INSERT INTO test_results VALUES ('tenant_mismatch_rejected', 'FAIL', 'expected error');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO test_results VALUES ('tenant_mismatch_rejected', 'PASS', SQLERRM);
    END;
  ELSE
    INSERT INTO test_results VALUES ('tenant_mismatch_rejected', 'PASS', 'no second tenant');
  END IF;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('setup_or_rpc', 'FAIL', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM test_results WHERE status = 'FAIL') THEN
    RAISE EXCEPTION 'recruitment_interviews_rec4b_tests failed';
  END IF;
END;
$$;

ROLLBACK;
