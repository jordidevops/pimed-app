-- =============================================================================
-- attendance_shift_recompute_ex035_tests.sql
-- EX-03.5 — Enqueue recompute en publish/cancel de shift_slots; draft no afecta.
--
-- Executar:
--   Get-Content supabase/tests/attendance_shift_recompute_ex035_tests.sql |
--     docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres -v ON_ERROR_STOP=0
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0360000-0000-0000-0000-000000000001', 'EX035 Tenant', 'ex035-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0360000-0000-0000-0000-000000000001', 'a0360000-0000-0000-0000-000000000001', 'EX035 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0360000-0000-0000-0000-000000000001', 'emp@ex035.test', 'authenticated', 'authenticated'),
  ('c0360000-0000-0000-0000-000000000002', 'mgr@ex035.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0360000-0000-0000-0000-000000000001', 'emp@ex035.test', 'Emp EX035'),
  ('c0360000-0000-0000-0000-000000000002', 'mgr@ex035.test', 'Mgr EX035')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0360000-0000-0000-0000-000000000001', 'c0360000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0360000-0000-0000-0000-000000000001', 'c0360000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, calendar_group_id)
VALUES (
  'd0360000-0000-0000-0000-000000000001',
  'a0360000-0000-0000-0000-000000000001',
  'b0360000-0000-0000-0000-000000000001',
  'c0360000-0000-0000-0000-000000000001',
  'Emp EX035', 'active', NULL
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, sort_order)
VALUES (
  'e0360000-0000-0000-0000-000000000001',
  'a0360000-0000-0000-0000-000000000001',
  'b0360000-0000-0000-0000-000000000001',
  'Grup EX035', '#0ea5e9', 1
)
ON CONFLICT (id) DO NOTHING;

UPDATE data.employees
SET calendar_group_id = 'e0360000-0000-0000-0000-000000000001'
WHERE id = 'd0360000-0000-0000-0000-000000000001';

-- Base recurrent dilluns 08:00-16:00 = 480 min
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES (
  'a0360000-0000-0000-0000-000000000001',
  'e0360000-0000-0000-0000-000000000001',
  1, 'work', '08:00', '16:00',
  '[{"start":"08:00","end":"16:00"}]'::jsonb,
  '2020-01-01'
)
ON CONFLICT DO NOTHING;

-- Plantilla 10:00-14:00 = 240 min (substitueix base quan published)
INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active)
VALUES (
  'f0360000-0000-0000-0000-000000000001',
  'a0360000-0000-0000-0000-000000000001',
  'b0360000-0000-0000-0000-000000000001',
  'Matí EX035', '#3b82f6', '10:00', '14:00', true
)
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE ex035_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.count_recompute_msgs(
  p_employee_id uuid,
  p_work_date date
) RETURNS int
LANGUAGE sql
STABLE
AS $$
  SELECT count(*)::int
  FROM pgmq.q_attendance_recompute_queue q
  WHERE q.message->>'task' = 'recompute_attendance_day'
    AND q.message->>'employee_id' = p_employee_id::text
    AND q.message->>'work_date' = p_work_date::text;
$$;

-- T1: assign draft NO encua recompute
DO $$
DECLARE
  v_before int;
  v_after int;
  v_result jsonb;
BEGIN
  v_before := pg_temp.count_recompute_msgs(
    'd0360000-0000-0000-0000-000000000001'::uuid, '2026-07-13'::date);

  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0360000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0360000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0360000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.assign_shift_slot(
    'd0360000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    'f0360000-0000-0000-0000-000000000001'::uuid
  );

  SET LOCAL ROLE postgres;

  v_after := pg_temp.count_recompute_msgs(
    'd0360000-0000-0000-0000-000000000001'::uuid, '2026-07-13'::date);

  IF v_result->>'slot_id' IS NOT NULL AND v_after = v_before THEN
    INSERT INTO ex035_results VALUES ('T1 draft no encua', 'PASS',
      format('msgs=%s', v_after));
  ELSE
    INSERT INTO ex035_results VALUES ('T1 draft no encua', 'FAIL',
      format('before=%s after=%s slot=%s', v_before, v_after, v_result->>'slot_id'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex035_results VALUES ('T1 draft no encua', 'ERROR', SQLERRM);
END;
$$;

-- T2: publish encua recompute + worker actualitza expected_minutes
DO $$
DECLARE
  v_before int;
  v_after int;
  v_pub jsonb;
  v_worker jsonb;
  v_expected int;
  v_week_start date := '2026-07-13'; -- dilluns
BEGIN
  v_before := pg_temp.count_recompute_msgs(
    'd0360000-0000-0000-0000-000000000001'::uuid, '2026-07-13'::date);

  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0360000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0360000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0360000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_pub := api.publish_shifts(
    'b0360000-0000-0000-0000-000000000001'::uuid,
    v_week_start
  );

  SET LOCAL ROLE postgres;

  v_after := pg_temp.count_recompute_msgs(
    'd0360000-0000-0000-0000-000000000001'::uuid, '2026-07-13'::date);

  v_worker := api.recompute_attendance_worker(
    'd0360000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    'a0360000-0000-0000-0000-000000000001'::uuid
  );

  SELECT expected_minutes INTO v_expected
  FROM data.time_daily_summaries
  WHERE employee_id = 'd0360000-0000-0000-0000-000000000001'
    AND work_date = '2026-07-13';

  IF v_after > v_before AND v_expected = 240 THEN
    INSERT INTO ex035_results VALUES ('T2 publish encua + expected 240', 'PASS',
      format('enqueued=%s expected=%s worker=%s', v_after - v_before, v_expected, v_worker->>'skipped'));
  ELSE
    INSERT INTO ex035_results VALUES ('T2 publish encua + expected 240', 'FAIL',
      format('before=%s after=%s expected=%s pub=%s worker=%s',
        v_before, v_after, v_expected, v_pub, v_worker));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex035_results VALUES ('T2 publish encua + expected 240', 'ERROR', SQLERRM);
END;
$$;

-- T3: cancel published encua + worker restaura base 480
DO $$
DECLARE
  v_before int;
  v_after int;
  v_slot uuid;
  v_del jsonb;
  v_expected int;
BEGIN
  SELECT id INTO v_slot
  FROM data.shift_slots
  WHERE employee_id = 'd0360000-0000-0000-0000-000000000001'
    AND slot_date = '2026-07-13'
    AND status = 'published'
  LIMIT 1;

  v_before := pg_temp.count_recompute_msgs(
    'd0360000-0000-0000-0000-000000000001'::uuid, '2026-07-13'::date);

  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0360000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0360000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0360000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_del := api.bulk_delete_shift_slots(ARRAY[v_slot]);

  SET LOCAL ROLE postgres;

  v_after := pg_temp.count_recompute_msgs(
    'd0360000-0000-0000-0000-000000000001'::uuid, '2026-07-13'::date);

  PERFORM api.recompute_attendance_worker(
    'd0360000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    'a0360000-0000-0000-0000-000000000001'::uuid
  );

  SELECT expected_minutes INTO v_expected
  FROM data.time_daily_summaries
  WHERE employee_id = 'd0360000-0000-0000-0000-000000000001'
    AND work_date = '2026-07-13';

  IF v_slot IS NOT NULL AND v_after > v_before AND v_expected = 480 THEN
    INSERT INTO ex035_results VALUES ('T3 cancel encua + expected 480', 'PASS',
      format('enqueued=%s expected=%s', v_after - v_before, v_expected));
  ELSE
    INSERT INTO ex035_results VALUES ('T3 cancel encua + expected 480', 'FAIL',
      format('slot=%s before=%s after=%s expected=%s del=%s',
        v_slot, v_before, v_after, v_expected, v_del));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex035_results VALUES ('T3 cancel encua + expected 480', 'ERROR', SQLERRM);
END;
$$;

-- T4: helper enqueue retorna msg_id i és cridable
DO $$
DECLARE
  v_msg bigint;
  v_before int;
  v_after int;
BEGIN
  v_before := pg_temp.count_recompute_msgs(
    'd0360000-0000-0000-0000-000000000001'::uuid, '2026-07-13'::date);

  v_msg := data.enqueue_attendance_day_recompute(
    'a0360000-0000-0000-0000-000000000001'::uuid,
    'd0360000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    'test-direct'
  );

  v_after := pg_temp.count_recompute_msgs(
    'd0360000-0000-0000-0000-000000000001'::uuid, '2026-07-13'::date);

  IF v_msg IS NOT NULL AND v_after = v_before + 1 THEN
    INSERT INTO ex035_results VALUES ('T4 helper enqueue directe', 'PASS',
      format('msg_id=%s', v_msg));
  ELSE
    INSERT INTO ex035_results VALUES ('T4 helper enqueue directe', 'FAIL',
      format('msg=%s before=%s after=%s', v_msg, v_before, v_after));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex035_results VALUES ('T4 helper enqueue directe', 'ERROR', SQLERRM);
END;
$$;

-- T5: recompute doble (idempotència del worker) no canvia expected
DO $$
DECLARE
  v_e1 int;
  v_e2 int;
BEGIN
  -- Re-publicar un slot nou per tenir expected=240
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0360000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0360000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0360000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;
  PERFORM api.assign_shift_slot(
    'd0360000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    'f0360000-0000-0000-0000-000000000001'::uuid
  );
  PERFORM api.publish_shifts(
    'b0360000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );
  SET LOCAL ROLE postgres;

  PERFORM api.recompute_attendance_worker(
    'd0360000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    'a0360000-0000-0000-0000-000000000001'::uuid
  );
  SELECT expected_minutes INTO v_e1
  FROM data.time_daily_summaries
  WHERE employee_id = 'd0360000-0000-0000-0000-000000000001'
    AND work_date = '2026-07-13';

  PERFORM api.recompute_attendance_worker(
    'd0360000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    'a0360000-0000-0000-0000-000000000001'::uuid
  );
  SELECT expected_minutes INTO v_e2
  FROM data.time_daily_summaries
  WHERE employee_id = 'd0360000-0000-0000-0000-000000000001'
    AND work_date = '2026-07-13';

  IF v_e1 = 240 AND v_e2 = 240 THEN
    INSERT INTO ex035_results VALUES ('T5 worker idempotent', 'PASS',
      format('expected=%s', v_e2));
  ELSE
    INSERT INTO ex035_results VALUES ('T5 worker idempotent', 'FAIL',
      format('e1=%s e2=%s', v_e1, v_e2));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex035_results VALUES ('T5 worker idempotent', 'ERROR', SQLERRM);
END;
$$;

SELECT * FROM ex035_results ORDER BY test_name;

SELECT
  count(*) FILTER (WHERE status = 'PASS') AS passed,
  count(*) FILTER (WHERE status = 'FAIL') AS failed,
  count(*) FILTER (WHERE status = 'ERROR') AS errors,
  count(*) AS total
FROM ex035_results;

ROLLBACK;
