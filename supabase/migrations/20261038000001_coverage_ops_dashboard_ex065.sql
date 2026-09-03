-- =============================================================================
-- EX-06.5 — Dashboard operatiu i alertes de gap de cobertura
-- Snapshot «ara»: bucket actual, gaps planificat/real, qui falta (no-show/tard).
-- No-objectius: push/escalat, vacants (EX-07), suggeriments de torns curts.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_coverage_operational_snapshot(
  p_site_id          uuid,
  p_bucket_minutes   int DEFAULT 30,
  p_horizon_minutes  int DEFAULT 240,
  p_role_id          uuid DEFAULT NULL,
  p_as_of            timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id uuid;
  v_bucket int;
  v_horizon int;
  v_tz text := 'Europe/Madrid';
  v_now timestamptz := COALESCE(p_as_of, clock_timestamp());
  v_date date;
  v_now_min int;
  v_buckets jsonb;
  v_current jsonb;
  v_alerts jsonb := '[]'::jsonb;
  v_missing jsonb := '[]'::jsonb;
  v_summary jsonb;
  v_open_gaps int := 0;
  v_worst_present int := 0;
  v_worst_planned int := 0;
  r jsonb;
  v_b_start int;
  v_b_end int;
  v_req int;
  v_planned int;
  v_present int;
  v_qualified int;
  v_gap_p int;
  v_gap_r int;
  v_gap_q int;
  v_severity text;
  v_kinds text[];
  v_role_name text;
BEGIN
  IF p_site_id IS NULL THEN
    RAISE EXCEPTION 'site_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_bucket := COALESCE(p_bucket_minutes, 30);
  IF v_bucket NOT IN (15, 30) THEN
    RAISE EXCEPTION 'invalid_bucket_minutes: use 15 or 30'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_horizon := GREATEST(0, COALESCE(p_horizon_minutes, 240));
  IF v_horizon > 1440 THEN
    v_horizon := 1440;
  END IF;

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

  SELECT COALESCE(
    NULLIF(btrim(si.settings->>'site_timezone'), ''),
    NULLIF(btrim(t.settings->>'site_timezone'), ''),
    'Europe/Madrid'
  )
  INTO v_tz
  FROM data.sites si
  JOIN data.tenants t ON t.id = si.tenant_id
  WHERE si.id = p_site_id;

  v_date := (v_now AT TIME ZONE v_tz)::date;
  v_now_min := (
    EXTRACT(HOUR FROM (v_now AT TIME ZONE v_tz)) * 60
    + EXTRACT(MINUTE FROM (v_now AT TIME ZONE v_tz))
  )::int;

  IF p_role_id IS NOT NULL THEN
    SELECT wr.name INTO v_role_name
    FROM data.work_roles wr
    WHERE wr.id = p_role_id AND wr.tenant_id = v_tenant_id;
  END IF;

  v_buckets := api.get_coverage_buckets(p_site_id, v_date, v_bucket, p_role_id, NULL);

  SELECT b INTO v_current
  FROM jsonb_array_elements(v_buckets) b
  WHERE (b->>'bucket_start_min')::int <= v_now_min
    AND (b->>'bucket_end_min')::int > v_now_min
  LIMIT 1;

  FOR r IN
    SELECT b
    FROM jsonb_array_elements(v_buckets) b
    ORDER BY (b->>'bucket_start_min')::int
  LOOP
    v_b_start := (r->>'bucket_start_min')::int;
    v_b_end := (r->>'bucket_end_min')::int;
    v_req := COALESCE((r->>'required')::int, 0);
    v_planned := COALESCE((r->>'planned')::int, (r->>'assigned')::int, 0);
    v_present := COALESCE((r->>'present')::int, 0);
    v_qualified := COALESCE((r->>'qualified')::int, 0);
    v_gap_p := v_planned - v_req;
    v_gap_r := v_present - v_req;
    v_gap_q := v_qualified - v_req;

    IF v_req <= 0 THEN
      CONTINUE;
    END IF;
    IF v_b_end <= v_now_min THEN
      CONTINUE;
    END IF;
    IF v_b_start >= v_now_min + v_horizon THEN
      CONTINUE;
    END IF;

    v_severity := CASE
      WHEN v_b_start <= v_now_min AND v_b_end > v_now_min THEN 'now'
      ELSE 'upcoming'
    END;

    v_kinds := ARRAY[]::text[];
    IF v_gap_p < 0 THEN
      v_kinds := array_append(v_kinds, 'understaffed_planned');
    END IF;
    IF v_severity = 'now' AND v_gap_r < 0 THEN
      v_kinds := array_append(v_kinds, 'understaffed_present');
    END IF;
    IF v_severity = 'now' AND v_gap_q < 0 AND v_present > 0 THEN
      v_kinds := array_append(v_kinds, 'understaffed_qualified');
    END IF;

    IF cardinality(v_kinds) = 0 THEN
      CONTINUE;
    END IF;

    v_open_gaps := v_open_gaps + 1;
    IF v_gap_p < v_worst_planned THEN
      v_worst_planned := v_gap_p;
    END IF;
    IF v_severity = 'now' AND v_gap_r < v_worst_present THEN
      v_worst_present := v_gap_r;
    END IF;

    v_alerts := v_alerts || jsonb_build_array(
      jsonb_build_object(
        'kinds', to_jsonb(v_kinds),
        'severity', v_severity,
        'bucket_start', r->>'bucket_start',
        'bucket_end', r->>'bucket_end',
        'bucket_start_min', v_b_start,
        'bucket_end_min', v_b_end,
        'role_id', p_role_id,
        'role_name', v_role_name,
        'required', v_req,
        'planned', v_planned,
        'present', v_present,
        'qualified', v_qualified,
        'gap_planned', v_gap_p,
        'gap_present', v_gap_r,
        'gap_qualified', v_gap_q
      )
    );
  END LOOP;

  -- Qui falta ara
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'employee_id', m.employee_id,
        'employee_name', m.employee_name,
        'role_id', m.role_id,
        'role_name', m.role_name,
        'slot_start', m.slot_start,
        'slot_end', m.slot_end,
        'status', m.status
      )
      ORDER BY m.slot_start_min, m.employee_name
    ),
    '[]'::jsonb
  )
  INTO v_missing
  FROM (
    SELECT
      ss.employee_id,
      e.full_name AS employee_name,
      ss.role_id,
      COALESCE(ss.role_name_snapshot, wr.name) AS role_name,
      to_char(
        CASE WHEN ss.slot_date = v_date THEN ss.start_time ELSE time '00:00' END,
        'HH24:MI'
      ) AS slot_start,
      to_char(
        CASE
          WHEN ss.slot_date = v_date - 1 THEN ss.end_time
          ELSE ss.end_time
        END,
        'HH24:MI'
      ) AS slot_end,
      CASE
        WHEN ss.slot_date = v_date THEN data.time_to_minutes(ss.start_time)
        ELSE 0
      END AS slot_start_min,
      CASE
        WHEN ss.slot_date = v_date AND ss.end_time > ss.start_time THEN data.time_to_minutes(ss.end_time)
        WHEN ss.slot_date = v_date AND ss.end_time <= ss.start_time THEN 1440
        WHEN ss.slot_date = v_date - 1 AND ss.end_time <= ss.start_time THEN data.time_to_minutes(ss.end_time)
        ELSE data.time_to_minutes(ss.end_time)
      END AS slot_end_min,
      CASE
        WHEN (
          CASE WHEN ss.slot_date = v_date THEN data.time_to_minutes(ss.start_time) ELSE 0 END
        ) + 15 < v_now_min THEN 'absent'
        ELSE 'late'
      END AS status
    FROM data.shift_slots ss
    JOIN data.employees e ON e.id = ss.employee_id
    LEFT JOIN data.work_roles wr ON wr.id = ss.role_id
    WHERE ss.site_id = p_site_id
      AND ss.status = 'published'
      AND (
        ss.slot_date = v_date
        OR (ss.slot_date = v_date - 1 AND ss.end_time <= ss.start_time)
      )
      AND (p_role_id IS NULL OR ss.role_id IS NULL OR ss.role_id = p_role_id)
      AND data.time_range_overlaps_minutes(
        CASE WHEN ss.slot_date = v_date THEN data.time_to_minutes(ss.start_time) ELSE 0 END,
        CASE
          WHEN ss.slot_date = v_date AND ss.end_time > ss.start_time THEN data.time_to_minutes(ss.end_time)
          WHEN ss.slot_date = v_date AND ss.end_time <= ss.start_time THEN 1440
          WHEN ss.slot_date = v_date - 1 AND ss.end_time <= ss.start_time THEN data.time_to_minutes(ss.end_time)
          ELSE data.time_to_minutes(ss.end_time)
        END,
        v_now_min,
        LEAST(1440, v_now_min + 1)
      )
      AND NOT EXISTS (
        SELECT 1
        FROM data.coverage_presence_intervals(p_site_id, v_date, v_tz) pr
        WHERE pr.employee_id = ss.employee_id
          AND data.time_range_overlaps_minutes(
            pr.start_min, pr.end_min, v_now_min, LEAST(1440, v_now_min + 1)
          )
      )
  ) m;

  IF jsonb_array_length(v_missing) > 0 THEN
    v_alerts := jsonb_build_array(
      jsonb_build_object(
        'kinds', '["no_show"]'::jsonb,
        'severity', 'now',
        'bucket_start', COALESCE(v_current->>'bucket_start', to_char(make_time(v_now_min / 60, v_now_min % 60, 0), 'HH24:MI')),
        'bucket_end', v_current->>'bucket_end',
        'bucket_start_min', COALESCE((v_current->>'bucket_start_min')::int, v_now_min),
        'bucket_end_min', COALESCE((v_current->>'bucket_end_min')::int, LEAST(1440, v_now_min + v_bucket)),
        'role_id', p_role_id,
        'role_name', v_role_name,
        'required', COALESCE((v_current->>'required')::int, 0),
        'planned', COALESCE((v_current->>'planned')::int, 0),
        'present', COALESCE((v_current->>'present')::int, 0),
        'qualified', COALESCE((v_current->>'qualified')::int, 0),
        'gap_planned', COALESCE((v_current->>'gap_planned')::int, 0),
        'gap_present', COALESCE((v_current->>'gap_present')::int, 0),
        'gap_qualified', COALESCE((v_current->>'gap_qualified')::int, 0),
        'missing_count', jsonb_array_length(v_missing)
      )
    ) || v_alerts;
  END IF;

  v_summary := jsonb_build_object(
    'open_gap_count', v_open_gaps,
    'missing_now_count', jsonb_array_length(COALESCE(v_missing, '[]'::jsonb)),
    'worst_gap_planned', v_worst_planned,
    'worst_gap_present', v_worst_present,
    'current_ok', COALESCE(
      (v_current IS NULL)
      OR (
        COALESCE((v_current->>'required')::int, 0) = 0
        OR (
          COALESCE((v_current->>'gap_planned')::int, 0) >= 0
          AND COALESCE((v_current->>'gap_present')::int, 0) >= 0
        )
      ),
      true
    )
  );

  RETURN jsonb_build_object(
    'site_id', p_site_id,
    'work_date', v_date,
    'as_of', v_now,
    'as_of_min', v_now_min,
    'timezone', v_tz,
    'bucket_minutes', v_bucket,
    'horizon_minutes', v_horizon,
    'role_id', p_role_id,
    'role_name', v_role_name,
    'current', v_current,
    'alerts', COALESCE(v_alerts, '[]'::jsonb),
    'missing_now', COALESCE(v_missing, '[]'::jsonb),
    'summary', v_summary
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_coverage_operational_snapshot(uuid, int, int, uuid, timestamptz)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.get_coverage_operational_snapshot IS
  'EX-06.5: snapshot operatiu de cobertura (bucket ara, alertes de gap, qui falta).';

NOTIFY pgrst, 'reload schema';
