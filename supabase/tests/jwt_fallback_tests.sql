-- =============================================================================
-- JWT Claims Fallback Tests
-- =============================================================================
-- Cobertura:
--   T1 jwt_user_tenants() usa data.user_permissions_cache si el JWT no porta claim
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- -----------------------------------------------------------------------------
-- T1: fallback cache quan JWT app_metadata.user_tenants no existeix
-- -----------------------------------------------------------------------------
RESET ROLE;

INSERT INTO data.user_permissions_cache (user_id, tenant_data)
VALUES (
  '20000000-0000-0000-0000-000000000003'::uuid,
  '{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"member"}}}'::jsonb
)
ON CONFLICT (user_id) DO UPDATE
  SET tenant_data = EXCLUDED.tenant_data,
      updated_at  = now();

SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_claim jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000003', true);

  -- JWT buit (sense app_metadata.user_tenants)
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000003","app_metadata":{}}',
    true
  );

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT data.jwt_user_tenants() INTO v_claim;

  IF v_claim ? '10000000-0000-0000-0000-000000000001'
     AND (v_claim -> '10000000-0000-0000-0000-000000000001' ->> 'global_role') IS NULL
     AND (v_claim -> '10000000-0000-0000-0000-000000000001' -> 'sites')
         ? '30000000-0000-0000-0000-000000000001'
  THEN
    INSERT INTO test_results VALUES (
      'T1 jwt_user_tenants cache fallback',
      'PASS',
      'Claim loaded from data.user_permissions_cache when JWT claim is missing'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 jwt_user_tenants cache fallback',
      'FAIL',
      format('Unexpected claim payload: %s', v_claim::text)
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
