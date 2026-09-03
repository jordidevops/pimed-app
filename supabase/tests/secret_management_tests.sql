-- =============================================================================
-- Secret management — tests bàsics de seguretat
-- Executar amb: psql ... -f supabase/tests/secret_management_tests.sql
-- =============================================================================

BEGIN;

-- Setup: assumim service_role via SET ROLE o execució com a superuser en local
-- Aquests tests són orientatius per CI local.

DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM data.platform_secret_registry;
  IF v_count < 10 THEN
    RAISE EXCEPTION 'platform_secret_registry seed missing (count=%)', v_count;
  END IF;
  RAISE NOTICE 'OK: platform_secret_registry has % rows', v_count;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.notification_event_catalog
    WHERE event_code = 'SECRET_ROTATION_DUE'
  ) THEN
    RAISE EXCEPTION 'SECRET_ROTATION_DUE event missing from catalog';
  END IF;
  RAISE NOTICE 'OK: SECRET_ROTATION_DUE in notification catalog';
END;
$$;

-- get_tenant_secret must not be granted to authenticated
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.routine_privileges
    WHERE routine_schema = 'api'
      AND routine_name = 'get_tenant_secret'
      AND grantee = 'authenticated'
  ) THEN
    RAISE EXCEPTION 'get_tenant_secret must not be granted to authenticated';
  END IF;
  RAISE NOTICE 'OK: get_tenant_secret not granted to authenticated';
END;
$$;

ROLLBACK;
