-- =============================================================================
-- attendance_shift_preflight_ex043_tests.sql
-- EX-04.3 — Preflight, períodes tancats, warnings_accepted, diff
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0430000-0000-0000-0000-000000000001', 'EX043 Tenant', 'ex043-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0430000-0000-0000-0000-000000000001', 'a0430000-0000-0000-0000-000000000001', 'EX043 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0430000-0000-0000-0000-000000000001', 'emp@ex043.test', 'authenticated', 'authenticated'),
  ('c0430000-0000-0000-0000-000000000002', 'mgr@ex043.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0430000-0000-0000-0000-000000000001', 'emp@ex043.test', 'Emp EX043'),
  ('c0430000-0000-0000-0000-000000000002', 'mgr@ex043.test', 'Mgr EX043')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0430000-0000-0000-0000-000000000001', 'c0430000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0430000-0000-0000-0000-000000000001', 'c0430000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES (
  'd0430000-0000-0000-0000-000000000001',
  'a0430000-0000-0000-0000-000000000001',
  'b0430000-0000-0000-0000-000000000001',
  'c0430000-0000-0000-0000-000000000001',
  'Emp EX043', 'active', 40
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_shifts (
  id, tenant_id, site_id, name, color, start_time, end_time, is_active
) VALUES
  (
    'f0430000-0000-0000-0000-000000000001',
    'a0430000-0000-0000-0000-000000000001',
    'b0430000-0000-0000-0000-000000000001',
    'Matí EX043', '#3b82f6', '09:00', '17:00', true
  ),
  (
    'f0430000-0000-0000-0000-000000000002',
    'a0430000-0000-0000-0000-000000000001',
    'b0430000-0000-0000-0000-000000000001',
    'Tarda EX043', '#22c55e', '13:00', '21:00', true
  )
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE ex043_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0430000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0430000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0430000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0430000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

-- T1: preflight net → can_publish
DO $$
DECLARE
  v_asg jsonb;
  v_pf jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_asg := api.assign_shift_slot(
    'd0430000-0000-0000-0000-000000000001'::uuid,
    '2026-08-03'::date,
    'f0430000-0000-0000-0000-000000000001'::uuid
  );
  v_pf := api.preflight_publish_shifts(
    'b0430000-0000-0000-0000-000000000001'::uuid,
    '2026-08-03'::date
  );

  SET LOCAL ROLE postgres;

  IF (v_pf->>'draft_count')::int = 1
     AND (v_pf->>'can_publish')::boolean = true
     AND jsonb_array_length(v_pf->'blockers') = 0
     AND v_asg->>'slot_id' IS NOT NULL
  THEN
    INSERT INTO ex043_results VALUES ('T1 preflight clean', 'PASS', v_pf::text);
  ELSE
    INSERT INTO ex043_results VALUES ('T1 preflight clean', 'FAIL', v_pf::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex043_results VALUES ('T1 preflight clean', 'ERROR', SQLERRM);
END;
$$;

-- T2: publish sense warnings → ok + diff added
DO $$
DECLARE
  v_pub jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_pub := api.publish_shifts(
    'b0430000-0000-0000-0000-000000000001'::uuid,
    '2026-08-03'::date,
    NULL
  );

  SET LOCAL ROLE postgres;

  IF (v_pub->>'published')::int = 1
     AND (v_pub->>'version')::int = 1
     AND (v_pub->'diff'->'counts'->>'added')::int = 1
  THEN
    INSERT INTO ex043_results VALUES ('T2 publish clean', 'PASS',
      format('v=%s added=%s', v_pub->>'version', v_pub->'diff'->'counts'->>'added'));
  ELSE
    INSERT INTO ex043_results VALUES ('T2 publish clean', 'FAIL', v_pub::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex043_results VALUES ('T2 publish clean', 'ERROR', SQLERRM);
END;
$$;

-- T3: overlap → warning; publish sense accept → fail; amb accept → ok
DO $$
DECLARE
  v_asg1 jsonb;
  v_asg2 jsonb;
  v_pf jsonb;
  v_failed boolean := false;
  v_pub jsonb;
  v_err text;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_asg1 := api.assign_shift_slot(
    'd0430000-0000-0000-0000-000000000001'::uuid,
    '2026-08-04'::date,
    'f0430000-0000-0000-0000-000000000001'::uuid
  );
  v_asg2 := api.assign_shift_slot(
    'd0430000-0000-0000-0000-000000000001'::uuid,
    '2026-08-04'::date,
    'f0430000-0000-0000-0000-000000000002'::uuid
  );

  v_pf := api.preflight_publish_shifts(
    'b0430000-0000-0000-0000-000000000001'::uuid,
    '2026-08-03'::date
  );

  BEGIN
    PERFORM api.publish_shifts(
      'b0430000-0000-0000-0000-000000000001'::uuid,
      '2026-08-03'::date,
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := SQLERRM LIKE 'preflight_warnings_unaccepted%';
    v_err := SQLERRM;
  END;

  IF NOT v_failed THEN
    SET LOCAL ROLE postgres;
    INSERT INTO ex043_results VALUES ('T3 warnings gate', 'FAIL',
      format('expected unaccepted; pf=%s err=%s', v_pf, v_err));
    RETURN;
  END IF;

  v_pub := api.publish_shifts(
    'b0430000-0000-0000-0000-000000000001'::uuid,
    '2026-08-03'::date,
    ARRAY['SHIFT_OVERLAP']
  );

  SET LOCAL ROLE postgres;

  IF (v_pf->>'can_publish')::boolean = true
     AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_pf->'warnings') w
       WHERE w->>'code' = 'SHIFT_OVERLAP'
     )
     AND (v_pub->>'version')::int = 2
     AND v_asg1->>'slot_id' IS NOT NULL
     AND v_asg2->>'slot_id' IS NOT NULL
  THEN
    INSERT INTO ex043_results VALUES ('T3 warnings gate', 'PASS',
      format('v=%s accepted=%s', v_pub->>'version', v_pub->'warnings_accepted'));
  ELSE
    INSERT INTO ex043_results VALUES ('T3 warnings gate', 'FAIL',
      format('pf=%s pub=%s', v_pf, v_pub));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex043_results VALUES ('T3 warnings gate', 'ERROR', SQLERRM);
END;
$$;

-- T4: diff v1→v2
DO $$
DECLARE
  v_v1 uuid;
  v_v2 uuid;
  v_diff jsonb;
BEGIN
  SELECT id INTO v_v1 FROM data.shift_publications
  WHERE site_id = 'b0430000-0000-0000-0000-000000000001'
    AND week_start = '2026-08-03' AND version = 1;
  SELECT id INTO v_v2 FROM data.shift_publications
  WHERE site_id = 'b0430000-0000-0000-0000-000000000001'
    AND week_start = '2026-08-03' AND version = 2;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_diff := api.diff_shift_publications(v_v1, v_v2);
  SET LOCAL ROLE postgres;

  IF (v_diff->'counts'->>'added')::int >= 1
     AND v_diff->>'from_publication_id' = v_v1::text
     AND v_diff->>'to_publication_id' = v_v2::text
  THEN
    INSERT INTO ex043_results VALUES ('T4 diff publications', 'PASS', v_diff->'counts'::text);
  ELSE
    INSERT INTO ex043_results VALUES ('T4 diff publications', 'FAIL', v_diff::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex043_results VALUES ('T4 diff publications', 'ERROR', SQLERRM);
END;
$$;

-- T5: payroll_locked bloqueja assign
DO $$
DECLARE
  v_blocked boolean := false;
BEGIN
  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date,
    day_type, expected_minutes, worked_minutes, status, payroll_locked_at
  ) VALUES (
    'a0430000-0000-0000-0000-000000000001',
    'b0430000-0000-0000-0000-000000000001',
    'd0430000-0000-0000-0000-000000000001',
    '2026-08-05',
    'work', 480, 480, 'exported', now()
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE
  SET payroll_locked_at = now(), status = 'exported';

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  BEGIN
    PERFORM api.assign_shift_slot(
      'd0430000-0000-0000-0000-000000000001'::uuid,
      '2026-08-05'::date,
      'f0430000-0000-0000-0000-000000000001'::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE 'period_closed:%PAYROLL_LOCKED%';
  END;

  SET LOCAL ROLE postgres;

  IF v_blocked THEN
    INSERT INTO ex043_results VALUES ('T5 payroll lock assign', 'PASS', 'blocked');
  ELSE
    INSERT INTO ex043_results VALUES ('T5 payroll lock assign', 'FAIL', 'not blocked');
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex043_results VALUES ('T5 payroll lock assign', 'ERROR', SQLERRM);
END;
$$;

-- T6: month closed bloqueja publish (via draft + monthly report)
DO $$
DECLARE
  v_asg jsonb;
  v_pf jsonb;
  v_blocked boolean := false;
BEGIN
  INSERT INTO data.attendance_monthly_reports (
    tenant_id, employee_id, year, month, status, approved_by, approved_at
  ) VALUES (
    'a0430000-0000-0000-0000-000000000001',
    'd0430000-0000-0000-0000-000000000001',
    2026, 9, 'manager_approved',
    'c0430000-0000-0000-0000-000000000002', now()
  )
  ON CONFLICT DO NOTHING;

  -- insert as postgres bypassing closed check... need a draft on Sep without assign RPC
  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, created_by
  ) VALUES (
    'a0430000-0000-0000-0000-000000000001',
    'b0430000-0000-0000-0000-000000000001',
    'd0430000-0000-0000-0000-000000000001',
    'f0430000-0000-0000-0000-000000000001',
    '2026-09-07',
    'draft',
    '09:00', '17:00',
    'c0430000-0000-0000-0000-000000000002'
  );

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_pf := api.preflight_publish_shifts(
    'b0430000-0000-0000-0000-000000000001'::uuid,
    '2026-09-07'::date
  );

  BEGIN
    PERFORM api.publish_shifts(
      'b0430000-0000-0000-0000-000000000001'::uuid,
      '2026-09-07'::date,
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE 'preflight_blocked%';
  END;

  SET LOCAL ROLE postgres;

  IF EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_pf->'blockers') b
       WHERE b->>'code' = 'MONTH_CLOSED'
     )
     AND (v_pf->>'can_publish')::boolean = false
     AND v_blocked
  THEN
    INSERT INTO ex043_results VALUES ('T6 month closed publish', 'PASS',
      format('blockers=%s', v_pf->'blockers'));
  ELSE
    INSERT INTO ex043_results VALUES ('T6 month closed publish', 'FAIL',
      format('pf=%s blocked=%s', v_pf, v_blocked));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex043_results VALUES ('T6 month closed publish', 'ERROR', SQLERRM);
END;
$$;

-- T7: bulk_delete en dia payroll_locked → fail
DO $$
DECLARE
  v_slot_id uuid;
  v_blocked boolean := false;
BEGIN
  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, created_by
  ) VALUES (
    'a0430000-0000-0000-0000-000000000001',
    'b0430000-0000-0000-0000-000000000001',
    'd0430000-0000-0000-0000-000000000001',
    'f0430000-0000-0000-0000-000000000001',
    '2026-08-05',
    'draft',
    '09:00', '17:00',
    'c0430000-0000-0000-0000-000000000002'
  )
  RETURNING id INTO v_slot_id;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  BEGIN
    PERFORM api.bulk_delete_shift_slots(ARRAY[v_slot_id]);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE 'period_closed:%';
  END;

  SET LOCAL ROLE postgres;

  IF v_blocked THEN
    INSERT INTO ex043_results VALUES ('T7 delete locked day', 'PASS', 'blocked');
  ELSE
    INSERT INTO ex043_results VALUES ('T7 delete locked day', 'FAIL', 'not blocked');
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex043_results VALUES ('T7 delete locked day', 'ERROR', SQLERRM);
END;
$$;

SELECT * FROM ex043_results ORDER BY test_name;

SELECT
  count(*) FILTER (WHERE status = 'PASS') AS passed,
  count(*) FILTER (WHERE status = 'FAIL') AS failed,
  count(*) FILTER (WHERE status = 'ERROR') AS errors,
  count(*) AS total
FROM ex043_results;

ROLLBACK;
