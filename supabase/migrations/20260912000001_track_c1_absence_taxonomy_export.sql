-- Track C1 — absence taxonomy (2 levels) + export_code for payroll connectors

-- --- 1. Schema ---

ALTER TABLE data.tenant_absence_type_configs
  ADD COLUMN IF NOT EXISTS parent_key   text,
  ADD COLUMN IF NOT EXISTS subtype_key  text,
  ADD COLUMN IF NOT EXISTS export_code  text;

ALTER TABLE data.tenant_absence_type_configs
  DROP CONSTRAINT IF EXISTS tenant_absence_type_configs_parent_key_check;

ALTER TABLE data.tenant_absence_type_configs
  ADD CONSTRAINT tenant_absence_type_configs_parent_key_check
  CHECK (
    parent_key IS NULL
    OR parent_key IN ('vacation', 'personal', 'family', 'permission', 'it', 'compensation', 'other')
  );

CREATE INDEX IF NOT EXISTS idx_tenant_absence_type_parent
  ON data.tenant_absence_type_configs (tenant_id, parent_key, sort_order);

-- --- 2. Backfill system types ---

UPDATE data.tenant_absence_type_configs
SET
  parent_key = CASE absence_type
    WHEN 'vacation' THEN 'vacation'
    WHEN 'personal_days' THEN 'personal'
    WHEN 'bereavement' THEN 'family'
    WHEN 'marriage' THEN 'family'
    WHEN 'family_hospitalization' THEN 'family'
    WHEN 'family_emergency' THEN 'family'
    WHEN 'partial_medical_personal' THEN 'permission'
    WHEN 'partial_medical_company' THEN 'permission'
    WHEN 'reduced_hours' THEN 'permission'
    WHEN 'it_common' THEN 'it'
    WHEN 'it_work_accident' THEN 'it'
    WHEN 'it_maternity' THEN 'it'
    WHEN 'it_parental' THEN 'it'
    WHEN 'it_menstrual' THEN 'it'
    ELSE COALESCE(parent_key, 'other')
  END,
  subtype_key = COALESCE(subtype_key, absence_type),
  export_code = COALESCE(NULLIF(trim(export_code), ''), CASE absence_type
    WHEN 'vacation' THEN 'VA'
    WHEN 'personal_days' THEN 'AP'
    WHEN 'bereavement' THEN 'DF'
    WHEN 'marriage' THEN 'MA'
    WHEN 'family_hospitalization' THEN 'HF'
    WHEN 'family_emergency' THEN 'UF'
    WHEN 'partial_medical_personal' THEN 'MP'
    WHEN 'partial_medical_company' THEN 'MC'
    WHEN 'reduced_hours' THEN 'RJ'
    WHEN 'it_common' THEN 'IT'
    WHEN 'it_work_accident' THEN 'ITA'
    WHEN 'it_maternity' THEN 'ITN'
    WHEN 'it_parental' THEN 'ITP'
    WHEN 'it_menstrual' THEN 'ITM'
    ELSE upper(left(replace(absence_type, '_', ''), 12))
  END)
WHERE is_system = true AND tenant_id IS NULL;

-- --- 3. View + resolver ---

DROP FUNCTION IF EXISTS api.list_absence_type_configs(boolean, boolean);

DROP VIEW IF EXISTS api.tenant_absence_type_configs;

CREATE VIEW api.tenant_absence_type_configs AS
SELECT
  id, tenant_id, absence_type, name_i18n,
  counts_as_worked, affects_entitlement, entitlement_type,
  requires_approval, requires_document, max_days_per_year,
  is_it, is_partial, is_active, is_system, sort_order,
  parent_key, subtype_key, export_code,
  created_at
FROM data.tenant_absence_type_configs;

GRANT SELECT ON api.tenant_absence_type_configs TO authenticated;

CREATE OR REPLACE FUNCTION api.list_absence_type_configs(
  p_include_it boolean DEFAULT true,
  p_include_partial boolean DEFAULT true
)
RETURNS SETOF api.tenant_absence_type_configs
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = api, data, public
AS $$
  SELECT DISTINCT ON (absence_type)
    t.id,
    t.tenant_id,
    t.absence_type,
    t.name_i18n,
    t.counts_as_worked,
    t.affects_entitlement,
    t.entitlement_type,
    t.requires_approval,
    t.requires_document,
    t.max_days_per_year,
    t.is_it,
    t.is_partial,
    t.is_active,
    t.is_system,
    t.sort_order,
    t.parent_key,
    t.subtype_key,
    t.export_code,
    t.created_at
  FROM data.tenant_absence_type_configs t
  WHERE
    t.is_active = true
    AND (p_include_it OR t.is_it = false)
    AND (p_include_partial OR t.is_partial = false)
    AND (
      t.tenant_id = data.active_tenant_id()
      OR (t.tenant_id IS NULL AND t.is_system = true)
    )
  ORDER BY absence_type, (t.tenant_id IS NOT NULL) DESC, t.sort_order;
$$;

GRANT EXECUTE ON FUNCTION api.list_absence_type_configs(boolean, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION data.resolve_tenant_absence_type_config(
  p_tenant_id    uuid,
  p_absence_type text
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT jsonb_build_object(
    'absence_type', c.absence_type,
    'is_it', c.is_it,
    'name_i18n', c.name_i18n,
    'parent_key', c.parent_key,
    'subtype_key', c.subtype_key,
    'export_code', COALESCE(
      NULLIF(trim(c.export_code), ''),
      upper(left(replace(c.absence_type, '_', ''), 12))
    )
  )
  FROM data.tenant_absence_type_configs c
  WHERE c.absence_type = p_absence_type
    AND (c.tenant_id = p_tenant_id OR (c.tenant_id IS NULL AND c.is_system = true))
  ORDER BY CASE WHEN c.tenant_id = p_tenant_id THEN 0 ELSE 1 END, c.sort_order
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION data.select_absence_for_employee_day(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_work_date   date
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT COALESCE((
    SELECT jsonb_build_object(
      'absence_id', ea.id,
      'absence_type', ea.absence_type,
      'absence_status', ea.status,
      'absence_is_paid', ea.is_paid,
      'partial_start_time', ea.partial_start_time,
      'partial_end_time', ea.partial_end_time,
      'partial_hours', ea.partial_hours,
      'is_it', COALESCE((cfg->>'is_it')::boolean, false),
      'absence_type_name', COALESCE(
        cfg->'name_i18n'->>'ca',
        cfg->'name_i18n'->>'es',
        ea.absence_type
      ),
      'export_code', cfg->>'export_code',
      'parent_key', cfg->>'parent_key',
      'subtype_key', cfg->>'subtype_key'
    )
    FROM data.employee_absences ea
    CROSS JOIN LATERAL (
      SELECT data.resolve_tenant_absence_type_config(p_tenant_id, ea.absence_type) AS cfg
    ) r
    WHERE ea.employee_id = p_employee_id
      AND ea.start_date <= p_work_date
      AND ea.end_date >= p_work_date
      AND ea.status IN ('approved', 'active', 'closed', 'requested')
    ORDER BY
      CASE ea.status
        WHEN 'active' THEN 0
        WHEN 'approved' THEN 1
        WHEN 'closed' THEN 2
        WHEN 'requested' THEN 3
        ELSE 4
      END,
      ea.created_at DESC
    LIMIT 1
  ), '{}'::jsonb);
$$;

-- --- 4. RPCs: save export / create subtype ---

CREATE OR REPLACE FUNCTION api.save_absence_type_export_settings(
  p_absence_type text,
  p_export_code  text,
  p_parent_key   text DEFAULT NULL,
  p_subtype_key  text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_base      data.tenant_absence_type_configs%ROWTYPE;
  v_id        uuid;
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage', NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  SELECT c.* INTO v_base
  FROM data.tenant_absence_type_configs c
  WHERE c.absence_type = p_absence_type
    AND (c.tenant_id = v_tenant_id OR (c.tenant_id IS NULL AND c.is_system = true))
  ORDER BY CASE WHEN c.tenant_id = v_tenant_id THEN 0 ELSE 1 END
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'absence_type_not_found: %', p_absence_type;
  END IF;

  INSERT INTO data.tenant_absence_type_configs (
    tenant_id, absence_type, name_i18n,
    counts_as_worked, affects_entitlement, entitlement_type,
    requires_approval, requires_document, max_days_per_year,
    is_it, is_partial, is_active, is_system, sort_order,
    parent_key, subtype_key, export_code
  ) VALUES (
    v_tenant_id, p_absence_type, v_base.name_i18n,
    v_base.counts_as_worked, v_base.affects_entitlement, v_base.entitlement_type,
    v_base.requires_approval, v_base.requires_document, v_base.max_days_per_year,
    v_base.is_it, v_base.is_partial, true, false, v_base.sort_order,
    COALESCE(p_parent_key, v_base.parent_key),
    COALESCE(p_subtype_key, v_base.subtype_key),
    NULLIF(trim(p_export_code), '')
  )
  ON CONFLICT (tenant_id, absence_type) DO UPDATE SET
    parent_key  = COALESCE(EXCLUDED.parent_key, data.tenant_absence_type_configs.parent_key),
    subtype_key = COALESCE(EXCLUDED.subtype_key, data.tenant_absence_type_configs.subtype_key),
    export_code = EXCLUDED.export_code
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.create_absence_type_subtype(
  p_absence_type        text,
  p_parent_key          text,
  p_subtype_key         text,
  p_name_i18n           jsonb,
  p_export_code         text,
  p_counts_as_worked    boolean DEFAULT false,
  p_affects_entitlement boolean DEFAULT false,
  p_entitlement_type    text DEFAULT NULL,
  p_requires_approval   boolean DEFAULT true,
  p_requires_document   boolean DEFAULT false,
  p_max_days_per_year   integer DEFAULT NULL,
  p_is_partial          boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id        uuid;
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage', NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  IF p_parent_key NOT IN ('vacation', 'personal', 'family', 'permission', 'it', 'compensation', 'other') THEN
    RAISE EXCEPTION 'invalid_parent_key';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.tenant_absence_type_configs
    WHERE absence_type = p_absence_type
      AND (tenant_id = v_tenant_id OR (tenant_id IS NULL AND is_system = true))
  ) THEN
    RAISE EXCEPTION 'absence_type_exists';
  END IF;

  INSERT INTO data.tenant_absence_type_configs (
    tenant_id, absence_type, name_i18n,
    counts_as_worked, affects_entitlement, entitlement_type,
    requires_approval, requires_document, max_days_per_year,
    is_it, is_partial, is_active, is_system, sort_order,
    parent_key, subtype_key, export_code
  ) VALUES (
    v_tenant_id, p_absence_type, p_name_i18n,
    p_counts_as_worked, p_affects_entitlement, p_entitlement_type,
    p_requires_approval, p_requires_document, p_max_days_per_year,
    false, p_is_partial, true, false,
    COALESCE((SELECT MAX(sort_order) + 10 FROM data.tenant_absence_type_configs WHERE tenant_id = v_tenant_id), 200),
    p_parent_key, p_subtype_key, NULLIF(trim(p_export_code), '')
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.save_absence_type_export_settings(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.create_absence_type_subtype(text, text, text, jsonb, text, boolean, boolean, text, boolean, boolean, integer, boolean) TO authenticated;

-- --- 5. Patch get_payroll_review_days (absence taxonomy fields) ---

CREATE OR REPLACE FUNCTION api.get_payroll_review_days(
  p_employee_id uuid,
  p_from        date,
  p_to          date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp   record;
  v_tz    text;
  v_days  int;
  v_rows  jsonb;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  v_days := (p_to - p_from) + 1;
  IF v_days > 93 THEN
    RAISE EXCEPTION 'date_range_too_large' USING DETAIL = 'max 93 days';
  END IF;

  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'employee_not_found'; END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_emp.tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id)
      OR EXISTS (SELECT 1 FROM data.employees e WHERE e.id = p_employee_id AND e.user_id = auth.uid())
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid');

  SELECT COALESCE(jsonb_agg(day_row ORDER BY day_row ->> 'work_date'), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'work_date', gs.dt::date,
      'day_type', wd.resolve ->> 'day_type',
      'work_day_type', COALESCE(wd.resolve ->> 'work_day_type', 'normal'),
      'expected_minutes', COALESCE((wd.resolve ->> 'expected_minutes')::int, 0),
      'holiday_name', wd.resolve ->> 'holiday_name',
      'is_laborable',
        COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
        OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'),
      'worked_minutes',
        COALESCE(
          NULLIF(tds.worked_minutes, 0),
          CASE
            WHEN punches.first_in IS NOT NULL AND punches.last_out IS NOT NULL AND punches.last_out > punches.first_in
            THEN ROUND(EXTRACT(EPOCH FROM (punches.last_out - punches.first_in)) / 60)::int
            WHEN punches.first_in IS NOT NULL
            THEN ROUND(EXTRACT(EPOCH FROM (now() - punches.first_in)) / 60)::int
            ELSE 0
          END
        ),
      'presence_minutes', tds.presence_minutes,
      'work_minutes', tds.work_minutes,
      'travel_minutes', COALESCE(tds.travel_minutes, 0),
      'effective_minutes', tds.effective_minutes,
      'paid_minutes', tds.paid_minutes,
      'overtime_authorized_minutes', tds.overtime_authorized_minutes,
      'work_profile_snapshot', tds.work_profile_snapshot,
      'overtime_minutes', COALESCE(tds.overtime_minutes, 0),
      'punch_count', COALESCE(tds.punch_count, COALESCE(punches.punch_count, 0)),
      'remote_punch_count', COALESCE(punches.remote_punch_count, 0),
      'entry_status', te.status,
      'summary_status', COALESCE(tds.status, 'none'),
      'needs_review', COALESCE(tds.needs_review, false),
      'anomalies', to_jsonb(COALESCE(tds.anomaly_codes, '{}'::text[])),
      'summary_id', tds.id,
      'absence_id', NULLIF(abs.config->>'absence_id', '')::uuid,
      'absence_type', NULLIF(abs.config->>'absence_type', ''),
      'absence_status', NULLIF(abs.config->>'absence_status', ''),
      'absence_is_paid', (abs.config->>'absence_is_paid')::boolean,
      'partial_start_time', abs.config->>'partial_start_time',
      'partial_end_time', abs.config->>'partial_end_time',
      'partial_hours', (abs.config->>'partial_hours')::numeric,
      'is_it', COALESCE((abs.config->>'is_it')::boolean, false),
      'it_type', CASE WHEN COALESCE((abs.config->>'is_it')::boolean, false) THEN abs.config->>'absence_type' ELSE NULL END,
      'absence_export_code', abs.config->>'export_code',
      'absence_parent_key', abs.config->>'parent_key',
      'absence_subtype_key', abs.config->>'subtype_key',
      'payroll_locked', tds.payroll_locked_at IS NOT NULL,
      'payroll_action',
        CASE
          WHEN te.status = 'open' OR COALESCE(tds.needs_review, false) OR tds.status = 'exported' OR tds.payroll_locked_at IS NOT NULL
          THEN 'blocked'
          WHEN abs.config->>'absence_id' IS NOT NULL AND abs.config->>'absence_status' IN ('approved', 'active', 'closed')
          THEN 'absence_ok'
          WHEN (COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0 OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'))
            AND (te.id IS NULL OR te.status NOT IN ('closed', 'adjusted'))
            AND abs.config->>'absence_id' IS NULL
          THEN 'missing_punch'
          WHEN tds.status = 'draft' AND (COALESCE(tds.worked_minutes, 0) > 0 OR COALESCE(tds.punch_count, punches.punch_count, 0) > 0)
          THEN 'approve'
          ELSE NULL
        END
    ) AS day_row
    FROM generate_series(p_from, p_to, interval '1 day') AS gs(dt)
    CROSS JOIN LATERAL (SELECT api.resolve_work_day(p_employee_id, gs.dt::date) AS resolve) wd
    LEFT JOIN data.time_entries te ON te.employee_id = p_employee_id AND te.work_date = gs.dt::date
    LEFT JOIN data.time_daily_summaries tds ON tds.employee_id = p_employee_id AND tds.work_date = gs.dt::date
    LEFT JOIN LATERAL (
      SELECT COUNT(*)::int AS punch_count,
        COUNT(*) FILTER (WHERE tp.is_remote)::int AS remote_punch_count,
        MIN(tp.occurred_at) FILTER (WHERE tp.punch_type = 'in') AS first_in,
        MAX(tp.occurred_at) FILTER (WHERE tp.punch_type = 'out') AS last_out
      FROM data.time_punches tp
      WHERE tp.employee_id = p_employee_id
        AND (tp.occurred_at AT TIME ZONE v_tz)::date = gs.dt::date
    ) punches ON true
    LEFT JOIN LATERAL (
      SELECT data.select_absence_for_employee_day(p_employee_id, v_emp.tenant_id, gs.dt::date) AS config
    ) abs ON true
  ) q;

  RETURN jsonb_build_object('employee_id', p_employee_id, 'from', p_from, 'to', p_to, 'days', v_rows);
END;
$$;

-- --- 6. Patch export_payroll_period (C1 export_code on daily rows) ---

CREATE OR REPLACE FUNCTION api.export_payroll_period(
  p_site_id     uuid,
  p_from        date,
  p_to          date,
  p_employee_id uuid DEFAULT NULL,
  p_format      text DEFAULT 'daily'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id  uuid;
  v_site_name  text;
  v_days       int;
  v_rows       jsonb;
  v_count      int;
  v_format     text;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  v_days := (p_to - p_from) + 1;
  IF v_days > 93 THEN
    RAISE EXCEPTION 'date_range_too_large' USING DETAIL = 'max 93 days';
  END IF;

  v_format := lower(COALESCE(p_format, 'daily'));
  IF v_format NOT IN ('daily', 'aggregate') THEN
    RAISE EXCEPTION 'invalid_format' USING DETAIL = 'daily or aggregate';
  END IF;

  SELECT s.tenant_id, s.name INTO v_tenant_id, v_site_name
  FROM data.sites s WHERE s.id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.export', p_site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.export required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_format = 'daily' THEN
    SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_name, sort_date), '[]'::jsonb), COUNT(*)
    INTO v_rows, v_count
    FROM (
      SELECT jsonb_build_object(
        'employee_id', e.id,
        'employee_name', e.full_name,
        'document_id', e.document_id,
        'work_date', gs.dt::date,
        'day_type', wd.resolve ->> 'day_type',
        'work_day_type', COALESCE(wd.resolve ->> 'work_day_type', 'normal'),
        'expected_minutes', COALESCE((wd.resolve ->> 'expected_minutes')::int, 0),
        'holiday_name', wd.resolve ->> 'holiday_name',
        'is_laborable',
          COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
          OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'),
        'worked_minutes', COALESCE(tds.worked_minutes, 0),
        'net_minutes', COALESCE(tds.worked_minutes, 0),
        'presence_minutes', tds.presence_minutes,
        'work_minutes', tds.work_minutes,
        'travel_minutes', COALESCE(tds.travel_minutes, 0),
        'effective_minutes', tds.effective_minutes,
        'paid_minutes', tds.paid_minutes,
        'overtime_minutes', COALESCE(tds.overtime_minutes, 0),
        'overtime_authorized_minutes', tds.overtime_authorized_minutes,
        'consolidation_needs_review', COALESCE(tds.needs_review, false),
        'work_profile', tds.work_profile_snapshot,
        'allowances', '[]'::jsonb,
        'punch_count', COALESCE(tds.punch_count, COALESCE(punches.punch_count, 0)),
        'remote_punch_count', COALESCE(punches.remote_punch_count, 0),
        'entry_status', te.status,
        'summary_status', COALESCE(tds.status, 'none'),
        'needs_review', COALESCE(tds.needs_review, false),
        'anomaly_codes', to_jsonb(COALESCE(tds.anomaly_codes, '{}'::text[])),
        'payroll_locked', tds.payroll_locked_at IS NOT NULL,
        'absence_id', NULLIF(abs.config->>'absence_id', '')::uuid,
        'absence_type', NULLIF(abs.config->>'absence_type', ''),
        'absence_type_name', NULLIF(abs.config->>'absence_type_name', ''),
        'absence_status', NULLIF(abs.config->>'absence_status', ''),
        'absence_is_paid', (abs.config->>'absence_is_paid')::boolean,
        'partial_start_time', abs.config->>'partial_start_time',
        'partial_end_time', abs.config->>'partial_end_time',
        'partial_hours', (abs.config->>'partial_hours')::numeric,
        'is_it', COALESCE((abs.config->>'is_it')::boolean, false),
        'absence_export_code', abs.config->>'export_code',
        'absence_parent_key', abs.config->>'parent_key',
        'absence_subtype_key', abs.config->>'subtype_key',
        'payroll_action',
          CASE
            WHEN te.status = 'open' OR COALESCE(tds.needs_review, false) OR tds.status = 'exported' OR tds.payroll_locked_at IS NOT NULL
            THEN 'blocked'
            WHEN abs.config->>'absence_id' IS NOT NULL AND abs.config->>'absence_status' IN ('approved', 'active', 'closed')
            THEN 'absence_ok'
            WHEN (COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0 OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'))
              AND (te.id IS NULL OR te.status NOT IN ('closed', 'adjusted'))
              AND abs.config->>'absence_id' IS NULL
            THEN 'missing_punch'
            WHEN tds.status = 'draft' AND (COALESCE(tds.worked_minutes, 0) > 0 OR COALESCE(tds.punch_count, punches.punch_count, 0) > 0)
            THEN 'approve'
            ELSE NULL
          END,
        'compensation_balance_minutes', data.get_compensation_balance_minutes(e.id)
      ) AS row_data,
      e.full_name AS sort_name,
      gs.dt::date AS sort_date
      FROM data.employees e
      CROSS JOIN generate_series(p_from, p_to, interval '1 day') AS gs(dt)
      CROSS JOIN LATERAL (SELECT api.resolve_work_day(e.id, gs.dt::date) AS resolve) wd
      LEFT JOIN data.time_entries te ON te.employee_id = e.id AND te.work_date = gs.dt::date
      LEFT JOIN data.time_daily_summaries tds ON tds.employee_id = e.id AND tds.work_date = gs.dt::date
      LEFT JOIN LATERAL (
        SELECT data.select_absence_for_employee_day(e.id, e.tenant_id, gs.dt::date) AS config
      ) abs ON true
      LEFT JOIN LATERAL (
        SELECT COUNT(*)::int AS punch_count,
          COUNT(*) FILTER (WHERE tp.is_remote)::int AS remote_punch_count
        FROM data.time_punches tp
        WHERE tp.employee_id = e.id
          AND (tp.occurred_at AT TIME ZONE COALESCE(data.get_site_timezone(e.site_id, e.tenant_id), 'Europe/Madrid'))::date = gs.dt::date
      ) punches ON true
      WHERE e.site_id = p_site_id AND e.tenant_id = v_tenant_id AND e.status = 'active'
        AND (p_employee_id IS NULL OR e.id = p_employee_id)
    ) sub;
  ELSE
    SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_name), '[]'::jsonb), COUNT(*)
    INTO v_rows, v_count
    FROM (
      SELECT jsonb_build_object(
        'employee_id', e.id,
        'employee_name', e.full_name,
        'document_id', e.document_id,
        'period_from', p_from,
        'period_to', p_to,
        'total_expected_minutes', COALESCE(SUM(COALESCE((wd.resolve ->> 'expected_minutes')::int, 0)), 0),
        'total_worked_minutes', COALESCE(SUM(COALESCE(tds.worked_minutes, 0)), 0),
        'total_presence_minutes', COALESCE(SUM(tds.presence_minutes), 0),
        'total_work_minutes', COALESCE(SUM(COALESCE(tds.work_minutes, 0)), 0),
        'total_travel_minutes', COALESCE(SUM(COALESCE(tds.travel_minutes, 0)), 0),
        'total_effective_minutes', COALESCE(SUM(tds.effective_minutes), 0),
        'total_paid_minutes', COALESCE(SUM(tds.paid_minutes), 0),
        'total_overtime_minutes', COALESCE(SUM(COALESCE(tds.overtime_minutes, 0)), 0),
        'total_overtime_authorized_minutes', COALESCE(SUM(COALESCE(tds.overtime_authorized_minutes, 0)), 0),
        'laborable_days', COUNT(*) FILTER (WHERE COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0 OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday')),
        'worked_days', COUNT(*) FILTER (WHERE COALESCE(tds.worked_minutes, 0) > 0),
        'absence_days', COUNT(*) FILTER (WHERE abs.config->>'absence_id' IS NOT NULL AND abs.config->>'absence_status' IN ('approved', 'active', 'closed') AND NOT COALESCE((abs.config->>'is_it')::boolean, false)),
        'it_days', COUNT(*) FILTER (WHERE abs.config->>'absence_id' IS NOT NULL AND COALESCE((abs.config->>'is_it')::boolean, false) AND abs.config->>'absence_status' IN ('approved', 'active', 'closed')),
        'missing_punch_days', COUNT(*) FILTER (WHERE (COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0 OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday')) AND abs.config->>'absence_id' IS NULL AND (te.id IS NULL OR te.status NOT IN ('closed', 'adjusted'))),
        'draft_days', COUNT(*) FILTER (WHERE tds.status = 'draft'),
        'approved_days', COUNT(*) FILTER (WHERE tds.status = 'approved'),
        'exported_days', COUNT(*) FILTER (WHERE tds.status = 'exported'),
        'remote_punch_days', COUNT(*) FILTER (WHERE COALESCE(punches.remote_punch_count, 0) > 0),
        'compensation_balance_minutes', data.get_compensation_balance_minutes(e.id)
      ) AS row_data,
      e.full_name AS sort_name
      FROM data.employees e
      CROSS JOIN generate_series(p_from, p_to, interval '1 day') AS gs(dt)
      CROSS JOIN LATERAL (SELECT api.resolve_work_day(e.id, gs.dt::date) AS resolve) wd
      LEFT JOIN data.time_entries te ON te.employee_id = e.id AND te.work_date = gs.dt::date
      LEFT JOIN data.time_daily_summaries tds ON tds.employee_id = e.id AND tds.work_date = gs.dt::date
      LEFT JOIN LATERAL (
        SELECT data.select_absence_for_employee_day(e.id, e.tenant_id, gs.dt::date) AS config
      ) abs ON true
      LEFT JOIN LATERAL (
        SELECT COUNT(*) FILTER (WHERE tp.is_remote)::int AS remote_punch_count
        FROM data.time_punches tp
        WHERE tp.employee_id = e.id
          AND (tp.occurred_at AT TIME ZONE COALESCE(data.get_site_timezone(e.site_id, e.tenant_id), 'Europe/Madrid'))::date = gs.dt::date
      ) punches ON true
      WHERE e.site_id = p_site_id AND e.tenant_id = v_tenant_id AND e.status = 'active'
        AND (p_employee_id IS NULL OR e.id = p_employee_id)
      GROUP BY e.id, e.full_name, e.document_id
    ) sub;
  END IF;

  RETURN jsonb_build_object(
    'site_id', p_site_id, 'site_name', v_site_name, 'tenant_id', v_tenant_id,
    'from', p_from, 'to', p_to, 'format', v_format,
    'row_count', COALESCE(v_count, 0), 'rows', COALESCE(v_rows, '[]'::jsonb),
    'generated_at', now(), 'read_only', true
  );
END;
$$;

COMMENT ON FUNCTION api.export_payroll_period(uuid, date, date, uuid, text) IS
  'Export nòmina (D2) amb absence_export_code (C1), buckets G4 i saldo C3.';

GRANT EXECUTE ON FUNCTION api.export_payroll_period(uuid, date, date, uuid, text) TO authenticated;

COMMENT ON FUNCTION data.resolve_tenant_absence_type_config IS
  'C1: resol config absència (tenant override → sistema) amb export_code.';

COMMENT ON FUNCTION data.select_absence_for_employee_day IS
  'C1: absència del dia amb taxonomia i export_code per a exports/RPCs.';
