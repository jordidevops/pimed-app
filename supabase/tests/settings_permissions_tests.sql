-- =============================================================================
-- Settings + Role Permissions Tests
-- =============================================================================
-- Cobertura:
--   T1  Owner pot editar setting tenant-scoped
--   T2  Manager local NO pot editar setting tenant-scoped
--   T3  Manager local pot editar setting site-scoped del seu site
--   T4  Member local NO pot editar setting site-scoped
--   T5  Manager local NO pot editar setting owner_only (site)
--   T6  Owner global pot editar setting owner_only (site)
--   T7  Scope mismatch: clau tenant escrita a scope site -> error explícit
--   T8  Viewer pot editar settings propis (scope user)
--   T9  User scope rebutja clau tenant-scoped
--   T10 get_effective_settings mergeja system || tenant || site || user
--   T11 get_effective_settings NO permet llegir settings d'un altre usuari
--   T12 get_tenant_role_permissions accessible per membre site-only
--   T13 update_tenant_role_permissions és owner-only
--   T14 update_tenant_role_permissions valida claus de permís
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- Seed deterministic membership required by user-scope tests (T8/T9/T11/T12)
DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );

  UPDATE data.tenant_members
  SET role = 'viewer',
      is_active = true
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND user_id   = '20000000-0000-0000-0000-000000000006'::uuid
    AND site_id   = '30000000-0000-0000-0000-000000000001'::uuid;

  IF NOT FOUND THEN
    INSERT INTO data.tenant_members (
      tenant_id,
      user_id,
      site_id,
      role,
      is_active
    ) VALUES (
      '10000000-0000-0000-0000-000000000001'::uuid,
      '20000000-0000-0000-0000-000000000006'::uuid,
      '30000000-0000-0000-0000-000000000001'::uuid,
      'viewer',
      true
    );
  END IF;

  -- update_my_member_settings requereix la fila de membresia global (site_id IS NULL)
  UPDATE data.tenant_members
  SET role = 'viewer',
      is_active = true
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND user_id   = '20000000-0000-0000-0000-000000000006'::uuid
    AND site_id IS NULL;

  IF NOT FOUND THEN
    INSERT INTO data.tenant_members (
      tenant_id,
      user_id,
      site_id,
      role,
      is_active
    ) VALUES (
      '10000000-0000-0000-0000-000000000001'::uuid,
      '20000000-0000-0000-0000-000000000006'::uuid,
      NULL,
      'viewer',
      true
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T1: Owner pot editar setting tenant-scoped
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_value text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );

  PERFORM api.update_tenant_settings(
    '{"default_language":"es"}'::jsonb,
    '10000000-0000-0000-0000-000000000001'::uuid
  );

  SELECT settings ->> 'default_language'
  INTO v_value
  FROM data.tenants
  WHERE id = '10000000-0000-0000-0000-000000000001'::uuid;

  IF v_value = 'es' THEN
    INSERT INTO test_results VALUES ('T1 owner update tenant setting', 'PASS', 'default_language updated to es');
  ELSE
    INSERT INTO test_results VALUES ('T1 owner update tenant setting', 'FAIL', format('Expected es, got %s', COALESCE(v_value, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T2: Manager local NO pot editar setting tenant-scoped
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_denied   boolean := false;
  v_message  text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );

  BEGIN
    PERFORM api.update_tenant_settings(
      '{"default_language":"en"}'::jsonb,
      '10000000-0000-0000-0000-000000000001'::uuid
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_denied := true;
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
  END;

  IF v_denied AND v_message LIKE 'Insufficient permission%' THEN
    INSERT INTO test_results VALUES ('T2 local manager denied tenant setting', 'PASS', v_message);
  ELSE
    INSERT INTO test_results VALUES ('T2 local manager denied tenant setting', 'FAIL', format('Expected insufficient permission, got denied=%s message=%s', v_denied, COALESCE(v_message, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T3: Manager local pot editar setting site-scoped del seu site
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_value text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );

  PERFORM api.update_site_settings(
    '30000000-0000-0000-0000-000000000001'::uuid,
    '{"site_language":"es"}'::jsonb
  );

  SELECT settings ->> 'site_language'
  INTO v_value
  FROM data.sites
  WHERE id = '30000000-0000-0000-0000-000000000001'::uuid;

  IF v_value = 'es' THEN
    INSERT INTO test_results VALUES ('T3 local manager update site setting', 'PASS', 'site_language updated to es');
  ELSE
    INSERT INTO test_results VALUES ('T3 local manager update site setting', 'FAIL', format('Expected es, got %s', COALESCE(v_value, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T4: Member local NO pot editar setting site-scoped
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_denied  boolean := false;
  v_message text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"member"}}}}}',
    true
  );

  BEGIN
    PERFORM api.update_site_settings(
      '30000000-0000-0000-0000-000000000001'::uuid,
      '{"site_language":"ca"}'::jsonb
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_denied := true;
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
  END;

  IF v_denied AND v_message LIKE 'Insufficient permission%' THEN
    INSERT INTO test_results VALUES ('T4 local member denied site setting', 'PASS', v_message);
  ELSE
    INSERT INTO test_results VALUES ('T4 local member denied site setting', 'FAIL', format('Expected insufficient permission, got denied=%s message=%s', v_denied, COALESCE(v_message, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T5: Manager local NO pot editar setting owner_only (site)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_denied  boolean := false;
  v_message text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );

  BEGIN
    PERFORM api.update_site_settings(
      '30000000-0000-0000-0000-000000000001'::uuid,
      '{"site_archived":true}'::jsonb
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_denied := true;
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
  END;

  IF v_denied AND v_message LIKE 'Setting key % requires owner role%' THEN
    INSERT INTO test_results VALUES ('T5 local manager denied owner-only site key', 'PASS', v_message);
  ELSE
    INSERT INTO test_results VALUES ('T5 local manager denied owner-only site key', 'FAIL', format('Expected owner-only denial, got denied=%s message=%s', v_denied, COALESCE(v_message, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T6: Owner global pot editar setting owner_only (site)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_value text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );

  PERFORM api.update_site_settings(
    '30000000-0000-0000-0000-000000000001'::uuid,
    '{"site_archived":true}'::jsonb
  );

  SELECT settings ->> 'site_archived'
  INTO v_value
  FROM data.sites
  WHERE id = '30000000-0000-0000-0000-000000000001'::uuid;

  IF v_value = 'true' THEN
    INSERT INTO test_results VALUES ('T6 owner update owner-only site key', 'PASS', 'site_archived updated to true');
  ELSE
    INSERT INTO test_results VALUES ('T6 owner update owner-only site key', 'FAIL', format('Expected true, got %s', COALESCE(v_value, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T7: Scope mismatch site write amb clau tenant-scoped
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_denied  boolean := false;
  v_message text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );

  BEGIN
    PERFORM api.update_site_settings(
      '30000000-0000-0000-0000-000000000001'::uuid,
      '{"default_language":"en"}'::jsonb
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_denied := true;
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
  END;

  IF v_denied AND v_message LIKE 'Setting key default_language cannot be written at scope site%' THEN
    INSERT INTO test_results VALUES ('T7 scope mismatch tenant key at site scope', 'PASS', v_message);
  ELSE
    INSERT INTO test_results VALUES ('T7 scope mismatch tenant key at site scope', 'FAIL', format('Expected explicit scope mismatch, got denied=%s message=%s', v_denied, COALESCE(v_message, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T8: Viewer pot editar els seus settings de scope user
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_value     text;
  v_effective jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000006', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000006","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"viewer"}}}}}',
    true
  );

  PERFORM api.update_my_member_settings(
    '{"theme":"solarized"}'::jsonb,
    '10000000-0000-0000-0000-000000000001'::uuid
  );

  SELECT api.get_effective_settings(
    NULL,
    '20000000-0000-0000-0000-000000000006'::uuid,
    '10000000-0000-0000-0000-000000000001'::uuid
  ) INTO v_effective;

  v_value := v_effective ->> 'theme';

  IF v_value = 'solarized' THEN
    INSERT INTO test_results VALUES ('T8 viewer update own user settings', 'PASS', 'theme updated to solarized');
  ELSE
    INSERT INTO test_results VALUES ('T8 viewer update own user settings', 'FAIL', format('Expected solarized, got %s', COALESCE(v_value, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T9: User scope rebutja clau tenant-scoped
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_denied  boolean := false;
  v_message text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000006', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000006","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"viewer"}}}}}',
    true
  );

  BEGIN
    PERFORM api.update_my_member_settings(
      '{"default_language":"en"}'::jsonb,
      '10000000-0000-0000-0000-000000000001'::uuid
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_denied := true;
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
  END;

  IF v_denied AND v_message LIKE 'Setting key default_language cannot be written at scope user%' THEN
    INSERT INTO test_results VALUES ('T9 user scope rejects tenant key', 'PASS', v_message);
  ELSE
    INSERT INTO test_results VALUES ('T9 user scope rejects tenant key', 'FAIL', format('Expected user scope mismatch, got denied=%s message=%s', v_denied, COALESCE(v_message, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T10: get_effective_settings merge (system || tenant || site || user)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_effective jsonb;
BEGIN
  -- Charlie: manager local Acme Gracia
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );

  SELECT api.get_effective_settings(
    '30000000-0000-0000-0000-000000000001'::uuid,
    '20000000-0000-0000-0000-000000000004'::uuid,
    '10000000-0000-0000-0000-000000000001'::uuid
  ) INTO v_effective;

  IF v_effective ->> 'default_event_start_time' = '08:30'
     AND v_effective ->> 'site_language' = 'es'
     AND v_effective ->> 'theme' = 'light'
  THEN
    INSERT INTO test_results VALUES (
      'T10 effective settings merge order',
      'PASS',
      format('default_event_start_time=%s site_language=%s theme=%s',
        v_effective ->> 'default_event_start_time',
        v_effective ->> 'site_language',
        v_effective ->> 'theme')
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T10 effective settings merge order',
      'FAIL',
      format('Unexpected effective payload: %s', v_effective::text)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T11: get_effective_settings no permet llegir settings d'un altre usuari
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_denied  boolean := false;
  v_message text;
BEGIN
  -- Eve intenta llegir Bob
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000006', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000006","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"viewer"}}}}}',
    true
  );

  BEGIN
    PERFORM api.get_effective_settings(
      NULL,
      '20000000-0000-0000-0000-000000000003'::uuid,
      '10000000-0000-0000-0000-000000000001'::uuid
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_denied := true;
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
  END;

  IF v_denied AND v_message LIKE 'Cannot read settings for another user%' THEN
    INSERT INTO test_results VALUES ('T11 deny reading another user settings', 'PASS', v_message);
  ELSE
    INSERT INTO test_results VALUES ('T11 deny reading another user settings', 'FAIL', format('Expected denial, got denied=%s message=%s', v_denied, COALESCE(v_message, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T12: get_tenant_role_permissions accessible per membre site-only
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_payload jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000006', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000006","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"viewer"}}}}}',
    true
  );

  SELECT api.get_tenant_role_permissions('10000000-0000-0000-0000-000000000001'::uuid)
  INTO v_payload;

  IF v_payload ? 'defaults' AND v_payload ? 'effective' THEN
    INSERT INTO test_results VALUES ('T12 get_tenant_role_permissions for site-only member', 'PASS', 'defaults/effective returned');
  ELSE
    INSERT INTO test_results VALUES ('T12 get_tenant_role_permissions for site-only member', 'FAIL', format('Unexpected payload: %s', v_payload::text));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T13: update_tenant_role_permissions és owner-only
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_denied  boolean := false;
  v_message text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );

  BEGIN
    PERFORM api.update_tenant_role_permissions(
      '{"viewer":["storage.view"]}'::jsonb,
      '10000000-0000-0000-0000-000000000001'::uuid
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_denied := true;
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
  END;

  IF v_denied AND v_message LIKE 'Only tenant owners can modify role permissions%' THEN
    INSERT INTO test_results VALUES ('T13 role permissions owner-only', 'PASS', v_message);
  ELSE
    INSERT INTO test_results VALUES ('T13 role permissions owner-only', 'FAIL', format('Expected owner-only denial, got denied=%s message=%s', v_denied, COALESCE(v_message, '<null>')));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T14: update_tenant_role_permissions valida claus de permís
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_denied  boolean := false;
  v_message text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );

  BEGIN
    PERFORM api.update_tenant_role_permissions(
      '{"viewer":["permission.invalid"]}'::jsonb,
      '10000000-0000-0000-0000-000000000001'::uuid
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_denied := true;
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
  END;

  IF v_denied AND v_message LIKE 'Invalid permission key:%' THEN
    INSERT INTO test_results VALUES ('T14 role permissions invalid key validation', 'PASS', v_message);
  ELSE
    INSERT INTO test_results VALUES ('T14 role permissions invalid key validation', 'FAIL', format('Expected invalid key error, got denied=%s message=%s', v_denied, COALESCE(v_message, '<null>')));
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
