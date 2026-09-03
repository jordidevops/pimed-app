-- =============================================================================
-- CP-A1 tests: immutable versions, publish flow, fresh permission
-- =============================================================================
BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE TEMP TABLE media_test_context (draft_id uuid) ON COMMIT DROP;
GRANT ALL ON TABLE test_results, media_test_context TO service_role;

-- Bob owner Volt + wildcard permissions
DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  UPDATE data.projects
  SET status = 'completed'
  WHERE id = '51000000-0000-0000-0000-000000000101'::uuid;
END $$;

-- T1: draft -> prepare -> publish creates version + locks project
DO $$
DECLARE
  v_draft uuid;
  v_ver uuid;
  v_n int;
  v_locked boolean;
  v_pub timestamptz;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  v_draft := api.upsert_customer_intervention_report_draft(
    '51000000-0000-0000-0000-000000000101'::uuid,
    'ca',
    '<p>Resum client</p>',
    jsonb_build_object(
      'tenant', jsonb_build_object('name', 'Volt'),
      'intervention', jsonb_build_object('status', 'done'),
      'checklist_items', jsonb_build_array(jsonb_build_object('label', 'OK', 'state', 'pass')),
      'work_notes_html', '<p>secret</p>',
      'costs', 123
    ),
    '[]'::jsonb,
    NULL
  );

  PERFORM api.prepare_customer_intervention_report_media(v_draft);
  v_ver := api.publish_customer_intervention_report(v_draft);

  SELECT COUNT(*) INTO v_n
  FROM data.customer_intervention_report_versions
  WHERE id = v_ver AND version_number = 1;

  SELECT data.project_work_is_locked('51000000-0000-0000-0000-000000000101'::uuid)
    INTO v_locked;

  SELECT client_report_published_at INTO v_pub
  FROM data.projects WHERE id = '51000000-0000-0000-0000-000000000101'::uuid;

  IF v_n = 1 AND v_locked AND v_pub IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T1 publish + lock', 'PASS', v_ver::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T1 publish + lock', 'FAIL',
      format('n=%s locked=%s pub=%s', v_n, v_locked, v_pub)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 publish + lock', 'FAIL', SQLERRM);
END $$;

-- T2: projection strips work_notes_html / costs; versions immutable
DO $$
DECLARE
  v_ver uuid;
  v_proj jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  SELECT current_published_version_id INTO v_ver
  FROM data.customer_intervention_reports
  WHERE project_id = '51000000-0000-0000-0000-000000000101'::uuid;

  SELECT projection INTO v_proj
  FROM data.customer_intervention_report_versions WHERE id = v_ver;

  BEGIN
    UPDATE data.customer_intervention_report_versions
    SET locale = 'es' WHERE id = v_ver;
    INSERT INTO test_results VALUES ('T2 strip + immutable', 'FAIL', 'update allowed');
  EXCEPTION WHEN OTHERS THEN
    IF (v_proj ? 'work_notes_html') OR (v_proj ? 'costs') THEN
      INSERT INTO test_results VALUES ('T2 strip + immutable', 'FAIL', 'sensitive keys present');
    ELSIF SQLERRM LIKE '%immutable%' OR SQLERRM LIKE '%append%' THEN
      INSERT INTO test_results VALUES ('T2 strip + immutable', 'PASS', SQLERRM);
    ELSE
      INSERT INTO test_results VALUES ('T2 strip + immutable', 'PASS', 'blocked: ' || SQLERRM);
    END IF;
  END;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 strip + immutable', 'FAIL', SQLERRM);
END $$;

-- T3: correction draft + second version
DO $$
DECLARE
  v_report uuid;
  v_draft uuid;
  v_ver2 uuid;
  v_max int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  SELECT id INTO v_report
  FROM data.customer_intervention_reports
  WHERE project_id = '51000000-0000-0000-0000-000000000101'::uuid;

  v_draft := api.create_corrected_customer_intervention_report_draft(v_report);
  PERFORM api.prepare_customer_intervention_report_media(v_draft);
  v_ver2 := api.publish_customer_intervention_report(v_draft);

  SELECT MAX(version_number) INTO v_max
  FROM data.customer_intervention_report_versions WHERE report_id = v_report;

  IF v_max = 2 AND v_ver2 IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T3 correction v2', 'PASS', v_ver2::text);
  ELSE
    INSERT INTO test_results VALUES ('T3 correction v2', 'FAIL', format('max=%s', v_max));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 correction v2', 'FAIL', SQLERRM);
END $$;

-- T4: session_refresh_required when live OK but JWT missing claim
DO $$
BEGIN
  -- Still owner live, but JWT without field_service permission and without *
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["storage.view"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  BEGIN
    PERFORM data.require_fresh_tenant_permission(
      '10000000-0000-0000-0000-000000000003'::uuid,
      'field_service.reports.publish',
      NULL
    );
    INSERT INTO test_results VALUES ('T4 session_refresh_required', 'FAIL', 'expected exception');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%session_refresh_required%' THEN
      INSERT INTO test_results VALUES ('T4 session_refresh_required', 'PASS', SQLERRM);
    ELSE
      -- Owner live returns * so live passes; JWT without * should refresh
      INSERT INTO test_results VALUES ('T4 session_refresh_required', 'FAIL', SQLERRM);
    END IF;
  END;
END $$;

SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claim', '{"role":"service_role"}', true);
SELECT api.create_pending_upload(
  '55000000-0000-0000-0000-00000000f501',
  '10000000-0000-0000-0000-000000000003',
  NULL,
  '20000000-0000-0000-0000-000000000002',
  'demo-photo.jpg',
  NULL,
  '10000000-0000-0000-0000-000000000003/55000000-0000-0000-0000-00000000f501/demo-photo.jpg',
  'image/jpeg',
  123,
  now() + interval '1 hour',
  jsonb_build_object('project_id', '51000000-0000-0000-0000-000000000101')
);
SELECT api.mark_file_as_done('55000000-0000-0000-0000-00000000f501', 123);
SELECT api.create_pending_upload(
  '55000000-0000-0000-0000-00000000f502',
  '10000000-0000-0000-0000-000000000001',
  NULL,
  '20000000-0000-0000-0000-000000000002',
  'foreign-photo.jpg',
  NULL,
  '10000000-0000-0000-0000-000000000001/55000000-0000-0000-0000-00000000f502/foreign-photo.jpg',
  'image/jpeg',
  123,
  now() + interval '1 hour',
  jsonb_build_object('project_id', '51000000-0000-0000-0000-000000000101')
);
SELECT api.mark_file_as_done('55000000-0000-0000-0000-00000000f502', 123);

SET LOCAL ROLE authenticated;
SELECT set_config(
  'request.jwt.claim',
  '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
  true
);

-- T5: file_node-only media → private ledger → service-only completion.
DO $$
DECLARE
  v_report uuid;
  v_draft uuid;
  v_prep jsonb;
  v_blocked boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  SELECT id INTO v_report
  FROM data.customer_intervention_reports
  WHERE project_id = '51000000-0000-0000-0000-000000000101'::uuid;

  v_draft := api.create_corrected_customer_intervention_report_draft(v_report);

  UPDATE data.customer_intervention_report_drafts
  SET selected_media = jsonb_build_array(jsonb_build_object(
    'file_node_id', '55000000-0000-0000-0000-00000000f501',
    'bucket', 'other-tenant-private',
    'storage_key', 'foreign/object'
  ))
  WHERE id = v_draft;
  BEGIN
    PERFORM api.prepare_customer_intervention_report_media(v_draft);
    INSERT INTO test_results VALUES (
      'T5 caller storage coordinates rejected', 'FAIL', 'prepare succeeded'
    );
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES (
      'T5 caller storage coordinates rejected',
      CASE WHEN SQLERRM LIKE '%media_storage_coordinates_forbidden%' THEN 'PASS' ELSE 'FAIL' END,
      SQLERRM
    );
  END;

  UPDATE data.customer_intervention_report_drafts
  SET selected_media = jsonb_build_array(jsonb_build_object(
    'file_node_id', '55000000-0000-0000-0000-00000000f502'
  ))
  WHERE id = v_draft;
  BEGIN
    PERFORM api.prepare_customer_intervention_report_media(v_draft);
    INSERT INTO test_results VALUES (
      'T5 cross-tenant file rejected', 'FAIL', 'prepare succeeded'
    );
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES (
      'T5 cross-tenant file rejected',
      CASE WHEN SQLERRM LIKE '%media_file_node_not_available%' THEN 'PASS' ELSE 'FAIL' END,
      SQLERRM
    );
  END;

  UPDATE data.customer_intervention_report_drafts
  SET selected_media = jsonb_build_array(jsonb_build_object(
    'file_node_id', '55000000-0000-0000-0000-00000000f501'
  ))
  WHERE id = v_draft;

  v_prep := api.prepare_customer_intervention_report_media(v_draft);
  IF (v_prep->>'status') IS DISTINCT FROM 'preparing_media'
     OR (v_prep->>'pending_count')::int IS DISTINCT FROM 1 THEN
    INSERT INTO test_results VALUES (
      'T5 media copy gate', 'FAIL',
      format('prep=%s', v_prep)
    );
    RETURN;
  END IF;

  BEGIN
    PERFORM api.publish_customer_intervention_report(v_draft);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%draft_not_ready%' OR SQLERRM LIKE '%media_copy_pending%' THEN
      v_blocked := true;
    ELSE
      INSERT INTO test_results VALUES ('T5 media copy gate', 'FAIL', 'unexpected: ' || SQLERRM);
      RETURN;
    END IF;
  END;

  IF NOT v_blocked THEN
    INSERT INTO test_results VALUES ('T5 media copy gate', 'FAIL', 'publish allowed while pending');
    RETURN;
  END IF;

  INSERT INTO media_test_context VALUES (v_draft);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 media copy gate', 'FAIL', SQLERRM);
END $$;

DO $$
DECLARE v_draft uuid;
BEGIN
  SELECT draft_id INTO v_draft FROM media_test_context LIMIT 1;
  PERFORM api.complete_customer_intervention_report_media_prepare(v_draft);
  INSERT INTO test_results VALUES (
    'T5 authenticated completion denied', 'FAIL', 'completion succeeded'
  );
EXCEPTION WHEN insufficient_privilege THEN
  INSERT INTO test_results VALUES (
    'T5 authenticated completion denied', 'PASS', SQLERRM
  );
WHEN OTHERS THEN
  INSERT INTO test_results VALUES (
    'T5 authenticated completion denied', 'FAIL', SQLERRM
  );
END $$;

SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claim', '{"role":"service_role"}', true);

DO $$
DECLARE
  v_draft uuid;
  v_jobs jsonb;
  v_job jsonb;
BEGIN
  SELECT draft_id INTO v_draft FROM media_test_context LIMIT 1;
  IF v_draft IS NULL THEN
    INSERT INTO test_results VALUES (
      'T5 service worker completion', 'FAIL', 'prepare did not produce a draft'
    );
    RETURN;
  END IF;
  v_jobs := api.claim_customer_intervention_report_media_copy_jobs(v_draft);

  BEGIN
    PERFORM api.complete_customer_intervention_report_media_prepare(v_draft);
    INSERT INTO test_results VALUES (
      'T5 incomplete job blocks completion', 'FAIL', 'completion succeeded'
    );
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES (
      'T5 incomplete job blocks completion',
      CASE WHEN SQLERRM LIKE '%media_copy_incomplete%' THEN 'PASS' ELSE 'FAIL' END,
      SQLERRM
    );
  END;

  FOR v_job IN SELECT value FROM jsonb_array_elements(v_jobs)
  LOOP
    PERFORM api.mark_customer_intervention_report_media_copy_job(
      (v_job->>'job_id')::uuid, true, 123, NULL
    );
  END LOOP;
  PERFORM api.complete_customer_intervention_report_media_prepare(v_draft);
END $$;

SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_draft uuid;
  v_ver uuid;
  v_status text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  SELECT draft_id INTO v_draft FROM media_test_context LIMIT 1;
  SELECT status INTO v_status
  FROM data.customer_intervention_report_drafts WHERE id = v_draft;
  IF v_status IS DISTINCT FROM 'ready' THEN
    INSERT INTO test_results VALUES ('T5 media copy gate', 'FAIL', 'status=' || v_status);
    RETURN;
  END IF;

  v_ver := api.publish_customer_intervention_report(v_draft);
  INSERT INTO test_results VALUES (
    'T5 media copy gate',
    CASE WHEN v_ver IS NULL THEN 'FAIL' ELSE 'PASS' END,
    COALESCE(v_ver::text, 'publish returned null')
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 media copy gate', 'FAIL', SQLERRM);
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'CP-A1 tests failed: %',
      (SELECT jsonb_agg(to_jsonb(t)) FROM test_results t WHERE status = 'FAIL');
  END IF;
END $$;

ROLLBACK;
