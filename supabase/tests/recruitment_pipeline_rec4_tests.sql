-- =============================================================================
-- REC-4 tests — move stage + export CSV ack/audit
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
  v_stage_review uuid;
  v_stage_reject uuid;
  v_other_stage uuid;
  v_move jsonb;
  v_export jsonb;
  v_vis text;
  v_outcome timestamptz;
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (v_tenant, 'recruitment_enabled', true)
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant)
  ON CONFLICT DO NOTHING;

  PERFORM data.seed_default_pipeline_stages(v_tenant);

  SELECT id INTO v_ps FROM data.public_sites WHERE tenant_id = v_tenant LIMIT 1;
  IF v_ps IS NULL THEN
    INSERT INTO data.public_sites (tenant_id, slug, name, status, default_locale)
    VALUES (v_tenant, 'rec4-test-site', 'REC4 Test', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;

  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_postings (
    tenant_id, title, public_slug, status, description, created_by
  ) VALUES (
    v_tenant, 'REC4 Kanban', 'rec4-kanban-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', 'Test', v_owner
  )
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant)
  ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  SELECT id INTO v_stage_review
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND name = 'En revisió'
  LIMIT 1;

  SELECT id INTO v_stage_reject
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL AND is_terminal_reject
  LIMIT 1;

  -- Foreign stage (wrong posting override)
  INSERT INTO data.pipeline_stages (tenant_id, job_posting_id, name, position)
  VALUES (v_tenant, v_posting, 'OnlyThisPosting', 99)
  RETURNING id INTO v_other_stage;
  -- Create a decoy posting-bound stage for another posting
  DELETE FROM data.pipeline_stages WHERE id = v_other_stage;
  INSERT INTO data.job_postings (tenant_id, title, public_slug, status)
  VALUES (v_tenant, 'Other', 'rec4-other-' || substr(gen_random_uuid()::text, 1, 8), 'draft')
  RETURNING id INTO v_other_stage; -- reuse var as other posting id briefly

  INSERT INTO data.pipeline_stages (tenant_id, job_posting_id, name, position)
  VALUES (v_tenant, v_other_stage, 'AlienStage', 0)
  RETURNING id INTO v_other_stage;

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec4-idem-1',
    'Kanban User', 'kanban.rec4@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca',
    'https://example.test'
  );

  SELECT a.id INTO v_app_id
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting AND ap.email = 'kanban.rec4@example.com';

  PERFORM pg_temp.set_owner_jwt();

  -- move OK (SECURITY DEFINER + JWT; no SET ROLE — temp table owned by postgres)
  v_move := api.move_application_stage(v_app_id, v_stage_review);
  IF (v_move->>'stage_id')::uuid = v_stage_review THEN
    INSERT INTO test_results VALUES ('move_stage_ok', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('move_stage_ok', 'FAIL', v_move::text);
  END IF;

  -- move to alien stage fails
  BEGIN
    PERFORM api.move_application_stage(v_app_id, v_other_stage);
    INSERT INTO test_results VALUES ('move_alien_stage_rejected', 'FAIL', 'expected error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('move_alien_stage_rejected', 'PASS', SQLERRM);
  END;

  -- terminal reject does not set outcome
  v_move := api.move_application_stage(v_app_id, v_stage_reject);
  SELECT candidate_visible_status, outcome_communicated_at
  INTO v_vis, v_outcome
  FROM data.applications WHERE id = v_app_id;

  IF v_vis = 'open' AND v_outcome IS NULL THEN
    INSERT INTO test_results VALUES ('terminal_reject_no_outcome', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'terminal_reject_no_outcome', 'FAIL',
      format('vis=%s outcome=%s', v_vis, v_outcome)
    );
  END IF;

  -- export without ack
  BEGIN
    PERFORM api.export_job_posting_applications_csv(v_posting, false);
    INSERT INTO test_results VALUES ('export_requires_ack', 'FAIL', 'expected error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('export_requires_ack', 'PASS', SQLERRM);
  END;

  -- export with ack — metadata only (no csv_text); audit deferred to finalize/Edge
  v_export := api.export_job_posting_applications_csv(v_posting, true);

  IF COALESCE((v_export->>'row_count')::int, 0) >= 1
     AND COALESCE(v_export->>'storage_path', '') <> ''
     AND COALESCE(v_export->>'package_id', '') <> ''
     AND NOT (v_export ? 'csv_text')
  THEN
    INSERT INTO test_results VALUES ('export_ack_audit', 'PASS', v_export->>'row_count');
  ELSE
    INSERT INTO test_results VALUES (
      'export_ack_audit', 'FAIL',
      format('export=%s', v_export::text)
    );
  END IF;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('setup_or_rpc', 'FAIL', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM test_results WHERE status = 'FAIL') THEN
    RAISE EXCEPTION 'recruitment_pipeline_rec4_tests failed';
  END IF;
END;
$$;

ROLLBACK;
