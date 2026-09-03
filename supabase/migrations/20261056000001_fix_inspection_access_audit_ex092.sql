-- EX-09.2 follow-up: audit només al primer page load (offsets 0), no a cada paginació.

CREATE OR REPLACE FUNCTION api.resolve_attendance_inspection_access(
  p_link_id uuid,
  p_secret  text,
  p_punches_offset int DEFAULT 0,
  p_punches_limit  int DEFAULT 500,
  p_summaries_offset int DEFAULT 0,
  p_summaries_limit  int DEFAULT 200
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
  v_summaries jsonb;
  v_punch_total int;
  v_sum_total   int;
  v_poff      int := GREATEST(COALESCE(p_punches_offset, 0), 0);
  v_plim      int := LEAST(GREATEST(COALESCE(p_punches_limit, 500), 1), 1000);
  v_soff      int := GREATEST(COALESCE(p_summaries_offset, 0), 0);
  v_slim      int := LEAST(GREATEST(COALESCE(p_summaries_limit, 200), 1), 500);
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

  -- Comptador + audit només al primer load (no a cada pàgina)
  IF v_poff = 0 AND v_soff = 0 THEN
    UPDATE data.attendance_inspection_access_links
    SET access_count = access_count + 1,
        last_accessed_at = now()
    WHERE id = v_link.id;
  ELSE
    UPDATE data.attendance_inspection_access_links
    SET last_accessed_at = now()
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

  -- Audit només al primer load (no a cada pàgina)
  IF v_poff = 0 AND v_soff = 0 THEN
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
        'access_count', v_link.access_count + 1
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'link_id', v_link.id,
    'tenant_name', v_tenant,
    'employee_id', v_link.employee_id,
    'employee_name', v_emp_name,
    'period_from', v_link.period_from,
    'period_to', v_link.period_to,
    'expires_at', v_link.expires_at,
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
