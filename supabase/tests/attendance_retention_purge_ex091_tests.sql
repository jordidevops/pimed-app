-- =============================================================================
-- attendance_retention_purge_ex091_tests.sql
-- EX-09.1 — retenció legal + purge batched
-- Executar:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
--     -f supabase/tests/attendance_retention_purge_ex091_tests.sql
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0910000-0000-0000-0000-000000000001', 'EX091 Tenant', 'ex091-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES (
  'b0910000-0000-0000-0000-000000000001',
  'a0910000-0000-0000-0000-000000000001',
  'EX091 Site',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES (
  'c0910000-0000-0000-0000-000000000001',
  'emp@ex091.test',
  'authenticated',
  'authenticated'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES (
  'c0910000-0000-0000-0000-000000000001',
  'emp@ex091.test',
  'Emp EX091'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (
  gen_random_uuid(),
  'a0910000-0000-0000-0000-000000000001',
  'c0910000-0000-0000-0000-000000000001',
  'member',
  true
)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0910000-0000-0000-0000-000000000001',
  'a0910000-0000-0000-0000-000000000001',
  'b0910000-0000-0000-0000-000000000001',
  'c0910000-0000-0000-0000-000000000001',
  'Emp EX091',
  'active'
)
ON CONFLICT (id) DO NOTHING;

-- Purge disabled by default for T1
UPDATE data.tenants
SET settings = coalesce(settings, '{}'::jsonb)
  || '{"attendance_retention_purge_enabled": false, "attendance_retention_years": 4}'::jsonb
WHERE id = 'a0910000-0000-0000-0000-000000000001';

CREATE TEMP TABLE ex091_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- T1: purge disabled → raises retention_purge_disabled
DO $$
DECLARE
  v_raised boolean := false;
  v_msg    text;
BEGIN
  BEGIN
    PERFORM data.purge_attendance_older_than_batch(
      'a0910000-0000-0000-0000-000000000001'::uuid,
      (CURRENT_DATE - INTERVAL '4 years')::date,
      5000
    );
  EXCEPTION WHEN OTHERS THEN
    v_raised := SQLERRM ILIKE '%retention_purge_disabled%';
    v_msg := SQLERRM;
  END;

  IF v_raised THEN
    INSERT INTO ex091_results VALUES ('T1 purge disabled raises', 'PASS', v_msg);
  ELSE
    INSERT INTO ex091_results VALUES ('T1 purge disabled raises', 'FAIL',
      COALESCE(v_msg, 'no exception'));
  END IF;
END $$;

-- T2: enabled but cutoff too recent (above floor) → raises
DO $$
DECLARE
  v_raised boolean := false;
  v_msg    text;
BEGIN
  UPDATE data.tenants
  SET settings = coalesce(settings, '{}'::jsonb)
    || '{"attendance_retention_purge_enabled": true, "attendance_retention_years": 4}'::jsonb
  WHERE id = 'a0910000-0000-0000-0000-000000000001';

  BEGIN
    PERFORM data.purge_attendance_older_than_batch(
      'a0910000-0000-0000-0000-000000000001'::uuid,
      (CURRENT_DATE - INTERVAL '3 years')::date,
      5000
    );
  EXCEPTION WHEN OTHERS THEN
    v_raised := SQLERRM ILIKE '%retention_floor%'
             OR SQLERRM ILIKE '%retention_absolute_floor%';
    v_msg := SQLERRM;
  END;

  IF v_raised THEN
    INSERT INTO ex091_results VALUES ('T2 cutoff above floor raises', 'PASS', v_msg);
  ELSE
    INSERT INTO ex091_results VALUES ('T2 cutoff above floor raises', 'FAIL',
      COALESCE(v_msg, 'no exception'));
  END IF;
END $$;

-- T3: enabled + old punch (5y) + recent → deletes old (+ entry/summary/segment); recent remains
DO $$
DECLARE
  v_tenant   uuid := 'a0910000-0000-0000-0000-000000000001';
  v_site     uuid := 'b0910000-0000-0000-0000-000000000001';
  v_emp      uuid := 'd0910000-0000-0000-0000-000000000001';
  v_old_id   uuid := 'e0910000-0000-0000-0000-000000000001';
  v_recent_id uuid := 'e0910000-0000-0000-0000-000000000002';
  v_old_day  date := (CURRENT_DATE - INTERVAL '5 years')::date;
  v_recent_day date := CURRENT_DATE;
  v_old_at   timestamptz;
  v_recent_at timestamptz;
  v_result   jsonb;
  v_old_gone boolean;
  v_recent_ok boolean;
  v_entry_gone boolean;
  v_sum_gone boolean;
  v_seg_gone boolean;
BEGIN
  UPDATE data.tenants
  SET settings = coalesce(settings, '{}'::jsonb)
    || '{"attendance_retention_purge_enabled": true, "attendance_retention_years": 4}'::jsonb
  WHERE id = v_tenant;

  v_old_at := (v_old_day + time '09:00') AT TIME ZONE 'Europe/Madrid';
  v_recent_at := (v_recent_day + time '09:00') AT TIME ZONE 'Europe/Madrid';

  -- Clean prior fixture rows for this employee (immutability: disable only for setup cleanup)
  ALTER TABLE data.time_punches DISABLE TRIGGER trg_immutable_time_punches;
  DELETE FROM data.time_activity_segments
  WHERE employee_id = v_emp
    AND work_date IN (v_old_day, v_recent_day);
  DELETE FROM data.time_entries
  WHERE employee_id = v_emp
    AND work_date IN (v_old_day, v_recent_day);
  DELETE FROM data.time_daily_summaries
  WHERE employee_id = v_emp
    AND work_date IN (v_old_day, v_recent_day);
  DELETE FROM data.time_punches
  WHERE employee_id = v_emp
    AND id IN (v_old_id, v_recent_id);
  ALTER TABLE data.time_punches ENABLE TRIGGER trg_immutable_time_punches;

  INSERT INTO data.time_punches (
    id, tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (
      v_old_id, v_tenant, v_site, v_emp,
      'e0910000-0000-0000-0000-0000000000c1',
      'in', v_old_at, 'manual_entry'
    ),
    (
      v_recent_id, v_tenant, v_site, v_emp,
      'e0910000-0000-0000-0000-0000000000c2',
      'in', v_recent_at, 'manual_entry'
    );

  INSERT INTO data.time_entries (
    id, tenant_id, site_id, employee_id, work_date, net_minutes, status, punch_in_id
  ) VALUES (
    'f0910000-0000-0000-0000-000000000001',
    v_tenant, v_site, v_emp, v_old_day, 480, 'closed', v_old_id
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE
    SET punch_in_id = EXCLUDED.punch_in_id, status = 'closed';

  INSERT INTO data.time_daily_summaries (
    id, tenant_id, site_id, employee_id, work_date, status, worked_minutes, punch_count
  ) VALUES (
    'f0910000-0000-0000-0000-000000000002',
    v_tenant, v_site, v_emp, v_old_day, 'draft', 480, 1
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE
    SET worked_minutes = 480, punch_count = 1, status = 'draft';

  INSERT INTO data.time_activity_segments (
    id, tenant_id, employee_id, work_date, activity_kind, started_at, ended_at, site_id,
    source_punch_ids
  ) VALUES (
    'f0910000-0000-0000-0000-000000000003',
    v_tenant, v_emp, v_old_day, 'WORK',
    v_old_at, v_old_at + interval '8 hours', v_site,
    ARRAY[v_old_id]
  )
  ON CONFLICT (employee_id, work_date, started_at, activity_kind) DO NOTHING;

  v_result := data.purge_attendance_older_than_batch(
    v_tenant,
    (CURRENT_DATE - INTERVAL '4 years')::date,
    5000
  );

  SELECT NOT EXISTS (SELECT 1 FROM data.time_punches WHERE id = v_old_id)
    INTO v_old_gone;
  SELECT EXISTS (SELECT 1 FROM data.time_punches WHERE id = v_recent_id)
    INTO v_recent_ok;
  SELECT NOT EXISTS (
    SELECT 1 FROM data.time_entries
    WHERE employee_id = v_emp AND work_date = v_old_day
  ) INTO v_entry_gone;
  SELECT NOT EXISTS (
    SELECT 1 FROM data.time_daily_summaries
    WHERE employee_id = v_emp AND work_date = v_old_day
  ) INTO v_sum_gone;
  SELECT NOT EXISTS (
    SELECT 1 FROM data.time_activity_segments
    WHERE employee_id = v_emp AND work_date = v_old_day
  ) INTO v_seg_gone;

  IF v_old_gone AND v_recent_ok AND v_entry_gone AND v_sum_gone AND v_seg_gone
     AND COALESCE((v_result->>'punches_deleted')::int, 0) >= 1
  THEN
    INSERT INTO ex091_results VALUES ('T3 purge old cascade keep recent', 'PASS',
      v_result::text);
  ELSE
    INSERT INTO ex091_results VALUES ('T3 purge old cascade keep recent', 'FAIL',
      format(
        'old_gone=%s recent_ok=%s entry=%s sum=%s seg=%s result=%s',
        v_old_gone, v_recent_ok, v_entry_gone, v_sum_gone, v_seg_gone, v_result
      ));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex091_results VALUES ('T3 purge old cascade keep recent', 'FAIL', SQLERRM);
END $$;

-- T4: without GUC, direct DELETE on time_punches still fails (immutability)
DO $$
DECLARE
  v_raised boolean := false;
  v_msg    text;
  v_id     uuid;
BEGIN
  -- Ensure a punch exists to attempt delete against
  SELECT id INTO v_id
  FROM data.time_punches
  WHERE id = 'e0910000-0000-0000-0000-000000000002';

  IF v_id IS NULL THEN
    INSERT INTO data.time_punches (
      id, tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
    ) VALUES (
      'e0910000-0000-0000-0000-000000000002',
      'a0910000-0000-0000-0000-000000000001',
      'b0910000-0000-0000-0000-000000000001',
      'd0910000-0000-0000-0000-000000000001',
      'e0910000-0000-0000-0000-0000000000c2',
      'in',
      (CURRENT_DATE + time '09:00') AT TIME ZONE 'Europe/Madrid',
      'manual_entry'
    )
    ON CONFLICT (id) DO NOTHING;
    v_id := 'e0910000-0000-0000-0000-000000000002';
  END IF;

  PERFORM set_config('app.allow_attendance_purge', '', true);

  BEGIN
    DELETE FROM data.time_punches WHERE id = v_id;
  EXCEPTION WHEN OTHERS THEN
    v_raised := SQLERRM ILIKE '%time_punches_immutable%';
    v_msg := SQLERRM;
  END;

  IF v_raised AND EXISTS (SELECT 1 FROM data.time_punches WHERE id = v_id) THEN
    INSERT INTO ex091_results VALUES ('T4 direct DELETE blocked', 'PASS', v_msg);
  ELSE
    INSERT INTO ex091_results VALUES ('T4 direct DELETE blocked', 'FAIL',
      COALESCE(v_msg, 'delete succeeded or wrong error'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex091_results VALUES ('T4 direct DELETE blocked', 'FAIL', SQLERRM);
END $$;

SELECT test_name, status, details FROM ex091_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex091_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-09.1 tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
