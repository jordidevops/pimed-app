-- =============================================================================
-- RLS Tests
-- =============================================================================
-- Cobertura:
--   T1 Charlie site-only isolation (notes)
--   T2 Dave can create site note, Eve cannot
--   T3 Alice multi-tenant global visibility
--   T4 Frank can manage own site but not tenant-global config
--   T5 Eve site-only can see tenant-global calendar events
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- -----------------------------------------------------------------------------
-- T1: Charlie site-only isolation (notes)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_gracia_count integer;
  v_sants_count  integer;
  v_beta_count   integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);

  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT COUNT(*) INTO v_gracia_count
  FROM data.notes
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND site_id   = '30000000-0000-0000-0000-000000000001'::uuid;

  SELECT COUNT(*) INTO v_sants_count
  FROM data.notes
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND site_id   = '30000000-0000-0000-0000-000000000002'::uuid;

  SELECT COUNT(*) INTO v_beta_count
  FROM data.notes
  WHERE tenant_id = '10000000-0000-0000-0000-000000000002'::uuid;

  IF v_gracia_count >= 1 AND v_sants_count = 0 AND v_beta_count = 0 THEN
    INSERT INTO test_results VALUES (
      'T1 Charlie site-only isolation (notes)',
      'PASS',
      format('gracia=%s, sants=%s, beta=%s', v_gracia_count, v_sants_count, v_beta_count)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 Charlie site-only isolation (notes)',
      'FAIL',
      format('Expected gracia>=1,sants=0,beta=0; got gracia=%s,sants=%s,beta=%s', v_gracia_count, v_sants_count, v_beta_count)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T2: Dave can create site note, Eve cannot
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_dave_inserted integer := 0;
  v_eve_denied    boolean := false;
BEGIN
  -- Dave (member local) -> pot crear nota del seu site
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);

  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"member"}}}}}',
    true
  );

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO data.notes (tenant_id, created_by, title, content, site_id)
  VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    '20000000-0000-0000-0000-000000000005'::uuid,
    'Test Dave Insert',
    'Dave member should be allowed to create this site note.',
    '30000000-0000-0000-0000-000000000001'::uuid
  );

  GET DIAGNOSTICS v_dave_inserted = ROW_COUNT;

  -- Eve (viewer local) -> NO pot crear nota
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000006', true);

  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000006","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"viewer"}}}}}',
    true
  );

  BEGIN
    INSERT INTO data.notes (tenant_id, created_by, title, content, site_id)
    VALUES (
      '10000000-0000-0000-0000-000000000001'::uuid,
      '20000000-0000-0000-0000-000000000006'::uuid,
      'Test Eve Insert',
      'Eve viewer must be denied.',
      '30000000-0000-0000-0000-000000000001'::uuid
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_eve_denied := true;
  END;

  IF v_dave_inserted = 1 AND v_eve_denied THEN
    INSERT INTO test_results VALUES (
      'T2 Dave create allowed / Eve create denied',
      'PASS',
      format('dave_rows=%s, eve_denied=%s', v_dave_inserted, v_eve_denied)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 Dave create allowed / Eve create denied',
      'FAIL',
      format('Expected dave_rows=1 and eve_denied=true; got dave_rows=%s, eve_denied=%s', v_dave_inserted, v_eve_denied)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T3: Alice multi-tenant global visibility
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_acme_count integer;
  v_beta_count integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);

  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}},"10000000-0000-0000-0000-000000000002":{"global_role":"owner","sites":{}}}}}',
    true
  );

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT COUNT(*) INTO v_acme_count
  FROM data.notes
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND title NOT LIKE 'Test %';

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000002"}', true);

  SELECT COUNT(*) INTO v_beta_count
  FROM data.notes
  WHERE tenant_id = '10000000-0000-0000-0000-000000000002'::uuid;

  IF v_acme_count = 3 AND v_beta_count = 2 THEN
    INSERT INTO test_results VALUES (
      'T3 Alice multi-tenant global visibility',
      'PASS',
      format('acme_notes=%s, beta_notes=%s', v_acme_count, v_beta_count)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 Alice multi-tenant global visibility',
      'FAIL',
      format('Expected acme_notes=3 and beta_notes=2; got acme_notes=%s, beta_notes=%s', v_acme_count, v_beta_count)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T4: Frank can manage own site but not tenant-global config
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_site_update_rows   integer := 0;
  v_tenant_update_rows integer := 0;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000007', true);

  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000007","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000002":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000003":"manager"}}}}}',
    true
  );

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000002"}', true);

  UPDATE data.sites
  SET address = address
  WHERE id = '30000000-0000-0000-0000-000000000003'::uuid;

  GET DIAGNOSTICS v_site_update_rows = ROW_COUNT;

  UPDATE data.tenants
  SET name = name
  WHERE id = '10000000-0000-0000-0000-000000000002'::uuid;

  GET DIAGNOSTICS v_tenant_update_rows = ROW_COUNT;

  IF v_site_update_rows = 1 AND v_tenant_update_rows = 0 THEN
    INSERT INTO test_results VALUES (
      'T4 Frank site-manage allowed / tenant-config denied',
      'PASS',
      format('site_update_rows=%s, tenant_update_rows=%s', v_site_update_rows, v_tenant_update_rows)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T4 Frank site-manage allowed / tenant-config denied',
      'FAIL',
      format('Expected site_update_rows=1 and tenant_update_rows=0; got site_update_rows=%s, tenant_update_rows=%s', v_site_update_rows, v_tenant_update_rows)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T5: Eve site-only can see tenant-global calendar events
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_visible_calendar_count integer;
BEGIN
  -- Seed local deterministic event (tenant-global) to avoid depending on external seed data.
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);

  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO api.calendar_events (
    tenant_id,
    site_id,
    entity_type,
    entity_id,
    title,
    description,
    start_at,
    end_at,
    required_permissions
  ) VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    NULL,
    'test',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1'::uuid,
    'T5 tenant-global visibility event',
    'Deterministic event for RLS test T5',
    now(),
    now() + interval '1 hour',
    '{}'::text[]
  );

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000006', true);

  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000006","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"viewer"}}}}}',
    true
  );

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT COUNT(*) INTO v_visible_calendar_count
  FROM api.calendar_events
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND site_id IS NULL
    AND title = 'T5 tenant-global visibility event';

  IF v_visible_calendar_count >= 1 THEN
    INSERT INTO test_results VALUES (
      'T5 Eve site-only can see tenant-global calendar events',
      'PASS',
      format('visible_calendar_events=%s', v_visible_calendar_count)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T5 Eve site-only can see tenant-global calendar events',
      'FAIL',
      format('Expected visible_calendar_events>=1; got visible_calendar_events=%s', v_visible_calendar_count)
    );
  END IF;
END $$;

SELECT test_name, status, details
FROM test_results
ORDER BY test_name;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS') AS pass_count,
  COUNT(*) FILTER (WHERE status = 'FAIL') AS fail_count,
  COUNT(*)                                 AS total_count
FROM test_results;

ROLLBACK;
