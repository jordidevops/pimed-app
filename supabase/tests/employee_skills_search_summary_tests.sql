-- Multi-skill search + summary tests (extends M-EHR-06)
BEGIN;
SET client_min_messages TO WARNING;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE test_ids (
  skill_a uuid,
  skill_b uuid,
  level_mid uuid,
  level_high uuid,
  es_alice_a uuid,
  es_charlie_a uuid,
  es_charlie_b uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

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

-- Setup: type + 2 skills + levels; assign Alice skill A (mid), Charlie A+B (high/mid)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_charlie uuid := '40000000-0000-0000-0000-000000000002';
  v_type uuid;
  v_la uuid;
  v_lb uuid;
  v_sa uuid;
  v_sb uuid;
  v_es1 uuid;
  v_es2 uuid;
  v_es3 uuid;
BEGIN
  INSERT INTO api.skill_types (tenant_id, name, is_active)
  VALUES (v_tenant, 'MS Search Test Type', true)
  RETURNING id INTO v_type;

  INSERT INTO api.skill_levels (skill_type_id, name, rank, is_default)
  VALUES (v_type, 'Mid', 2, true) RETURNING id INTO v_la;
  INSERT INTO api.skill_levels (skill_type_id, name, rank, is_default)
  VALUES (v_type, 'High', 3, false) RETURNING id INTO v_lb;

  INSERT INTO api.skills (tenant_id, skill_type_id, name, is_active)
  VALUES (v_tenant, v_type, 'MS Alpha', true) RETURNING id INTO v_sa;
  INSERT INTO api.skills (tenant_id, skill_type_id, name, is_active)
  VALUES (v_tenant, v_type, 'MS Beta', true) RETURNING id INTO v_sb;

  INSERT INTO api.employee_skills (tenant_id, employee_id, skill_id, level_id)
  VALUES (v_tenant, v_alice, v_sa, v_la) RETURNING id INTO v_es1;
  INSERT INTO api.employee_skills (tenant_id, employee_id, skill_id, level_id)
  VALUES (v_tenant, v_charlie, v_sa, v_lb) RETURNING id INTO v_es2;
  INSERT INTO api.employee_skills (tenant_id, employee_id, skill_id, level_id)
  VALUES (v_tenant, v_charlie, v_sb, v_la) RETURNING id INTO v_es3;

  UPDATE test_ids SET
    skill_a = v_sa, skill_b = v_sb,
    level_mid = v_la, level_high = v_lb,
    es_alice_a = v_es1, es_charlie_a = v_es2, es_charlie_b = v_es3;

  INSERT INTO test_results VALUES ('T0 setup', 'PASS', format('A=%s B=%s', v_sa, v_sb));
END $$;

-- T1: empty criteria → 0 rows
DO $$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM api.search_employees_by_skills('[]'::jsonb, 'and', NULL, 48);
  IF v_n = 0 THEN
    INSERT INTO test_results VALUES ('T1 empty criteria', 'PASS', '0');
  ELSE
    INSERT INTO test_results VALUES ('T1 empty criteria', 'FAIL', format('n=%s', v_n));
  END IF;
END $$;

-- T2: AND both skills → only Charlie
DO $$
DECLARE
  v_sa uuid; v_sb uuid;
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_charlie uuid := '40000000-0000-0000-0000-000000000002';
  v_has_c boolean; v_has_a boolean; v_n int;
BEGIN
  SELECT skill_a, skill_b INTO v_sa, v_sb FROM test_ids;
  SELECT count(*),
         bool_or(employee_id = v_charlie),
         bool_or(employee_id = v_alice)
  INTO v_n, v_has_c, v_has_a
  FROM api.search_employees_by_skills(
    jsonb_build_array(
      jsonb_build_object('skill_id', v_sa),
      jsonb_build_object('skill_id', v_sb)
    ),
    'and', NULL, 48
  );
  IF v_has_c AND NOT coalesce(v_has_a, false) THEN
    INSERT INTO test_results VALUES ('T2 AND both skills', 'PASS', format('n=%s', v_n));
  ELSE
    INSERT INTO test_results VALUES ('T2 AND both skills', 'FAIL', format('n=%s c=%s a=%s', v_n, v_has_c, v_has_a));
  END IF;
END $$;

-- T3: OR → Alice and Charlie
DO $$
DECLARE
  v_sa uuid; v_sb uuid;
  v_n int;
BEGIN
  SELECT skill_a, skill_b INTO v_sa, v_sb FROM test_ids;
  SELECT count(*) INTO v_n
  FROM api.search_employees_by_skills(
    jsonb_build_array(
      jsonb_build_object('skill_id', v_sa),
      jsonb_build_object('skill_id', v_sb)
    ),
    'or', NULL, 48
  );
  IF v_n >= 2 THEN
    INSERT INTO test_results VALUES ('T3 OR skills', 'PASS', format('n=%s', v_n));
  ELSE
    INSERT INTO test_results VALUES ('T3 OR skills', 'FAIL', format('n=%s', v_n));
  END IF;
END $$;

-- T4: min_level_rank filters Alice (rank 2) when min=3
DO $$
DECLARE
  v_sa uuid;
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_charlie uuid := '40000000-0000-0000-0000-000000000002';
  v_has_a boolean; v_has_c boolean;
BEGIN
  SELECT skill_a INTO v_sa FROM test_ids;
  SELECT bool_or(employee_id = v_alice), bool_or(employee_id = v_charlie)
  INTO v_has_a, v_has_c
  FROM api.search_employees_by_skills(
    jsonb_build_array(jsonb_build_object('skill_id', v_sa, 'min_level_rank', 3)),
    'and', NULL, 48
  );
  IF NOT coalesce(v_has_a, false) AND v_has_c THEN
    INSERT INTO test_results VALUES ('T4 min_level_rank', 'PASS', 'alice filtered');
  ELSE
    INSERT INTO test_results VALUES ('T4 min_level_rank', 'FAIL', format('a=%s c=%s', v_has_a, v_has_c));
  END IF;
END $$;

-- T5: wrapper still finds Alice
DO $$
DECLARE
  v_sa uuid;
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_n int;
BEGIN
  SELECT skill_a INTO v_sa FROM test_ids;
  SELECT count(*) INTO v_n
  FROM api.search_employees_by_skill(v_sa, NULL)
  WHERE employee_id = v_alice;
  IF v_n = 1 THEN
    INSERT INTO test_results VALUES ('T5 wrapper single skill', 'PASS', '1');
  ELSE
    INSERT INTO test_results VALUES ('T5 wrapper single skill', 'FAIL', format('n=%s', v_n));
  END IF;
END $$;

-- T6: summary returns kpis + gaps array
DO $$
DECLARE
  v_sum jsonb;
  v_ok boolean;
BEGIN
  v_sum := api.employee_skills_summary(NULL);
  v_ok := (v_sum ? 'kpis')
    AND (v_sum ? 'coverage_by_skill')
    AND (v_sum ? 'gaps')
    AND ((v_sum->'kpis'->>'skills_in_catalog')::int >= 2);
  IF v_ok THEN
    INSERT INTO test_results VALUES ('T6 summary shape', 'PASS', v_sum->'kpis'::text);
  ELSE
    INSERT INTO test_results VALUES ('T6 summary shape', 'FAIL', coalesce(v_sum::text, 'null'));
  END IF;
END $$;

-- T7: alien skill → exception
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM * FROM api.search_employees_by_skills(
      jsonb_build_array(jsonb_build_object('skill_id', '00000000-0000-0000-0000-000000000099')),
      'and', NULL, 48
    );
  EXCEPTION WHEN others THEN
    IF SQLERRM ILIKE '%skill_not_found%' OR SQLSTATE = 'P0002' THEN
      v_ok := true;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 alien skill', 'PASS', 'denied');
  ELSE
    INSERT INTO test_results VALUES ('T7 alien skill', 'FAIL', 'no exception');
  END IF;
END $$;

-- Cleanup
DO $$
DECLARE
  r test_ids%ROWTYPE;
  v_type uuid;
BEGIN
  SELECT * INTO r FROM test_ids;
  DELETE FROM api.employee_skills WHERE id IN (r.es_alice_a, r.es_charlie_a, r.es_charlie_b);
  SELECT skill_type_id INTO v_type FROM data.skills WHERE id = r.skill_a;
  DELETE FROM api.skills WHERE id IN (r.skill_a, r.skill_b);
  DELETE FROM api.skill_levels WHERE skill_type_id = v_type;
  DELETE FROM api.skill_types WHERE id = v_type;
  INSERT INTO test_results VALUES ('T8 cleanup', 'PASS', 'ok');
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_pass int;
  v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'PASS'), count(*) FILTER (WHERE status = 'FAIL')
  INTO v_pass, v_fail FROM test_results;
  RAISE NOTICE 'skills search/summary tests: % PASS, % FAIL', v_pass, v_fail;
  IF v_fail > 0 OR v_pass < 8 THEN
    RAISE EXCEPTION 'skills search/summary tests failed (pass=%, fail=%)', v_pass, v_fail;
  END IF;
END $$;

ROLLBACK;
