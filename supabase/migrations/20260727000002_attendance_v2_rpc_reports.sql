-- =============================================================================
-- Control Horari v2 — record_time_punch, recompute, reports, MV, pipeline
-- =============================================================================

-- Drop old record_time_punch signature to allow new params
DROP FUNCTION IF EXISTS api.record_time_punch(uuid, uuid, text, timestamptz, jsonb, text, text, text, uuid);

CREATE OR REPLACE FUNCTION api.record_time_punch(
  p_employee_id          uuid,
  p_client_op_id         uuid,
  p_punch_type           text,
  p_occurred_at          timestamptz DEFAULT now(),
  p_geo                  jsonb       DEFAULT NULL,
  p_location_perm        text        DEFAULT 'notrequired',
  p_notes                text        DEFAULT NULL,
  p_source               text        DEFAULT 'mobile',
  p_device_id            uuid        DEFAULT NULL,
  p_pause_type           text        DEFAULT NULL,
  p_pause_counts_as_work boolean     DEFAULT NULL,
  p_is_remote            boolean     DEFAULT false,
  p_geo_consent          boolean     DEFAULT false,
  p_geo_error            text        DEFAULT NULL,
  p_device_info          jsonb       DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, pgmq
AS $$
DECLARE
  v_employee       record;
  v_punch_id       uuid;
  v_anomalies      text[];
  v_offset_ms      bigint;
  v_threshold_ms   bigint;
  v_settings       jsonb;
  v_last_punch     record;
  v_pause_cfg      record;
  v_counts_work    boolean;
  v_geo_lat        numeric(10,7);
  v_geo_lng        numeric(10,7);
  v_geo_acc        real;
  v_geo_alt        real;
  v_geo_spd        real;
  v_work_date      date;
BEGIN
  SELECT e.tenant_id, e.site_id, e.user_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND (data.active_tenant_id() IS NULL OR e.tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_employee.status != 'active' THEN
    RAISE EXCEPTION 'employee_not_active: %', p_employee_id USING ERRCODE = 'check_violation';
  END IF;
  IF v_employee.site_id IS NULL THEN
    RAISE EXCEPTION 'employee_no_site' USING ERRCODE = 'check_violation';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_employee.user_id IS DISTINCT FROM auth.uid() THEN
      IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.adjust', v_employee.site_id) THEN
        RAISE EXCEPTION 'insufficient_privilege: cannot punch for another employee' USING ERRCODE = 'insufficient_privilege';
      END IF;
    ELSE
      IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.punch_own', v_employee.site_id) THEN
        RAISE EXCEPTION 'insufficient_privilege: attendance.punch_own required' USING ERRCODE = 'insufficient_privilege';
      END IF;
    END IF;
  END IF;

  SELECT id INTO v_punch_id FROM data.time_punches
  WHERE tenant_id = v_employee.tenant_id AND client_op_id = p_client_op_id;

  IF v_punch_id IS NOT NULL THEN
    RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'duplicate', 'anomaly_codes', ARRAY[]::text[]);
  END IF;

  v_work_date := (p_occurred_at AT TIME ZONE 'Europe/Madrid')::date;

  -- Màquina d'estats: validar seqüència del dia
  SELECT punch_type, pause_type INTO v_last_punch
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_work_date
  ORDER BY occurred_at DESC, id DESC
  LIMIT 1;

  IF p_punch_type = 'in' AND v_last_punch.punch_type IN ('in', 'break_start') THEN
    RAISE EXCEPTION 'invalid_sequence: already working or on pause' USING ERRCODE = 'check_violation';
  END IF;
  IF p_punch_type = 'out' THEN
    IF v_last_punch IS NULL OR v_last_punch.punch_type = 'out' THEN
      RAISE EXCEPTION 'invalid_sequence: not working' USING ERRCODE = 'check_violation';
    END IF;
    IF v_last_punch.punch_type = 'break_start' THEN
      RAISE EXCEPTION 'invalid_sequence: close pause before punch out' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF p_punch_type = 'break_start' AND COALESCE(v_last_punch.punch_type, 'out') NOT IN ('in', 'break_end') THEN
    RAISE EXCEPTION 'invalid_sequence: must be working to start pause' USING ERRCODE = 'check_violation';
  END IF;
  IF p_punch_type = 'break_end' AND v_last_punch.punch_type != 'break_start' THEN
    RAISE EXCEPTION 'invalid_sequence: no open pause' USING ERRCODE = 'check_violation';
  END IF;

  -- Snapshot pause_counts_as_work des de config tenant
  v_counts_work := p_pause_counts_as_work;
  IF p_punch_type IN ('break_start', 'break_end') AND p_pause_type IS NOT NULL THEN
    SELECT counts_as_work INTO v_pause_cfg
    FROM data.tenant_pause_configs
    WHERE tenant_id = v_employee.tenant_id AND key = p_pause_type AND is_active = true;
    IF FOUND THEN
      v_counts_work := v_pause_cfg.counts_as_work;
    END IF;
  END IF;

  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);

  SELECT api.get_effective_settings(
    p_site_id => v_employee.site_id, p_user_id => auth.uid(), p_tenant_id => v_employee.tenant_id
  ) INTO v_settings;

  v_threshold_ms := COALESCE((v_settings->>'attendance_clock_offset_threshold_ms')::bigint, 300000);
  v_offset_ms := ABS(EXTRACT(EPOCH FROM (p_occurred_at - now())) * 1000)::bigint;
  IF v_offset_ms > v_threshold_ms AND NOT ('CLOCK_SKEW' = ANY(v_anomalies)) THEN
    v_anomalies := array_append(v_anomalies, 'CLOCK_SKEW');
  END IF;

  v_geo_lat := COALESCE((p_geo->>'lat')::numeric, (p_geo->>'latitude')::numeric);
  v_geo_lng := COALESCE((p_geo->>'lng')::numeric, (p_geo->>'longitude')::numeric);
  v_geo_acc := COALESCE((p_geo->>'accuracy')::real, (p_geo->>'accuracy_m')::real);
  v_geo_alt := (p_geo->>'altitude')::real;
  v_geo_spd := (p_geo->>'speed')::real;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, device_id, client_op_id,
    punch_type, occurred_at, received_at,
    geo, location_permission, anomaly_codes, source, notes,
    pause_type, pause_counts_as_work, is_remote,
    geo_lat, geo_lng, geo_accuracy_m, geo_altitude_m, geo_speed_ms,
    geo_consent, geo_error, device_info
  ) VALUES (
    v_employee.tenant_id, v_employee.site_id, p_employee_id, p_device_id, p_client_op_id,
    p_punch_type, p_occurred_at, now(),
    p_geo, p_location_perm, v_anomalies, p_source, p_notes,
    p_pause_type, v_counts_work, COALESCE(p_is_remote, false),
    v_geo_lat, v_geo_lng, v_geo_acc, v_geo_alt, v_geo_spd,
    COALESCE(p_geo_consent, false), p_geo_error, p_device_info
  )
  RETURNING id INTO v_punch_id;

  PERFORM pgmq.send('attendance_recompute_queue', jsonb_build_object(
    'task', 'recompute_attendance_day',
    'tenant_id', v_employee.tenant_id,
    'employee_id', p_employee_id,
    'work_date', v_work_date,
    'idempotency_key', 'recompute-' || p_employee_id::text || '-' || v_work_date::text || '-' || v_punch_id::text
  ));

  -- Trigger d'automatització (no bloquejant)
  BEGIN
    PERFORM pgmq.send('workflow_trigger_queue', jsonb_build_object(
      'trigger_event', CASE p_punch_type
        WHEN 'in' THEN 'PUNCH_IN'
        WHEN 'out' THEN 'PUNCH_OUT'
        WHEN 'break_start' THEN 'PAUSE_START'
        ELSE 'PAUSE_END'
      END,
      'tenant_id', v_employee.tenant_id,
      'trigger_entity_type', 'employee',
      'trigger_entity_id', p_employee_id,
      'payload', jsonb_build_object(
        'punch_id', v_punch_id, 'punch_type', p_punch_type,
        'pause_type', p_pause_type, 'occurred_at', p_occurred_at, 'is_remote', p_is_remote
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    NULL; -- no trencar el punch si la cua d'automatització falla
  END;

  RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'created', 'anomaly_codes', v_anomalies);
END;
$$;

GRANT EXECUTE ON FUNCTION api.record_time_punch(
  uuid, uuid, text, timestamptz, jsonb, text, text, text, uuid,
  text, boolean, boolean, boolean, text, jsonb
) TO authenticated;

-- sync_time_punches: passar camps nous
CREATE OR REPLACE FUNCTION api.sync_time_punches(p_batch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_op      jsonb;
  v_result  jsonb;
  v_results jsonb[] := '{}';
BEGIN
  FOR v_op IN SELECT jsonb_array_elements(p_batch)
  LOOP
    BEGIN
      IF (v_op->>'kind') = 'punch' THEN
        v_result := api.record_time_punch(
          p_employee_id          => (v_op->'payload'->>'employee_id')::uuid,
          p_client_op_id         => (v_op->>'id')::uuid,
          p_punch_type           => v_op->'payload'->>'punch_type',
          p_occurred_at          => (v_op->'payload'->>'occurred_at')::timestamptz,
          p_geo                  => v_op->'payload'->'geo',
          p_location_perm        => COALESCE(v_op->'payload'->>'location_permission', 'notrequired'),
          p_notes                => v_op->'payload'->>'notes',
          p_source               => COALESCE(v_op->'payload'->>'source', 'mobile'),
          p_pause_type           => v_op->'payload'->>'pause_type',
          p_pause_counts_as_work => (v_op->'payload'->>'pause_counts_as_work')::boolean,
          p_is_remote            => COALESCE((v_op->'payload'->>'is_remote')::boolean, false),
          p_geo_consent          => COALESCE((v_op->'payload'->>'geo_consent')::boolean, false),
          p_geo_error            => v_op->'payload'->>'geo_error',
          p_device_info          => v_op->'payload'->'device_info'
        );
        v_results := array_append(v_results, jsonb_build_object(
          'client_op_id', v_op->>'id', 'status', v_result->>'status',
          'server_id', v_result->>'punch_id', 'message', NULL
        ));
      ELSE
        v_results := array_append(v_results, jsonb_build_object(
          'client_op_id', v_op->>'id', 'status', 'rejected', 'server_id', NULL,
          'message', 'unknown_kind: ' || COALESCE(v_op->>'kind', 'null')
        ));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      PERFORM data.log_audit_event(NULL, auth.uid(), NULL,
        'TIME_PUNCH_REJECTED', 'time_punch', NULL,
        jsonb_build_object('client_op_id', v_op->>'id', 'error', SQLERRM));
      v_results := array_append(v_results, jsonb_build_object(
        'client_op_id', v_op->>'id', 'status', 'rejected', 'server_id', NULL, 'message', SQLERRM
      ));
    END;
  END LOOP;
  RETURN to_jsonb(v_results);
END;
$$;

-- recompute_attendance_worker actualitzat
CREATE OR REPLACE FUNCTION api.recompute_attendance_worker(
  p_employee_id  uuid,
  p_work_date    date,
  p_tenant_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp              record;
  v_first_in_at      timestamptz;
  v_first_in_id      uuid;
  v_last_out_at      timestamptz;
  v_last_out_id      uuid;
  v_gross_min        int;
  v_break_min        int  := 0;
  v_net_min          int;
  v_punch_count      int;
  v_in_count         int;
  v_out_count        int;
  v_bs_count         int;
  v_be_count         int;
  v_anomalies        text[] := '{}';
  v_entry_status     text;
  v_locked_at        timestamptz;
  v_existing_status  text;
  v_open_pause       record;
  v_max_pause_min    int;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND OR v_emp.site_id IS NULL THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'employee_not_found_or_no_site');
  END IF;

  SELECT COUNT(*) AS total,
    COUNT(*) FILTER (WHERE punch_type = 'in') AS in_c,
    COUNT(*) FILTER (WHERE punch_type = 'out') AS out_c,
    COUNT(*) FILTER (WHERE punch_type = 'break_start') AS bs_c,
    COUNT(*) FILTER (WHERE punch_type = 'break_end') AS be_c,
    MIN(occurred_at) FILTER (WHERE punch_type = 'in') AS first_in,
    MAX(occurred_at) FILTER (WHERE punch_type = 'out') AS last_out
  INTO v_punch_count, v_in_count, v_out_count, v_bs_count, v_be_count, v_first_in_at, v_last_out_at
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date;

  SELECT id INTO v_first_in_id FROM data.time_punches
  WHERE employee_id = p_employee_id AND punch_type = 'in'
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
  ORDER BY occurred_at ASC LIMIT 1;

  SELECT id INTO v_last_out_id FROM data.time_punches
  WHERE employee_id = p_employee_id AND punch_type = 'out'
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
  ORDER BY occurred_at DESC LIMIT 1;

  SELECT ARRAY(SELECT DISTINCT unnest_a FROM data.time_punches tp,
    LATERAL unnest(tp.anomaly_codes) AS unnest_a
    WHERE tp.employee_id = p_employee_id
      AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
      AND cardinality(tp.anomaly_codes) > 0
  ) INTO v_anomalies;
  v_anomalies := COALESCE(v_anomalies, '{}');

  IF v_punch_count > 0 AND v_in_count = 0 THEN v_anomalies := array_append(v_anomalies, 'MISSING_IN'); END IF;
  IF v_in_count > v_out_count AND v_out_count > 0 THEN v_anomalies := array_append(v_anomalies, 'EXTRA_IN'); END IF;
  IF v_out_count > v_in_count THEN v_anomalies := array_append(v_anomalies, 'EXTRA_OUT'); END IF;
  IF v_bs_count != v_be_count THEN v_anomalies := array_append(v_anomalies, 'BREAK_MISMATCH'); END IF;

  -- PAUSE_NOT_CLOSED: pausa oberta més enllà del límit
  IF v_bs_count > v_be_count THEN
    SELECT tp.occurred_at, tp.pause_type INTO v_open_pause
    FROM data.time_punches tp
    WHERE tp.employee_id = p_employee_id
      AND tp.punch_type = 'break_start'
      AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
    ORDER BY tp.occurred_at DESC LIMIT 1;

    SELECT COALESCE(tpc.max_duration_minutes, 240) INTO v_max_pause_min
    FROM data.tenant_pause_configs tpc
    WHERE tpc.tenant_id = p_tenant_id AND tpc.key = COALESCE(v_open_pause.pause_type, 'rest')
    LIMIT 1;
    v_max_pause_min := COALESCE(v_max_pause_min, 240);

    IF EXTRACT(EPOCH FROM (now() - v_open_pause.occurred_at)) / 60 > v_max_pause_min THEN
      v_anomalies := array_append(v_anomalies, 'PAUSE_NOT_CLOSED');
    END IF;
  END IF;

  IF v_first_in_at IS NOT NULL AND v_last_out_at IS NOT NULL THEN
    v_gross_min := ROUND(EXTRACT(EPOCH FROM (v_last_out_at - v_first_in_at)) / 60)::int;

    -- Pauses: excloure les que compten com a treball
    SELECT COALESCE(ROUND(SUM(
      EXTRACT(EPOCH FROM (be.occurred_at - bs.occurred_at)) / 60
    ))::int, 0)
    INTO v_break_min
    FROM (
      SELECT occurred_at, pause_counts_as_work, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
      FROM data.time_punches
      WHERE employee_id = p_employee_id AND punch_type = 'break_start'
        AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
    ) bs
    JOIN (
      SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
      FROM data.time_punches
      WHERE employee_id = p_employee_id AND punch_type = 'break_end'
        AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
    ) be ON bs.rn = be.rn
    WHERE be.occurred_at > bs.occurred_at
      AND COALESCE(bs.pause_counts_as_work, false) = false;

    v_net_min := GREATEST(0, v_gross_min - v_break_min);
    v_entry_status := 'closed';
  ELSIF v_first_in_at IS NOT NULL THEN
    v_gross_min := NULL; v_net_min := NULL; v_entry_status := 'open';
  ELSE
    v_gross_min := NULL; v_net_min := NULL;
    v_entry_status := CASE WHEN v_punch_count = 0 THEN 'missing' ELSE 'open' END;
  END IF;

  SELECT payroll_locked_at INTO v_locked_at
  FROM data.time_daily_summaries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF v_locked_at IS NOT NULL THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'payroll_locked',
      'employee_id', p_employee_id, 'work_date', p_work_date);
  END IF;

  SELECT status INTO v_existing_status FROM data.time_entries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF v_existing_status = 'adjusted' THEN
    UPDATE data.time_daily_summaries SET
      punch_count = v_punch_count, anomaly_codes = v_anomalies,
      needs_review = (cardinality(v_anomalies) > 0), recomputed_at = now(), updated_at = now()
    WHERE employee_id = p_employee_id AND work_date = p_work_date AND status = 'draft';
    RETURN jsonb_build_object('skipped_entry', true, 'reason', 'entry_adjusted',
      'employee_id', p_employee_id, 'work_date', p_work_date);
  END IF;

  INSERT INTO data.time_entries (
    tenant_id, site_id, employee_id, work_date, starts_at, ends_at,
    punch_in_id, punch_out_id, gross_minutes, break_minutes, net_minutes,
    regular_minutes, overtime_minutes, status, updated_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date,
    v_first_in_at, v_last_out_at, v_first_in_id, v_last_out_id,
    v_gross_min, v_break_min, v_net_min, v_net_min, 0, v_entry_status, now()
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE SET
    starts_at = EXCLUDED.starts_at, ends_at = EXCLUDED.ends_at,
    punch_in_id = EXCLUDED.punch_in_id, punch_out_id = EXCLUDED.punch_out_id,
    gross_minutes = EXCLUDED.gross_minutes, break_minutes = EXCLUDED.break_minutes,
    net_minutes = EXCLUDED.net_minutes, regular_minutes = EXCLUDED.regular_minutes,
    overtime_minutes = EXCLUDED.overtime_minutes, status = EXCLUDED.status, updated_at = EXCLUDED.updated_at
  WHERE data.time_entries.status != 'adjusted';

  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date, day_type, expected_minutes,
    worked_minutes, break_minutes, overtime_minutes, absence_minutes, punch_count,
    anomaly_codes, needs_review, recomputed_at, updated_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, 'unknown', 0,
    COALESCE(v_net_min, 0), v_break_min, 0, 0, v_punch_count,
    v_anomalies, (cardinality(v_anomalies) > 0 OR v_entry_status = 'missing'), now(), now()
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE SET
    worked_minutes = EXCLUDED.worked_minutes, break_minutes = EXCLUDED.break_minutes,
    punch_count = EXCLUDED.punch_count, anomaly_codes = EXCLUDED.anomaly_codes,
    needs_review = EXCLUDED.needs_review, recomputed_at = EXCLUDED.recomputed_at, updated_at = EXCLUDED.updated_at
  WHERE data.time_daily_summaries.status = 'draft';

  -- Refrescar vista materialitzada del tauler (best-effort)
  BEGIN
    PERFORM data.refresh_today_site_status_mv();
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object('success', true, 'employee_id', p_employee_id, 'work_date', p_work_date,
    'punch_count', v_punch_count, 'net_minutes', v_net_min, 'entry_status', v_entry_status,
    'anomaly_codes', v_anomalies);
END;
$$;

-- attendance_monthly_reports
CREATE TABLE IF NOT EXISTS data.attendance_monthly_reports (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id     uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  year            int         NOT NULL,
  month           int         NOT NULL CHECK (month BETWEEN 1 AND 12),
  document_id     uuid        REFERENCES data.documents(id) ON DELETE SET NULL,
  content_hash    text,
  status          text        NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft', 'employee_confirmed', 'manager_approved', 'signed', 'archived')),
  confirmed_by    uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  confirmed_at    timestamptz,
  approved_by     uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  approved_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, year, month)
);

CREATE TRIGGER trg_set_updated_at_attendance_monthly_reports
  BEFORE UPDATE ON data.attendance_monthly_reports
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.attendance_monthly_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY attendance_monthly_reports_select ON data.attendance_monthly_reports
  FOR SELECT USING (
    tenant_id = data.active_tenant_id()
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR employee_id IN (SELECT id FROM data.employees WHERE user_id = auth.uid())
    )
  );

CREATE OR REPLACE VIEW api.attendance_monthly_reports
  WITH (security_invoker = true) AS SELECT * FROM data.attendance_monthly_reports;

GRANT SELECT ON api.attendance_monthly_reports TO authenticated;

-- export_attendance_month
CREATE OR REPLACE FUNCTION api.export_attendance_month(
  p_employee_id uuid,
  p_year        int,
  p_month       int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp       record;
  v_days      jsonb;
  v_from      date;
  v_to        date;
  v_worked    int;
  v_expected  int;
BEGIN
  SELECT e.tenant_id, e.site_id, e.full_name INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'employee_not_found'; END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      EXISTS (SELECT 1 FROM data.employees WHERE id = p_employee_id AND user_id = auth.uid())
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.export', v_emp.site_id)
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  v_from := make_date(p_year, p_month, 1);
  v_to   := (v_from + interval '1 month' - interval '1 day')::date;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'work_date', te.work_date,
    'starts_at', te.starts_at,
    'ends_at', te.ends_at,
    'break_minutes', te.break_minutes,
    'net_minutes', te.net_minutes,
    'status', te.status,
    'anomaly_codes', COALESCE(tds.anomaly_codes, '{}')
  ) ORDER BY te.work_date), '[]'::jsonb)
  INTO v_days
  FROM data.time_entries te
  LEFT JOIN data.time_daily_summaries tds
    ON tds.employee_id = te.employee_id AND tds.work_date = te.work_date
  WHERE te.employee_id = p_employee_id
    AND te.work_date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(net_minutes), 0), COALESCE(SUM(expected_minutes), 0)
  INTO v_worked, v_expected
  FROM data.time_entries te
  LEFT JOIN data.time_daily_summaries tds
    ON tds.employee_id = te.employee_id AND tds.work_date = te.work_date
  WHERE te.employee_id = p_employee_id AND te.work_date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'employee_name', v_emp.full_name,
    'year', p_year,
    'month', p_month,
    'days', v_days,
    'summary', jsonb_build_object(
      'worked_minutes', v_worked,
      'expected_minutes', v_expected,
      'difference_minutes', v_worked - v_expected
    ),
    'generated_at', now()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.export_attendance_month(uuid, int, int) TO authenticated;

-- confirm / approve monthly report
CREATE OR REPLACE FUNCTION api.confirm_attendance_month(
  p_employee_id uuid, p_year int, p_month int
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, api
AS $$
DECLARE v_id uuid; v_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_tenant FROM data.employees WHERE id = p_employee_id AND user_id = auth.uid();
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'insufficient_privilege'; END IF;

  INSERT INTO data.attendance_monthly_reports (tenant_id, employee_id, year, month, status, confirmed_by, confirmed_at)
  VALUES (v_tenant, p_employee_id, p_year, p_month, 'employee_confirmed', auth.uid(), now())
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'employee_confirmed', confirmed_by = auth.uid(), confirmed_at = now(), updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.confirm_attendance_month(uuid, int, int) TO authenticated;

CREATE OR REPLACE FUNCTION api.approve_attendance_month(
  p_employee_id uuid, p_year int, p_month int
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, api
AS $$
DECLARE v_id uuid; v_emp record;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = p_employee_id;
  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  INSERT INTO data.attendance_monthly_reports (tenant_id, employee_id, year, month, status, approved_by, approved_at)
  VALUES (v_emp.tenant_id, p_employee_id, p_year, p_month, 'manager_approved', auth.uid(), now())
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'manager_approved', approved_by = auth.uid(), approved_at = now(), updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_attendance_month(uuid, int, int) TO authenticated;

-- RPC per Edge Function: esborrar draft report
CREATE OR REPLACE FUNCTION api.upsert_attendance_monthly_report_draft(
  p_tenant_id uuid, p_employee_id uuid, p_year int, p_month int, p_content_hash text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, api
AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO data.attendance_monthly_reports (tenant_id, employee_id, year, month, content_hash, status)
  VALUES (p_tenant_id, p_employee_id, p_year, p_month, p_content_hash, 'draft')
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    content_hash = EXCLUDED.content_hash, updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_attendance_monthly_report_draft(uuid, uuid, int, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_attendance_monthly_report_draft(uuid, uuid, int, int, text) TO service_role;

-- Entitlement decrement on absence approval
CREATE OR REPLACE FUNCTION data.trg_absence_entitlement_on_approve()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_days numeric;
BEGIN
  IF NEW.status = 'approved' AND OLD.status = 'requested' AND NEW.absence_type = 'vacation' THEN
    v_days := (NEW.end_date - NEW.start_date + 1)::numeric;
    UPDATE data.vacation_entitlements ve SET
      days_used = days_used + v_days, updated_at = now()
    WHERE ve.tenant_id = NEW.tenant_id AND ve.year = EXTRACT(YEAR FROM NEW.start_date)::int
      AND ve.leave_type = 'vacation'
      AND (
        (ve.scope = 'employee' AND ve.employee_id = NEW.employee_id)
        OR (ve.scope = 'department' AND ve.department_id = (
          SELECT department_id FROM data.employees WHERE id = NEW.employee_id))
        OR (ve.scope = 'tenant')
      );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_absence_entitlement_on_approve ON data.employee_absences;
CREATE TRIGGER trg_absence_entitlement_on_approve
  AFTER UPDATE OF status ON data.employee_absences
  FOR EACH ROW EXECUTE FUNCTION data.trg_absence_entitlement_on_approve();

-- Pipeline: augmentar batch default
CREATE OR REPLACE FUNCTION data.invoke_attendance_queue_worker(p_batch_size integer DEFAULT 50)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, public
AS $$
DECLARE v_url text; v_key text; v_req bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING 'invoke_attendance_queue_worker: pg_net not installed.'; RETURN -2;
  END IF;
  SELECT decrypted_secret INTO v_url FROM vault.decrypted_secrets WHERE name = 'supabase_url' LIMIT 1;
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'service_role_key' LIMIT 1;
  IF v_url IS NULL OR v_key IS NULL THEN RAISE WARNING 'vault secrets missing'; RETURN -1; END IF;
  BEGIN
    SELECT net.http_post(
      url := v_url || '/functions/v1/process-attendance-queue',
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
      body := jsonb_build_object('batch_size', p_batch_size)
    ) INTO v_req;
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'http_post failed: %', SQLERRM; RETURN NULL;
  END;
  RETURN v_req;
END;
$$;

NOTIFY pgrst, 'reload schema';
