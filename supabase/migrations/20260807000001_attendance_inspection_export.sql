-- Exportació de registre horari per a Inspecció de Treball (RD 8/2019).
-- Només lectura: NO marca dies com exportats ni estableix payroll_locked_at.

CREATE OR REPLACE FUNCTION api.export_attendance_inspection(
  p_site_id     uuid,
  p_from        date,
  p_to          date,
  p_employee_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_site_name text;
  v_rows      jsonb;
  v_count     int;
BEGIN
  SELECT s.tenant_id, s.name INTO v_tenant_id, v_site_name
  FROM data.sites s
  WHERE s.id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.export', p_site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.export required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT
    COALESCE(jsonb_agg(row_data ORDER BY sort_name, sort_date), '[]'::jsonb),
    COUNT(*)
  INTO v_rows, v_count
  FROM (
    SELECT
      jsonb_build_object(
        'employee_id',      e.id,
        'employee_name',    e.full_name,
        'work_date',        tds.work_date,
        'starts_at',        te.starts_at,
        'ends_at',          te.ends_at,
        'break_minutes',    te.break_minutes,
        'net_minutes',      te.net_minutes,
        'gross_minutes',    te.gross_minutes,
        'expected_minutes', tds.expected_minutes,
        'worked_minutes',   tds.worked_minutes,
        'overtime_minutes', tds.overtime_minutes,
        'day_type',         tds.day_type,
        'summary_status',   tds.status,
        'entry_status',     te.status,
        'anomaly_codes',    COALESCE(tds.anomaly_codes, '{}'),
        'punch_count',      tds.punch_count,
        'needs_review',     COALESCE(tds.needs_review, false),
        'approved_at',      tds.approved_at
      ) AS row_data,
      e.full_name AS sort_name,
      tds.work_date AS sort_date
    FROM data.time_daily_summaries tds
    JOIN data.employees e ON e.id = tds.employee_id
    LEFT JOIN data.time_entries te
      ON te.employee_id = tds.employee_id AND te.work_date = tds.work_date
    WHERE tds.site_id = p_site_id
      AND tds.work_date BETWEEN p_from AND p_to
      AND (p_employee_id IS NULL OR tds.employee_id = p_employee_id)
  ) sub;

  RETURN jsonb_build_object(
    'site_id',      p_site_id,
    'site_name',    v_site_name,
    'tenant_id',    v_tenant_id,
    'from',         p_from,
    'to',           p_to,
    'row_count',    COALESCE(v_count, 0),
    'rows',         COALESCE(v_rows, '[]'::jsonb),
    'generated_at', now(),
    'format',       'inspection_v1'
  );
END;
$$;

COMMENT ON FUNCTION api.export_attendance_inspection(uuid, date, date, uuid) IS
  'Exportació llegible del registre horari per inspecció (sense bloquejar dies).';

GRANT EXECUTE ON FUNCTION api.export_attendance_inspection(uuid, date, date, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
