-- E5: autocorrecció al fitxar — incidències lligades al punch (punches immutables excepte geo GDPR)

CREATE TABLE IF NOT EXISTS data.attendance_punch_discrepancies (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  punch_id    uuid NOT NULL REFERENCES data.time_punches(id) ON DELETE CASCADE,
  resolution  text NOT NULL CHECK (resolution IN (
    'confirmed_ok',
    'strip_geo',
    'overtime_claimed',
    'scheduled_hours_claimed'
  )),
  note        text,
  context     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT attendance_punch_discrepancies_punch_unique UNIQUE (punch_id)
);

CREATE INDEX IF NOT EXISTS idx_attendance_punch_discrepancies_employee
  ON data.attendance_punch_discrepancies (employee_id, created_at DESC);

COMMENT ON TABLE data.attendance_punch_discrepancies IS
  'Declaració de l''empleat després d''un fitxatge amb incidència (E5).';

ALTER TABLE data.attendance_punch_discrepancies ENABLE ROW LEVEL SECURITY;

CREATE POLICY "punch_discrepancies: employee own or manager"
  ON data.attendance_punch_discrepancies FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = attendance_punch_discrepancies.employee_id
        AND (
          e.user_id = auth.uid()
          OR data.jwt_has_permission(e.tenant_id, 'attendance.view', e.site_id)
        )
    )
  );

CREATE POLICY "punch_discrepancies: employee insert own"
  ON data.attendance_punch_discrepancies FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = attendance_punch_discrepancies.employee_id
        AND e.user_id = auth.uid()
    )
  );

GRANT SELECT, INSERT ON data.attendance_punch_discrepancies TO authenticated;

-- Permet anonimitzar geo (GDPR) sense trencar immutabilitat legal del punch
CREATE OR REPLACE FUNCTION data.trg_immutable_time_punches()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF OLD.geo_anonymized_at IS NULL
       AND NEW.geo_anonymized_at IS NOT NULL
       AND NEW.geo_lat IS NULL AND NEW.geo_lng IS NULL
       AND NEW.geo IS NULL
       AND NEW.tenant_id = OLD.tenant_id
       AND NEW.site_id = OLD.site_id
       AND NEW.employee_id = OLD.employee_id
       AND NEW.punch_type = OLD.punch_type
       AND NEW.occurred_at = OLD.occurred_at
       AND NEW.client_op_id = OLD.client_op_id
    THEN
      RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'time_punches_immutable: UPDATE i DELETE no permesos (RDL 8/2019)'
    USING ERRCODE = 'check_violation';
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_anonymize_punch_geo(p_punch_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_punch record;
BEGIN
  SELECT tp.id, tp.employee_id, tp.tenant_id, tp.geo_anonymized_at, e.user_id
  INTO v_punch
  FROM data.time_punches tp
  JOIN data.employees e ON e.id = tp.employee_id
  WHERE tp.id = p_punch_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'punch_not_found: %', p_punch_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_punch.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'insufficient_privilege: not your punch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_punch.geo_anonymized_at IS NOT NULL THEN
    RETURN false;
  END IF;

  UPDATE data.time_punches
  SET geo_lat = NULL,
      geo_lng = NULL,
      geo_accuracy_m = NULL,
      geo_altitude_m = NULL,
      geo_speed_ms = NULL,
      geo = NULL,
      geo_anonymized_at = now(),
      anomaly_codes = array_remove(anomaly_codes, 'HIGH_UNCERTAINTY')
  WHERE id = p_punch_id;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION api.employee_anonymize_punch_geo(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.submit_punch_discrepancy(
  p_punch_id   uuid,
  p_resolution text,
  p_note       text DEFAULT NULL,
  p_context    jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, pgmq, public
AS $$
DECLARE
  v_punch      record;
  v_work_date  date;
  v_anomaly    text;
  v_geo_stripped boolean := false;
BEGIN
  IF p_resolution NOT IN (
    'confirmed_ok', 'strip_geo', 'overtime_claimed', 'scheduled_hours_claimed'
  ) THEN
    RAISE EXCEPTION 'invalid_resolution: %', p_resolution USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT tp.id, tp.employee_id, tp.tenant_id, tp.site_id, tp.occurred_at, e.user_id
  INTO v_punch
  FROM data.time_punches tp
  JOIN data.employees e ON e.id = tp.employee_id
  WHERE tp.id = p_punch_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'punch_not_found: %', p_punch_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_punch.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'insufficient_privilege: not your punch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.attendance_punch_discrepancies d WHERE d.punch_id = p_punch_id
  ) THEN
    RAISE EXCEPTION 'discrepancy_already_submitted' USING ERRCODE = 'unique_violation';
  END IF;

  INSERT INTO data.attendance_punch_discrepancies (
    tenant_id, employee_id, punch_id, resolution, note, context
  ) VALUES (
    v_punch.tenant_id, v_punch.employee_id, p_punch_id, p_resolution, p_note, COALESCE(p_context, '{}'::jsonb)
  );

  IF p_resolution = 'strip_geo' THEN
    v_geo_stripped := api.employee_anonymize_punch_geo(p_punch_id);
  END IF;

  v_work_date := (v_punch.occurred_at AT TIME ZONE 'Europe/Madrid')::date;

  IF p_resolution = 'overtime_claimed' THEN
    v_anomaly := 'OVERTIME_CLAIMED';
  ELSIF p_resolution = 'scheduled_hours_claimed' THEN
    v_anomaly := 'SCHEDULE_HOURS_CLAIMED';
  ELSE
    v_anomaly := NULL;
  END IF;

  IF v_anomaly IS NOT NULL THEN
    INSERT INTO data.time_daily_summaries (
      tenant_id, site_id, employee_id, work_date,
      punch_count, anomaly_codes, needs_review, status, updated_at
    )
    VALUES (
      v_punch.tenant_id, v_punch.site_id, v_punch.employee_id, v_work_date,
      0, ARRAY[v_anomaly], true, 'draft', now()
    )
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      anomaly_codes = (
        SELECT array_agg(DISTINCT x)
        FROM unnest(COALESCE(time_daily_summaries.anomaly_codes, '{}') || ARRAY[v_anomaly]) AS x
      ),
      needs_review = true,
      updated_at = now();
  END IF;

  PERFORM pgmq.send('attendance_recompute_queue', jsonb_build_object(
    'task', 'recompute_attendance_day',
    'tenant_id', v_punch.tenant_id,
    'employee_id', v_punch.employee_id,
    'work_date', v_work_date,
    'idempotency_key', 'recompute-' || v_punch.employee_id::text || '-' || v_work_date::text || '-e5-' || p_punch_id::text
  ));

  PERFORM data.log_audit_event(
    v_punch.tenant_id, auth.uid(), v_punch.site_id,
    'PUNCH_DISCREPANCY_SUBMITTED', 'time_punch', p_punch_id,
    jsonb_build_object(
      'resolution', p_resolution,
      'note', p_note,
      'geo_stripped', v_geo_stripped
    )
  );

  RETURN jsonb_build_object(
    'status', 'submitted',
    'resolution', p_resolution,
    'geo_stripped', v_geo_stripped
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.submit_punch_discrepancy(uuid, text, text, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
