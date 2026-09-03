-- =============================================================================
-- REC-4 hotfix P0 tests — export without csv_text, Art.18/21 exclude, purge
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
  v_app_ok uuid;
  v_app_rest uuid;
  v_applicant_rest uuid;
  v_export jsonb;
  v_pkg uuid;
  v_has_csv boolean;
  v_csv text;
  v_claim jsonb;
  v_audit int;
  v_purged int;
  v_left int;
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
    VALUES (v_tenant, 'rec4h-site', 'REC4h', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC4h Export', 'rec4h-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec4h-ok',
    'Ok Cand', 'ok.rec4h@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec4h-rest',
    'Rest Cand', 'rest.rec4h@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  SELECT a.id INTO v_app_ok
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting AND ap.email = 'ok.rec4h@example.com';

  SELECT a.id, a.applicant_id INTO v_app_rest, v_applicant_rest
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting AND ap.email = 'rest.rec4h@example.com';

  UPDATE data.applicants
  SET processing_restricted_at = now()
  WHERE id = v_applicant_rest;

  PERFORM pg_temp.set_owner_jwt();

  -- 1) prepare returns no csv_text
  v_export := api.export_job_posting_applications_csv(v_posting, true);
  v_pkg := (v_export->>'package_id')::uuid;

  IF v_pkg IS NOT NULL
     AND NOT (v_export ? 'csv_text')
     AND COALESCE((v_export->>'row_count')::int, -1) = 1
     AND COALESCE((v_export->>'excluded_count')::int, -1) = 1
  THEN
    INSERT INTO test_results VALUES ('prepare_no_csv_text', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('prepare_no_csv_text', 'FAIL', v_export::text);
  END IF;

  -- 2) package holds csv server-side; restricted email absent
  SELECT csv_text IS NOT NULL, csv_text
  INTO v_has_csv, v_csv
  FROM data.recruitment_export_packages WHERE id = v_pkg;

  IF v_has_csv
     AND v_csv LIKE '%ok.rec4h@example.com%'
     AND v_csv NOT LIKE '%rest.rec4h@example.com%'
  THEN
    INSERT INTO test_results VALUES ('excludes_restricted', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'excludes_restricted', 'FAIL',
      format('has=%s csv=%s', v_has_csv, left(COALESCE(v_csv, ''), 200))
    );
  END IF;

  -- 3) claim as service_role + finalize clears csv + audit
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  v_claim := api.claim_recruitment_export_package(v_pkg);
  PERFORM api.finalize_recruitment_export(v_pkg, true);

  SELECT csv_text IS NULL INTO v_has_csv
  FROM data.recruitment_export_packages WHERE id = v_pkg;

  SELECT count(*) INTO v_audit
  FROM data.audit_logs
  WHERE tenant_id = v_tenant
    AND action = 'recruitment.export_applications'
    AND entity_id = v_posting
    AND (payload->>'package_id') = v_pkg::text;

  IF (v_claim ? 'csv_text')
     AND v_has_csv
     AND v_audit >= 1
  THEN
    INSERT INTO test_results VALUES ('claim_finalize_audit', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'claim_finalize_audit', 'FAIL',
      format('claim_keys=%s cleared=%s audit=%s', v_claim::text, v_has_csv, v_audit)
    );
  END IF;

  -- 4) purge expired packages (+ storage if present)
  UPDATE data.recruitment_export_packages
  SET expires_at = now() - interval '1 minute'
  WHERE id = v_pkg;

  INSERT INTO storage.objects (bucket_id, name)
  VALUES (
    'recruitment-exports',
    (SELECT storage_path FROM data.recruitment_export_packages WHERE id = v_pkg)
  )
  ON CONFLICT DO NOTHING;

  v_purged := data.purge_expired_recruitment_exports();

  SELECT count(*)::int INTO v_left
  FROM data.recruitment_export_packages WHERE id = v_pkg;

  IF v_purged >= 1 AND v_left = 0 THEN
    INSERT INTO test_results VALUES ('purge_expired_packages', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'purge_expired_packages', 'FAIL',
      format('purged=%s left=%s', v_purged, v_left)
    );
  END IF;

  -- 5) ack still required
  BEGIN
    PERFORM api.export_job_posting_applications_csv(v_posting, false);
    INSERT INTO test_results VALUES ('ack_still_required', 'FAIL', 'expected error');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%ack_required%' THEN
      INSERT INTO test_results VALUES ('ack_still_required', 'PASS', NULL);
    ELSE
      INSERT INTO test_results VALUES ('ack_still_required', 'FAIL', SQLERRM);
    END IF;
  END;
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'REC-4 hotfix P0 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
