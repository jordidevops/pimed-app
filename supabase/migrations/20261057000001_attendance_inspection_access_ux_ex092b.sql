-- =============================================================================
-- EX-09.2 UX — include_consolidated + metadades d'accés (IP / UA / primer-últim)
-- =============================================================================

ALTER TABLE data.attendance_inspection_access_links
  ADD COLUMN IF NOT EXISTS include_consolidated boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS first_accessed_at timestamptz,
  ADD COLUMN IF NOT EXISTS first_access_ip text,
  ADD COLUMN IF NOT EXISTS first_access_user_agent text,
  ADD COLUMN IF NOT EXISTS last_access_ip text,
  ADD COLUMN IF NOT EXISTS last_access_user_agent text;

COMMENT ON COLUMN data.attendance_inspection_access_links.include_consolidated IS
  'Si true, el portal públic exposa també el registre consolidat (summaries).';

-- -----------------------------------------------------------------------------
-- create (nou param p_include_consolidated)
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.create_attendance_inspection_access_link(uuid, date, date, int, text);

CREATE OR REPLACE FUNCTION api.create_attendance_inspection_access_link(
  p_employee_id uuid,
  p_period_from date,
  p_period_to   date,
  p_ttl_days    int DEFAULT 7,
  p_label       text DEFAULT NULL,
  p_include_consolidated boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant_id uuid;
  v_emp       record;
  v_ttl       int;
  v_secret    text;
  v_hash      bytea;
  v_id        uuid;
  v_expires   timestamptz;
  v_include   boolean := COALESCE(p_include_consolidated, true);
BEGIN
  v_tenant_id := api._assert_attendance_inspection_manage();

  IF p_employee_id IS NULL OR p_period_from IS NULL OR p_period_to IS NULL THEN
    RAISE EXCEPTION 'invalid_args'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_period_to < p_period_from THEN
    RAISE EXCEPTION 'invalid_period: to < from'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF (p_period_to - p_period_from) > 400 THEN
    RAISE EXCEPTION 'period_too_long: max 400 days'
      USING ERRCODE = 'check_violation';
  END IF;

  v_ttl := LEAST(GREATEST(COALESCE(p_ttl_days, 7), 1), 30);
  v_expires := now() + make_interval(days => v_ttl);

  SELECT e.id, e.tenant_id, e.full_name, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found'
      USING ERRCODE = 'no_data_found';
  END IF;

  v_secret := api._employee_portal_generate_secret();
  v_hash := api._employee_portal_secret_hash_bytea(v_secret);

  INSERT INTO data.attendance_inspection_access_links (
    tenant_id, employee_id, period_from, period_to,
    token_hash, expires_at, created_by, label, include_consolidated
  ) VALUES (
    v_tenant_id, v_emp.id, p_period_from, p_period_to,
    v_hash, v_expires, auth.uid(), NULLIF(btrim(p_label), ''), v_include
  )
  RETURNING id INTO v_id;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    v_emp.site_id,
    'ATTENDANCE_INSPECTION_LINK_CREATED',
    'attendance_inspection_access_link',
    v_id,
    jsonb_build_object(
      'link_id', v_id,
      'employee_id', v_emp.id,
      'employee_name', v_emp.full_name,
      'period_from', p_period_from,
      'period_to', p_period_to,
      'expires_at', v_expires,
      'ttl_days', v_ttl,
      'include_consolidated', v_include
    )
  );

  RETURN jsonb_build_object(
    'id', v_id,
    'url_secret', v_secret,
    'expires_at', v_expires,
    'employee_id', v_emp.id,
    'employee_name', v_emp.full_name,
    'period_from', p_period_from,
    'period_to', p_period_to,
    'ttl_days', v_ttl,
    'include_consolidated', v_include
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_attendance_inspection_access_link(uuid, date, date, int, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_attendance_inspection_access_link(uuid, date, date, int, text, boolean) TO authenticated;

-- -----------------------------------------------------------------------------
-- list (metadades d'accés + estat clar)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_attendance_inspection_access_links(
  p_include_inactive boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_rows      jsonb;
BEGIN
  v_tenant_id := api._assert_attendance_inspection_manage();

  SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_created DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'id', l.id,
        'employee_id', l.employee_id,
        'employee_name', e.full_name,
        'period_from', l.period_from,
        'period_to', l.period_to,
        'expires_at', l.expires_at,
        'revoked_at', l.revoked_at,
        'created_at', l.created_at,
        'created_by', l.created_by,
        'last_accessed_at', l.last_accessed_at,
        'first_accessed_at', l.first_accessed_at,
        'first_access_ip', l.first_access_ip,
        'first_access_user_agent', l.first_access_user_agent,
        'last_access_ip', l.last_access_ip,
        'last_access_user_agent', l.last_access_user_agent,
        'access_count', l.access_count,
        'label', l.label,
        'include_consolidated', l.include_consolidated,
        'is_active', (l.revoked_at IS NULL AND l.expires_at > now()),
        'status', CASE
          WHEN l.revoked_at IS NOT NULL THEN 'revoked'
          WHEN l.expires_at <= now() THEN 'expired'
          ELSE 'active'
        END
      ) AS row_data,
      l.created_at AS sort_created
    FROM data.attendance_inspection_access_links l
    JOIN data.employees e ON e.id = l.employee_id
    WHERE l.tenant_id = v_tenant_id
      AND (
        p_include_inactive
        OR (l.revoked_at IS NULL AND l.expires_at > now())
        OR (l.created_at > now() - INTERVAL '90 days')
      )
      AND (
        p_include_inactive
        OR l.revoked_at IS NULL
        OR l.revoked_at > now() - INTERVAL '90 days'
      )
      AND (
        p_include_inactive
        OR l.expires_at > now() - INTERVAL '90 days'
      )
  ) sub;

  RETURN jsonb_build_object('links', COALESCE(v_rows, '[]'::jsonb));
END;
$$;

-- -----------------------------------------------------------------------------
-- resolve: include_consolidated + IP/UA
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.resolve_attendance_inspection_access(uuid, text, int, int, int, int);

CREATE OR REPLACE FUNCTION api.resolve_attendance_inspection_access(
  p_link_id uuid,
  p_secret  text,
  p_punches_offset int DEFAULT 0,
  p_punches_limit  int DEFAULT 500,
  p_summaries_offset int DEFAULT 0,
  p_summaries_limit  int DEFAULT 200,
  p_client_ip text DEFAULT NULL,
  p_user_agent text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_hash      bytea;
  v_link      record;
  v_tenant    text;
  v_emp_name  text;
  v_punches   jsonb;
  v_summaries jsonb := '[]'::jsonb;
  v_punch_total int;
  v_sum_total   int := 0;
  v_poff      int := GREATEST(COALESCE(p_punches_offset, 0), 0);
  v_plim      int := LEAST(GREATEST(COALESCE(p_punches_limit, 500), 1), 1000);
  v_soff      int := GREATEST(COALESCE(p_summaries_offset, 0), 0);
  v_slim      int := LEAST(GREATEST(COALESCE(p_summaries_limit, 200), 1), 500);
  v_ip        text := NULLIF(left(btrim(COALESCE(p_client_ip, '')), 128), '');
  v_ua        text := NULLIF(left(btrim(COALESCE(p_user_agent, '')), 512), '');
BEGIN
  IF p_link_id IS NULL OR NULLIF(btrim(p_secret), '') IS NULL THEN
    RETURN NULL;
  END IF;

  v_hash := api._employee_portal_secret_hash_bytea(btrim(p_secret));

  SELECT l.*
  INTO v_link
  FROM data.attendance_inspection_access_links l
  WHERE l.id = p_link_id
    AND l.token_hash = v_hash
  FOR UPDATE;

  IF NOT FOUND
     OR v_link.revoked_at IS NOT NULL
     OR v_link.expires_at <= now()
  THEN
    RETURN NULL;
  END IF;

  IF v_poff = 0 AND v_soff = 0 THEN
    UPDATE data.attendance_inspection_access_links
    SET
      access_count = access_count + 1,
      last_accessed_at = now(),
      last_access_ip = COALESCE(v_ip, last_access_ip),
      last_access_user_agent = COALESCE(v_ua, last_access_user_agent),
      first_accessed_at = COALESCE(first_accessed_at, now()),
      first_access_ip = COALESCE(first_access_ip, v_ip),
      first_access_user_agent = COALESCE(first_access_user_agent, v_ua)
    WHERE id = v_link.id;

    PERFORM data.log_audit_event(
      v_link.tenant_id,
      NULL,
      NULL,
      'ATTENDANCE_INSPECTION_LINK_ACCESSED',
      'attendance_inspection_access_link',
      v_link.id,
      jsonb_build_object(
        'link_id', v_link.id,
        'employee_id', v_link.employee_id,
        'actor', 'inspection_authority',
        'access_count', v_link.access_count + 1,
        'client_ip', v_ip,
        'user_agent', v_ua
      )
    );
  ELSE
    UPDATE data.attendance_inspection_access_links
    SET
      last_accessed_at = now(),
      last_access_ip = COALESCE(v_ip, last_access_ip),
      last_access_user_agent = COALESCE(v_ua, last_access_user_agent)
    WHERE id = v_link.id;
  END IF;

  SELECT t.name INTO v_tenant FROM data.tenants t WHERE t.id = v_link.tenant_id;
  SELECT e.full_name INTO v_emp_name FROM data.employees e WHERE e.id = v_link.employee_id;

  SELECT COUNT(*) INTO v_punch_total
  FROM data.time_punches tp
  WHERE tp.tenant_id = v_link.tenant_id
    AND tp.employee_id = v_link.employee_id
    AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date
        BETWEEN v_link.period_from AND v_link.period_to;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_at), '[]'::jsonb)
  INTO v_punches
  FROM (
    SELECT
      jsonb_build_object(
        'id', tp.id,
        'punch_type', tp.punch_type,
        'occurred_at', tp.occurred_at,
        'received_at', tp.received_at,
        'source', tp.source,
        'location_name_snapshot', tp.location_name_snapshot,
        'device_name_snapshot', tp.device_name_snapshot,
        'anomaly_codes', COALESCE(tp.anomaly_codes, '{}'),
        'notes', tp.notes,
        'pause_type', tp.pause_type
      ) AS row_data,
      tp.occurred_at AS sort_at
    FROM data.time_punches tp
    WHERE tp.tenant_id = v_link.tenant_id
      AND tp.employee_id = v_link.employee_id
      AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date
          BETWEEN v_link.period_from AND v_link.period_to
    ORDER BY tp.occurred_at
    OFFSET v_poff
    LIMIT v_plim
  ) sub;

  IF COALESCE(v_link.include_consolidated, true) THEN
    SELECT COUNT(*) INTO v_sum_total
    FROM data.time_daily_summaries tds
    WHERE tds.tenant_id = v_link.tenant_id
      AND tds.employee_id = v_link.employee_id
      AND tds.work_date BETWEEN v_link.period_from AND v_link.period_to;

    SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_date), '[]'::jsonb)
    INTO v_summaries
    FROM (
      SELECT
        jsonb_build_object(
          'work_date', tds.work_date,
          'expected_minutes', tds.expected_minutes,
          'worked_minutes', tds.worked_minutes,
          'overtime_minutes', tds.overtime_minutes,
          'day_type', tds.day_type,
          'summary_status', tds.status,
          'punch_count', tds.punch_count,
          'needs_review', COALESCE(tds.needs_review, false),
          'anomaly_codes', COALESCE(tds.anomaly_codes, '{}'),
          'starts_at', te.starts_at,
          'ends_at', te.ends_at,
          'break_minutes', te.break_minutes,
          'net_minutes', te.net_minutes,
          'gross_minutes', te.gross_minutes,
          'entry_status', te.status,
          'effective_work_minutes', COALESCE(
            (SELECT SUM(
               EXTRACT(EPOCH FROM (COALESCE(s.ended_at, s.started_at) - s.started_at)) / 60.0
             )::int
             FROM data.time_activity_segments s
             WHERE s.employee_id = tds.employee_id
               AND s.work_date = tds.work_date
               AND s.activity_kind = 'WORK'),
            tds.worked_minutes
          )
        ) AS row_data,
        tds.work_date AS sort_date
      FROM data.time_daily_summaries tds
      LEFT JOIN data.time_entries te
        ON te.employee_id = tds.employee_id AND te.work_date = tds.work_date
      WHERE tds.tenant_id = v_link.tenant_id
        AND tds.employee_id = v_link.employee_id
        AND tds.work_date BETWEEN v_link.period_from AND v_link.period_to
      ORDER BY tds.work_date
      OFFSET v_soff
      LIMIT v_slim
    ) sub;
  END IF;

  RETURN jsonb_build_object(
    'link_id', v_link.id,
    'tenant_name', v_tenant,
    'employee_id', v_link.employee_id,
    'employee_name', v_emp_name,
    'period_from', v_link.period_from,
    'period_to', v_link.period_to,
    'expires_at', v_link.expires_at,
    'include_consolidated', COALESCE(v_link.include_consolidated, true),
    'punches', COALESCE(v_punches, '[]'::jsonb),
    'punches_total', v_punch_total,
    'punches_offset', v_poff,
    'punches_limit', v_plim,
    'summaries', COALESCE(v_summaries, '[]'::jsonb),
    'summaries_total', v_sum_total,
    'summaries_offset', v_soff,
    'summaries_limit', v_slim,
    'format', 'inspection_access_v1',
    'generated_at', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_attendance_inspection_access(uuid, text, int, int, int, int, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_attendance_inspection_access(uuid, text, int, int, int, int, text, text) TO service_role;

NOTIFY pgrst, 'reload schema';
