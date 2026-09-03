-- =============================================================================
-- employee_portal_token_batch_tests.sql — EP-ACC-3b-prep + ack + rate/url (B-T1…B-T13)
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ep_batch_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active, public_portal_enabled)
VALUES ('d1000000-0000-0000-0000-000000000001', 'EP Batch Tenant', 'ep-batch', true, true)
ON CONFLICT (id) DO UPDATE SET public_portal_enabled = EXCLUDED.public_portal_enabled;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES
  ('d2000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'EP Batch Site', true),
  ('d2000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000001', 'EP Batch Site No Portal', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('d3000000-0000-0000-0000-000000000001', 'ep-batch-mgr@test.com', 'authenticated', 'authenticated'),
  ('d3000000-0000-0000-0000-000000000002', 'ep-batch-viewer@test.com', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('d3000000-0000-0000-0000-000000000001', 'ep-batch-mgr@test.com', 'EP Batch Manager'),
  ('d3000000-0000-0000-0000-000000000002', 'ep-batch-viewer@test.com', 'EP Batch Viewer')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  ('d4000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'd3000000-0000-0000-0000-000000000001', 'manager', true),
  ('d4000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000001', 'd3000000-0000-0000-0000-000000000002', 'viewer', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, document_id, status)
VALUES
  ('d5000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001', NULL, 'Batch Emp 1', 'BATCH001', 'active'),
  ('d5000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001', NULL, 'Batch Emp 2', 'BATCH002', 'active'),
  ('d5000000-0000-0000-0000-000000000003', 'd1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001', NULL, 'Batch Emp 3', 'BATCH003', 'active'),
  ('d5000000-0000-0000-0000-000000000004', 'd1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001', NULL, 'Batch Emp Inactive', 'BATCH004', 'inactive'),
  ('d5000000-0000-0000-0000-000000000005', 'd1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000002', NULL, 'Batch Emp No Site', 'BATCH005', 'active'),
  ('d5000000-0000-0000-0000-000000000006', 'd1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001', NULL, 'Batch Emp No Doc', NULL, 'active')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.public_sites (id, tenant_id, site_id, slug, name, status)
VALUES ('d6000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001', 'ep-batch-site', 'EP Batch Portal', 'published')
ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, slug = EXCLUDED.slug;

INSERT INTO data.public_domains (id, public_site_id, tenant_id, domain, status)
VALUES ('d7000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'batch.ep3b.test', 'ssl_active')
ON CONFLICT (id) DO NOTHING;

UPDATE data.public_sites
SET primary_domain_id = 'd7000000-0000-0000-0000-000000000001'
WHERE id = 'd6000000-0000-0000-0000-000000000001';

CREATE OR REPLACE FUNCTION pg_temp.ep_batch_set_manager_jwt()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"d3000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"d1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"d1000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"d1000000-0000-0000-0000-000000000001"}', true);
  SET LOCAL ROLE authenticated;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.ep_batch_set_viewer_jwt()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"d3000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"d1000000-0000-0000-0000-000000000001":{"global_role":"viewer","sites":{}}},"user_permissions":{"d1000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"d1000000-0000-0000-0000-000000000001"}', true);
  SET LOCAL ROLE authenticated;
END;
$$;

-- Evitar batch_rate_limited per lots anteriors (fora del BEGIN) o dins la bateria
UPDATE data.employee_portal_token_batch_jobs
SET created_at = now() - interval '2 hours'
WHERE tenant_id = 'd1000000-0000-0000-0000-000000000001';

DO $$
DECLARE
  v_result jsonb;
  v_batch_id uuid;
  v_batch_id2 uuid;
  v_created_items int;
  v_secrets int;
  v_token_count int;
  v_token_count2 int;
  v_first_token uuid;
  v_second_superseded uuid;
  v_fetch jsonb;
  v_err text;
  v_ids uuid[];
  v_i int;
BEGIN
  -- B-T1: Lot 3 empleats → 3 created, secrets no NULL
  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt1-batch-key-001',
    p_employee_ids => ARRAY[
      'd5000000-0000-0000-0000-000000000001'::uuid,
      'd5000000-0000-0000-0000-000000000002'::uuid,
      'd5000000-0000-0000-0000-000000000003'::uuid
    ]
  );
  v_batch_id := (v_result ->> 'batch_id')::uuid;

  SET LOCAL ROLE postgres;

  SELECT count(*), count(*) FILTER (WHERE secret_plaintext IS NOT NULL)
  INTO v_created_items, v_secrets
  FROM data.employee_portal_token_batch_items
  WHERE batch_job_id = v_batch_id
    AND status = 'created';

  IF (v_result ->> 'status') = 'completed'
     AND (v_result -> 'summary' ->> 'created')::int = 3
     AND v_created_items = 3
     AND v_secrets = 3 THEN
    INSERT INTO ep_batch_results VALUES ('B-T1 batch 3 created', 'PASS', v_batch_id::text);
  ELSE
    INSERT INTO ep_batch_results VALUES ('B-T1 batch 3 created', 'FAIL', v_result::text);
  END IF;

  -- B-T2: Idempotència mateixa key → mateix batch_id, cap token duplicat
  PERFORM pg_temp.ep_batch_set_manager_jwt();
  SELECT count(*) INTO v_token_count
  FROM data.employee_portal_tokens t
  WHERE t.employee_id IN (
    'd5000000-0000-0000-0000-000000000001',
    'd5000000-0000-0000-0000-000000000002',
    'd5000000-0000-0000-0000-000000000003'
  )
    AND t.is_active = true
    AND t.revoked_at IS NULL;

  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt1-batch-key-001',
    p_employee_ids => ARRAY[
      'd5000000-0000-0000-0000-000000000001'::uuid,
      'd5000000-0000-0000-0000-000000000002'::uuid,
      'd5000000-0000-0000-0000-000000000003'::uuid
    ]
  );

  SET LOCAL ROLE postgres;

  SELECT count(*) INTO v_token_count2
  FROM data.employee_portal_tokens t
  WHERE t.employee_id IN (
    'd5000000-0000-0000-0000-000000000001',
    'd5000000-0000-0000-0000-000000000002',
    'd5000000-0000-0000-0000-000000000003'
  )
    AND t.is_active = true
    AND t.revoked_at IS NULL;

  IF (v_result ->> 'batch_id')::uuid = v_batch_id
     AND COALESCE((v_result ->> 'idempotent_replay')::boolean, false) = true
     AND v_token_count = v_token_count2 THEN
    INSERT INTO ep_batch_results VALUES ('B-T2 idempotent replay', 'PASS', (v_result ->> 'batch_id'));
  ELSE
    INSERT INTO ep_batch_results VALUES ('B-T2 idempotent replay', 'FAIL', v_result::text);
  END IF;

  -- B-T3: Empleat inactiu → skipped
  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt3-batch-key-001',
    p_employee_ids => ARRAY[
      'd5000000-0000-0000-0000-000000000004'::uuid
    ],
    p_skip_inactive => true
  );
  v_batch_id := (v_result ->> 'batch_id')::uuid;

  SET LOCAL ROLE postgres;

  IF EXISTS (
    SELECT 1
    FROM data.employee_portal_token_batch_items i
    WHERE i.batch_job_id = v_batch_id
      AND i.status = 'skipped'
      AND i.error_code = 'employee_not_active'
  ) THEN
    INSERT INTO ep_batch_results VALUES ('B-T3 inactive skipped', 'PASS', NULL);
  ELSE
    INSERT INTO ep_batch_results VALUES ('B-T3 inactive skipped', 'FAIL', v_result::text);
  END IF;

  SET LOCAL ROLE postgres;

  -- B-T4: 2n lot mateix tipus revoca token anterior
  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt4-batch-key-001',
    p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000001'::uuid],
  );
  v_batch_id := (v_result ->> 'batch_id')::uuid;

  SET LOCAL ROLE postgres;

  SELECT token_id INTO v_first_token
  FROM data.employee_portal_token_batch_items
  WHERE batch_job_id = v_batch_id
    AND employee_id = 'd5000000-0000-0000-0000-000000000001';

  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt4-batch-key-002',
    p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000001'::uuid],
  );
  v_batch_id2 := (v_result ->> 'batch_id')::uuid;

  SET LOCAL ROLE postgres;

  SELECT superseded_token_id INTO v_second_superseded
  FROM data.employee_portal_token_batch_items
  WHERE batch_job_id = v_batch_id2
    AND employee_id = 'd5000000-0000-0000-0000-000000000001';

  IF v_second_superseded = v_first_token
     AND EXISTS (
       SELECT 1 FROM data.employee_portal_tokens
       WHERE id = v_first_token AND is_active = false AND revoke_reason = 'superseded'
     ) THEN
    INSERT INTO ep_batch_results VALUES ('B-T4 supersedes prior token', 'PASS', v_first_token::text);
  ELSE
    INSERT INTO ep_batch_results VALUES ('B-T4 supersedes prior token', 'FAIL', coalesce(v_second_superseded::text, 'null'));
  END IF;

  -- B-T5: fetch després expires_at → batch_expired
  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt5-batch-key-001',
    p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000002'::uuid]
  );
  v_batch_id := (v_result ->> 'batch_id')::uuid;

  SET LOCAL ROLE postgres;
  UPDATE data.employee_portal_token_batch_jobs
  SET expires_at = now() - interval '1 minute'
  WHERE id = v_batch_id;

  PERFORM pg_temp.ep_batch_set_manager_jwt();
  BEGIN
    PERFORM api.fetch_employee_portal_token_batch_results(v_batch_id);
    SET LOCAL ROLE postgres;
    INSERT INTO ep_batch_results VALUES ('B-T5 fetch expired', 'FAIL', 'no exception');
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      SET LOCAL ROLE postgres;
      IF v_err LIKE '%batch_expired%' THEN
        INSERT INTO ep_batch_results VALUES ('B-T5 fetch expired', 'PASS', v_err);
      ELSE
        INSERT INTO ep_batch_results VALUES ('B-T5 fetch expired', 'FAIL', v_err);
      END IF;
  END;

  -- B-T6: Purge esborra secret_plaintext
  SET LOCAL ROLE postgres;
  UPDATE data.employee_portal_token_batch_jobs
  SET created_at = now() - interval '2 hours'
  WHERE tenant_id = 'd1000000-0000-0000-0000-000000000001';

  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt6-batch-key-001',
    p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000003'::uuid]
  );
  v_batch_id := (v_result ->> 'batch_id')::uuid;

  SET LOCAL ROLE postgres;
  UPDATE data.employee_portal_token_batch_jobs
  SET expires_at = now() - interval '1 minute',
      status = 'completed'
  WHERE id = v_batch_id;

  PERFORM data.purge_expired_employee_portal_token_batches();

  SELECT count(*) INTO v_secrets
  FROM data.employee_portal_token_batch_items
  WHERE batch_job_id = v_batch_id
    AND secret_plaintext IS NOT NULL;

  IF v_secrets = 0
     AND EXISTS (
       SELECT 1 FROM data.employee_portal_token_batch_jobs
       WHERE id = v_batch_id AND status = 'expired'
     ) THEN
    INSERT INTO ep_batch_results VALUES ('B-T6 purge secrets', 'PASS', NULL);
  ELSE
    INSERT INTO ep_batch_results VALUES ('B-T6 purge secrets', 'FAIL', v_secrets::text);
  END IF;

  -- B-T7: 101 empleats → batch_too_large
  v_ids := ARRAY[]::uuid[];
  FOR v_i IN 1..101 LOOP
    v_ids := array_append(v_ids, ('d9000000-0000-0000-0000-' || lpad(v_i::text, 12, '0'))::uuid);
  END LOOP;

  PERFORM pg_temp.ep_batch_set_manager_jwt();
  BEGIN
    PERFORM api.start_employee_portal_token_batch(
      p_idempotency_key => 'bt7-batch-key-001',
      p_employee_ids => v_ids
    );
    SET LOCAL ROLE postgres;
    INSERT INTO ep_batch_results VALUES ('B-T7 batch too large', 'FAIL', 'no exception');
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      SET LOCAL ROLE postgres;
      IF v_err LIKE '%batch_too_large%' THEN
        INSERT INTO ep_batch_results VALUES ('B-T7 batch too large', 'PASS', v_err);
      ELSE
        INSERT INTO ep_batch_results VALUES ('B-T7 batch too large', 'FAIL', v_err);
      END IF;
  END;

  -- B-T8: Sense attendance.manage → insufficient_privilege
  PERFORM pg_temp.ep_batch_set_viewer_jwt();
  BEGIN
    PERFORM api.start_employee_portal_token_batch(
      p_idempotency_key => 'bt8-batch-key-001',
      p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000001'::uuid]
    );
    SET LOCAL ROLE postgres;
    INSERT INTO ep_batch_results VALUES ('B-T8 insufficient privilege', 'FAIL', 'no exception');
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      SET LOCAL ROLE postgres;
      IF v_err LIKE '%insufficient_privilege%' THEN
        INSERT INTO ep_batch_results VALUES ('B-T8 insufficient privilege', 'PASS', v_err);
      ELSE
        INSERT INTO ep_batch_results VALUES ('B-T8 insufficient privilege', 'FAIL', v_err);
      END IF;
  END;

  -- B-T9: no_published_public_site → fila error, job completed amb errors
  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt9-batch-key-001',
    p_employee_ids => ARRAY[
      'd5000000-0000-0000-0000-000000000001'::uuid,
      'd5000000-0000-0000-0000-000000000005'::uuid
    ]
  );
  v_batch_id := (v_result ->> 'batch_id')::uuid;

  SET LOCAL ROLE postgres;

  IF (v_result ->> 'status') = 'completed'
     AND (v_result -> 'summary' ->> 'created')::int >= 1
     AND (v_result -> 'summary' ->> 'errors')::int >= 1
     AND EXISTS (
       SELECT 1 FROM data.employee_portal_token_batch_items
       WHERE batch_job_id = v_batch_id
         AND employee_id = 'd5000000-0000-0000-0000-000000000005'
         AND status = 'error'
         AND error_code = 'no_published_public_site'
     ) THEN
    INSERT INTO ep_batch_results VALUES ('B-T9 no published site row error', 'PASS', NULL);
  ELSE
    INSERT INTO ep_batch_results VALUES ('B-T9 no published site row error', 'FAIL', v_result::text);
  END IF;

  -- B-T10: ack purge secrets → fetch posterior batch_expired
  SET LOCAL ROLE postgres;
  UPDATE data.employee_portal_token_batch_jobs
  SET created_at = now() - interval '2 hours'
  WHERE tenant_id = 'd1000000-0000-0000-0000-000000000001';

  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt10-batch-key-001',
    p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000001'::uuid]
  );
  v_batch_id := (v_result ->> 'batch_id')::uuid;

  PERFORM api.fetch_employee_portal_token_batch_results(v_batch_id);

  v_result := api.ack_employee_portal_token_batch(v_batch_id);

  SET LOCAL ROLE postgres;

  SELECT count(*) INTO v_secrets
  FROM data.employee_portal_token_batch_items
  WHERE batch_job_id = v_batch_id
    AND secret_plaintext IS NOT NULL;

  IF (v_result ->> 'status') = 'expired'
     AND COALESCE((v_result ->> 'already_acked')::boolean, false) = false
     AND v_secrets = 0
     AND EXISTS (
       SELECT 1 FROM data.employee_portal_token_batch_jobs
       WHERE id = v_batch_id AND status = 'expired'
     ) THEN
    BEGIN
      PERFORM pg_temp.ep_batch_set_manager_jwt();
      PERFORM api.fetch_employee_portal_token_batch_results(v_batch_id);
      SET LOCAL ROLE postgres;
      INSERT INTO ep_batch_results VALUES ('B-T10 ack then fetch expired', 'FAIL', 'fetch should fail');
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      SET LOCAL ROLE postgres;
      IF v_err LIKE '%batch_expired%' THEN
        INSERT INTO ep_batch_results VALUES ('B-T10 ack then fetch expired', 'PASS', v_err);
      ELSE
        INSERT INTO ep_batch_results VALUES ('B-T10 ack then fetch expired', 'FAIL', v_err);
      END IF;
    END;

    PERFORM pg_temp.ep_batch_set_manager_jwt();
    v_result := api.ack_employee_portal_token_batch(v_batch_id);
    SET LOCAL ROLE postgres;
    IF COALESCE((v_result ->> 'already_acked')::boolean, false) = true THEN
      INSERT INTO ep_batch_results VALUES ('B-T10 ack idempotent', 'PASS', NULL);
    ELSE
      INSERT INTO ep_batch_results VALUES ('B-T10 ack idempotent', 'FAIL', v_result::text);
    END IF;
  ELSE
    INSERT INTO ep_batch_results VALUES ('B-T10 ack then fetch expired', 'FAIL', v_result::text);
  END IF;

  -- B-T11: rate limit 5 lots/h (només lots nous; replay idempotent exempt)
  SET LOCAL ROLE postgres;
  UPDATE data.employee_portal_token_batch_jobs
  SET created_at = now() - interval '2 hours'
  WHERE tenant_id = 'd1000000-0000-0000-0000-000000000001';

  FOR v_i IN 1..5 LOOP
    PERFORM pg_temp.ep_batch_set_manager_jwt();
    v_result := api.start_employee_portal_token_batch(
      p_idempotency_key => 'bt11-rate-' || lpad(v_i::text, 2, '0'),
      p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000001'::uuid]
    );
  END LOOP;

  BEGIN
    PERFORM pg_temp.ep_batch_set_manager_jwt();
    PERFORM api.start_employee_portal_token_batch(
      p_idempotency_key => 'bt11-rate-06',
      p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000001'::uuid]
    );
    SET LOCAL ROLE postgres;
    INSERT INTO ep_batch_results VALUES ('B-T11 sixth batch rate limited', 'FAIL', 'should raise batch_rate_limited');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    SET LOCAL ROLE postgres;
    IF v_err LIKE '%batch_rate_limited%' THEN
      INSERT INTO ep_batch_results VALUES ('B-T11 sixth batch rate limited', 'PASS', NULL);
    ELSE
      INSERT INTO ep_batch_results VALUES ('B-T11 sixth batch rate limited', 'FAIL', v_err);
    END IF;
  END;

  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt11-rate-01',
    p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000001'::uuid]
  );
  SET LOCAL ROLE postgres;
  IF COALESCE((v_result ->> 'idempotent_replay')::boolean, false) = true THEN
    INSERT INTO ep_batch_results VALUES ('B-T11 idempotent replay exempt', 'PASS', NULL);
  ELSE
    INSERT INTO ep_batch_results VALUES ('B-T11 idempotent replay exempt', 'FAIL', v_result::text);
  END IF;

  -- B-T12: portal_url via dev_base_url sense domini SSL
  SET LOCAL ROLE postgres;
  UPDATE data.employee_portal_token_batch_jobs
  SET created_at = now() - interval '2 hours'
  WHERE tenant_id = 'd1000000-0000-0000-0000-000000000001';

  INSERT INTO data.system_settings (module, settings)
  VALUES ('employee_portal', '{"dev_base_url": "http://portal-dev.test"}'::jsonb)
  ON CONFLICT (module) DO UPDATE
    SET settings = data.system_settings.settings || '{"dev_base_url": "http://portal-dev.test"}'::jsonb;

  UPDATE data.public_sites
  SET primary_domain_id = NULL
  WHERE id = 'd6000000-0000-0000-0000-000000000001';

  DELETE FROM data.public_domains
  WHERE public_site_id = 'd6000000-0000-0000-0000-000000000001';

  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt12-no-ssl-key-001',
    p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000002'::uuid],
    p_force_new => true
  );
  v_batch_id := (v_result ->> 'batch_id')::uuid;

  SET LOCAL ROLE postgres;
  SELECT portal_url INTO v_err
  FROM data.employee_portal_token_batch_items
  WHERE batch_job_id = v_batch_id
    AND status = 'created'
  LIMIT 1;

  IF v_err LIKE 'http://portal-dev.test/e/%' THEN
    INSERT INTO ep_batch_results VALUES ('B-T12 portal_url dev fallback', 'PASS', v_err);
  ELSE
    INSERT INTO ep_batch_results VALUES ('B-T12 portal_url dev fallback', 'FAIL', COALESCE(v_err, 'null portal_url'));
  END IF;

  -- B-T13: Sense DNI → skipped, cap token
  SET LOCAL ROLE postgres;
  UPDATE data.employee_portal_token_batch_jobs
  SET created_at = now() - interval '2 hours'
  WHERE tenant_id = 'd1000000-0000-0000-0000-000000000001';

  PERFORM pg_temp.ep_batch_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'bt13-no-doc-key-001',
    p_employee_ids => ARRAY['d5000000-0000-0000-0000-000000000006'::uuid]
  );
  v_batch_id := (v_result ->> 'batch_id')::uuid;

  SET LOCAL ROLE postgres;

  IF EXISTS (
    SELECT 1
    FROM data.employee_portal_token_batch_items i
    WHERE i.batch_job_id = v_batch_id
      AND i.employee_id = 'd5000000-0000-0000-0000-000000000006'
      AND i.status = 'skipped'
      AND i.error_code = 'employee_missing_document_id'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM data.employee_portal_tokens t
    WHERE t.employee_id = 'd5000000-0000-0000-0000-000000000006'
      AND t.is_active = true
      AND t.revoked_at IS NULL
  )
  AND (v_result -> 'summary' ->> 'created')::int = 0 THEN
    INSERT INTO ep_batch_results VALUES ('B-T13 missing document skipped', 'PASS', NULL);
  ELSE
    INSERT INTO ep_batch_results VALUES ('B-T13 missing document skipped', 'FAIL', v_result::text);
  END IF;

EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ep_batch_results VALUES ('EP3b setup', 'ERROR', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM ep_batch_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ep_batch_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'employee_portal_token_batch_tests failed: % cases', v_fail;
  END IF;
END;
$$;

ROLLBACK;
