-- M-EHR-06 employee skills (talent) tests
BEGIN;
SET client_min_messages TO WARNING;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE test_ids (
  skill_type_id uuid,
  skill_id uuid,
  level1_id uuid,
  level2_id uuid,
  employee_skill_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

-- T1: tables exist
DO $$
BEGIN
  IF to_regclass('data.skill_types') IS NOT NULL
     AND to_regclass('data.skills') IS NOT NULL
     AND to_regclass('data.skill_levels') IS NOT NULL
     AND to_regclass('data.employee_skills') IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T1 skill tables exist', 'PASS', '4 tables');
  ELSE
    INSERT INTO test_results VALUES ('T1 skill tables exist', 'FAIL', 'missing tables');
  END IF;
END $$;

-- JWT owner (Alice owner user) — same pattern as employees_profile_v2_tests.sql
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

-- T2: owner creates skill_type + 2 levels (ranks 1,2; one default) + skill
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_type_id uuid;
  v_level1 uuid;
  v_level2 uuid;
  v_skill_id uuid;
BEGIN
  INSERT INTO api.skill_types (tenant_id, name, is_certification_type, is_active)
  VALUES (v_tenant, 'EHR6 Test Skill Type', false, true)
  RETURNING id INTO v_type_id;

  INSERT INTO api.skill_levels (skill_type_id, name, rank, is_default)
  VALUES (v_type_id, 'Junior', 1, true)
  RETURNING id INTO v_level1;

  INSERT INTO api.skill_levels (skill_type_id, name, rank, is_default)
  VALUES (v_type_id, 'Senior', 2, false)
  RETURNING id INTO v_level2;

  INSERT INTO api.skills (tenant_id, skill_type_id, name, description, is_active)
  VALUES (v_tenant, v_type_id, 'EHR6 Welding', 'test skill', true)
  RETURNING id INTO v_skill_id;

  UPDATE test_ids SET
    skill_type_id = v_type_id,
    skill_id = v_skill_id,
    level1_id = v_level1,
    level2_id = v_level2;

  IF v_type_id IS NOT NULL AND v_level1 IS NOT NULL AND v_level2 IS NOT NULL AND v_skill_id IS NOT NULL THEN
    INSERT INTO test_results VALUES (
      'T2 owner create type levels skill',
      'PASS',
      format('type=%s skill=%s L1=%s L2=%s', v_type_id, v_skill_id, v_level1, v_level2)
    );
  ELSE
    INSERT INTO test_results VALUES ('T2 owner create type levels skill', 'FAIL', 'null ids');
  END IF;
END $$;

-- T3: assign skill to Alice; duplicate assign fails (unique)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_skill  uuid;
  v_level  uuid;
  v_es_id  uuid;
  v_dup_ok boolean := false;
BEGIN
  SELECT skill_id, level1_id INTO v_skill, v_level FROM test_ids;

  INSERT INTO api.employee_skills (tenant_id, employee_id, skill_id, level_id)
  VALUES (v_tenant, v_alice, v_skill, v_level)
  RETURNING id INTO v_es_id;

  UPDATE test_ids SET employee_skill_id = v_es_id;

  BEGIN
    INSERT INTO api.employee_skills (tenant_id, employee_id, skill_id, level_id)
    VALUES (v_tenant, v_alice, v_skill, v_level);
  EXCEPTION WHEN unique_violation THEN
    v_dup_ok := true;
  END;

  IF v_es_id IS NOT NULL AND v_dup_ok THEN
    INSERT INTO test_results VALUES ('T3 assign Alice + unique', 'PASS', format('es=%s', v_es_id));
  ELSE
    INSERT INTO test_results VALUES (
      'T3 assign Alice + unique',
      'FAIL',
      format('es=%s dup_ok=%s', v_es_id, v_dup_ok)
    );
  END IF;
END $$;

-- T4: search_employees_by_skill returns Alice; high min_rank filters out
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_skill uuid;
  v_found int;
  v_filtered int;
BEGIN
  SELECT skill_id INTO v_skill FROM test_ids;

  SELECT count(*) INTO v_found
  FROM api.search_employees_by_skill(v_skill, NULL)
  WHERE employee_id = v_alice;

  -- Alice has rank 1 (Junior); min_rank 2 should filter her out
  SELECT count(*) INTO v_filtered
  FROM api.search_employees_by_skill(v_skill, 2)
  WHERE employee_id = v_alice;

  IF v_found = 1 AND v_filtered = 0 THEN
    INSERT INTO test_results VALUES (
      'T4 search by skill + min_rank',
      'PASS',
      format('found=%s filtered=%s', v_found, v_filtered)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T4 search by skill + min_rank',
      'FAIL',
      format('found=%s filtered=%s', v_found, v_filtered)
    );
  END IF;
END $$;

-- T5: Dave (member, no skills.manage) — INSERT skill_types fails
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    INSERT INTO api.skill_types (tenant_id, name)
    VALUES (v_tenant, 'EHR6 Dave Forbidden Type');
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_ok := true;
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%policy%' OR SQLSTATE = '42501' THEN
        v_ok := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T5 Dave cannot insert skill_types', 'PASS', 'denied');
  ELSE
    INSERT INTO test_results VALUES ('T5 Dave cannot insert skill_types', 'FAIL', 'insert allowed');
  END IF;
END $$;

-- T6: cleanup test rows
DO $$
DECLARE
  v_type uuid;
  v_skill uuid;
  v_es uuid;
  v_left int;
BEGIN
  -- Restore owner JWT for deletes
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT skill_type_id, skill_id, employee_skill_id INTO v_type, v_skill, v_es FROM test_ids;

  DELETE FROM api.employee_skills WHERE id = v_es;
  DELETE FROM api.skills WHERE id = v_skill;
  DELETE FROM api.skill_levels WHERE skill_type_id = v_type;
  DELETE FROM api.skill_types WHERE id = v_type;

  SELECT count(*) INTO v_left
  FROM (
    SELECT 1 FROM data.employee_skills WHERE id = v_es
    UNION ALL
    SELECT 1 FROM data.skills WHERE id = v_skill
    UNION ALL
    SELECT 1 FROM data.skill_levels WHERE skill_type_id = v_type
    UNION ALL
    SELECT 1 FROM data.skill_types WHERE id = v_type
  ) x;

  IF v_left = 0 THEN
    INSERT INTO test_results VALUES ('T6 cleanup test rows', 'PASS', 'deleted');
  ELSE
    INSERT INTO test_results VALUES ('T6 cleanup test rows', 'FAIL', format('left=%s', v_left));
  END IF;
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_pass int;
  v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'PASS'), count(*) FILTER (WHERE status = 'FAIL')
  INTO v_pass, v_fail FROM test_results;
  RAISE NOTICE 'M-EHR-06 skills tests: % PASS, % FAIL', v_pass, v_fail;
  IF v_fail > 0 OR v_pass < 6 THEN
    RAISE EXCEPTION 'M-EHR-06 employee skills tests failed (pass=%, fail=%)', v_pass, v_fail;
  END IF;
END $$;

ROLLBACK;
