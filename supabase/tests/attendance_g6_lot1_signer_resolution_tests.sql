-- Track G6 Lot 1 — resolve_employee_signer_email RPC
BEGIN;

CREATE TEMP TABLE g6_lot1_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION g6_lot1_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO g6_lot1_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

DO $$
DECLARE
  v_tenant    uuid := '10000000-0000-0000-0000-000000000001';
  v_site      uuid := '30000000-0000-0000-0000-000000000001';
  v_employee  uuid := '40000000-0000-0000-0000-000000000001';
  v_manager   uuid := '20000000-0000-0000-0000-000000000004';
  v_email     text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    format(
      '{"sub":"%s","app_metadata":{"user_tenants":{"%s":{"global_role":"manager","sites":{"%s":"manager"}}},"user_permissions":{"%s":{"global_permissions":["attendance.manage"],"sites":{"%s":{"permissions":["attendance.manage"]}}}}}}',
      v_manager, v_tenant, v_site, v_tenant, v_site
    ),
    true
  );

  -- T1: HR email on employee record
  UPDATE data.employees
  SET email = 'empleat.hr@example.com'
  WHERE id = v_employee;

  v_email := api.resolve_employee_signer_email(v_employee);
  PERFORM g6_lot1_assert(v_email = 'empleat.hr@example.com', 'prefers HR email');

  -- T2: fallback to profile when HR email empty
  UPDATE data.employees
  SET email = NULL
  WHERE id = v_employee;

  UPDATE data.profiles
  SET email = 'portal.user@example.com'
  WHERE id = (SELECT user_id FROM data.employees WHERE id = v_employee);

  v_email := api.resolve_employee_signer_email(v_employee);
  PERFORM g6_lot1_assert(v_email = 'portal.user@example.com', 'falls back to profile email');
END;
$$;

SELECT msg FROM g6_lot1_test_log ORDER BY id;

ROLLBACK;
