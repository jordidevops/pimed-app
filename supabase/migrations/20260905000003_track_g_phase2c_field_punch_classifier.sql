-- Track G Phase 2c: field_punch classifier path (D-INT-3, D-INT-4)

CREATE OR REPLACE FUNCTION data.employee_has_field_punch_logs(
  p_employee_id uuid,
  p_work_date   date,
  p_tenant_id   uuid,
  p_tz          text DEFAULT 'Europe/Madrid'
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.work_logs wl
    WHERE wl.employee_id = p_employee_id
      AND wl.tenant_id = p_tenant_id
      AND wl.entry_mode = 'field_punch'
      AND wl.check_in >= (p_work_date AT TIME ZONE p_tz)
      AND wl.check_in < ((p_work_date + 1) AT TIME ZONE p_tz)
  );
$$;

CREATE OR REPLACE FUNCTION data.classify_field_punch_segments(
  p_employee_id uuid,
  p_work_date   date,
  p_tenant_id   uuid
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp         record;
  v_tz          text;
  v_punch_from  timestamptz;
  v_punch_to    timestamptz;
  v_profile     text;
  v_count       int := 0;
  v_day_start   timestamptz;
  v_day_end     timestamptz;
  v_first_ts    timestamptz;
  v_last_ts     timestamptz;
  v_log         record;
  v_gap         record;
  v_cursor      timestamptz;
  v_bs          timestamptz;
  v_be          timestamptz;
  v_added       int;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, p_tenant_id), 'Europe/Madrid');
  v_punch_from := p_work_date AT TIME ZONE v_tz;
  v_punch_to   := (p_work_date + 1) AT TIME ZONE v_tz;

  v_profile := COALESCE(
    (data.resolve_attendance_record_policy(p_employee_id, p_work_date)->>'work_profile'),
    'mobile_peripatetic'
  );

  SELECT MIN(occurred_at) FILTER (WHERE punch_type = 'day_start'),
         MAX(occurred_at) FILTER (WHERE punch_type = 'day_end')
  INTO v_day_start, v_day_end
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND occurred_at >= v_punch_from
    AND occurred_at < v_punch_to;

  SELECT MIN(wl.check_in)
  INTO v_first_ts
  FROM data.work_logs wl
  WHERE wl.employee_id = p_employee_id
    AND wl.entry_mode = 'field_punch'
    AND wl.check_in >= v_punch_from
    AND wl.check_in < v_punch_to;

  SELECT MAX(wl.check_out)
  INTO v_last_ts
  FROM data.work_logs wl
  WHERE wl.employee_id = p_employee_id
    AND wl.entry_mode = 'field_punch'
    AND wl.check_in >= v_punch_from
    AND wl.check_in < v_punch_to
    AND wl.check_out IS NOT NULL;

  -- TRAVEL: day_start → first work
  IF v_day_start IS NOT NULL AND v_first_ts IS NOT NULL AND v_first_ts > v_day_start THEN
    INSERT INTO data.time_activity_segments (
      tenant_id, employee_id, work_date, activity_kind,
      started_at, ended_at, site_id, source_punch_ids, flags_snapshot
    ) VALUES (
      p_tenant_id, p_employee_id, p_work_date, 'TRAVEL',
      v_day_start, v_first_ts, v_emp.site_id, '{}',
      jsonb_build_object('classifier', 'field_punch', 'envelope', 'day_start_to_first_work')
    );
    v_count := v_count + 1;
  END IF;

  -- Declared gaps (except UNCLASSIFIED — handled at consolidate)
  FOR v_gap IN
    SELECT g.*
    FROM data.work_log_field_gaps g
    WHERE g.employee_id = p_employee_id
      AND g.work_date = p_work_date
      AND g.gap_kind <> 'UNCLASSIFIED'
    ORDER BY g.started_at
  LOOP
    IF v_gap.gap_kind IN ('TRAVEL', 'BREAK_UNPAID', 'BREAK_PAID', 'OFF_DUTY') THEN
      INSERT INTO data.time_activity_segments (
        tenant_id, employee_id, work_date, activity_kind,
        started_at, ended_at, site_id, source_punch_ids, flags_snapshot
      ) VALUES (
        p_tenant_id, p_employee_id, p_work_date, v_gap.gap_kind,
        v_gap.started_at, v_gap.ended_at, v_emp.site_id, '{}',
        jsonb_build_object(
          'classifier', 'field_punch',
          'gap_id', v_gap.id,
          'gap_kind', v_gap.gap_kind
        )
      )
      ON CONFLICT (employee_id, work_date, started_at, activity_kind) DO NOTHING;
      v_count := v_count + 1;
    END IF;
  END LOOP;

  -- WORK segments from field_punch work_logs, split at legal breaks
  FOR v_log IN
    SELECT wl.*
    FROM data.work_logs wl
    WHERE wl.employee_id = p_employee_id
      AND wl.entry_mode = 'field_punch'
      AND wl.check_in >= v_punch_from
      AND wl.check_in < v_punch_to
      AND wl.check_out IS NOT NULL
    ORDER BY wl.check_in
  LOOP
    v_cursor := v_log.check_in;

    FOR v_bs, v_be IN
      SELECT bs.occurred_at, be.occurred_at
      FROM (
        SELECT occurred_at, pause_counts_as_work,
               ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
        FROM data.time_punches
        WHERE employee_id = p_employee_id
          AND punch_type = 'break_start'
          AND occurred_at >= v_log.check_in
          AND occurred_at < COALESCE(v_log.check_out, v_punch_to)
      ) bs
      JOIN (
        SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
        FROM data.time_punches
        WHERE employee_id = p_employee_id
          AND punch_type = 'break_end'
          AND occurred_at >= v_log.check_in
          AND occurred_at < COALESCE(v_log.check_out, v_punch_to)
      ) be ON bs.rn = be.rn
      WHERE be.occurred_at > bs.occurred_at
        AND COALESCE(bs.pause_counts_as_work, false) = false
      ORDER BY bs.occurred_at
    LOOP
      IF v_bs > v_cursor THEN
        INSERT INTO data.time_activity_segments (
          tenant_id, employee_id, work_date, activity_kind,
          started_at, ended_at, site_id, work_log_id, source_punch_ids, flags_snapshot
        ) VALUES (
          p_tenant_id, p_employee_id, p_work_date, 'WORK',
          v_cursor, v_bs, v_emp.site_id, v_log.id,
          ARRAY(SELECT id FROM data.time_punches WHERE id IN (v_log.time_punch_in_id, v_log.time_punch_out_id) AND id IS NOT NULL),
          jsonb_build_object('classifier', 'field_punch', 'project_id', v_log.project_id)
        )
        ON CONFLICT (employee_id, work_date, started_at, activity_kind) DO NOTHING;
        v_count := v_count + 1;
      END IF;

      INSERT INTO data.time_activity_segments (
        tenant_id, employee_id, work_date, activity_kind,
        started_at, ended_at, site_id, source_punch_ids, flags_snapshot
      ) VALUES (
        p_tenant_id, p_employee_id, p_work_date, 'BREAK_UNPAID',
        v_bs, v_be, v_emp.site_id, '{}',
        jsonb_build_object('classifier', 'field_punch')
      )
      ON CONFLICT (employee_id, work_date, started_at, activity_kind) DO NOTHING;
      v_count := v_count + 1;
      v_cursor := v_be;
    END LOOP;

    IF v_log.check_out > v_cursor THEN
      INSERT INTO data.time_activity_segments (
        tenant_id, employee_id, work_date, activity_kind,
        started_at, ended_at, site_id, work_log_id, source_punch_ids, flags_snapshot
      ) VALUES (
        p_tenant_id, p_employee_id, p_work_date, 'WORK',
        v_cursor, v_log.check_out, v_emp.site_id, v_log.id,
        ARRAY(SELECT id FROM data.time_punches WHERE id IN (v_log.time_punch_in_id, v_log.time_punch_out_id) AND id IS NOT NULL),
        jsonb_build_object('classifier', 'field_punch', 'project_id', v_log.project_id)
      )
      ON CONFLICT (employee_id, work_date, started_at, activity_kind) DO NOTHING;
      v_count := v_count + 1;
    END IF;
  END LOOP;

  -- Open work_log at EOD
  FOR v_log IN
    SELECT wl.*
    FROM data.work_logs wl
    WHERE wl.employee_id = p_employee_id
      AND wl.entry_mode = 'field_punch'
      AND wl.check_in >= v_punch_from
      AND wl.check_in < v_punch_to
      AND wl.check_out IS NULL
  LOOP
    INSERT INTO data.time_activity_segments (
      tenant_id, employee_id, work_date, activity_kind,
      started_at, ended_at, site_id, work_log_id, source_punch_ids, flags_snapshot
    ) VALUES (
      p_tenant_id, p_employee_id, p_work_date, 'WORK',
      v_log.check_in, NULL, v_emp.site_id, v_log.id, '{}',
      jsonb_build_object('classifier', 'field_punch', 'open_at_eod', true)
    )
    ON CONFLICT (employee_id, work_date, started_at, activity_kind) DO NOTHING;
    v_count := v_count + 1;
  END LOOP;

  -- TRAVEL: last work → day_end
  IF v_day_end IS NOT NULL AND v_last_ts IS NOT NULL AND v_day_end > v_last_ts THEN
    INSERT INTO data.time_activity_segments (
      tenant_id, employee_id, work_date, activity_kind,
      started_at, ended_at, site_id, source_punch_ids, flags_snapshot
    ) VALUES (
      p_tenant_id, p_employee_id, p_work_date, 'TRAVEL',
      v_last_ts, v_day_end, v_emp.site_id, '{}',
      jsonb_build_object('classifier', 'field_punch', 'envelope', 'last_work_to_day_end')
    );
    v_count := v_count + 1;
  END IF;

  RETURN v_count;
END;
$$;

-- Patch classify_activity_segments: prefer field_punch when logs exist
CREATE OR REPLACE FUNCTION data.classify_activity_segments(
  p_employee_id uuid,
  p_work_date   date,
  p_tenant_id   uuid
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp          record;
  v_tz           text;
  v_resolved     jsonb;
  v_profile      text;
  v_legacy       boolean;
  v_punch_from   timestamptz;
  v_punch_to     timestamptz;
  v_count        int := 0;
  v_punch        record;
  v_open_kind    text;
  v_open_start   timestamptz;
  v_open_punches uuid[] := '{}';
  v_break_kind   text;
  v_first_in     timestamptz;
  v_last_out     timestamptz;
  v_day_start    timestamptz;
  v_day_end      timestamptz;
  v_added        int;
  v_has_day_start boolean := false;
  v_has_day_end   boolean := false;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, p_tenant_id), 'Europe/Madrid');
  v_punch_from := p_work_date AT TIME ZONE v_tz;
  v_punch_to   := (p_work_date + 1) AT TIME ZONE v_tz;

  v_resolved := data.resolve_attendance_record_policy(p_employee_id, p_work_date);
  v_profile  := COALESCE(v_resolved->>'work_profile', 'fixed_site');
  v_legacy   := data.policy_legacy_in_out_only(v_resolved->'policy', v_profile);

  DELETE FROM data.time_activity_segments
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  -- G2c: field_punch path when mobile + field_punch logs exist
  IF data.is_mobile_work_profile(v_profile)
     AND NOT v_legacy
     AND data.employee_has_field_punch_logs(p_employee_id, p_work_date, p_tenant_id, v_tz) THEN
    RETURN data.classify_field_punch_segments(p_employee_id, p_work_date, p_tenant_id);
  END IF;

  SELECT MIN(occurred_at) FILTER (WHERE punch_type = 'in'),
         MAX(occurred_at) FILTER (WHERE punch_type = 'out'),
         MIN(occurred_at) FILTER (WHERE punch_type = 'day_start'),
         MAX(occurred_at) FILTER (WHERE punch_type = 'day_end')
  INTO v_first_in, v_last_out, v_day_start, v_day_end
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND occurred_at >= v_punch_from
    AND occurred_at < v_punch_to;

  v_has_day_start := v_day_start IS NOT NULL;
  v_has_day_end   := v_day_end IS NOT NULL;

  IF NOT data.is_mobile_work_profile(v_profile) OR v_legacy THEN
    IF v_first_in IS NOT NULL AND v_last_out IS NOT NULL AND v_last_out > v_first_in THEN
      INSERT INTO data.time_activity_segments (
        tenant_id, employee_id, work_date, activity_kind,
        started_at, ended_at, site_id, source_punch_ids, flags_snapshot
      )
      SELECT
        p_tenant_id, p_employee_id, p_work_date, 'WORK',
        v_first_in, v_last_out, v_emp.site_id,
        ARRAY(
          SELECT id FROM data.time_punches
          WHERE employee_id = p_employee_id
            AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
            AND punch_type IN ('in', 'out')
        ),
        jsonb_build_object('work_profile', v_profile, 'classifier', 'fixed_site_legacy');
      v_count := v_count + 1;
    END IF;

    INSERT INTO data.time_activity_segments (
      tenant_id, employee_id, work_date, activity_kind,
      started_at, ended_at, site_id, source_punch_ids, flags_snapshot
    )
    SELECT
      p_tenant_id, p_employee_id, p_work_date,
      CASE WHEN COALESCE(bs.pause_counts_as_work, false) THEN 'BREAK_PAID' ELSE 'BREAK_UNPAID' END,
      bs.occurred_at, be.occurred_at, v_emp.site_id,
      ARRAY[bs.id, be.id],
      jsonb_build_object('pause_type', bs.pause_type, 'classifier', 'fixed_site_legacy')
    FROM (
      SELECT id, occurred_at, pause_type, pause_counts_as_work,
             ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
      FROM data.time_punches
      WHERE employee_id = p_employee_id
        AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
        AND punch_type = 'break_start'
    ) bs
    JOIN (
      SELECT id, occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
      FROM data.time_punches
      WHERE employee_id = p_employee_id
        AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
        AND punch_type = 'break_end'
    ) be ON bs.rn = be.rn
    WHERE be.occurred_at > bs.occurred_at;

    GET DIAGNOSTICS v_added = ROW_COUNT;
    v_count := v_count + v_added;
    RETURN v_count;
  END IF;

  FOR v_punch IN
    SELECT id, punch_type, occurred_at, pause_type, pause_counts_as_work
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND occurred_at >= v_punch_from
      AND occurred_at < v_punch_to
    ORDER BY occurred_at ASC, id ASC
  LOOP
    IF v_open_kind IS NOT NULL THEN
      INSERT INTO data.time_activity_segments (
        tenant_id, employee_id, work_date, activity_kind,
        started_at, ended_at, site_id, source_punch_ids, flags_snapshot
      ) VALUES (
        p_tenant_id, p_employee_id, p_work_date, v_open_kind,
        v_open_start, v_punch.occurred_at, v_emp.site_id, v_open_punches,
        jsonb_build_object('work_profile', v_profile, 'classifier', 'mobile_walk')
      );
      v_count := v_count + 1;
      v_open_kind := NULL;
      v_open_punches := '{}';
    END IF;

    CASE v_punch.punch_type
      WHEN 'day_start' THEN
        v_open_kind := 'TRAVEL';
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'travel_start' THEN
        v_open_kind := 'TRAVEL';
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'in' THEN
        v_open_kind := 'WORK';
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'break_start' THEN
        v_break_kind := CASE WHEN COALESCE(v_punch.pause_counts_as_work, false)
          THEN 'BREAK_PAID' ELSE 'BREAK_UNPAID' END;
        v_open_kind := v_break_kind;
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'out' THEN
        v_open_kind := 'TRAVEL';
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'break_end' THEN
        v_open_kind := 'WORK';
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'travel_end', 'day_end' THEN
        NULL;
      ELSE
        NULL;
    END CASE;
  END LOOP;

  IF v_open_kind IS NOT NULL THEN
    INSERT INTO data.time_activity_segments (
      tenant_id, employee_id, work_date, activity_kind,
      started_at, ended_at, site_id, source_punch_ids, flags_snapshot
    ) VALUES (
      p_tenant_id, p_employee_id, p_work_date, v_open_kind,
      v_open_start, NULL, v_emp.site_id, v_open_punches,
      jsonb_build_object('work_profile', v_profile, 'classifier', 'mobile_walk', 'open_at_eod', true)
    );
    v_count := v_count + 1;
  END IF;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION data.employee_has_field_punch_logs(uuid, date, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.classify_field_punch_segments(uuid, date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.employee_has_field_punch_logs(uuid, date, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION data.classify_field_punch_segments(uuid, date, uuid) TO service_role;

GRANT EXECUTE ON FUNCTION data.classify_activity_segments(uuid, date, uuid) TO service_role;
