-- =============================================================================
-- employee_portal_tests.sql — EP1
--
-- Executar:
--   Get-Content supabase/tests/employee_portal_tests.sql -Raw |
--     docker exec -i supabase_db_<project> psql -U postgres -d postgres
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ep_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a1000000-0000-0000-0000-000000000001', 'EP Test Tenant', 'ep-test', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('a2000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'EP Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES ('a3000000-0000-0000-0000-000000000001', 'ep-mgr@test.com', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('a3000000-0000-0000-0000-000000000001', 'ep-mgr@test.com', 'EP Manager')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (
  'a4000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001',
  'a3000000-0000-0000-0000-000000000001',
  'manager',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'a5000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001',
  'a2000000-0000-0000-0000-000000000001',
  NULL,
  'EP Employee',
  'active'
)
ON CONFLICT (id) DO NOTHING;

-- EP1-T1
DO $$
DECLARE
  v_result jsonb;
  v_token_id uuid;
  v_hash bytea := decode('aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899', 'hex');
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"a3000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a1000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"a1000000-0000-0000-0000-000000000001"}', true);
  SET LOCAL ROLE authenticated;

  v_result := api.create_employee_portal_token(
    p_employee_id => 'a5000000-0000-0000-0000-000000000001',
    p_token_hash  => v_hash,
    p_label       => 'WhatsApp'
  );
  v_token_id := (v_result ->> 'token_id')::uuid;

  SET LOCAL ROLE postgres;

  IF v_token_id IS NULL THEN
    INSERT INTO ep_test_results VALUES ('EP1-T1 create token', 'FAIL', 'token_id null');
  ELSE
    INSERT INTO ep_test_results VALUES ('EP1-T1 create token', 'PASS', v_token_id::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ep_test_results VALUES ('EP1-T1 create token', 'ERROR', SQLERRM);
END;
$$;

-- EP1-T2
DO $$
DECLARE
  v_hash bytea := decode('bbccddeeff00112233445566778899aabbccddeeff00112233445566778899aa', 'hex');
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"a3000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a1000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
    true
  );
  SET LOCAL ROLE authenticated;

  BEGIN
    PERFORM api.create_employee_portal_token(
      p_employee_id => 'a5000000-0000-0000-0000-000000000001',
      p_token_hash  => v_hash,
      p_label       => 'WhatsApp'
    );
    SET LOCAL ROLE postgres;
    INSERT INTO ep_test_results VALUES ('EP1-T2 duplicate label', 'FAIL', 'expected unique_violation');
  EXCEPTION
    WHEN unique_violation OR OTHERS THEN
      SET LOCAL ROLE postgres;
      IF SQLERRM ILIKE '%duplicate_active_label%' OR SQLSTATE = '23505' THEN
        INSERT INTO ep_test_results VALUES ('EP1-T2 duplicate label', 'PASS', SQLERRM);
      ELSE
        INSERT INTO ep_test_results VALUES ('EP1-T2 duplicate label', 'FAIL', SQLERRM);
      END IF;
  END;
END;
$$;

-- EP1-T3
DO $$
DECLARE
  v_token_id uuid;
  v_before integer;
  v_after integer;
  v_result jsonb;
BEGIN
  SELECT id, session_version
  INTO v_token_id, v_before
  FROM data.employee_portal_tokens
  WHERE employee_id = 'a5000000-0000-0000-0000-000000000001'
    AND label = 'WhatsApp'
  LIMIT 1;

  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"a3000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a1000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
    true
  );
  SET LOCAL ROLE authenticated;

  v_result := api.revoke_employee_portal_token(
    p_token_id => v_token_id,
    p_reason => 'test revoke',
    p_compromised => true
  );
  v_after := (v_result ->> 'session_version')::integer;

  SET LOCAL ROLE postgres;

  IF v_after = v_before + 1 AND (v_result ->> 'compromised')::boolean IS TRUE THEN
    INSERT INTO ep_test_results VALUES ('EP1-T3 revoke session_version', 'PASS', v_before || ' -> ' || v_after);
  ELSE
    INSERT INTO ep_test_results VALUES ('EP1-T3 revoke session_version', 'FAIL', v_result::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ep_test_results VALUES ('EP1-T3 revoke session_version', 'ERROR', SQLERRM);
END;
$$;

-- EP1-T4
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'data'
      AND t.relname = 'time_punches'
      AND c.conname = 'time_punches_source_check'
      AND pg_get_constraintdef(c.oid) LIKE '%portal%'
  ) THEN
    INSERT INTO ep_test_results VALUES ('EP1-T4 portal source enum', 'PASS', 'constraint includes portal');
  ELSE
    INSERT INTO ep_test_results VALUES ('EP1-T4 portal source enum', 'FAIL', 'portal missing from check');
  END IF;
END;
$$;

-- EP1-T5
DO $$
DECLARE
  v_hash bytea := decode('ccddeeff00112233445566778899aabbccddeeff00112233445566778899aabb', 'hex');
  v_list jsonb;
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"a3000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a1000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
    true
  );
  SET LOCAL ROLE authenticated;

  PERFORM api.create_employee_portal_token(
    p_employee_id => 'a5000000-0000-0000-0000-000000000001',
    p_token_hash  => v_hash,
    p_label       => 'QR vestuari'
  );
  v_list := api.list_employee_portal_tokens('a5000000-0000-0000-0000-000000000001');

  SET LOCAL ROLE postgres;

  IF v_list::text ILIKE '%token_hash%' THEN
    INSERT INTO ep_test_results VALUES ('EP1-T5 list tokens', 'FAIL', 'token_hash leaked');
  ELSIF jsonb_array_length(v_list) < 1 THEN
    INSERT INTO ep_test_results VALUES ('EP1-T5 list tokens', 'FAIL', 'empty list');
  ELSE
    INSERT INTO ep_test_results VALUES ('EP1-T5 list tokens', 'PASS', jsonb_array_length(v_list)::text || ' rows');
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ep_test_results VALUES ('EP1-T5 list tokens', 'ERROR', SQLERRM);
END;
$$;

-- EP-TL1 — audit create/revoke apunta a l'empleat (timeline)
DO $$
DECLARE
  v_token_id uuid;
  v_created_ok boolean;
  v_revoked_ok boolean;
BEGIN
  SELECT id INTO v_token_id
  FROM data.employee_portal_tokens
  WHERE employee_id = 'a5000000-0000-0000-0000-000000000001'
    AND label = 'QR vestuari'
  LIMIT 1;

  SELECT EXISTS (
    SELECT 1 FROM data.audit_logs al
    WHERE al.action = 'EMPLOYEE_PORTAL_TOKEN_CREATED'
      AND al.entity_type = 'employee'
      AND al.entity_id = 'a5000000-0000-0000-0000-000000000001'
      AND al.payload ->> 'token_id' = v_token_id::text
  ) INTO v_created_ok;

  SELECT EXISTS (
    SELECT 1 FROM data.audit_logs al
    WHERE al.action = 'EMPLOYEE_PORTAL_TOKEN_REVOKED'
      AND al.entity_type = 'employee'
      AND al.entity_id = 'a5000000-0000-0000-0000-000000000001'
      AND al.payload ->> 'token_id' = (
        SELECT id::text FROM data.employee_portal_tokens
        WHERE label = 'WhatsApp' LIMIT 1
      )
  ) INTO v_revoked_ok;

  IF v_created_ok AND v_revoked_ok THEN
    INSERT INTO ep_test_results VALUES ('EP-TL1 audit on employee timeline', 'PASS', 'create+revoke');
  ELSE
    INSERT INTO ep_test_results VALUES (
      'EP-TL1 audit on employee timeline',
      'FAIL',
      'created=' || v_created_ok::text || ' revoked=' || v_revoked_ok::text
    );
  END IF;
END;
$$;

-- EP-TL2 — primer accés: first_accessed_at + audit EMPLOYEE_PORTAL_FIRST_ACCESS
DO $$
DECLARE
  v_token_id uuid;
  v_first timestamptz;
  v_audit_ok boolean;
BEGIN
  SELECT id INTO v_token_id
  FROM data.employee_portal_tokens
  WHERE employee_id = 'a5000000-0000-0000-0000-000000000001'
    AND label = 'QR vestuari'
  LIMIT 1;

  PERFORM api.log_employee_portal_access_event(
    p_token_id => v_token_id,
    p_employee_id => 'a5000000-0000-0000-0000-000000000001',
    p_tenant_id => 'a1000000-0000-0000-0000-000000000001',
    p_action => 'session_create',
    p_http_status => 200::smallint
  );

  SELECT first_accessed_at INTO v_first
  FROM data.employee_portal_tokens
  WHERE id = v_token_id;

  SELECT EXISTS (
    SELECT 1 FROM data.audit_logs al
    WHERE al.action = 'EMPLOYEE_PORTAL_FIRST_ACCESS'
      AND al.entity_type = 'employee'
      AND al.entity_id = 'a5000000-0000-0000-0000-000000000001'
  ) INTO v_audit_ok;

  IF v_first IS NOT NULL AND v_audit_ok THEN
    INSERT INTO ep_test_results VALUES ('EP-TL2 first access tracking', 'PASS', v_first::text);
  ELSE
    INSERT INTO ep_test_results VALUES (
      'EP-TL2 first access tracking',
      'FAIL',
      'first=' || coalesce(v_first::text, 'null') || ' audit=' || v_audit_ok::text
    );
  END IF;
END;
$$;

SELECT * FROM ep_test_results ORDER BY test_name;

ROLLBACK;
