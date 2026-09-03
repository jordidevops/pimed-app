-- =============================================================================
-- Quota + Atomicity Tests
-- =============================================================================
-- Cobertura:
--   T1 Site quota trigger (enforce_site_quota)
--   T2 provision_tenant atomicity (slug duplicat)
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- -----------------------------------------------------------------------------
-- T1: Site quota trigger (Beta Free max_sites=1)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_sqlstate text;
  v_message  text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);

  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000002":{"global_role":"owner","sites":{}}}}}',
    true
  );

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000002"}', true);

  BEGIN
    INSERT INTO data.sites (tenant_id, name, is_active)
    VALUES (
      '10000000-0000-0000-0000-000000000002'::uuid,
      'Beta Overflow Site',
      true
    );

    INSERT INTO test_results VALUES (
      'T1 site quota trigger',
      'FAIL',
      'Expected quota exception, but INSERT succeeded'
    );
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS
        v_sqlstate = RETURNED_SQLSTATE,
        v_message  = MESSAGE_TEXT;

      IF v_sqlstate = 'P0001' AND v_message LIKE 'quota_exceeded:%' THEN
        INSERT INTO test_results VALUES (
          'T1 site quota trigger',
          'PASS',
          format('Raised expected quota exception (%s: %s)', v_sqlstate, v_message)
        );
      ELSE
        INSERT INTO test_results VALUES (
          'T1 site quota trigger',
          'FAIL',
          format('Unexpected exception (%s: %s)', v_sqlstate, v_message)
        );
      END IF;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- T2: provision_tenant atomicity
--   slug duplicat ha de fallar i no deixar sites orfes
-- -----------------------------------------------------------------------------
RESET ROLE;

DO $$
DECLARE
  v_before integer;
  v_after  integer;
  v_sqlstate text;
BEGIN
  SELECT COUNT(*) INTO v_before FROM data.sites;

  BEGIN
    PERFORM data.provision_tenant(
      'Acme Duplicate Tenant',
      'acme-corp', -- slug existent
      '00000000-0000-0000-0000-000000000001'::uuid
    );

    INSERT INTO test_results VALUES (
      'T2 provision_tenant atomicity',
      'FAIL',
      'Expected unique_violation, but function succeeded'
    );
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      SELECT COUNT(*) INTO v_after FROM data.sites;

      IF v_sqlstate = '23505' AND v_after = v_before THEN
        INSERT INTO test_results VALUES (
          'T2 provision_tenant atomicity',
          'PASS',
          format('unique_violation and no side effects (sites before=%s after=%s)', v_before, v_after)
        );
      ELSE
        INSERT INTO test_results VALUES (
          'T2 provision_tenant atomicity',
          'FAIL',
          format('sqlstate=%s, sites before=%s after=%s', v_sqlstate, v_before, v_after)
        );
      END IF;
  END;
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
