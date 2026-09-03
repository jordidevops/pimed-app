-- =============================================================================
-- Customer Portal P2 hardening tests (BEGIN/ROLLBACK)
-- fulfill mark_only/remint, backfill skips on_publish, CIR INSERT revoked
-- =============================================================================
BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;
GRANT ALL ON TABLE test_results TO service_role;
GRANT ALL ON TABLE test_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.as_service_role() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  SET ROLE service_role;
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM set_config('request.jwt.claim', '{"role":"service_role"}', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.as_authenticated_owner() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);
END;
$$;

SELECT pg_temp.as_authenticated_owner();

-- Ensure published CIR on project 101
DO $$
DECLARE
  v_draft uuid;
  v_ver uuid;
BEGIN
  UPDATE data.projects SET status = 'completed'
  WHERE id = '51000000-0000-0000-0000-000000000101';

  IF NOT EXISTS (
    SELECT 1 FROM data.customer_intervention_reports r
    WHERE r.project_id = '51000000-0000-0000-0000-000000000101'
      AND r.current_published_version_id IS NOT NULL
  ) THEN
    v_draft := api.upsert_customer_intervention_report_draft(
      '51000000-0000-0000-0000-000000000101'::uuid,
      'ca',
      '<p>P2 test</p>',
      jsonb_build_object(
        'tenant', jsonb_build_object('name', 'Volt'),
        'checklist_items', jsonb_build_array(jsonb_build_object('label', 'OK'))
      ),
      '[]'::jsonb,
      NULL
    );
    PERFORM api.prepare_customer_intervention_report_media(v_draft);
    v_ver := api.publish_customer_intervention_report(v_draft);
  END IF;
END $$;

-- T1: authenticated cannot INSERT CIR versions
DO $$
BEGIN
  IF has_table_privilege('authenticated', 'data.customer_intervention_report_versions', 'INSERT') THEN
    INSERT INTO test_results VALUES ('T1_cir_versions_insert_revoked', 'FAIL', 'INSERT still granted');
  ELSE
    INSERT INTO test_results VALUES ('T1_cir_versions_insert_revoked', 'PASS', NULL);
  END IF;
END $$;

-- T2: legacy/backfill version insert does not enqueue on_publish intents
DO $$
DECLARE
  v_report uuid;
  v_account uuid := '80000000-0000-0000-0000-000000000101'::uuid;
  v_channel uuid := '83000000-0000-0000-0000-000000000101'::uuid;
  v_ver uuid := 'a1000000-0000-0000-0000-00000000f201'::uuid;
  v_before int;
  v_after int;
  v_rule uuid;
BEGIN
  SELECT id INTO v_report
  FROM data.customer_intervention_reports
  WHERE project_id = '51000000-0000-0000-0000-000000000101'
  LIMIT 1;

  -- Fixture writes as postgres (superuser). Privileged RPCs still use service_role+JWT.
  RESET ROLE;

  IF NOT EXISTS (
    SELECT 1 FROM data.contact_delivery_rules
    WHERE tenant_id = '10000000-0000-0000-0000-000000000003'
      AND client_account_contact_id = v_account
      AND contact_point_id = v_channel
      AND purpose = 'bulletin'
      AND policy = 'on_publish'
      AND disabled_at IS NULL
  ) THEN
    INSERT INTO data.contact_delivery_rules (
      tenant_id, client_account_contact_id, contact_point_id,
      purpose, policy, created_by
    ) VALUES (
      '10000000-0000-0000-0000-000000000003',
      v_account,
      v_channel,
      'bulletin',
      'on_publish',
      '20000000-0000-0000-0000-000000000002'
    )
    RETURNING id INTO v_rule;
  ELSE
    SELECT id INTO v_rule
    FROM data.contact_delivery_rules
    WHERE tenant_id = '10000000-0000-0000-0000-000000000003'
      AND client_account_contact_id = v_account
      AND contact_point_id = v_channel
      AND purpose = 'bulletin'
      AND policy = 'on_publish'
      AND disabled_at IS NULL
    LIMIT 1;
  END IF;

  SELECT COUNT(*) INTO v_before
  FROM data.customer_report_share_delivery_intents
  WHERE report_version_id = v_ver
    AND idempotency_key LIKE 'on_publish:%';

  INSERT INTO data.customer_intervention_report_versions (
    id, tenant_id, report_id, project_id, version_number,
    customer_account_contact_id, locale, schema_version, template_version,
    content_digest, projection, media_manifest, snapshots, published_by
  ) VALUES (
    v_ver,
    '10000000-0000-0000-0000-000000000003',
    v_report,
    '51000000-0000-0000-0000-000000000101',
    9001,
    v_account,
    'ca', '1.0', '1.0-p2-backfill-only',
    'p2-backfill-digest',
    '{"checklist_items":[]}'::jsonb,
    '[]'::jsonb,
    jsonb_build_object('backfill', true),
    '20000000-0000-0000-0000-000000000002'
  );

  SELECT COUNT(*) INTO v_after
  FROM data.customer_report_share_delivery_intents
  WHERE report_version_id = v_ver
    AND idempotency_key LIKE 'on_publish:%';

  PERFORM pg_temp.as_authenticated_owner();

  IF v_after = v_before AND v_rule IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T2_backfill_skips_on_publish', 'PASS',
      format('rule=%s before=%s after=%s', v_rule, v_before, v_after));
  ELSE
    INSERT INTO test_results VALUES ('T2_backfill_skips_on_publish', 'FAIL',
      format('rule=%s before=%s after=%s', v_rule, v_before, v_after));
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.as_authenticated_owner();
  INSERT INTO test_results VALUES ('T2_backfill_skips_on_publish', 'FAIL', SQLERRM);
END $$;

-- T3: live share + email_logs → mark_only (no remint / no secret)
DO $$
DECLARE
  v_intent uuid;
  v_ful1 jsonb;
  v_ful2 jsonb;
  v_share uuid;
  v_key text;
BEGIN
  v_intent := api.enqueue_customer_report_share_email(
    '51000000-0000-0000-0000-000000000101'::uuid,
    '83000000-0000-0000-0000-000000000101'::uuid,
    'cpa-p2-mark-only',
    24,
    NULL,
    '80000000-0000-0000-0000-000000000102'::uuid
  );

  PERFORM pg_temp.as_service_role();
  v_ful1 := api.fulfill_customer_report_share_delivery_intent(v_intent);
  v_share := (v_ful1->>'share_id')::uuid;
  v_key := 'crs-email:cpa-p2-mark-only:' || v_share::text;

  INSERT INTO data.email_logs (
    tenant_id, idempotency_key, status, email_type,
    from_email, to_emails, subject
  ) VALUES (
    '10000000-0000-0000-0000-000000000003',
    v_key,
    'queued',
    'transactional',
    'noreply@example.com',
    ARRAY['client@example.com'],
    'P2 mark-only probe'
  );

  UPDATE data.customer_report_share_delivery_intents
  SET status = 'failed', failure_reason = 'simulated_post_enqueue_crash', updated_at = now()
  WHERE id = v_intent;

  v_ful2 := api.fulfill_customer_report_share_delivery_intent(v_intent);
  PERFORM pg_temp.as_authenticated_owner();

  IF (v_ful2->>'mark_only')::boolean IS TRUE
     AND (v_ful2->>'already_enqueued')::boolean IS TRUE
     AND (v_ful2->>'share_id')::uuid = v_share
     AND v_ful2 ? 'secret' IS FALSE THEN
    INSERT INTO test_results VALUES ('T3_fulfill_mark_only', 'PASS', v_ful2::text);
  ELSE
    INSERT INTO test_results VALUES ('T3_fulfill_mark_only', 'FAIL', v_ful2::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.as_authenticated_owner();
  INSERT INTO test_results VALUES ('T3_fulfill_mark_only', 'FAIL', SQLERRM);
END $$;

-- T4: live share without email_logs → revoke + remint (new secret)
DO $$
DECLARE
  v_intent uuid;
  v_ful1 jsonb;
  v_ful2 jsonb;
  v_share1 uuid;
  v_share2 uuid;
  v_revoked timestamptz;
BEGIN
  v_intent := api.enqueue_customer_report_share_email(
    '51000000-0000-0000-0000-000000000101'::uuid,
    '83000000-0000-0000-0000-000000000101'::uuid,
    'cpa-p2-remint',
    24,
    NULL,
    '80000000-0000-0000-0000-000000000102'::uuid
  );

  PERFORM pg_temp.as_service_role();
  v_ful1 := api.fulfill_customer_report_share_delivery_intent(v_intent);
  v_share1 := (v_ful1->>'share_id')::uuid;

  -- Crash before enqueue: no email_logs row; force retryable status
  UPDATE data.customer_report_share_delivery_intents
  SET status = 'failed', failure_reason = 'simulated_pre_enqueue_crash', updated_at = now()
  WHERE id = v_intent;

  v_ful2 := api.fulfill_customer_report_share_delivery_intent(v_intent);
  v_share2 := (v_ful2->>'share_id')::uuid;
  SELECT revoked_at INTO v_revoked FROM data.customer_report_shares WHERE id = v_share1;
  PERFORM pg_temp.as_authenticated_owner();

  IF (v_ful2->>'mark_only')::boolean IS NOT TRUE
     AND (v_ful2->>'secret') ~ '^[0-9a-f]{64}$'
     AND v_share2 IS DISTINCT FROM v_share1
     AND v_revoked IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T4_fulfill_remint_pre_enqueue', 'PASS',
      format('old=%s new=%s', v_share1, v_share2));
  ELSE
    INSERT INTO test_results VALUES ('T4_fulfill_remint_pre_enqueue', 'FAIL',
      format('ful1=%s ful2=%s revoked=%s', v_ful1, v_ful2, v_revoked));
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.as_authenticated_owner();
  INSERT INTO test_results VALUES ('T4_fulfill_remint_pre_enqueue', 'FAIL', SQLERRM);
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'CP-P2 tests failed: % failures', v_fail;
  END IF;
END $$;

ROLLBACK;
