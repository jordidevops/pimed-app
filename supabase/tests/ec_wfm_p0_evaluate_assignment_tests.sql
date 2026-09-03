-- EC-WFM P0 §5 tests — evaluate_employee_assignment
BEGIN;
SET client_min_messages TO WARNING;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END $$;

-- T1: ready (or warning) for Alice on home site
RESET ROLE;
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_site  uuid := '30000000-0000-0000-0000-000000000001';
  v_eval  jsonb;
  v_day   date := CURRENT_DATE + 14;
BEGIN
  -- Prefer a weekday without known absence
  WHILE EXTRACT(ISODOW FROM v_day) IN (6, 7) LOOP
    v_day := v_day + 1;
  END LOOP;

  v_eval := data.evaluate_employee_assignment(
    v_alice, v_site, v_day, time '09:00', time '17:00', NULL, NULL
  );

  INSERT INTO test_results VALUES (
    'T1 ready-or-warning home site',
    CASE WHEN v_eval->>'status' IN ('ready', 'warning') THEN 'PASS' ELSE 'FAIL' END,
    coalesce(v_eval->>'status', 'null') || ' blocks=' || coalesce((v_eval->'blocks')::text, '[]')
  );
END $$;

-- T2: wrong site blocked when contract/flat site set
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_home  uuid;
  v_other uuid := '30000000-0000-0000-0000-000000000002';
  v_eval  jsonb;
  v_day   date := CURRENT_DATE + 21;
BEGIN
  SELECT coalesce(data.employee_effective_site_id(v_alice, v_day), site_id)
  INTO v_home FROM data.employees WHERE id = v_alice;

  IF v_home IS NULL OR v_home = v_other THEN
    INSERT INTO test_results VALUES ('T2 wrong site blocked', 'PASS', 'skipped_no_home_divergence');
    RETURN;
  END IF;

  v_eval := data.evaluate_employee_assignment(
    v_alice, v_other, v_day, time '09:00', time '13:00', NULL, NULL
  );

  INSERT INTO test_results VALUES (
    'T2 wrong site blocked',
    CASE WHEN v_eval->>'status' = 'blocked'
              AND EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_eval->'blocks') b
                WHERE b->>'code' = 'employee_wrong_site'
              )
         THEN 'PASS' ELSE 'FAIL' END,
    coalesce(v_eval->>'status', 'null') || ' ' || coalesce((v_eval->'blocks')::text, '[]')
  );
END $$;

-- T3: absence blocks
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_site   uuid;
  v_day    date := CURRENT_DATE + 30;
  v_abs    uuid;
  v_eval   jsonb;
BEGIN
  SELECT coalesce(data.employee_effective_site_id(v_alice, v_day), site_id)
  INTO v_site FROM data.employees WHERE id = v_alice;

  INSERT INTO data.employee_absences (
    tenant_id, employee_id, absence_type, start_date, end_date, status
  ) VALUES (
    v_tenant, v_alice, 'vacation', v_day, v_day, 'approved'
  ) RETURNING id INTO v_abs;

  v_eval := data.evaluate_employee_assignment(
    v_alice, v_site, v_day, time '09:00', time '17:00', NULL, NULL
  );

  INSERT INTO test_results VALUES (
    'T3 absence blocks',
    CASE WHEN v_eval->>'status' = 'blocked'
              AND EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_eval->'blocks') b
                WHERE b->>'code' = 'employee_on_absence'
              )
         THEN 'PASS' ELSE 'FAIL' END,
    coalesce(v_eval->>'status', 'null') || ' ' || coalesce((v_eval->'blocks')::text, '[]')
  );

  DELETE FROM data.employee_absences WHERE id = v_abs;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 absence blocks', 'FAIL', SQLERRM)
  ON CONFLICT (test_name) DO UPDATE SET status = 'FAIL', details = EXCLUDED.details;
  BEGIN
    DELETE FROM data.employee_absences WHERE id = v_abs;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
END $$;

-- T4: overlap warns (soft, matching assign_shift_slot anomaly behavior)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_site   uuid;
  v_day    date := CURRENT_DATE + 40;
  v_shift  uuid;
  v_slot   uuid;
  v_eval   jsonb;
  v_created boolean := false;
BEGIN
  WHILE EXTRACT(ISODOW FROM v_day) IN (6, 7) LOOP
    v_day := v_day + 1;
  END LOOP;

  SELECT coalesce(data.employee_effective_site_id(v_alice, v_day), site_id)
  INTO v_site FROM data.employees WHERE id = v_alice;

  SELECT id INTO v_shift
  FROM data.work_shifts
  WHERE tenant_id = v_tenant AND is_active
  ORDER BY created_at NULLS LAST
  LIMIT 1;

  IF v_shift IS NULL THEN
    INSERT INTO data.work_shifts (
      tenant_id, site_id, name, start_time, end_time, is_active
    ) VALUES (
      v_tenant, v_site, 'EC-WFM-P05-SHIFT', time '09:00', time '17:00', true
    ) RETURNING id INTO v_shift;
    v_created := true;
  END IF;

  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, created_by
  ) VALUES (
    v_tenant, v_site, v_alice, v_shift, v_day, 'draft',
    time '09:00', time '17:00', '20000000-0000-0000-0000-000000000002'
  ) RETURNING id INTO v_slot;

  v_eval := data.evaluate_employee_assignment(
    v_alice, v_site, v_day, time '10:00', time '14:00', NULL, NULL
  );

  INSERT INTO test_results VALUES (
    'T4 overlap warns',
    CASE WHEN v_eval->>'status' IN ('warning', 'blocked')
              AND EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_eval->'warnings') b
                WHERE b->>'code' = 'SHIFT_OVERLAP'
              )
         THEN 'PASS' ELSE 'FAIL' END,
    coalesce(v_eval->>'status', 'null') || ' ' || coalesce((v_eval->'warnings')::text, '[]')
  );

  DELETE FROM data.shift_slots WHERE id = v_slot;
  IF v_created THEN
    DELETE FROM data.work_shifts WHERE id = v_shift;
  END IF;
END $$;

-- T5: api wrapper as owner
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_site  uuid := '30000000-0000-0000-0000-000000000001';
  v_day   date := CURRENT_DATE + 14;
  v_starts timestamptz;
  v_ends   timestamptz;
  v_eval   jsonb;
BEGIN
  WHILE EXTRACT(ISODOW FROM v_day) IN (6, 7) LOOP
    v_day := v_day + 1;
  END LOOP;

  v_starts := (v_day::text || ' 09:00')::timestamp AT TIME ZONE 'Europe/Madrid';
  v_ends   := (v_day::text || ' 17:00')::timestamp AT TIME ZONE 'Europe/Madrid';

  v_eval := api.evaluate_employee_assignment(v_alice, v_site, v_starts, v_ends, NULL);

  INSERT INTO test_results VALUES (
    'T5 api evaluate as owner',
    CASE WHEN v_eval->>'resolver_version' IN ('ec_wfm_p1_v1', 'ec_wfm_p0_v1')
              AND v_eval->>'status' IS NOT NULL
         THEN 'PASS' ELSE 'FAIL' END,
    coalesce(v_eval->>'status', 'null') || ' ' || coalesce(v_eval->>'resolver_version', '?')
  );
END $$;

-- T6: assign_shift_slot surfaces evaluation on success path
RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_site   uuid;
  v_day    date := CURRENT_DATE + 50;
  v_shift  uuid;
  v_res    jsonb;
BEGIN
  WHILE EXTRACT(ISODOW FROM v_day) IN (6, 7) LOOP
    v_day := v_day + 1;
  END LOOP;

  SELECT coalesce(data.employee_effective_site_id(v_alice, v_day), site_id)
  INTO v_site FROM data.employees WHERE id = v_alice;

  -- Clear absences / slots that day
  DELETE FROM data.shift_slots
  WHERE employee_id = v_alice AND slot_date = v_day;
  DELETE FROM data.employee_absences
  WHERE employee_id = v_alice
    AND start_date <= v_day AND coalesce(end_date, start_date) >= v_day
    AND status IN ('approved', 'active', 'closed');

  INSERT INTO data.work_shifts (
    tenant_id, site_id, name, start_time, end_time, is_active
  ) VALUES (
    v_tenant, v_site, 'EC-WFM-P05-ASG', time '08:00', time '12:00', true
  ) RETURNING id INTO v_shift;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SET LOCAL ROLE authenticated;
  v_res := api.assign_shift_slot(v_alice, v_day, v_shift, 'p05-test', NULL, NULL);
  RESET ROLE;

  INSERT INTO test_results VALUES (
    'T6 assign returns evaluation',
    CASE WHEN v_res ? 'slot_id'
              AND v_res->'evaluation'->>'resolver_version' IN ('ec_wfm_p1_v1', 'ec_wfm_p0_v1')
         THEN 'PASS' ELSE 'FAIL' END,
    coalesce(v_res::text, 'null')
  );

  DELETE FROM data.shift_slots WHERE id = (v_res->>'slot_id')::uuid;
  DELETE FROM data.work_shifts WHERE id = v_shift;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO test_results VALUES ('T6 assign returns evaluation', 'FAIL', SQLERRM)
  ON CONFLICT (test_name) DO UPDATE SET status = 'FAIL', details = EXCLUDED.details;
  DELETE FROM data.work_shifts WHERE name = 'EC-WFM-P05-ASG' AND tenant_id = v_tenant;
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'EC-WFM P0 §5: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EC-WFM P0 §5 tests failed';
  END IF;
END $$;

ROLLBACK;

