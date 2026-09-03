-- =============================================================================
-- CP-A0.3–7 tests: legacy backfill, unresolved, dual-write, projection lock
-- =============================================================================
BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;
GRANT ALL ON TABLE test_results TO service_role;

-- Bob owner Volt
DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);
END $$;

-- ---------------------------------------------------------------------------
-- Fixtures: 3 completed projects for backfill scenarios
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_pub_at timestamptz := timestamptz '2026-07-01 10:00:00+00';
  v_payload jsonb := jsonb_build_object(
    'schema_version', 2,
    'locale', 'ca',
    'project_id', '51000000-0000-0000-0000-00000000bf01',
    'items', jsonb_build_array(jsonb_build_object('title', 'OK', 'value_bool', true)),
    'bypass_reason', 'should-not-leak'
  );
  v_payload_b jsonb := jsonb_build_object(
    'schema_version', 2,
    'locale', 'ca',
    'items', jsonb_build_array(jsonb_build_object('title', 'OTHER'))
  );
  v_doc uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  INSERT INTO data.projects (
    id, tenant_id, type, name, status, visibility, site_id, client_id, created_by
  ) VALUES
    (
      '51000000-0000-0000-0000-00000000bf01',
      '10000000-0000-0000-0000-000000000003',
      'work_order', 'CP-A037 backfill OK', 'completed', 'company',
      '30000000-0000-0000-0000-000000000004',
      '80000000-0000-0000-0000-000000000101',
      '20000000-0000-0000-0000-000000000002'
    ),
    (
      '51000000-0000-0000-0000-00000000bf02',
      '10000000-0000-0000-0000-000000000003',
      'work_order', 'CP-A037 missing payload', 'completed', 'company',
      '30000000-0000-0000-0000-000000000004',
      '80000000-0000-0000-0000-000000000101',
      '20000000-0000-0000-0000-000000000002'
    ),
    (
      '51000000-0000-0000-0000-00000000bf03',
      '10000000-0000-0000-0000-000000000003',
      'work_order', 'CP-A037 ambiguous DMS', 'completed', 'company',
      '30000000-0000-0000-0000-000000000004',
      '80000000-0000-0000-0000-000000000101',
      '20000000-0000-0000-0000-000000000002'
    ),
    (
      '51000000-0000-0000-0000-00000000bf04',
      '10000000-0000-0000-0000-000000000003',
      'work_order', 'CP-A037 dual-write', 'completed', 'company',
      '30000000-0000-0000-0000-000000000004',
      '80000000-0000-0000-0000-000000000101',
      '20000000-0000-0000-0000-000000000002'
    )
  ON CONFLICT (id) DO NOTHING;

  -- bf01: DMS JSON + legacy published stamp (pre-CIR)
  INSERT INTO data.documents (
    id, tenant_id, site_id, title, entity_type, entity_id, category, created_by
  ) VALUES (
    'd1000000-0000-0000-0000-00000000bf01',
    '10000000-0000-0000-0000-000000000003',
    '30000000-0000-0000-0000-000000000004',
    'Part legacy bf01',
    'project',
    '51000000-0000-0000-0000-00000000bf01',
    'field_service_intervention_report',
    '20000000-0000-0000-0000-000000000002'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes, created_by
  )
  SELECT
    'd1000000-0000-0000-0000-00000000bf01',
    1,
    'external_link',
    'data:application/json;base64,' || encode(convert_to(v_payload::text, 'UTF8'), 'base64'),
    'application/json',
    octet_length(v_payload::text),
    '20000000-0000-0000-0000-000000000002'
  WHERE NOT EXISTS (
    SELECT 1 FROM data.document_versions
    WHERE document_id = 'd1000000-0000-0000-0000-00000000bf01'
      AND version_number = 1
  );

  PERFORM set_config('data.allow_client_report_projection', 'true', true);
  UPDATE data.projects
  SET
    client_report_published_at = v_pub_at,
    client_report_published_by = '20000000-0000-0000-0000-000000000002'
  WHERE id = '51000000-0000-0000-0000-00000000bf01';

  UPDATE data.projects
  SET
    client_report_published_at = v_pub_at + interval '1 hour',
    client_report_published_by = '20000000-0000-0000-0000-000000000002'
  WHERE id = '51000000-0000-0000-0000-00000000bf02';

  UPDATE data.projects
  SET
    client_report_published_at = v_pub_at + interval '2 hour',
    client_report_published_by = '20000000-0000-0000-0000-000000000002'
  WHERE id = '51000000-0000-0000-0000-00000000bf03';
  PERFORM set_config('data.allow_client_report_projection', 'false', true);

  -- bf03: two DMS docs with different payloads
  INSERT INTO data.documents (
    id, tenant_id, site_id, title, entity_type, entity_id, category, created_by
  ) VALUES
    (
      'd1000000-0000-0000-0000-00000000bf03',
      '10000000-0000-0000-0000-000000000003',
      '30000000-0000-0000-0000-000000000004',
      'Part A bf03', 'project', '51000000-0000-0000-0000-00000000bf03',
      'field_service_intervention_report', '20000000-0000-0000-0000-000000000002'
    ),
    (
      'd1000000-0000-0000-0000-00000000bf13',
      '10000000-0000-0000-0000-000000000003',
      '30000000-0000-0000-0000-000000000004',
      'Part B bf03', 'project', '51000000-0000-0000-0000-00000000bf03',
      'field_service_intervention_report', '20000000-0000-0000-0000-000000000002'
    )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes, created_by
  )
  SELECT * FROM (VALUES
    (
      'd1000000-0000-0000-0000-00000000bf03'::uuid,
      1,
      'external_link',
      'data:application/json;base64,' || encode(convert_to(v_payload::text, 'UTF8'), 'base64'),
      'application/json',
      octet_length(v_payload::text),
      '20000000-0000-0000-0000-000000000002'::uuid
    ),
    (
      'd1000000-0000-0000-0000-00000000bf13'::uuid,
      1,
      'external_link',
      'data:application/json;base64,' || encode(convert_to(v_payload_b::text, 'UTF8'), 'base64'),
      'application/json',
      octet_length(v_payload_b::text),
      '20000000-0000-0000-0000-000000000002'::uuid
    )
  ) AS x(document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes, created_by)
  WHERE NOT EXISTS (
    SELECT 1 FROM data.document_versions dv
    WHERE dv.document_id = x.document_id AND dv.version_number = 1
  );
END $$;

SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claim', '{"role":"service_role"}', true);

-- ---------------------------------------------------------------------------
-- T1: backfill from DMS preserves published_at + creates v1
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_res jsonb;
  v_ver_at timestamptz;
  v_items jsonb;
  v_bypass text;
BEGIN
  v_res := data.backfill_customer_intervention_report_for_project(
    '51000000-0000-0000-0000-00000000bf01'
  );

  SELECT v.published_at, v.projection->'checklist_items', v.projection->>'bypass_reason'
    INTO v_ver_at, v_items, v_bypass
  FROM data.customer_intervention_reports r
  JOIN data.customer_intervention_report_versions v
    ON v.id = r.current_published_version_id
  WHERE r.project_id = '51000000-0000-0000-0000-00000000bf01';

  IF v_res->>'status' = 'backfilled'
     AND v_ver_at = timestamptz '2026-07-01 10:00:00+00'
     AND jsonb_array_length(v_items) = 1
     AND v_bypass IS NULL THEN
    INSERT INTO test_results VALUES ('T1 backfill DMS preserves published_at', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T1 backfill DMS preserves published_at', 'FAIL',
      format('res=%s ver_at=%s items=%s bypass=%s',
        v_res, v_ver_at, v_items, v_bypass)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 backfill DMS preserves published_at', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T2: missing payload → legacy_unresolved; project stays locked
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_res jsonb;
  v_unres boolean;
BEGIN
  v_res := data.backfill_customer_intervention_report_for_project(
    '51000000-0000-0000-0000-00000000bf02'
  );

  SELECT r.legacy_unresolved
    INTO v_unres
  FROM data.customer_intervention_reports r
  WHERE r.project_id = '51000000-0000-0000-0000-00000000bf02';

  IF v_res->>'status' = 'legacy_unresolved'
     AND v_unres THEN
    INSERT INTO test_results VALUES ('T2 missing → legacy_unresolved', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T2 missing → legacy_unresolved', 'FAIL',
      format('res=%s unres=%s', v_res, v_unres)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 missing → legacy_unresolved', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T3: ambiguous DMS payloads → legacy_unresolved
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_res jsonb;
  v_unres boolean;
BEGIN
  v_res := data.backfill_customer_intervention_report_for_project(
    '51000000-0000-0000-0000-00000000bf03'
  );

  SELECT legacy_unresolved INTO v_unres
  FROM data.customer_intervention_reports
  WHERE project_id = '51000000-0000-0000-0000-00000000bf03';

  IF v_res->>'status' = 'legacy_unresolved'
     AND v_res->>'reason' = 'ambiguous_dms_payloads'
     AND v_unres THEN
    INSERT INTO test_results VALUES ('T3 ambiguous DMS → unresolved', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T3 ambiguous DMS → unresolved', 'FAIL',
      format('res=%s unres=%s', v_res, v_unres)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 ambiguous DMS → unresolved', 'FAIL', SQLERRM);
END $$;

SET LOCAL ROLE authenticated;
SELECT set_config(
  'request.jwt.claim',
  '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
  true
);

-- ---------------------------------------------------------------------------
-- T4: direct write blocked when aggregate exists
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  UPDATE data.projects
  SET client_report_published_at = now()
  WHERE id = '51000000-0000-0000-0000-00000000bf01';

  INSERT INTO test_results VALUES (
    'T4 direct published write blocked', 'FAIL', 'update succeeded'
  );
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE '%client_report_published_projection_only%' THEN
    INSERT INTO test_results VALUES ('T4 direct published write blocked', 'PASS', SQLERRM);
  ELSE
    INSERT INTO test_results VALUES ('T4 direct published write blocked', 'FAIL', SQLERRM);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- T5: legacy upsert is migration/service-role only
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM data.upsert_customer_intervention_report_from_legacy(
    '51000000-0000-0000-0000-00000000bf04'::uuid,
    '{}'::jsonb,
    'forbidden_authenticated_call',
    NULL,
    NULL,
    now(),
    '20000000-0000-0000-0000-000000000002'::uuid,
    false,
    NULL
  );
  INSERT INTO test_results VALUES (
    'T5 legacy upsert denied', 'FAIL', 'authenticated call succeeded'
  );
EXCEPTION WHEN insufficient_privilege THEN
  INSERT INTO test_results VALUES ('T5 legacy upsert denied', 'PASS', SQLERRM);
WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 legacy upsert denied', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T5b: legacy publish RPC no longer exists
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('api.publish_project_client_report(uuid,text,text)') IS NULL THEN
    INSERT INTO test_results VALUES ('T5b legacy publish removed', 'PASS', 'function absent');
  ELSE
    INSERT INTO test_results VALUES ('T5b legacy publish removed', 'FAIL', 'function exists');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- T6: inventory sees reconciliation statuses
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_ok int;
  v_unres int;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE reconciliation_status = 'ok'),
    COUNT(*) FILTER (WHERE reconciliation_status = 'legacy_unresolved')
  INTO v_ok, v_unres
  FROM api.legacy_client_report_inventory
  WHERE project_id IN (
    '51000000-0000-0000-0000-00000000bf01',
    '51000000-0000-0000-0000-00000000bf02',
    '51000000-0000-0000-0000-00000000bf03',
    '51000000-0000-0000-0000-00000000bf04'
  );

  IF v_ok >= 1 AND v_unres >= 2 THEN
    INSERT INTO test_results VALUES (
      'T6 inventory reconciliation', 'PASS',
      format('ok=%s unres=%s', v_ok, v_unres)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T6 inventory reconciliation', 'FAIL',
      format('ok=%s unres=%s', v_ok, v_unres)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 inventory reconciliation', 'FAIL', SQLERRM);
END $$;

-- Results
SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'CP-A0.3–7 tests failed: %',
      (SELECT jsonb_agg(to_jsonb(t)) FROM test_results t WHERE status = 'FAIL');
  END IF;
END $$;

ROLLBACK;
