-- =============================================================================
-- REC-0…3 P2 tests
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
  v_app1 jsonb;
  v_app2 jsonb;
  v_cnt int;
  v_key text;
  v_has_priv boolean;
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
    VALUES (v_tenant, 'rec03-p2-site', 'REC03 P2', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  -- 1) published without public site rejected
  BEGIN
    INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
    VALUES (
      v_tenant, 'No site', 'rec03-p2-nosite-' || substr(gen_random_uuid()::text, 1, 8),
      'published', v_owner
    );
    INSERT INTO test_results VALUES ('published_requires_site', 'FAIL', 'expected error');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%public_site_required%' OR SQLSTATE = '23514' THEN
      INSERT INTO test_results VALUES ('published_requires_site', 'PASS', SQLERRM);
    ELSE
      INSERT INTO test_results VALUES ('published_requires_site', 'FAIL', SQLERRM);
    END IF;
  END;

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by)
  VALUES (
    v_tenant, 'REC03 P2', 'rec03-p2-' || substr(gen_random_uuid()::text, 1, 8),
    'draft', v_owner
  ) RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;
  INSERT INTO test_results VALUES ('publish_with_site_ok', 'PASS', NULL);

  -- 2) flag off → RLS blocks select as authenticated
  UPDATE data.tenant_feature_overrides
  SET override_status = false
  WHERE tenant_id = v_tenant AND feature_key = 'recruitment_enabled';

  PERFORM pg_temp.set_owner_jwt();
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_cnt FROM data.job_postings WHERE id = v_posting;
  RESET ROLE;

  IF v_cnt = 0 THEN
    INSERT INTO test_results VALUES ('flag_off_blocks_rls', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('flag_off_blocks_rls', 'FAIL', v_cnt::text);
  END IF;

  UPDATE data.tenant_feature_overrides
  SET override_status = true
  WHERE tenant_id = v_tenant AND feature_key = 'recruitment_enabled';

  -- 3) erasure_hmac_key not selectable by authenticated (column privilege)
  SELECT has_column_privilege('authenticated', 'data.recruitment_settings', 'erasure_hmac_key', 'SELECT')
  INTO v_has_priv;
  IF NOT COALESCE(v_has_priv, true) THEN
    INSERT INTO test_results VALUES ('hmac_key_no_select_grant', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('hmac_key_no_select_grant', 'FAIL', 'still granted');
  END IF;

  -- 4) idempotency key returns same application
  PERFORM pg_temp.set_owner_jwt();
  v_key := 'idem-rec03-p2-' || gen_random_uuid()::text;
  v_app1 := api.submit_job_application(
    v_ps, v_posting, v_key,
    'Idem Cand', 'idem.rec03p2@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  v_app2 := api.submit_job_application(
    v_ps, v_posting, v_key,
    'Idem Cand', 'idem.rec03p2@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, 'orphan-cv-path', 'v1', true, 'ca', NULL
  );

  IF (v_app1->>'application_id') = (v_app2->>'application_id')
     AND COALESCE((v_app2->>'duplicate')::boolean, false) THEN
    INSERT INTO test_results VALUES ('submit_idempotency_key', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'submit_idempotency_key', 'FAIL',
      format('%s / %s', v_app1, v_app2)
    );
  END IF;

  -- 5) pgcrypto path: hmac works
  BEGIN
    PERFORM data.applicant_email_hmac(v_tenant, 'hmac.test@example.com');
    INSERT INTO test_results VALUES ('pgcrypto_hmac_ok', 'PASS', NULL);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('pgcrypto_hmac_ok', 'FAIL', SQLERRM);
  END;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('setup_or_rpc', 'FAIL', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM test_results WHERE status = 'FAIL') THEN
    RAISE EXCEPTION 'recruitment_rec03_p2_tests failed';
  END IF;
END;
$$;

ROLLBACK;
