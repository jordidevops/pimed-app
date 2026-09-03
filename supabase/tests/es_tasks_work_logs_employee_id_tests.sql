-- =============================================================================
-- ES-3 — tasks/work_logs employee_id dual-write tests
-- =============================================================================

BEGIN;

SET LOCAL ROLE authenticated;

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
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}},"10000000-0000-0000-0000-000000000002":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_charlie_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

SELECT pg_temp.set_owner_jwt();

-- T1: resolve helper maps Alice user → employee (internal; run as postgres)
RESET ROLE;
DO $$
DECLARE
  v_emp uuid;
BEGIN
  SELECT data.resolve_employee_id_for_user(
    '10000000-0000-0000-0000-000000000001'::uuid,
    '20000000-0000-0000-0000-000000000002'::uuid
  ) INTO v_emp;

  IF v_emp = '40000000-0000-0000-0000-000000000001'::uuid THEN
    INSERT INTO test_results VALUES ('T1 resolve alice', 'PASS', v_emp::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 resolve alice', 'FAIL', coalesce(v_emp::text, 'null'));
  END IF;
END $$;

SET LOCAL ROLE authenticated;
SELECT pg_temp.set_owner_jwt();

-- T2: start_work_log dual-write employee_id (Charlie)
RESET ROLE;
UPDATE data.work_logs
SET status = 'closed', check_out = coalesce(check_out, now())
WHERE worker_id = '20000000-0000-0000-0000-000000000004'
  AND status = 'open';

SET LOCAL ROLE authenticated;
SELECT pg_temp.set_charlie_jwt();

DO $$
DECLARE
  v_project uuid := '51000000-0000-0000-0000-000000000001';
  v_result  jsonb;
  v_log_id  uuid;
  v_emp_id  uuid;
BEGIN
  v_result := api.start_work_log(
    gen_random_uuid(), v_project, NULL, now(), NULL, 'notrequired', 'es3_dual_write'
  );
  v_log_id := (v_result->>'work_log_id')::uuid;

  SELECT employee_id INTO v_emp_id FROM data.work_logs WHERE id = v_log_id;

  IF (v_result->>'status') = 'created'
     AND v_emp_id = '40000000-0000-0000-0000-000000000002'::uuid
     AND (v_result->>'employee_id')::uuid = v_emp_id THEN
    INSERT INTO test_results VALUES ('T2 start_work_log dual-write', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T2 start_work_log dual-write',
      'FAIL',
      format('result=%s emp=%s', v_result::text, coalesce(v_emp_id::text, 'null'))
    );
  END IF;
END $$;

-- T3: task INSERT via api.tasks dual-writes assignee_employee_id
SELECT pg_temp.set_owner_jwt();

DO $$
DECLARE
  v_project uuid := '51000000-0000-0000-0000-000000000001';
  v_task_id uuid;
  v_assignee_emp uuid;
BEGIN
  INSERT INTO api.tasks (tenant_id, project_id, title, status, assignee_id)
  VALUES (
    '10000000-0000-0000-0000-000000000001',
    v_project,
    'ES-3 dual-write task',
    'todo',
    '20000000-0000-0000-0000-000000000004'
  )
  RETURNING id INTO v_task_id;

  SELECT assignee_employee_id INTO v_assignee_emp
  FROM data.tasks WHERE id = v_task_id;

  IF v_assignee_emp = '40000000-0000-0000-0000-000000000002'::uuid THEN
    INSERT INTO test_results VALUES ('T3 task assignee dual-write', 'PASS', v_task_id::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T3 task assignee dual-write',
      'FAIL',
      coalesce(v_assignee_emp::text, 'null')
    );
  END IF;
END $$;

-- T4: unmapped assignee leaves assignee_employee_id NULL (Eve = profile sense employee)
DO $$
DECLARE
  v_project uuid := '51000000-0000-0000-0000-000000000001';
  v_task_id uuid;
  v_assignee_emp uuid;
  v_eve uuid := '20000000-0000-0000-0000-000000000006';
BEGIN
  INSERT INTO api.tasks (tenant_id, project_id, title, status, assignee_id)
  VALUES (
    '10000000-0000-0000-0000-000000000001',
    v_project,
    'ES-3 unmapped assignee',
    'todo',
    v_eve
  )
  RETURNING id INTO v_task_id;

  SELECT assignee_employee_id INTO v_assignee_emp
  FROM data.tasks WHERE id = v_task_id;

  IF v_assignee_emp IS NULL THEN
    INSERT INTO test_results VALUES ('T4 unmapped assignee null', 'PASS', v_task_id::text);
  ELSE
    INSERT INTO test_results VALUES ('T4 unmapped assignee null', 'FAIL', v_assignee_emp::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 unmapped assignee null', 'FAIL', SQLERRM);
END $$;

-- T5: clear assignee clears assignee_employee_id
DO $$
DECLARE
  v_project uuid := '51000000-0000-0000-0000-000000000001';
  v_task_id uuid;
  v_assignee_emp uuid;
BEGIN
  INSERT INTO api.tasks (tenant_id, project_id, title, status, assignee_id)
  VALUES (
    '10000000-0000-0000-0000-000000000001',
    v_project,
    'ES-3 clear assignee',
    'todo',
    '20000000-0000-0000-0000-000000000002'
  )
  RETURNING id INTO v_task_id;

  UPDATE api.tasks SET assignee_id = NULL WHERE id = v_task_id;

  SELECT assignee_employee_id INTO v_assignee_emp
  FROM data.tasks WHERE id = v_task_id;

  IF v_assignee_emp IS NULL THEN
    INSERT INTO test_results VALUES ('T5 clear assignee clears emp', 'PASS', v_task_id::text);
  ELSE
    INSERT INTO test_results VALUES ('T5 clear assignee clears emp', 'FAIL', v_assignee_emp::text);
  END IF;
END $$;

-- T6: api.work_logs / api.tasks exposen columnes noves
DO $$
DECLARE
  v_has_wl boolean;
  v_has_t  boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'work_logs' AND column_name = 'employee_id'
  ) INTO v_has_wl;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'tasks' AND column_name = 'assignee_employee_id'
  ) INTO v_has_t;

  IF v_has_wl AND v_has_t THEN
    INSERT INTO test_results VALUES ('T6 views expose employee cols', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES (
      'T6 views expose employee cols',
      'FAIL',
      format('wl=%s tasks=%s', v_has_wl, v_has_t)
    );
  END IF;
END $$;

-- T7: worker_id encara es llegeix (zero regressió columnes legacy)
DO $$
DECLARE
  v_cnt int;
BEGIN
  SELECT count(*) INTO v_cnt
  FROM api.work_logs
  WHERE worker_id = '20000000-0000-0000-0000-000000000004';

  IF v_cnt >= 0 THEN
    INSERT INTO test_results VALUES ('T7 legacy worker_id readable', 'PASS', v_cnt::text);
  ELSE
    INSERT INTO test_results VALUES ('T7 legacy worker_id readable', 'FAIL', 'unexpected');
  END IF;
END $$;

-- Summary
SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'ES-3 tests failed: % failures', v_fail;
  END IF;
END $$;

ROLLBACK;
