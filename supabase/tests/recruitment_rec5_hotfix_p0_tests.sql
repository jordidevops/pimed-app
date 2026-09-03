-- =============================================================================
-- REC-5 hotfix P0 tests — archive prefs URL, CV storage purge, SLA internal
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
  v_posting2 uuid;
  v_app_id uuid;
  v_app2 uuid;
  v_applicant uuid;
  v_req uuid;
  v_token_hash text;
  v_visible text;
  v_ok boolean;
  v_count int;
  v_cv_path text;
  v_storage_left int;
  v_to text[];
  v_owner_email text;
  v_requester text := 'sla.candidate.hotfix@example.com';
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (v_tenant, 'recruitment_enabled', true)
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant) ON CONFLICT DO NOTHING;

  UPDATE data.recruitment_settings
  SET rejection_notify_policy = 'on_posting_close',
      candidate_portal_base_url = NULL,
      rights_sla_notify_emails = '{}',
      default_max_retention_months = 12
  WHERE tenant_id = v_tenant;

  -- Clear system fallback so "no URL" path is deterministic
  UPDATE data.system_settings
  SET settings = COALESCE(settings, '{}'::jsonb) - 'dev_base_url'
  WHERE module = 'employee_portal';

  PERFORM data.seed_default_pipeline_stages(v_tenant);

  SELECT id INTO v_ps FROM data.public_sites WHERE tenant_id = v_tenant LIMIT 1;
  IF v_ps IS NULL THEN
    INSERT INTO data.public_sites (tenant_id, slug, name, status, default_locale)
    VALUES (v_tenant, 'rec5h-site', 'REC5h', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  SELECT email INTO v_owner_email FROM data.profiles WHERE id = v_owner;

  -- -------------------------------------------------------------------------
  -- 1) Archive without portal base URL → communicate but NO dead token
  -- -------------------------------------------------------------------------
  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC5h no-url', 'rec5h-nu-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5h-idem-1',
    'NoUrl Cand', 'nourl.hotfix@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  SELECT a.id INTO v_app_id
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting AND ap.email = 'nourl.hotfix@example.com';

  UPDATE data.job_postings SET status = 'archived' WHERE id = v_posting;

  SELECT candidate_visible_status, post_rejection_token_hash IS NULL
  INTO v_visible, v_ok
  FROM data.applications WHERE id = v_app_id;

  IF v_visible = 'closed' AND v_ok THEN
    INSERT INTO test_results VALUES ('archive_no_url_no_dead_token', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'archive_no_url_no_dead_token', 'FAIL',
      format('visible=%s token_null=%s', v_visible, v_ok)
    );
  END IF;

  -- -------------------------------------------------------------------------
  -- 2) Archive with candidate_portal_base_url → token + usable prefs path
  -- -------------------------------------------------------------------------
  UPDATE data.recruitment_settings
  SET candidate_portal_base_url = 'https://portal.hotfix.test',
      rejection_notify_policy = 'on_posting_close'
  WHERE tenant_id = v_tenant;

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC5h with-url', 'rec5h-wu-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting2;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting2, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting2;

  PERFORM api.submit_job_application(
    v_ps, v_posting2, 'rec5h-idem-2',
    'WithUrl Cand', 'withurl.hotfix@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  SELECT a.id INTO v_app2
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = v_posting2 AND ap.email = 'withurl.hotfix@example.com';

  DELETE FROM data.email_logs
  WHERE tenant_id = v_tenant
    AND idempotency_key = 'recruitment-rejected-' || v_app2::text;

  -- JWT so enqueue_email accepts the archive trigger path
  PERFORM pg_temp.set_owner_jwt();
  UPDATE data.job_postings SET status = 'archived' WHERE id = v_posting2;

  SELECT post_rejection_token_hash INTO v_token_hash
  FROM data.applications WHERE id = v_app2;

  SELECT coalesce(
    (SELECT template_variables ->> 'preferences_url'
     FROM data.email_logs
     WHERE tenant_id = v_tenant
       AND idempotency_key = 'recruitment-rejected-' || v_app2::text
     LIMIT 1),
    ''
  ) INTO v_visible;

  IF v_token_hash IS NOT NULL
     AND v_visible LIKE 'https://portal.hotfix.test/recruitment/preferences?token=%'
  THEN
    INSERT INTO test_results VALUES ('archive_with_url_prefs_link', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'archive_with_url_prefs_link', 'FAIL',
      format('hash_present=%s prefs=%s', (v_token_hash IS NOT NULL), v_visible)
    );
  END IF;

  -- -------------------------------------------------------------------------
  -- 3) Rights purge deletes CV storage object
  -- -------------------------------------------------------------------------
  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC5h cv', 'rec5h-cv-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  v_cv_path := v_ps::text || '/' || v_posting::text || '/' || gen_random_uuid()::text || '.pdf';

  INSERT INTO storage.objects (bucket_id, name)
  VALUES ('recruitment-cvs', v_cv_path)
  ON CONFLICT DO NOTHING;

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5h-idem-cv',
    'CvPurge Cand', 'cvpurge.hotfix@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, v_cv_path, 'v1', true, 'ca', NULL
  );

  SELECT a.id, a.applicant_id INTO v_app_id, v_applicant
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'cvpurge.hotfix@example.com' AND a.job_posting_id = v_posting
  LIMIT 1;

  UPDATE data.applicants
  SET email_verified_at = now()
  WHERE id = v_applicant;

  v_count := data.purge_applicant_for_rights(v_tenant, v_applicant);

  SELECT count(*)::int INTO v_storage_left
  FROM storage.objects
  WHERE bucket_id = 'recruitment-cvs' AND name = v_cv_path;

  IF v_count >= 1 AND v_storage_left = 0 THEN
    INSERT INTO test_results VALUES ('rights_purge_deletes_cv_storage', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'rights_purge_deletes_cv_storage', 'FAIL',
      format('purged=%s storage_left=%s', v_count, v_storage_left)
    );
  END IF;

  -- -------------------------------------------------------------------------
  -- 4) Retention purge deletes CV storage
  -- -------------------------------------------------------------------------
  v_cv_path := v_ps::text || '/' || gen_random_uuid()::text || '/ret.pdf';
  INSERT INTO storage.objects (bucket_id, name)
  VALUES ('recruitment-cvs', v_cv_path);

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (v_tenant, 'REC5h ret', 'rec5h-ret-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner)
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5h-idem-ret',
    'RetPurge Cand', 'retpurge.hotfix@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, v_cv_path, 'v1', true, 'ca', NULL
  );

  SELECT a.id INTO v_app_id
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'retpurge.hotfix@example.com' AND a.job_posting_id = v_posting;

  UPDATE data.applications SET purge_at = now() - interval '1 hour' WHERE id = v_app_id;

  v_count := data.purge_expired_applications();

  SELECT count(*)::int INTO v_storage_left
  FROM storage.objects
  WHERE bucket_id = 'recruitment-cvs' AND name = v_cv_path;

  IF v_storage_left = 0 THEN
    INSERT INTO test_results VALUES ('retention_purge_deletes_cv_storage', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'retention_purge_deletes_cv_storage', 'FAIL',
      format('storage_left=%s purged_count=%s', v_storage_left, v_count)
    );
  END IF;

  -- -------------------------------------------------------------------------
  -- 5) SLA reminder goes to owner/manager, not requester
  -- -------------------------------------------------------------------------
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec5h-idem-sla',
    'Sla Cand', v_requester, NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );

  SELECT a.applicant_id INTO v_applicant
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = v_requester AND a.job_posting_id = v_posting
  LIMIT 1;

  UPDATE data.applicants SET email_verified_at = now() WHERE id = v_applicant;

  INSERT INTO data.applicant_data_requests (
    tenant_id, applicant_id, request_type, requester_email, due_at, status
  ) VALUES (
    v_tenant, v_applicant, 'access', v_requester,
    now() + interval '1 day', 'pending_review'
  )
  RETURNING id INTO v_req;

  DELETE FROM data.email_logs
  WHERE tenant_id = v_tenant AND idempotency_key = 'rights-sla-' || v_req::text;

  v_count := data.remind_rights_sla();

  SELECT to_emails INTO v_to
  FROM data.email_logs
  WHERE tenant_id = v_tenant AND idempotency_key = 'rights-sla-' || v_req::text
  LIMIT 1;

  IF v_count >= 1
     AND v_to IS NOT NULL
     AND lower(v_owner_email) = ANY (SELECT lower(unnest(v_to)))
     AND NOT (lower(v_requester) = ANY (SELECT lower(unnest(v_to))))
  THEN
    INSERT INTO test_results VALUES ('sla_reminder_internal_not_candidate', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'sla_reminder_internal_not_candidate', 'FAIL',
      format('count=%s to=%s owner=%s', v_count, v_to, v_owner_email)
    );
  END IF;

  -- restore settings
  UPDATE data.recruitment_settings
  SET rejection_notify_policy = 'on_decision',
      candidate_portal_base_url = NULL
  WHERE tenant_id = v_tenant;

  INSERT INTO data.system_settings (module, settings)
  VALUES ('employee_portal', jsonb_build_object('dev_base_url', 'http://localhost:3002'))
  ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || jsonb_build_object('dev_base_url', 'http://localhost:3002');
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'REC-5 hotfix P0 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
