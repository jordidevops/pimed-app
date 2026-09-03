-- attendance_interval_intersection_tests.sql — Track G spike
BEGIN;

CREATE TEMP TABLE interval_test_results (
  test_name text,
  status    text,
  expected  int,
  actual    int
) ON COMMIT DROP;

DO $$
DECLARE
  v_tz text := 'Europe/Madrid';
  v_day date := '2026-06-15';
  v_start timestamptz;
  v_end timestamptz;
  v_iv jsonb;
  v_actual int;
BEGIN
  v_iv := '[{"start":"08:00","end":"14:00"},{"start":"16:00","end":"18:00"}]'::jsonb;
  v_start := (v_day + time '07:55') AT TIME ZONE v_tz;
  v_end   := (v_day + time '18:40') AT TIME ZONE v_tz;
  v_actual := data.interval_intersection_minutes(v_start, v_end, v_iv, v_tz);

  INSERT INTO interval_test_results VALUES (
    'split_day_0755_1840', 'PASS', 480, v_actual
  );
  IF v_actual <> 480 THEN
    UPDATE interval_test_results SET status = 'FAIL' WHERE test_name = 'split_day_0755_1840';
  END IF;
END;
$$;

DO $$
DECLARE
  v_actual int;
BEGIN
  v_actual := data.interval_intersection_minutes(
    now(), now(), '[]'::jsonb, 'Europe/Madrid'
  );
  INSERT INTO interval_test_results VALUES ('empty_intervals', 'PASS', 0, v_actual);
  IF v_actual <> 0 THEN
    UPDATE interval_test_results SET status = 'FAIL' WHERE test_name = 'empty_intervals';
  END IF;
END;
$$;

DO $$
DECLARE
  r record;
  v_fail int := 0;
BEGIN
  FOR r IN SELECT * FROM interval_test_results ORDER BY test_name LOOP
    RAISE NOTICE '[%] % expected=% actual=%', r.status, r.test_name, r.expected, r.actual;
    IF r.status <> 'PASS' THEN v_fail := v_fail + 1; END IF;
  END LOOP;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'Interval tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
