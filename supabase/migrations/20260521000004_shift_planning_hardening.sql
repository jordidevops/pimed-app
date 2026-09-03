CREATE TABLE IF NOT EXISTS data.shift_coverage_requirements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id uuid NOT NULL REFERENCES data.sites(id) ON DELETE CASCADE,
  shift_id uuid REFERENCES data.work_shifts(id) ON DELETE CASCADE,
  day_of_week smallint CHECK (day_of_week BETWEEN 0 AND 6),
  required_employees int NOT NULL CHECK (required_employees >= 0),
  effective_from date NOT NULL DEFAULT CURRENT_DATE,
  effective_to date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_shift_coverage_dates CHECK (effective_to IS NULL OR effective_to > effective_from)
);

CREATE INDEX IF NOT EXISTS idx_shift_coverage_req_site_day
  ON data.shift_coverage_requirements (site_id, day_of_week, effective_from, effective_to);

DROP TRIGGER IF EXISTS trg_updated_at_shift_coverage_requirements ON data.shift_coverage_requirements;
CREATE TRIGGER trg_updated_at_shift_coverage_requirements
  BEFORE UPDATE ON data.shift_coverage_requirements
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.shift_coverage_requirements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS scr_select ON data.shift_coverage_requirements;
DROP POLICY IF EXISTS scr_insert ON data.shift_coverage_requirements;
DROP POLICY IF EXISTS scr_update ON data.shift_coverage_requirements;
DROP POLICY IF EXISTS scr_delete ON data.shift_coverage_requirements;

CREATE POLICY scr_select ON data.shift_coverage_requirements FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.view', site_id)
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
      OR data.jwt_has_permission(tenant_id, 'attendance.view_all', site_id)
    )
  );

CREATE POLICY scr_insert ON data.shift_coverage_requirements FOR INSERT
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  );

CREATE POLICY scr_update ON data.shift_coverage_requirements FOR UPDATE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  );

CREATE POLICY scr_delete ON data.shift_coverage_requirements FOR DELETE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  );

CREATE OR REPLACE VIEW api.shift_coverage_requirements
  WITH (security_invoker = true)
AS
SELECT * FROM data.shift_coverage_requirements;

GRANT SELECT ON data.shift_coverage_requirements TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.shift_coverage_requirements TO service_role;
GRANT SELECT ON api.shift_coverage_requirements TO authenticated;

CREATE OR REPLACE FUNCTION data.shift_slot_start_ts(
  p_slot_date date,
  p_start_time time
)
RETURNS timestamp
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_slot_date::timestamp + p_start_time;
$$;

CREATE OR REPLACE FUNCTION data.shift_slot_end_ts(
  p_slot_date date,
  p_start_time time,
  p_end_time time
)
RETURNS timestamp
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_end_time > p_start_time THEN p_slot_date::timestamp + p_end_time
    ELSE (p_slot_date + 1)::timestamp + p_end_time
  END;
$$;

CREATE OR REPLACE FUNCTION data.shift_slots_overlap(
  p_date_a date,
  p_start_a time,
  p_end_a time,
  p_date_b date,
  p_start_b time,
  p_end_b time
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT data.shift_slot_start_ts(p_date_a, p_start_a) < data.shift_slot_end_ts(p_date_b, p_start_b, p_end_b)
     AND data.shift_slot_start_ts(p_date_b, p_start_b) < data.shift_slot_end_ts(p_date_a, p_start_a, p_end_a);
$$;

CREATE OR REPLACE FUNCTION data.trg_validate_work_shift_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_site_tenant uuid;
BEGIN
  IF NEW.site_id IS NOT NULL THEN
    SELECT tenant_id INTO v_site_tenant FROM data.sites WHERE id = NEW.site_id;
    IF v_site_tenant IS NULL OR v_site_tenant <> NEW.tenant_id THEN
      RAISE EXCEPTION 'integrity_violation: work_shift site tenant mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_work_shift_integrity ON data.work_shifts;
CREATE TRIGGER trg_validate_work_shift_integrity
  BEFORE INSERT OR UPDATE ON data.work_shifts
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_work_shift_integrity();

CREATE OR REPLACE FUNCTION data.trg_validate_shift_slot_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp record;
  v_shift record;
  v_site_tenant uuid;
BEGIN
  SELECT tenant_id, site_id, status INTO v_emp FROM data.employees WHERE id = NEW.employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'integrity_violation: employee not found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_emp.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot employee tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT tenant_id, site_id, start_time, end_time INTO v_shift FROM data.work_shifts WHERE id = NEW.shift_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'integrity_violation: work_shift not found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_shift.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot shift tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT tenant_id INTO v_site_tenant FROM data.sites WHERE id = NEW.site_id;
  IF v_site_tenant IS NULL OR v_site_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot site tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_shift.site_id IS NOT NULL AND v_shift.site_id <> NEW.site_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot shift site mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.start_time IS NULL THEN
    NEW.start_time := v_shift.start_time;
  END IF;
  IF NEW.end_time IS NULL THEN
    NEW.end_time := v_shift.end_time;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_shift_slot_integrity ON data.shift_slots;
CREATE TRIGGER trg_validate_shift_slot_integrity
  BEFORE INSERT OR UPDATE OF tenant_id, site_id, employee_id, shift_id, start_time, end_time ON data.shift_slots
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_shift_slot_integrity();

CREATE OR REPLACE FUNCTION data.trg_validate_shift_swap_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_req_slot record;
  v_target_slot record;
  v_target_emp_tenant uuid;
BEGIN
  SELECT tenant_id, employee_id, status INTO v_req_slot FROM data.shift_slots WHERE id = NEW.requester_slot_id;
  IF NOT FOUND OR v_req_slot.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: invalid requester slot for swap'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.status = 'pending' AND v_req_slot.employee_id <> NEW.requester_id THEN
    RAISE EXCEPTION 'integrity_violation: invalid requester slot for pending swap'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.target_employee_id IS NOT NULL THEN
    SELECT tenant_id INTO v_target_emp_tenant FROM data.employees WHERE id = NEW.target_employee_id;
    IF v_target_emp_tenant IS NULL OR v_target_emp_tenant <> NEW.tenant_id THEN
      RAISE EXCEPTION 'integrity_violation: invalid target employee for swap'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  IF NEW.target_slot_id IS NOT NULL THEN
    SELECT tenant_id, employee_id, status INTO v_target_slot FROM data.shift_slots WHERE id = NEW.target_slot_id;
    IF NOT FOUND OR v_target_slot.tenant_id <> NEW.tenant_id THEN
      RAISE EXCEPTION 'integrity_violation: invalid target slot for swap'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF NEW.target_employee_id IS NOT NULL AND v_target_slot.employee_id <> NEW.target_employee_id THEN
      RAISE EXCEPTION 'integrity_violation: target slot employee mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_shift_swap_integrity ON data.shift_swap_requests;
CREATE TRIGGER trg_validate_shift_swap_integrity
  BEFORE INSERT OR UPDATE OF tenant_id, requester_slot_id, target_slot_id, requester_id, target_employee_id ON data.shift_swap_requests
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_shift_swap_integrity();

CREATE OR REPLACE FUNCTION data.trg_validate_shift_coverage_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_site_tenant uuid;
  v_shift record;
BEGIN
  SELECT tenant_id INTO v_site_tenant FROM data.sites WHERE id = NEW.site_id;
  IF v_site_tenant IS NULL OR v_site_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: coverage site tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.shift_id IS NOT NULL THEN
    SELECT tenant_id, site_id INTO v_shift FROM data.work_shifts WHERE id = NEW.shift_id;
    IF NOT FOUND OR v_shift.tenant_id <> NEW.tenant_id THEN
      RAISE EXCEPTION 'integrity_violation: coverage shift tenant mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_shift.site_id IS NOT NULL AND v_shift.site_id <> NEW.site_id THEN
      RAISE EXCEPTION 'integrity_violation: coverage shift site mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_shift_coverage_integrity ON data.shift_coverage_requirements;
CREATE TRIGGER trg_validate_shift_coverage_integrity
  BEFORE INSERT OR UPDATE ON data.shift_coverage_requirements
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_shift_coverage_integrity();

CREATE OR REPLACE FUNCTION api.assign_shift_slot(
  p_employee_id uuid,
  p_slot_date date,
  p_shift_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_shift record;
  v_slot_id uuid;
  v_anomalies text[] := '{}';
  v_week_start date;
  v_week_min numeric := 0;
  v_shift_min numeric;
BEGIN
  SELECT e.tenant_id, e.site_id, e.weekly_hours, e.status INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;

  IF v_emp.status = 'terminated' THEN
    RAISE EXCEPTION 'employee_terminated: no es pot assignar torn a un empleat donat de baixa'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT ws.* INTO v_shift
  FROM data.work_shifts ws
  WHERE ws.id = p_shift_id
    AND ws.tenant_id = v_emp.tenant_id
    AND ws.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shift_not_found_or_inactive: %', p_shift_id USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.shift_slots ss2
    WHERE ss2.employee_id = p_employee_id
      AND ss2.status <> 'cancelled'
      AND ss2.slot_date BETWEEN p_slot_date - 1 AND p_slot_date + 1
      AND data.shift_slots_overlap(
        p_slot_date, v_shift.start_time, v_shift.end_time,
        ss2.slot_date, ss2.start_time, ss2.end_time
      )
  ) THEN
    v_anomalies := array_append(v_anomalies, 'SHIFT_OVERLAP');
  END IF;

  v_week_start := date_trunc('week', p_slot_date::timestamptz)::date;

  v_shift_min := ROUND(EXTRACT(EPOCH FROM CASE WHEN v_shift.end_time > v_shift.start_time THEN v_shift.end_time - v_shift.start_time ELSE interval '24 hours' + (v_shift.end_time - v_shift.start_time) END) / 60);

  SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM CASE WHEN ss2.end_time > ss2.start_time THEN ss2.end_time - ss2.start_time ELSE interval '24 hours' + (ss2.end_time - ss2.start_time) END) / 60)), 0)
  INTO v_week_min
  FROM data.shift_slots ss2
  WHERE ss2.employee_id = p_employee_id
    AND ss2.slot_date >= v_week_start
    AND ss2.slot_date <= v_week_start + 6
    AND ss2.status <> 'cancelled';

  IF v_emp.weekly_hours IS NOT NULL AND (v_week_min + v_shift_min) > (v_emp.weekly_hours * 60) THEN
    v_anomalies := array_append(v_anomalies, 'WEEKLY_HOURS_EXCEEDED');
  END IF;

  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id, slot_date, status, notes, created_by, start_time, end_time
  ) VALUES (
    v_emp.tenant_id, COALESCE(v_shift.site_id, v_emp.site_id), p_employee_id, p_shift_id,
    p_slot_date, 'draft', p_notes, auth.uid(), v_shift.start_time, v_shift.end_time
  )
  RETURNING id INTO v_slot_id;

  PERFORM data.log_audit_event(
    v_emp.tenant_id, auth.uid(), v_emp.site_id,
    'SHIFT_SLOT_ASSIGNED', 'shift_slot', v_slot_id,
    jsonb_build_object('employee_id', p_employee_id, 'shift_id', p_shift_id, 'slot_date', p_slot_date, 'anomalies', v_anomalies)
  );

  RETURN jsonb_build_object('slot_id', v_slot_id, 'status', 'draft', 'anomalies', v_anomalies);
END;
$$;

CREATE OR REPLACE FUNCTION api.publish_shifts(
  p_site_id uuid,
  p_week_start date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id uuid;
  v_tz text;
  v_week_end date;
  v_count int;
  v_slot record;
  v_start_at timestamptz;
  v_end_at timestamptz;
BEGIN
  IF EXTRACT(DOW FROM p_week_start)::int <> 1 THEN
    RAISE EXCEPTION 'invalid_week_start: p_week_start ha de ser dilluns'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_tz := COALESCE((api.get_effective_settings(p_site_id => p_site_id, p_user_id => NULL, p_tenant_id => v_tenant_id) ->> 'site_timezone'), 'Europe/Madrid');
  v_week_end := p_week_start + 6;

  UPDATE data.shift_slots
  SET status = 'published', published_at = now(), updated_at = now()
  WHERE site_id = p_site_id AND slot_date BETWEEN p_week_start AND v_week_end AND status = 'draft';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  FOR v_slot IN
    SELECT ss.id AS slot_id, ss.employee_id, ss.slot_date, ss.site_id, ss.start_time, ss.end_time, ws.name, ws.color
    FROM data.shift_slots ss
    JOIN data.work_shifts ws ON ws.id = ss.shift_id
    WHERE ss.site_id = p_site_id AND ss.slot_date BETWEEN p_week_start AND v_week_end AND ss.status = 'published'
  LOOP
    v_start_at := (v_slot.slot_date::text || ' ' || v_slot.start_time::text)::timestamp AT TIME ZONE v_tz;
    IF v_slot.end_time > v_slot.start_time THEN
      v_end_at := (v_slot.slot_date::text || ' ' || v_slot.end_time::text)::timestamp AT TIME ZONE v_tz;
    ELSE
      v_end_at := ((v_slot.slot_date + 1)::text || ' ' || v_slot.end_time::text)::timestamp AT TIME ZONE v_tz;
    END IF;

    DELETE FROM data.calendar_events WHERE entity_type = 'shift_slot' AND entity_id = v_slot.slot_id;

    INSERT INTO data.calendar_events (
      tenant_id, site_id, entity_type, entity_id, title, start_at, end_at, color, required_permissions, owner_id, metadata
    ) VALUES (
      v_tenant_id, v_slot.site_id, 'shift_slot', v_slot.slot_id, v_slot.name,
      v_start_at, v_end_at, v_slot.color, ARRAY['labor_calendar.view'],
      (SELECT id FROM data.profiles WHERE id = auth.uid() LIMIT 1),
      jsonb_build_object('employee_id', v_slot.employee_id, 'slot_date', v_slot.slot_date)
    );
  END LOOP;

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(), p_site_id,
    'SHIFTS_PUBLISHED', 'shift_slot', NULL,
    jsonb_build_object('site_id', p_site_id, 'week_start', p_week_start, 'published', v_count)
  );

  RETURN jsonb_build_object('site_id', p_site_id, 'week_start', p_week_start, 'published', v_count);
END;
$$;

CREATE OR REPLACE FUNCTION api.get_coverage_for_period(
  p_site_id uuid,
  p_from date,
  p_to date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id uuid;
  v_result jsonb;
BEGIN
  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_privilege: no ets membre del tenant'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_tenant_id, 'attendance.view_all')
    OR data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage')
    OR data.jwt_has_permission(v_tenant_id, 'labor_calendar.view')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.view o view_all requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT jsonb_agg(day_row ORDER BY work_date)
  INTO v_result
  FROM (
    SELECT
      gs.d::date AS work_date,
      COUNT(DISTINCT ss.employee_id) AS employee_count,
      COALESCE((
        SELECT SUM(scr.required_employees)
        FROM data.shift_coverage_requirements scr
        WHERE scr.site_id = p_site_id
          AND (scr.day_of_week IS NULL OR scr.day_of_week = EXTRACT(DOW FROM gs.d)::smallint)
          AND scr.effective_from <= gs.d::date
          AND (scr.effective_to IS NULL OR scr.effective_to > gs.d::date)
      ), 0)::int AS required_employee_count,
      (
        COUNT(DISTINCT ss.employee_id)
        - COALESCE((
          SELECT SUM(scr.required_employees)
          FROM data.shift_coverage_requirements scr
          WHERE scr.site_id = p_site_id
            AND (scr.day_of_week IS NULL OR scr.day_of_week = EXTRACT(DOW FROM gs.d)::smallint)
            AND scr.effective_from <= gs.d::date
            AND (scr.effective_to IS NULL OR scr.effective_to > gs.d::date)
        ), 0)
      )::int AS coverage_delta,
      COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
        'requirement_id', scr.id,
        'shift_id', scr.shift_id,
        'required_employees', scr.required_employees
      )) FILTER (WHERE scr.id IS NOT NULL), '[]'::jsonb) AS requirements,
      COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
        'slot_id', ss.id,
        'employee_id', ss.employee_id,
        'shift_id', ss.shift_id,
        'shift_name', ws.name,
        'color', ws.color,
        'start_time', ss.start_time,
        'end_time', ss.end_time,
        'spans_midnight', (ss.end_time < ss.start_time),
        'status', ss.status
      )) FILTER (WHERE ss.id IS NOT NULL), '[]'::jsonb) AS slots
    FROM generate_series(p_from, p_to, '1 day'::interval) AS gs(d)
    LEFT JOIN data.shift_slots ss
      ON ss.slot_date = gs.d::date
     AND ss.site_id = p_site_id
     AND ss.status <> 'cancelled'
    LEFT JOIN data.work_shifts ws ON ws.id = ss.shift_id
    LEFT JOIN data.shift_coverage_requirements scr
      ON scr.site_id = p_site_id
     AND (scr.day_of_week IS NULL OR scr.day_of_week = EXTRACT(DOW FROM gs.d)::smallint)
     AND scr.effective_from <= gs.d::date
     AND (scr.effective_to IS NULL OR scr.effective_to > gs.d::date)
    GROUP BY gs.d::date
  ) AS day_row;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION api.accept_shift_swap(
  p_request_id uuid,
  p_target_employee_id uuid,
  p_target_slot_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_req record;
BEGIN
  SELECT * INTO v_req FROM data.shift_swap_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'swap_request_not_found: %', p_request_id USING ERRCODE = 'P0002';
  END IF;

  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'swap_not_actionable: status actual = %', v_req.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_req.target_employee_id IS NOT NULL AND v_req.target_employee_id <> p_target_employee_id THEN
    RAISE EXCEPTION 'target_employee_mismatch: la sol·licitud no està adreçada a aquest empleat'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_target_employee_id
      AND e.tenant_id = v_req.tenant_id
      AND e.user_id = auth.uid()
      AND e.status <> 'terminated'
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: has de ser l''empleat destinatari actiu'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_target_employee_id = v_req.requester_id THEN
    RAISE EXCEPTION 'swap_same_employee: target i requester no poden ser el mateix'
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_target_slot_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.shift_slots ss
      WHERE ss.id = p_target_slot_id
        AND ss.tenant_id = v_req.tenant_id
        AND ss.employee_id = p_target_employee_id
        AND ss.status = 'published'
    ) THEN
      RAISE EXCEPTION 'target_slot_not_found_or_invalid: %', p_target_slot_id
        USING ERRCODE = 'P0002';
    END IF;
  END IF;

  UPDATE data.shift_swap_requests
  SET target_employee_id = p_target_employee_id,
      target_slot_id = COALESCE(p_target_slot_id, target_slot_id),
      updated_at = now()
  WHERE id = p_request_id;

  PERFORM data.log_audit_event(
    v_req.tenant_id, auth.uid(), NULL,
    'SHIFT_SWAP_ACCEPTED', 'shift_swap_request', p_request_id,
    jsonb_build_object('target_employee_id', p_target_employee_id, 'target_slot_id', p_target_slot_id)
  );

  RETURN jsonb_build_object('request_id', p_request_id, 'status', 'pending', 'target_employee_id', p_target_employee_id);
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_audit_shift_planning()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_new jsonb;
  v_old jsonb;
  v_tenant uuid;
  v_site uuid;
  v_entity_id uuid;
  v_entity_type text;
BEGIN
  v_new := CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) ELSE NULL END;
  v_old := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) ELSE NULL END;
  v_tenant := COALESCE((v_new->>'tenant_id')::uuid, (v_old->>'tenant_id')::uuid);
  v_site := COALESCE((v_new->>'site_id')::uuid, (v_old->>'site_id')::uuid);
  v_entity_id := COALESCE((v_new->>'id')::uuid, (v_old->>'id')::uuid);
  v_entity_type := TG_TABLE_NAME;

  PERFORM data.log_audit_event(
    v_tenant, auth.uid(), v_site,
    upper(TG_TABLE_NAME || '_' || TG_OP), v_entity_type, v_entity_id,
    jsonb_build_object('old', v_old, 'new', v_new)
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_work_shifts ON data.work_shifts;
CREATE TRIGGER trg_audit_work_shifts
  AFTER INSERT OR UPDATE OR DELETE ON data.work_shifts
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_shift_planning();

DROP TRIGGER IF EXISTS trg_audit_shift_slots ON data.shift_slots;
CREATE TRIGGER trg_audit_shift_slots
  AFTER INSERT OR UPDATE OR DELETE ON data.shift_slots
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_shift_planning();

DROP TRIGGER IF EXISTS trg_audit_shift_swap_requests ON data.shift_swap_requests;
CREATE TRIGGER trg_audit_shift_swap_requests
  AFTER INSERT OR UPDATE OR DELETE ON data.shift_swap_requests
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_shift_planning();

DROP TRIGGER IF EXISTS trg_audit_shift_coverage_requirements ON data.shift_coverage_requirements;
CREATE TRIGGER trg_audit_shift_coverage_requirements
  AFTER INSERT OR UPDATE OR DELETE ON data.shift_coverage_requirements
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_shift_planning();

GRANT EXECUTE ON FUNCTION api.accept_shift_swap(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION data.shift_slots_overlap(date, time, time, date, time, time) TO authenticated;
