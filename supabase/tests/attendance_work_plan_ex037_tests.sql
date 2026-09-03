-- =============================================================================
-- attendance_work_plan_ex037_tests.sql
-- EX-03.7 — FF-03 work_plan_resolver_v2, shadow-compare, backfill draft/unlocked
--
-- Executar:
--   Get-Content supabase/tests/attendance_work_plan_ex037_tests.sql |
--     docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres -v ON_ERROR_STOP=0
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0380000-0000-0000-0000-000000000001', 'EX037 Tenant', 'ex037-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0380000-0000-0000-0000-000000000001', 'a0380000-0000-0000-0000-000000000001', 'EX037 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0380000-0000-0000-0000-000000000001', 'emp@ex037.test', 'authenticated', 'authenticated'),
  ('c0380000-0000-0000-0000-000000000002', 'mgr@ex037.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0380000-0000-0000-0000-000000000001', 'emp@ex037.test', 'Emp EX037'),
  ('c0380000-0000-0000-0000-000000000002', 'mgr@ex037.test', 'Mgr EX037')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0380000-0000-0000-0000-000000000001', 'c0380000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0380000-0000-0000-0000-000000000001', 'c0380000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, sort_order)
VALUES (
  'e0380000-0000-0000-0000-000000000001',
  'a0380000-0000-0000-0000-000000000001',
  'b0380000-0000-0000-0000-000000000001',
  'Grup EX037', '#0ea5e9', 1
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, calendar_group_id)
VALUES (
  'd0380000-0000-0000-0000-000000000001',
  'a0380000-0000-0000-0000-000000000001',
  'b0380000-0000-0000-0000-000000000001',
  'c0380000-0000-0000-0000-000000000001',
  'Emp EX037', 'active',
  'e0380000-0000-0000-0000-000000000001'
)
ON CONFLICT (id) DO NOTHING;

-- Dilluns 2026-07-13 DOW=1 → 08:00-16:00 = 480
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES (
  'a0380000-0000-0000-0000-000000000001',
  'e0380000-0000-0000-0000-000000000001',
  1, 'work', '08:00', '16:00',
  '[{"start":"08:00","end":"16:00"}]'::jsonb,
  '2020-01-01'
)
ON CONFLICT DO NOTHING;

INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active)
VALUES (
  'f0380000-0000-0000-0000-000000000001',
  'a0380000-0000-0000-0000-000000000001',
  'b0380000-0000-0000-0000-000000000001',
  'Matí EX037', '#3b82f6', '10:00', '14:00', true
)
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE ex037_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0380000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0380000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0380000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0380000-0000-0000-0000-000000000001":{"global_permissions":["attendance.view_all","labor_calendar.manage"],"sites":{}}}}}',
    true);
END;
$$;

-- T1: flag global ON
DO $$
BEGIN
  IF data.is_work_plan_resolver_v2_enabled('a0380000-0000-0000-0000-000000000001'::uuid) THEN
    INSERT INTO ex037_results VALUES ('T1 flag default ON', 'PASS', 'ok');
  ELSE
    INSERT INTO ex037_results VALUES ('T1 flag default ON', 'FAIL', 'flag off');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex037_results VALUES ('T1 flag default ON', 'ERROR', SQLERRM);
END;
$$;

-- T2: override OFF → compare skipped; resolve_work_day encara funciona
DO $$
DECLARE
  v_cmp jsonb;
  v_day jsonb;
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (
    'a0380000-0000-0000-0000-000000000001',
    'work_plan_resolver_v2',
    false
  )
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = false;

  v_cmp := data.compare_work_plan_resolver(
    'd0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_day := api.resolve_work_day(
    'd0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );
  SET LOCAL ROLE postgres;

  IF COALESCE((v_cmp->>'skipped')::boolean, false)
     AND v_day->>'day_type' = 'working'
     AND (v_day->>'expected_minutes')::int = 480
  THEN
    INSERT INTO ex037_results VALUES ('T2 flag OFF skip + hot path', 'PASS',
      format('cmp=%s day=%s', v_cmp->>'reason', v_day->>'expected_minutes'));
  ELSE
    INSERT INTO ex037_results VALUES ('T2 flag OFF skip + hot path', 'FAIL',
      format('cmp=%s day=%s', v_cmp, v_day));
  END IF;

  DELETE FROM data.tenant_feature_overrides
  WHERE tenant_id = 'a0380000-0000-0000-0000-000000000001'
    AND feature_key = 'work_plan_resolver_v2';
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  DELETE FROM data.tenant_feature_overrides
  WHERE tenant_id = 'a0380000-0000-0000-0000-000000000001'
    AND feature_key = 'work_plan_resolver_v2';
  INSERT INTO ex037_results VALUES ('T2 flag OFF skip + hot path', 'ERROR', SQLERRM);
END;
$$;

-- T3: labor plain → match
DO $$
DECLARE
  v_cmp jsonb;
BEGIN
  v_cmp := data.compare_work_plan_resolver(
    'd0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  IF COALESCE((v_cmp->>'match')::boolean, false)
     AND NOT COALESCE((v_cmp->>'expected_diff')::boolean, true)
  THEN
    INSERT INTO ex037_results VALUES ('T3 labor match', 'PASS', 'ok');
  ELSE
    INSERT INTO ex037_results VALUES ('T3 labor match', 'FAIL', v_cmp::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex037_results VALUES ('T3 labor match', 'ERROR', SQLERRM);
END;
$$;

-- T4: published slot → expected_diff published_slots
DO $$
DECLARE
  v_cmp jsonb;
  v_asg jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_asg := api.assign_shift_slot(
    'd0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    'f0380000-0000-0000-0000-000000000001'::uuid
  );
  PERFORM api.publish_shifts(
    'b0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );
  SET LOCAL ROLE postgres;

  v_cmp := data.compare_work_plan_resolver(
    'd0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  IF COALESCE((v_cmp->>'expected_diff')::boolean, false)
     AND v_cmp->'diff_reasons' ? 'published_slots'
     AND (v_cmp->'canonical'->>'expected_minutes')::int = 240
     AND (v_cmp->'labor_only'->>'expected_minutes')::int = 480
     AND v_asg->>'slot_id' IS NOT NULL
  THEN
    INSERT INTO ex037_results VALUES ('T4 slot expected_diff', 'PASS',
      format('canon=%s labor=%s', v_cmp->'canonical'->>'expected_minutes',
             v_cmp->'labor_only'->>'expected_minutes'));
  ELSE
    INSERT INTO ex037_results VALUES ('T4 slot expected_diff', 'FAIL', v_cmp::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex037_results VALUES ('T4 slot expected_diff', 'ERROR', SQLERRM);
END;
$$;

-- T5: absència → expected_diff absence
DO $$
DECLARE
  v_cmp jsonb;
BEGIN
  -- Cancel slot published perquè absència sigui clara
  UPDATE data.shift_slots
  SET status = 'cancelled'
  WHERE employee_id = 'd0380000-0000-0000-0000-000000000001'
    AND slot_date = '2026-07-13'
    AND status = 'published';

  INSERT INTO data.employee_absences (
    id, tenant_id, site_id, employee_id,
    absence_type, start_date, end_date,
    status, is_paid, requested_by, reviewed_by, reviewed_at
  ) VALUES (
    'ab038000-0000-0000-0000-000000000001',
    'a0380000-0000-0000-0000-000000000001',
    'b0380000-0000-0000-0000-000000000001',
    'd0380000-0000-0000-0000-000000000001',
    'vacation', '2026-07-13', '2026-07-13',
    'approved', true,
    'c0380000-0000-0000-0000-000000000001',
    'c0380000-0000-0000-0000-000000000002',
    now()
  ) ON CONFLICT (id) DO NOTHING;

  v_cmp := data.compare_work_plan_resolver(
    'd0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  IF COALESCE((v_cmp->>'expected_diff')::boolean, false)
     AND v_cmp->'diff_reasons' ? 'absence'
     AND v_cmp->'canonical'->>'day_type' = 'absence'
  THEN
    INSERT INTO ex037_results VALUES ('T5 absence expected_diff', 'PASS', 'ok');
  ELSE
    INSERT INTO ex037_results VALUES ('T5 absence expected_diff', 'FAIL', v_cmp::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex037_results VALUES ('T5 absence expected_diff', 'ERROR', SQLERRM);
END;
$$;

-- T6: backfill dry_run compta eligible
DO $$
DECLARE
  v_res jsonb;
BEGIN
  DELETE FROM data.employee_absences
  WHERE id = 'ab038000-0000-0000-0000-000000000001';

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_res := api.backfill_attendance_work_plan(
    'a0380000-0000-0000-0000-000000000001'::uuid,
    'b0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    '2026-07-13'::date,
    true,
    'enqueue'
  );

  SET LOCAL ROLE postgres;

  IF COALESCE((v_res->>'dry_run')::boolean, false)
     AND (v_res->>'eligible')::int >= 1
     AND (v_res->>'enqueued')::int = 0
  THEN
    INSERT INTO ex037_results VALUES ('T6 backfill dry_run', 'PASS',
      format('eligible=%s', v_res->>'eligible'));
  ELSE
    INSERT INTO ex037_results VALUES ('T6 backfill dry_run', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex037_results VALUES ('T6 backfill dry_run', 'ERROR', SQLERRM);
END;
$$;

-- T7: payroll_locked skip
DO $$
DECLARE
  v_res jsonb;
BEGIN
  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date,
    day_type, expected_minutes, worked_minutes, status, payroll_locked_at
  ) VALUES (
    'a0380000-0000-0000-0000-000000000001',
    'b0380000-0000-0000-0000-000000000001',
    'd0380000-0000-0000-0000-000000000001',
    '2026-07-13',
    'work', 999, 0, 'draft', now()
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE
  SET payroll_locked_at = now(), expected_minutes = 999, status = 'draft';

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_res := api.backfill_attendance_work_plan(
    'a0380000-0000-0000-0000-000000000001'::uuid,
    'b0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    '2026-07-13'::date,
    true,
    'enqueue'
  );
  SET LOCAL ROLE postgres;

  IF (v_res->>'skipped_locked')::int >= 1
     AND (v_res->>'eligible')::int = 0
  THEN
    INSERT INTO ex037_results VALUES ('T7 skip locked', 'PASS',
      format('locked=%s', v_res->>'skipped_locked'));
  ELSE
    INSERT INTO ex037_results VALUES ('T7 skip locked', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex037_results VALUES ('T7 skip locked', 'ERROR', SQLERRM);
END;
$$;

-- T8: status approved skip
DO $$
DECLARE
  v_res jsonb;
BEGIN
  UPDATE data.time_daily_summaries
  SET payroll_locked_at = NULL,
      status = 'approved',
      expected_minutes = 999
  WHERE employee_id = 'd0380000-0000-0000-0000-000000000001'
    AND work_date = '2026-07-13';

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_res := api.backfill_attendance_work_plan(
    'a0380000-0000-0000-0000-000000000001'::uuid,
    'b0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    '2026-07-13'::date,
    true,
    'enqueue'
  );
  SET LOCAL ROLE postgres;

  IF (v_res->>'skipped_non_draft')::int >= 1
     AND (v_res->>'eligible')::int = 0
  THEN
    INSERT INTO ex037_results VALUES ('T8 skip approved', 'PASS',
      format('non_draft=%s', v_res->>'skipped_non_draft'));
  ELSE
    INSERT INTO ex037_results VALUES ('T8 skip approved', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex037_results VALUES ('T8 skip approved', 'ERROR', SQLERRM);
END;
$$;

-- T9: backfill sync actualitza expected_minutes
DO $$
DECLARE
  v_res jsonb;
  v_exp int;
BEGIN
  UPDATE data.time_daily_summaries
  SET status = 'draft',
      payroll_locked_at = NULL,
      expected_minutes = 999
  WHERE employee_id = 'd0380000-0000-0000-0000-000000000001'
    AND work_date = '2026-07-13';

  -- Sense absència ni slot → canònic = 480
  UPDATE data.shift_slots
  SET status = 'cancelled'
  WHERE employee_id = 'd0380000-0000-0000-0000-000000000001'
    AND slot_date = '2026-07-13';

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_res := api.backfill_attendance_work_plan(
    'a0380000-0000-0000-0000-000000000001'::uuid,
    'b0380000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    '2026-07-13'::date,
    false,
    'sync'
  );
  SET LOCAL ROLE postgres;

  SELECT expected_minutes INTO v_exp
  FROM data.time_daily_summaries
  WHERE employee_id = 'd0380000-0000-0000-0000-000000000001'
    AND work_date = '2026-07-13';

  IF (v_res->>'recomputed')::int >= 1 AND v_exp = 480 THEN
    INSERT INTO ex037_results VALUES ('T9 backfill sync 480', 'PASS',
      format('expected=%s recomputed=%s', v_exp, v_res->>'recomputed'));
  ELSE
    INSERT INTO ex037_results VALUES ('T9 backfill sync 480', 'FAIL',
      format('res=%s expected=%s', v_res, v_exp));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex037_results VALUES ('T9 backfill sync 480', 'ERROR', SQLERRM);
END;
$$;

SELECT * FROM ex037_results ORDER BY test_name;

SELECT
  count(*) FILTER (WHERE status = 'PASS') AS passed,
  count(*) FILTER (WHERE status = 'FAIL') AS failed,
  count(*) FILTER (WHERE status = 'ERROR') AS errors,
  count(*) AS total
FROM ex037_results;

ROLLBACK;
