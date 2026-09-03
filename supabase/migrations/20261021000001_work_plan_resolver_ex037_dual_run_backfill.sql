-- =============================================================================
-- EX-03.7 — Dual-run (shadow compare) + feature flag FF-03 + backfill
--
-- Després d'ADR-0003 no hi ha resolver V1 viu. El flag NO canvia el hot path
-- (resolve_work_day → resolve_employee_work_plan sempre). Serveix per:
--   1) documentar FF-03 / kill-switch operatiu de shadow compare
--   2) comparar canònic vs labor-only (diffs esperats: absència, slots, edo)
--   3) backfill de dies draft/unlocked via worker/cua existent
-- =============================================================================

-- ─── 1. FF-03: work_plan_resolver_v2 (default ON) ────────────────────────────

INSERT INTO data.feature_flags (key, description, is_enabled, rollout_percentage)
VALUES (
  'work_plan_resolver_v2',
  'FF-03 / EX-03.7: resolver canònic resolve_employee_work_plan. '
  'Gate de shadow-compare i backfill; NO torna a un path V1 (eliminat ADR-0003).',
  true,
  100
)
ON CONFLICT (key) DO UPDATE
SET description = EXCLUDED.description,
    is_enabled = EXCLUDED.is_enabled,
    rollout_percentage = EXCLUDED.rollout_percentage,
    updated_at = now();

CREATE OR REPLACE FUNCTION data.is_work_plan_resolver_v2_enabled(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(data.is_feature_enabled(p_tenant_id, 'work_plan_resolver_v2'), false);
$$;

COMMENT ON FUNCTION data.is_work_plan_resolver_v2_enabled(uuid) IS
  'EX-03.7 FF-03: true si el tenant té work_plan_resolver_v2 actiu (default global ON).';

REVOKE ALL ON FUNCTION data.is_work_plan_resolver_v2_enabled(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.is_work_plan_resolver_v2_enabled(uuid) TO authenticated, service_role;

-- ─── 2. Baseline labor-only (sense absència / slots / edo) ───────────────────

CREATE OR REPLACE FUNCTION data.build_labor_only_work_plan(
  p_employee_id uuid,
  p_work_date   date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_emp record;
  v_lab record;
  v_day_type text;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND OR v_emp.site_id IS NULL THEN
    RETURN jsonb_build_object(
      'day_type', 'unknown',
      'labor_day_type', 'undefined',
      'expected_minutes', 0,
      'work_intervals', '[]'::jsonb,
      'labor_source', 'none',
      'error', 'employee_not_found_or_no_site'
    );
  END IF;

  SELECT * INTO v_lab
  FROM data.resolve_labor_calendar_for_employee(
    v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, false
  );

  v_day_type := CASE COALESCE(v_lab.labor_day_type, 'undefined')
    WHEN 'work' THEN 'working'
    WHEN 'holiday' THEN 'holiday'
    WHEN 'vacation' THEN 'non_working'
    WHEN 'leave' THEN 'non_working'
    WHEN 'undefined' THEN 'unknown'
    ELSE 'unknown'
  END;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'work_date', p_work_date,
    'day_type', v_day_type,
    'labor_day_type', COALESCE(v_lab.labor_day_type, 'undefined'),
    'expected_minutes', COALESCE(v_lab.planned_minutes, 0),
    'work_intervals', COALESCE(v_lab.work_intervals, '[]'::jsonb),
    'labor_source', COALESCE(v_lab.labor_source, 'none'),
    'is_half_day', COALESCE(v_lab.is_half_day, false),
    'holiday_name', v_lab.labor_day_name
  );
END;
$$;

COMMENT ON FUNCTION data.build_labor_only_work_plan(uuid, date) IS
  'EX-03.7: baseline labor-only per shadow-compare (sense absència/slots/edo).';

REVOKE ALL ON FUNCTION data.build_labor_only_work_plan(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.build_labor_only_work_plan(uuid, date) TO authenticated, service_role;

-- ─── 3. Shadow compare canònic vs labor-only ─────────────────────────────────

CREATE OR REPLACE FUNCTION data.compare_work_plan_resolver(
  p_employee_id    uuid,
  p_work_date      date,
  p_include_stored boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_canon     jsonb;
  v_labor     jsonb;
  v_stored    jsonb := NULL;
  v_reasons   text[] := ARRAY[]::text[];
  v_fields    text[] := ARRAY[]::text[];
  v_match     boolean;
  v_expected  boolean;
  v_canon_min int;
  v_labor_min int;
  v_canon_dt  text;
  v_labor_dt  text;
BEGIN
  SELECT tenant_id INTO v_tenant_id
  FROM data.employees WHERE id = p_employee_id;

  IF v_tenant_id IS NULL THEN
    RETURN jsonb_build_object('error', 'employee_not_found');
  END IF;

  IF NOT data.is_work_plan_resolver_v2_enabled(v_tenant_id) THEN
    RETURN jsonb_build_object(
      'enabled', false,
      'skipped', true,
      'reason', 'work_plan_resolver_v2_disabled'
    );
  END IF;

  v_canon := data.resolve_employee_work_plan(p_employee_id, p_work_date);
  v_labor := data.build_labor_only_work_plan(p_employee_id, p_work_date);

  v_canon_min := COALESCE((v_canon->>'expected_minutes')::int, 0);
  v_labor_min := COALESCE((v_labor->>'expected_minutes')::int, 0);
  v_canon_dt  := COALESCE(v_canon->>'day_type', 'unknown');
  v_labor_dt  := COALESCE(v_labor->>'day_type', 'unknown');

  IF v_canon_dt IS DISTINCT FROM v_labor_dt THEN
    v_fields := array_append(v_fields, 'day_type');
  END IF;
  IF v_canon_min IS DISTINCT FROM v_labor_min THEN
    v_fields := array_append(v_fields, 'expected_minutes');
  END IF;
  IF (v_canon->'work_intervals') IS DISTINCT FROM (v_labor->'work_intervals') THEN
    v_fields := array_append(v_fields, 'work_intervals');
  END IF;

  v_match := cardinality(v_fields) = 0;

  IF COALESCE((v_canon->>'is_absence')::boolean, false) THEN
    v_reasons := array_append(v_reasons, 'absence');
  END IF;
  IF jsonb_typeof(v_canon->'published_slot_ids') = 'array'
     AND jsonb_array_length(COALESCE(v_canon->'published_slot_ids', '[]'::jsonb)) > 0 THEN
    v_reasons := array_append(v_reasons, 'published_slots');
  END IF;
  IF COALESCE((v_canon->>'employee_override')::boolean, false) THEN
    v_reasons := array_append(v_reasons, 'employee_day_override');
  END IF;

  v_expected := (NOT v_match) AND cardinality(v_reasons) > 0;

  IF p_include_stored THEN
    SELECT jsonb_build_object(
      'expected_minutes', tds.expected_minutes,
      'day_type', tds.day_type,
      'status', tds.status,
      'payroll_locked_at', tds.payroll_locked_at,
      'recomputed_at', tds.recomputed_at
    )
    INTO v_stored
    FROM data.time_daily_summaries tds
    WHERE tds.employee_id = p_employee_id
      AND tds.work_date = p_work_date;
  END IF;

  RETURN jsonb_build_object(
    'enabled', true,
    'skipped', false,
    'match', v_match,
    'expected_diff', v_expected,
    'unexpected_diff', (NOT v_match) AND (NOT v_expected),
    'diff_reasons', to_jsonb(v_reasons),
    'diff_fields', to_jsonb(v_fields),
    'canonical', jsonb_build_object(
      'day_type', v_canon_dt,
      'expected_minutes', v_canon_min,
      'work_intervals', v_canon->'work_intervals',
      'is_absence', COALESCE((v_canon->>'is_absence')::boolean, false),
      'published_slot_ids', COALESCE(v_canon->'published_slot_ids', '[]'::jsonb),
      'labor_source', v_canon->>'labor_source'
    ),
    'labor_only', jsonb_build_object(
      'day_type', v_labor_dt,
      'expected_minutes', v_labor_min,
      'work_intervals', v_labor->'work_intervals',
      'labor_source', v_labor->>'labor_source'
    ),
    'stored', v_stored
  );
END;
$$;

COMMENT ON FUNCTION data.compare_work_plan_resolver(uuid, date, boolean) IS
  'EX-03.7: shadow-compare canònic vs labor-only; flag OFF → skipped.';

REVOKE ALL ON FUNCTION data.compare_work_plan_resolver(uuid, date, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.compare_work_plan_resolver(uuid, date, boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.compare_work_plan_resolver(
  p_employee_id    uuid,
  p_work_date      date,
  p_include_stored boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'employee_not_found');
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_emp.tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT COALESCE(
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage'),
      false
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN data.compare_work_plan_resolver(p_employee_id, p_work_date, p_include_stored);
END;
$$;

GRANT EXECUTE ON FUNCTION api.compare_work_plan_resolver(uuid, date, boolean) TO authenticated, service_role;

-- ─── 4. Backfill dies draft / unlocked ───────────────────────────────────────

CREATE OR REPLACE FUNCTION api.backfill_attendance_work_plan(
  p_tenant_id uuid,
  p_site_id   uuid DEFAULT NULL,
  p_from_date date DEFAULT NULL,
  p_to_date   date DEFAULT NULL,
  p_dry_run   boolean DEFAULT true,
  p_mode      text DEFAULT 'enqueue'
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_mode text := lower(COALESCE(nullif(btrim(p_mode), ''), 'enqueue'));
  v_from date := COALESCE(p_from_date, (current_date - 30));
  v_to   date := COALESCE(p_to_date, current_date);
  v_eligible int := 0;
  v_locked   int := 0;
  v_non_draft int := 0;
  v_enqueued int := 0;
  v_recomputed int := 0;
  v_sync_cap int := 500;
  r record;
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_id_required';
  END IF;

  IF v_to < v_from THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  IF v_mode NOT IN ('enqueue', 'sync') THEN
    RAISE EXCEPTION 'invalid_mode: use enqueue|sync';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT COALESCE(
      data.jwt_has_permission(p_tenant_id, 'attendance.view_all', p_site_id)
      OR data.jwt_has_permission(p_tenant_id, 'labor_calendar.manage'),
      false
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  IF NOT data.is_work_plan_resolver_v2_enabled(p_tenant_id) THEN
    RETURN jsonb_build_object(
      'enabled', false,
      'skipped', true,
      'reason', 'work_plan_resolver_v2_disabled'
    );
  END IF;

  FOR r IN
    SELECT
      e.id AS employee_id,
      gs.d::date AS work_date,
      tds.status,
      tds.payroll_locked_at
    FROM data.employees e
    CROSS JOIN generate_series(v_from, v_to, '1 day'::interval) AS gs(d)
    LEFT JOIN data.time_daily_summaries tds
      ON tds.employee_id = e.id
     AND tds.work_date = gs.d::date
    WHERE e.tenant_id = p_tenant_id
      AND e.status = 'active'
      AND (p_site_id IS NULL OR e.site_id = p_site_id)
    ORDER BY e.id, gs.d
  LOOP
    IF r.payroll_locked_at IS NOT NULL THEN
      v_locked := v_locked + 1;
      CONTINUE;
    END IF;

    IF r.status IS NOT NULL AND r.status IS DISTINCT FROM 'draft' THEN
      v_non_draft := v_non_draft + 1;
      CONTINUE;
    END IF;

    -- Eligible: sense summary (es crearà) o draft sense lock
    v_eligible := v_eligible + 1;

    IF p_dry_run THEN
      CONTINUE;
    END IF;

    IF v_mode = 'enqueue' THEN
      PERFORM data.enqueue_attendance_day_recompute(
        p_tenant_id, r.employee_id, r.work_date,
        format('backfill-ex037-%s', r.work_date)
      );
      v_enqueued := v_enqueued + 1;
    ELSIF v_mode = 'sync' AND v_recomputed < v_sync_cap THEN
      PERFORM api.recompute_attendance_worker(r.employee_id, r.work_date, p_tenant_id);
      v_recomputed := v_recomputed + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'enabled', true,
    'dry_run', p_dry_run,
    'mode', v_mode,
    'from_date', v_from,
    'to_date', v_to,
    'eligible', v_eligible,
    'skipped_locked', v_locked,
    'skipped_non_draft', v_non_draft,
    'enqueued', v_enqueued,
    'recomputed', v_recomputed,
    'sync_cap', v_sync_cap
  );
END;
$$;

COMMENT ON FUNCTION api.backfill_attendance_work_plan(uuid, uuid, date, date, boolean, text) IS
  'EX-03.7: recompute dies draft/unlocked (enqueue|sync); dry_run per defecte.';

REVOKE ALL ON FUNCTION api.backfill_attendance_work_plan(uuid, uuid, date, date, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.backfill_attendance_work_plan(uuid, uuid, date, date, boolean, text) TO authenticated, service_role;
