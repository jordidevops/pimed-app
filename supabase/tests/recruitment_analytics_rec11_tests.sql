-- =============================================================================
-- REC-11 tests — get_recruitment_analytics + k-anonymity
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

CREATE OR REPLACE FUNCTION pg_temp.set_view_jwt() RETURNS void
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

CREATE OR REPLACE FUNCTION pg_temp.set_no_perm_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000097', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000097","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
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
  v_site uuid;
  v_result jsonb;
  v_ok boolean;
  v_err text;
  v_i int;
  v_apps jsonb;
  v_funnel jsonb;
  v_keys text[];
  v_web_count int;
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (v_tenant, 'recruitment_enabled', true)
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant) ON CONFLICT DO NOTHING;

  UPDATE data.recruitment_settings
  SET analytics_min_cohort = 5
  WHERE tenant_id = v_tenant;

  PERFORM data.seed_default_pipeline_stages(v_tenant);

  SELECT id INTO v_ps FROM data.public_sites WHERE tenant_id = v_tenant LIMIT 1;
  IF v_ps IS NULL THEN
    INSERT INTO data.public_sites (tenant_id, slug, name, status, default_locale)
    VALUES (v_tenant, 'rec11-site', 'REC11', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  SELECT id INTO v_site FROM data.sites WHERE tenant_id = v_tenant LIMIT 1;

  INSERT INTO data.job_postings (
    tenant_id, title, public_slug, status, created_by, site_id
  )
  VALUES (
    v_tenant, 'REC11 Job A', 'rec11a-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner, v_site
  )
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  INSERT INTO data.job_postings (
    tenant_id, title, public_slug, status, created_by, site_id
  )
  VALUES (
    v_tenant, 'REC11 Job B', 'rec11b-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner, v_site
  )
  RETURNING id INTO v_posting2;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting2, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting2;

  -- Forbidden without recruitment.view
  PERFORM pg_temp.set_no_perm_jwt();
  v_ok := false;
  BEGIN
    PERFORM api.get_recruitment_analytics(NULL, NULL, NULL, NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('analytics_forbidden_without_view', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('analytics_forbidden_without_view', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- 3 apps → suppressed (< k=5)
  FOR v_i IN 1..3 LOOP
    PERFORM api.submit_job_application(
      v_ps, v_posting, 'rec11-small-' || v_i,
      'Small ' || v_i, 'small' || v_i || '.rec11@example.com', NULL, NULL,
      'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
    );
  END LOOP;

  PERFORM pg_temp.set_view_jwt();
  v_result := api.get_recruitment_analytics(NULL, NULL, NULL, v_posting, NULL);
  v_apps := v_result -> 'kpis' -> 'applications';

  IF (v_apps->>'suppressed')::boolean = true
     AND v_apps->>'value' IS NULL
     AND (v_result->>'min_cohort')::int = 5
     AND (v_result -> 'funnel' -> 0 ->> 'suppressed')::boolean = true
     AND (v_result -> 'funnel' -> 0 ->> 'count') IS NULL
  THEN
    INSERT INTO test_results VALUES ('analytics_k_suppresses_small_cohort', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'analytics_k_suppresses_small_cohort', 'FAIL', v_result::text
    );
  END IF;

  -- Add 2 more → 5 apps on posting A → visible
  FOR v_i IN 4..5 LOOP
    PERFORM api.submit_job_application(
      v_ps, v_posting, 'rec11-ok-' || v_i,
      'Ok ' || v_i, 'ok' || v_i || '.rec11@example.com', NULL, NULL,
      'qr', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
    );
  END LOOP;

  -- 1 app on posting B (small cohort for filter test)
  PERFORM api.submit_job_application(
    v_ps, v_posting2, 'rec11-b-1',
    'B One', 'bone.rec11@example.com', NULL, NULL,
    'whatsapp', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  PERFORM pg_temp.set_view_jwt();
  v_result := api.get_recruitment_analytics(NULL, NULL, NULL, v_posting, NULL);
  v_apps := v_result -> 'kpis' -> 'applications';

  IF (v_apps->>'suppressed')::boolean = false
     AND (v_apps->>'value')::int = 5
     AND (v_result -> 'funnel' -> 0 ->> 'count')::int = 5
  THEN
    INSERT INTO test_results VALUES ('analytics_visible_when_ge_k', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'analytics_visible_when_ge_k', 'FAIL', v_result::text
    );
  END IF;

  -- Filter by posting B → suppressed (1 < 5)
  v_result := api.get_recruitment_analytics(NULL, NULL, NULL, v_posting2, NULL);
  IF (v_result -> 'kpis' -> 'applications' ->> 'suppressed')::boolean = true THEN
    INSERT INTO test_results VALUES ('analytics_filter_posting_scope', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'analytics_filter_posting_scope', 'FAIL', v_result::text
    );
  END IF;

  -- Site filter (when site exists): all apps on that site should include both postings
  IF v_site IS NOT NULL THEN
    v_result := api.get_recruitment_analytics(NULL, NULL, v_site, NULL, NULL);
    IF (v_result -> 'kpis' -> 'applications' ->> 'suppressed')::boolean = false
       AND (v_result -> 'kpis' -> 'applications' ->> 'value')::int >= 6
    THEN
      INSERT INTO test_results VALUES ('analytics_filter_site', 'PASS', NULL);
    ELSE
      INSERT INTO test_results VALUES (
        'analytics_filter_site', 'FAIL', v_result::text
      );
    END IF;
  ELSE
    INSERT INTO test_results VALUES ('analytics_filter_site', 'PASS', 'no site in seed — skipped');
  END IF;

  -- No PII keys in response
  SELECT array_agg(k ORDER BY k) INTO v_keys
  FROM jsonb_object_keys(v_result) AS k;

  IF v_result ? 'kpis'
     AND v_result ? 'funnel'
     AND v_result ? 'by_source'
     AND v_result ? 'min_cohort'
     AND NOT (v_result::text ILIKE '%@example.com%')
     AND NOT (v_result::text ILIKE '%full_name%')
     AND NOT (v_result::text ILIKE '%cv_storage%')
  THEN
    INSERT INTO test_results VALUES ('analytics_no_pii_in_payload', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'analytics_no_pii_in_payload', 'FAIL', v_result::text
    );
  END IF;

  -- by_source: web=3 and qr=2 on posting A → both < 5 → omitted from by_source when filtered to A
  -- Across tenant with site filter we have web=3, qr=2, whatsapp=1 — all < 5
  -- Add 2 more web on posting A so web >= 5
  FOR v_i IN 6..7 LOOP
    PERFORM api.submit_job_application(
      v_ps, v_posting, 'rec11-web-' || v_i,
      'Web ' || v_i, 'web' || v_i || '.rec11@example.com', NULL, NULL,
      'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
    );
  END LOOP;

  v_result := api.get_recruitment_analytics(NULL, NULL, NULL, v_posting, NULL);
  SELECT (e->>'count')::int INTO v_web_count
  FROM jsonb_array_elements(v_result -> 'by_source') e
  WHERE e->>'key' = 'web'
  LIMIT 1;

  IF v_web_count = 5
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_result -> 'by_source') e
       WHERE e->>'key' = 'qr'
     )
  THEN
    INSERT INTO test_results VALUES ('analytics_by_source_omits_small', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'analytics_by_source_omits_small', 'FAIL',
      format('web=%s payload=%s', v_web_count, v_result -> 'by_source')
    );
  END IF;

  -- Feature flag off → forbidden (SECURITY DEFINER must not bypass)
  UPDATE data.tenant_feature_overrides
  SET override_status = false
  WHERE tenant_id = v_tenant AND feature_key = 'recruitment_enabled';

  PERFORM pg_temp.set_view_jwt();
  v_ok := false;
  v_err := NULL;
  BEGIN
    PERFORM api.get_recruitment_analytics(NULL, NULL, NULL, NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('analytics_forbidden_when_flag_off', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'analytics_forbidden_when_flag_off', 'FAIL', COALESCE(v_err, 'no error')
    );
  END IF;

  -- Restore flag for other suites sharing DB in same session (rollback anyway)
  UPDATE data.tenant_feature_overrides
  SET override_status = true
  WHERE tenant_id = v_tenant AND feature_key = 'recruitment_enabled';
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*)::int INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'REC-11 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
