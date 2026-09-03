-- =============================================================================
-- REC-12 tests — CSV import + Art. 14
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
  v_result jsonb;
  v_ok boolean;
  v_err text;
  v_locale text;
  v_art14 timestamptz;
  v_src text;
  v_label text;
  v_count int;
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (v_tenant, 'recruitment_enabled', true)
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant) ON CONFLICT DO NOTHING;

  UPDATE data.recruitment_settings
  SET import_legal_basis = 'legitimate_interest',
      import_legal_basis_note = NULL
  WHERE tenant_id = v_tenant;

  PERFORM data.seed_default_pipeline_stages(v_tenant);

  SELECT id INTO v_ps FROM data.public_sites WHERE tenant_id = v_tenant LIMIT 1;
  IF v_ps IS NULL THEN
    INSERT INTO data.public_sites (tenant_id, slug, name, status, default_locale)
    VALUES (v_tenant, 'rec12-site', 'REC12', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_postings (
    tenant_id, title, public_slug, status, created_by
  )
  VALUES (
    v_tenant, 'REC12 Job', 'rec12-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner
  )
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  -- Forbidden without manage
  PERFORM pg_temp.set_view_only_jwt();
  v_ok := false;
  BEGIN
    PERFORM api.import_applications_bulk(
      v_posting,
      '[{"full_name":"X","email":"x.rec12@example.com"}]'::jsonb,
      'InfoJobs'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('import_requires_manage', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('import_requires_manage', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- other without note blocked
  PERFORM pg_temp.set_owner_jwt();
  UPDATE data.recruitment_settings
  SET import_legal_basis = 'other', import_legal_basis_note = NULL
  WHERE tenant_id = v_tenant;

  v_ok := false;
  v_err := NULL;
  BEGIN
    PERFORM api.import_applications_bulk(
      v_posting,
      '[{"full_name":"Y","email":"y.rec12@example.com"}]'::jsonb,
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%legal_basis_note_required%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('import_other_requires_note', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('import_other_requires_note', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  UPDATE data.recruitment_settings
  SET import_legal_basis = 'legitimate_interest', import_legal_basis_note = NULL
  WHERE tenant_id = v_tenant;

  -- Create with locale
  PERFORM pg_temp.set_owner_jwt();
  v_result := api.import_applications_bulk(
    v_posting,
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'Locale ES',
        'email', 'locale.es.rec12@example.com',
        'locale', 'es',
        'phone', '600000001'
      ),
      jsonb_build_object(
        'full_name', 'Dup Cand',
        'email', 'dup.rec12@example.com'
      )
    ),
    'InfoJobs'
  );

  IF (v_result->>'created')::int = 2
     AND (v_result->>'art14_queued')::int >= 1
  THEN
    INSERT INTO test_results VALUES ('import_creates_rows', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('import_creates_rows', 'FAIL', v_result::text);
  END IF;

  SELECT ap.preferred_locale, ap.art14_notice_sent_at, a.source, a.import_source_label
  INTO v_locale, v_art14, v_src, v_label
  FROM data.applicants ap
  JOIN data.applications a ON a.applicant_id = ap.id
  WHERE ap.email = 'locale.es.rec12@example.com' AND a.job_posting_id = v_posting;

  IF v_locale = 'es' AND v_art14 IS NOT NULL AND v_src = 'csv_import' AND v_label = 'InfoJobs' THEN
    INSERT INTO test_results VALUES ('import_locale_source_art14', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'import_locale_source_art14', 'FAIL',
      format('locale=%s art14=%s src=%s label=%s', v_locale, v_art14, v_src, v_label)
    );
  END IF;

  -- Skip duplicates on reimport
  v_result := api.import_applications_bulk(
    v_posting,
    jsonb_build_array(
      jsonb_build_object('full_name', 'Locale ES', 'email', 'locale.es.rec12@example.com'),
      jsonb_build_object('full_name', 'Dup Cand', 'email', 'dup.rec12@example.com')
    ),
    'InfoJobs'
  );

  SELECT count(*)::int INTO v_count
  FROM data.applications
  WHERE job_posting_id = v_posting AND source = 'csv_import';

  IF (v_result->>'created')::int = 0
     AND (v_result->>'skipped_duplicate')::int = 2
     AND v_count = 2
  THEN
    INSERT INTO test_results VALUES ('import_skips_duplicates', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'import_skips_duplicates', 'FAIL',
      format('result=%s count=%s', v_result, v_count)
    );
  END IF;

  -- Art.14 not re-queued on second create for same applicant different posting
  -- (art14_notice_sent_at already set)
  INSERT INTO data.job_postings (
    tenant_id, title, public_slug, status, created_by
  )
  VALUES (
    v_tenant, 'REC12 Job B', 'rec12b-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner
  )
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  v_result := api.import_applications_bulk(
    v_posting,
    jsonb_build_array(
      jsonb_build_object('full_name', 'Locale ES', 'email', 'locale.es.rec12@example.com', 'locale', 'es')
    ),
    'LinkedIn'
  );

  IF (v_result->>'created')::int = 1
     AND (v_result->>'art14_queued')::int = 0
  THEN
    INSERT INTO test_results VALUES ('import_art14_once_per_applicant', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('import_art14_once_per_applicant', 'FAIL', v_result::text);
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
    RAISE EXCEPTION 'REC-12 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
