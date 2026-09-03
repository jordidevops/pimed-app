-- =============================================================================
-- REC-1 tests — recruitment ATS core
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
  v_app jsonb;
  v_purge timestamptz;
  v_vis text;
  v_ok boolean;
BEGIN
  -- Ensure feature + settings
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
    VALUES (v_tenant, 'rec-test-site', 'REC Test', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;

  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  -- Setup under postgres (seed), then assert RLS as authenticated
  INSERT INTO data.job_postings (
    tenant_id, title, public_slug, status, description, created_by
  ) VALUES (
    v_tenant, 'Cuiner/a', 'cuiner-test-' || substr(gen_random_uuid()::text, 1, 8), 'draft', 'Descripció prova', v_owner
  )
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant)
  ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  PERFORM pg_temp.set_owner_jwt();
  SET ROLE authenticated;

  IF NOT EXISTS (SELECT 1 FROM data.job_postings WHERE id = v_posting) THEN
    RAISE EXCEPTION 'rls_select_job_postings_denied';
  END IF;

  RESET ROLE;

  -- purge_at always finite
  v_app := api.submit_job_application(
    v_ps, v_posting, 'idem-rec-1',
    'Maria Test', 'maria.rec@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca',
    'https://example.test'
  );

  SELECT purge_at, candidate_visible_status INTO v_purge, v_vis
  FROM data.applications
  WHERE id = (v_app->>'application_id')::uuid;

  IF v_purge IS NULL OR v_purge > now() + interval '13 months' THEN
    INSERT INTO test_results VALUES ('purge_at_finite', 'FAIL', v_purge::text);
  ELSE
    INSERT INTO test_results VALUES ('purge_at_finite', 'PASS', v_purge::text);
  END IF;

  IF v_vis = 'open' THEN
    INSERT INTO test_results VALUES ('visible_status_open', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('visible_status_open', 'FAIL', v_vis);
  END IF;

  -- duplicate application
  v_app := api.submit_job_application(
    v_ps, v_posting, 'idem-rec-2',
    'Maria Test', 'maria.rec@example.com', NULL, NULL,
    'qr', 'delete_on_process_end', NULL, NULL, 'v1', true, 'ca',
    'https://example.test'
  );

  IF COALESCE((v_app->>'duplicate')::boolean, false) THEN
    INSERT INTO test_results VALUES ('dedupe_email_posting', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('dedupe_email_posting', 'FAIL', v_app::text);
  END IF;

  -- settings NOT NULL max retention
  SELECT default_max_retention_months IS NOT NULL INTO v_ok
  FROM data.recruitment_settings WHERE tenant_id = v_tenant;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('settings_max_retention_required', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('settings_max_retention_required', 'FAIL', NULL);
  END IF;

  -- list public
  IF jsonb_array_length(api.list_public_job_postings(v_ps)) >= 1 THEN
    INSERT INTO test_results VALUES ('list_public_postings', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('list_public_postings', 'FAIL', NULL);
  END IF;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('setup_or_rpc', 'FAIL', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM test_results WHERE status = 'FAIL') THEN
    RAISE EXCEPTION 'recruitment_ats_rec1_tests failed';
  END IF;
END;
$$;

ROLLBACK;
