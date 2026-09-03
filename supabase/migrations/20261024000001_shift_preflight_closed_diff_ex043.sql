-- =============================================================================
-- EX-04.3 — Preflight publicació, bloqueig períodes tancats, diff entre lots
-- =============================================================================

-- ─── 1. Detecció de dies no mutables (payroll lock + mes tancat) ─────────────

CREATE OR REPLACE FUNCTION data.shift_closed_period_issues(
  p_pairs jsonb  -- [{employee_id, work_date}, ...]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_issues jsonb := '[]'::jsonb;
BEGIN
  IF p_pairs IS NULL OR jsonb_typeof(p_pairs) <> 'array' OR jsonb_array_length(p_pairs) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(issue ORDER BY issue->>'employee_id', issue->>'work_date', issue->>'code'), '[]'::jsonb)
  INTO v_issues
  FROM (
    SELECT DISTINCT jsonb_build_object(
      'code', 'PAYROLL_LOCKED',
      'severity', 'block',
      'employee_id', tds.employee_id,
      'work_date', tds.work_date,
      'message', 'Dia bloquejat per exportació de nòmina'
    ) AS issue
    FROM jsonb_to_recordset(p_pairs) AS p(employee_id uuid, work_date date)
    JOIN data.time_daily_summaries tds
      ON tds.employee_id = p.employee_id
     AND tds.work_date = p.work_date
    WHERE tds.payroll_locked_at IS NOT NULL

    UNION ALL

    SELECT DISTINCT jsonb_build_object(
      'code', 'MONTH_CLOSED',
      'severity', 'block',
      'employee_id', p.employee_id,
      'work_date', p.work_date,
      'message', 'Mes tancat (manager_approved/signed/archived); cal esmena'
    ) AS issue
    FROM jsonb_to_recordset(p_pairs) AS p(employee_id uuid, work_date date)
    JOIN data.attendance_monthly_reports amr
      ON amr.employee_id = p.employee_id
     AND amr.year = EXTRACT(YEAR FROM p.work_date)::int
     AND amr.month = EXTRACT(MONTH FROM p.work_date)::int
    WHERE amr.status IN ('manager_approved', 'signed', 'archived')
  ) x;

  RETURN COALESCE(v_issues, '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION data.shift_closed_period_issues(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.shift_closed_period_issues(jsonb) TO service_role;

CREATE OR REPLACE FUNCTION data.assert_shift_pairs_mutable(p_pairs jsonb)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_issues jsonb;
  v_first jsonb;
BEGIN
  v_issues := data.shift_closed_period_issues(p_pairs);
  IF jsonb_array_length(v_issues) > 0 THEN
    v_first := v_issues->0;
    RAISE EXCEPTION 'period_closed: % (employee=% work_date=%)',
      v_first->>'code',
      v_first->>'employee_id',
      v_first->>'work_date'
      USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_shift_pairs_mutable(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_shift_pairs_mutable(jsonb) TO service_role;

-- ─── 2. Preflight de publicació ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.preflight_publish_shifts(
  p_site_id    uuid,
  p_week_start date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_week_end date;
  v_draft_count int := 0;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_pairs jsonb := '[]'::jsonb;
  v_closed jsonb;
  v_affected uuid[] := ARRAY[]::uuid[];
  v_slot record;
  v_plan jsonb;
  v_labor_day text;
  v_day_type text;
  v_other record;
  v_week_min numeric;
  v_slot_min numeric;
  v_weekly_hours numeric;
  v_cov record;
  v_emp_ids uuid[];
BEGIN
  IF EXTRACT(DOW FROM p_week_start)::int <> 1 THEN
    RAISE EXCEPTION 'invalid_week_start: p_week_start ha de ser dilluns'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage', p_site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_week_end := p_week_start + 6;

  SELECT count(*)::int,
         coalesce(array_agg(DISTINCT ss.employee_id), ARRAY[]::uuid[])
  INTO v_draft_count, v_emp_ids
  FROM data.shift_slots ss
  WHERE ss.site_id = p_site_id
    AND ss.slot_date BETWEEN p_week_start AND v_week_end
    AND ss.status = 'draft';

  v_affected := coalesce(v_emp_ids, ARRAY[]::uuid[]);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'employee_id', ss.employee_id,
    'work_date', ss.slot_date
  )), '[]'::jsonb)
  INTO v_pairs
  FROM data.shift_slots ss
  WHERE ss.site_id = p_site_id
    AND ss.slot_date BETWEEN p_week_start AND v_week_end
    AND ss.status = 'draft';

  v_closed := data.shift_closed_period_issues(v_pairs);
  IF jsonb_array_length(v_closed) > 0 THEN
    v_blockers := v_blockers || v_closed;
  END IF;

  FOR v_slot IN
    SELECT ss.id, ss.employee_id, ss.slot_date, ss.start_time, ss.end_time
    FROM data.shift_slots ss
    WHERE ss.site_id = p_site_id
      AND ss.slot_date BETWEEN p_week_start AND v_week_end
      AND ss.status = 'draft'
    ORDER BY ss.slot_date, ss.start_time, ss.id
  LOOP
    -- Solapament amb qualsevol altre slot no cancel·lat
    SELECT ss2.id, ss2.slot_date, ss2.start_time, ss2.end_time
    INTO v_other
    FROM data.shift_slots ss2
    WHERE ss2.employee_id = v_slot.employee_id
      AND ss2.id <> v_slot.id
      AND ss2.status <> 'cancelled'
      AND ss2.slot_date BETWEEN v_slot.slot_date - 1 AND v_slot.slot_date + 1
      AND data.shift_slots_overlap(
        v_slot.slot_date, v_slot.start_time, v_slot.end_time,
        ss2.slot_date, ss2.start_time, ss2.end_time
      )
    LIMIT 1;

    IF FOUND THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'SHIFT_OVERLAP',
        'severity', 'warn_require_reason',
        'employee_id', v_slot.employee_id,
        'work_date', v_slot.slot_date,
        'slot_id', v_slot.id,
        'message', 'Solapament amb un altre torn'
      ));
    END IF;

    -- Hores setmanals
    SELECT e.weekly_hours INTO v_weekly_hours
    FROM data.employees e WHERE e.id = v_slot.employee_id;

    v_slot_min := ROUND(EXTRACT(EPOCH FROM CASE
      WHEN v_slot.end_time > v_slot.start_time THEN v_slot.end_time - v_slot.start_time
      ELSE interval '24 hours' + (v_slot.end_time - v_slot.start_time)
    END) / 60);

    SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM CASE
      WHEN ss2.end_time > ss2.start_time THEN ss2.end_time - ss2.start_time
      ELSE interval '24 hours' + (ss2.end_time - ss2.start_time)
    END) / 60)), 0)
    INTO v_week_min
    FROM data.shift_slots ss2
    WHERE ss2.employee_id = v_slot.employee_id
      AND ss2.slot_date BETWEEN p_week_start AND v_week_end
      AND ss2.status <> 'cancelled';

    IF v_weekly_hours IS NOT NULL AND v_week_min > (v_weekly_hours * 60) THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'WEEKLY_HOURS_EXCEEDED',
        'severity', 'warn_require_reason',
        'employee_id', v_slot.employee_id,
        'work_date', v_slot.slot_date,
        'slot_id', v_slot.id,
        'message', format('Hores setmanals superades (%s min / %s h)', round(v_week_min)::int, v_weekly_hours)
      ));
    END IF;

    -- Dia no laboral (festiu/vacances/leave) sense override work
    v_plan := data.resolve_employee_work_plan(v_slot.employee_id, v_slot.slot_date);
    v_labor_day := v_plan->>'labor_day_type';
    v_day_type := v_plan->>'day_type';

    IF COALESCE(v_labor_day, '') IN ('holiday', 'vacation', 'leave')
       OR COALESCE(v_day_type, '') IN ('holiday', 'half_holiday', 'non_working', 'absence')
    THEN
      -- Absència total ja coberta més avall; holiday/vacation/leave sense work → blocker
      IF COALESCE(v_day_type, '') <> 'absence'
         AND COALESCE(v_labor_day, '') IN ('holiday', 'vacation', 'leave') THEN
        v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
          'code', 'NON_WORK_DAY',
          'severity', 'block',
          'employee_id', v_slot.employee_id,
          'work_date', v_slot.slot_date,
          'slot_id', v_slot.id,
          'labor_day_type', v_labor_day,
          'message', 'Cal override laboral (work) abans de publicar un torn en festiu/vacances/leave'
        ));
      END IF;
    END IF;

    -- Absència aprovada solapada
    IF EXISTS (
      SELECT 1
      FROM data.employee_absences ea
      WHERE ea.employee_id = v_slot.employee_id
        AND ea.status IN ('approved', 'active', 'closed')
        AND ea.start_date <= v_slot.slot_date
        AND COALESCE(ea.end_date, '9999-12-31'::date) >= v_slot.slot_date
    ) THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'APPROVED_ABSENCE',
        'severity', 'warn_require_reason',
        'employee_id', v_slot.employee_id,
        'work_date', v_slot.slot_date,
        'slot_id', v_slot.id,
        'message', 'Hi ha una absència aprovada/activa aquest dia'
      ));
    END IF;
  END LOOP;

  -- Cobertura negativa (warn informatiu)
  FOR v_cov IN
    SELECT *
    FROM jsonb_array_elements(
      COALESCE(api.get_coverage_for_period(p_site_id, p_week_start, v_week_end), '[]'::jsonb)
    ) AS x(day)
  LOOP
    IF COALESCE((v_cov.day->>'coverage_delta')::int, 0) < 0 THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'COVERAGE_SHORTAGE',
        'severity', 'warn',
        'work_date', v_cov.day->>'work_date',
        'coverage_delta', (v_cov.day->>'coverage_delta')::int,
        'message', format(
          'Cobertura insuficient: %s/%s',
          v_cov.day->>'employee_count',
          v_cov.day->>'required_employee_count'
        )
      ));
    END IF;
  END LOOP;

  -- Deduplicar warnings per (code, employee_id, work_date, slot_id)
  SELECT COALESCE(jsonb_agg(DISTINCT w), '[]'::jsonb)
  INTO v_warnings
  FROM jsonb_array_elements(v_warnings) AS w;

  SELECT COALESCE(jsonb_agg(DISTINCT b), '[]'::jsonb)
  INTO v_blockers
  FROM jsonb_array_elements(v_blockers) AS b;

  RETURN jsonb_build_object(
    'site_id', p_site_id,
    'week_start', p_week_start,
    'week_end', v_week_end,
    'draft_count', v_draft_count,
    'can_publish', jsonb_array_length(v_blockers) = 0 AND v_draft_count > 0,
    'blockers', COALESCE(v_blockers, '[]'::jsonb),
    'warnings', COALESCE(v_warnings, '[]'::jsonb),
    'affected_employee_ids', to_jsonb(v_affected),
    'required_warning_codes', (
      SELECT COALESCE(jsonb_agg(DISTINCT w->>'code'), '[]'::jsonb)
      FROM jsonb_array_elements(COALESCE(v_warnings, '[]'::jsonb)) w
      WHERE w->>'severity' = 'warn_require_reason'
    )
  );
END;
$$;

COMMENT ON FUNCTION api.preflight_publish_shifts(uuid, date) IS
  'EX-04.3: validació prèvia a publish_shifts (blockers + warnings).';

GRANT EXECUTE ON FUNCTION api.preflight_publish_shifts(uuid, date) TO authenticated, service_role;

-- ─── 3. publish_shifts amb warnings acceptats + gate preflight ───────────────

DROP FUNCTION IF EXISTS api.publish_shifts(uuid, date);

CREATE OR REPLACE FUNCTION api.publish_shifts(
  p_site_id            uuid,
  p_week_start         date,
  p_warnings_accepted  text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_tz text;
  v_week_end date;
  v_count int;
  v_slot record;
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_version int;
  v_pub_id uuid;
  v_hash text;
  v_slot_ids uuid[];
  v_employee_ids uuid[];
  v_preflight jsonb;
  v_blockers jsonb;
  v_required text[];
  v_accepted text[] := COALESCE(p_warnings_accepted, ARRAY[]::text[]);
  v_missing text[];
  v_prev_pub_id uuid;
  v_diff jsonb;
BEGIN
  IF EXTRACT(DOW FROM p_week_start)::int <> 1 THEN
    RAISE EXCEPTION 'invalid_week_start: p_week_start ha de ser dilluns'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage'), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext(p_site_id::text || ':' || p_week_start::text)
  );

  v_tz := COALESCE(
    (api.get_effective_settings(
      p_site_id => p_site_id, p_user_id => NULL, p_tenant_id => v_tenant_id
    ) ->> 'site_timezone'),
    'Europe/Madrid'
  );
  v_week_end := p_week_start + 6;

  SELECT count(*)::int INTO v_count
  FROM data.shift_slots
  WHERE site_id = p_site_id
    AND slot_date BETWEEN p_week_start AND v_week_end
    AND status = 'draft';

  IF v_count = 0 THEN
    RETURN jsonb_build_object(
      'site_id', p_site_id,
      'week_start', p_week_start,
      'published', 0,
      'publication_id', NULL,
      'version', NULL,
      'content_hash', NULL,
      'diff', NULL
    );
  END IF;

  v_preflight := api.preflight_publish_shifts(p_site_id, p_week_start);
  v_blockers := COALESCE(v_preflight->'blockers', '[]'::jsonb);

  IF jsonb_array_length(v_blockers) > 0 THEN
    RAISE EXCEPTION 'preflight_blocked: hi ha % blocker(s)', jsonb_array_length(v_blockers)
      USING ERRCODE = 'check_violation',
            DETAIL = v_blockers::text;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::text[])
  INTO v_required
  FROM jsonb_array_elements_text(COALESCE(v_preflight->'required_warning_codes', '[]'::jsonb)) AS t(x);

  SELECT COALESCE(array_agg(r), ARRAY[]::text[])
  INTO v_missing
  FROM unnest(v_required) AS r
  WHERE NOT (r = ANY (v_accepted));

  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'preflight_warnings_unaccepted: cal acceptar %', array_to_string(v_missing, ',')
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT id INTO v_prev_pub_id
  FROM data.shift_publications
  WHERE site_id = p_site_id
    AND week_start = p_week_start
    AND status = 'published'
  ORDER BY version DESC
  LIMIT 1;

  SELECT COALESCE(MAX(sp.version), 0) + 1 INTO v_version
  FROM data.shift_publications sp
  WHERE sp.tenant_id = v_tenant_id
    AND sp.site_id = p_site_id
    AND sp.week_start = p_week_start;

  UPDATE data.shift_publications
  SET status = 'superseded', updated_at = now()
  WHERE site_id = p_site_id
    AND week_start = p_week_start
    AND status = 'published';

  INSERT INTO data.shift_publications (
    tenant_id, site_id, week_start, version, status,
    published_by, published_at, summary, content_hash
  ) VALUES (
    v_tenant_id, p_site_id, p_week_start, v_version, 'published',
    auth.uid(), now(), '{}'::jsonb, ''
  )
  RETURNING id INTO v_pub_id;

  UPDATE data.shift_slots
  SET status = 'published',
      published_at = now(),
      publication_id = v_pub_id,
      updated_at = now()
  WHERE site_id = p_site_id
    AND slot_date BETWEEN p_week_start AND v_week_end
    AND status = 'draft';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  v_hash := data.shift_publication_content_hash(v_pub_id);

  SELECT
    coalesce(array_agg(ss.id ORDER BY ss.id), ARRAY[]::uuid[]),
    coalesce(array_agg(DISTINCT ss.employee_id), ARRAY[]::uuid[])
  INTO v_slot_ids, v_employee_ids
  FROM data.shift_slots ss
  WHERE ss.publication_id = v_pub_id;

  UPDATE data.shift_publications
  SET content_hash = v_hash,
      summary = jsonb_build_object(
        'slot_count', v_count,
        'slot_ids', to_jsonb(v_slot_ids),
        'employee_ids', to_jsonb(v_employee_ids),
        'warnings_accepted', to_jsonb(v_accepted),
        'preflight', jsonb_build_object(
          'warning_count', jsonb_array_length(COALESCE(v_preflight->'warnings', '[]'::jsonb)),
          'blocker_count', 0
        )
      ),
      updated_at = now()
  WHERE id = v_pub_id;

  FOR v_slot IN
    SELECT ss.id AS slot_id, ss.employee_id, ss.slot_date, ss.site_id,
           ss.start_time, ss.end_time, ss.location_id,
           ss.location_name_snapshot, ss.location_path_snapshot,
           ws.name, ws.color
    FROM data.shift_slots ss
    JOIN data.work_shifts ws ON ws.id = ss.shift_id
    WHERE ss.site_id = p_site_id
      AND ss.slot_date BETWEEN p_week_start AND v_week_end
      AND ss.status = 'published'
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
      jsonb_build_object(
        'employee_id', v_slot.employee_id,
        'slot_date', v_slot.slot_date,
        'location_id', v_slot.location_id,
        'location_name', v_slot.location_name_snapshot,
        'location_path', v_slot.location_path_snapshot,
        'publication_id', v_pub_id
      )
    );
  END LOOP;

  IF v_prev_pub_id IS NOT NULL THEN
    v_diff := api.diff_shift_publications(v_prev_pub_id, v_pub_id);
  ELSE
    v_diff := jsonb_build_object(
      'from_publication_id', NULL,
      'to_publication_id', v_pub_id,
      'added', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'slot_id', ss.id,
          'employee_id', ss.employee_id,
          'slot_date', ss.slot_date,
          'start_time', ss.start_time,
          'end_time', ss.end_time,
          'location_id', ss.location_id
        ) ORDER BY ss.slot_date, ss.start_time), '[]'::jsonb)
        FROM data.shift_slots ss WHERE ss.publication_id = v_pub_id
      ),
      'removed', '[]'::jsonb,
      'changed', '[]'::jsonb,
      'counts', jsonb_build_object(
        'added', v_count,
        'removed', 0,
        'changed', 0
      )
    );
  END IF;

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(), p_site_id,
    'SHIFTS_PUBLISHED', 'shift_publication', v_pub_id,
    jsonb_build_object(
      'site_id', p_site_id,
      'week_start', p_week_start,
      'published', v_count,
      'publication_id', v_pub_id,
      'version', v_version,
      'content_hash', v_hash,
      'warnings_accepted', to_jsonb(v_accepted)
    )
  );

  RETURN jsonb_build_object(
    'site_id', p_site_id,
    'week_start', p_week_start,
    'published', v_count,
    'publication_id', v_pub_id,
    'version', v_version,
    'content_hash', v_hash,
    'warnings_accepted', to_jsonb(v_accepted),
    'diff', v_diff
  );
END;
$$;

COMMENT ON FUNCTION api.publish_shifts(uuid, date, text[]) IS
  'EX-04.3: publica drafts amb preflight + warnings_accepted; retorna diff vs lot anterior.';

GRANT EXECUTE ON FUNCTION api.publish_shifts(uuid, date, text[]) TO authenticated, service_role;

-- ─── 4. Diff entre publicacions ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.diff_shift_publications(
  p_from_publication_id uuid,
  p_to_publication_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_from record;
  v_to record;
  v_added jsonb;
  v_removed jsonb;
  v_changed jsonb;
BEGIN
  SELECT * INTO v_from FROM data.shift_publications WHERE id = p_from_publication_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'publication_not_found: %', p_from_publication_id USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_to FROM data.shift_publications WHERE id = p_to_publication_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'publication_not_found: %', p_to_publication_id USING ERRCODE = 'P0002';
  END IF;

  IF v_from.tenant_id <> v_to.tenant_id OR v_from.site_id <> v_to.site_id THEN
    RAISE EXCEPTION 'publication_mismatch: lots de centre/tenant diferents'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_to.tenant_id, 'labor_calendar.view', v_to.site_id)
    OR data.jwt_has_permission(v_to.tenant_id, 'labor_calendar.manage', v_to.site_id)
    OR data.jwt_has_permission(v_to.tenant_id, 'attendance.view_all', v_to.site_id),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Matching per (employee_id, slot_date, start_time, end_time, location_id)
  WITH from_slots AS (
    SELECT ss.*
    FROM data.shift_slots ss
    WHERE ss.publication_id = p_from_publication_id
  ),
  to_slots AS (
    SELECT ss.*
    FROM data.shift_slots ss
    WHERE ss.publication_id = p_to_publication_id
  ),
  matched AS (
    SELECT
      f.id AS from_id,
      t.id AS to_id,
      f.employee_id,
      f.slot_date,
      f.start_time AS from_start,
      f.end_time AS from_end,
      f.location_id AS from_location_id,
      t.start_time AS to_start,
      t.end_time AS to_end,
      t.location_id AS to_location_id
    FROM from_slots f
    JOIN to_slots t
      ON t.employee_id = f.employee_id
     AND t.slot_date = f.slot_date
     AND t.start_time = f.start_time
     AND t.end_time = f.end_time
     AND t.location_id IS NOT DISTINCT FROM f.location_id
  )
  SELECT
    (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'slot_id', t.id,
        'employee_id', t.employee_id,
        'slot_date', t.slot_date,
        'start_time', t.start_time,
        'end_time', t.end_time,
        'location_id', t.location_id
      ) ORDER BY t.slot_date, t.start_time, t.id), '[]'::jsonb)
      FROM to_slots t
      WHERE NOT EXISTS (
        SELECT 1 FROM matched m WHERE m.to_id = t.id
      )
    ),
    (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'slot_id', f.id,
        'employee_id', f.employee_id,
        'slot_date', f.slot_date,
        'start_time', f.start_time,
        'end_time', f.end_time,
        'location_id', f.location_id
      ) ORDER BY f.slot_date, f.start_time, f.id), '[]'::jsonb)
      FROM from_slots f
      WHERE NOT EXISTS (
        SELECT 1 FROM matched m WHERE m.from_id = f.id
      )
    ),
    (
      -- Same employee+date but different times/location → changed
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'from_slot_id', f.id,
        'to_slot_id', t.id,
        'employee_id', f.employee_id,
        'slot_date', f.slot_date,
        'from', jsonb_build_object(
          'start_time', f.start_time,
          'end_time', f.end_time,
          'location_id', f.location_id
        ),
        'to', jsonb_build_object(
          'start_time', t.start_time,
          'end_time', t.end_time,
          'location_id', t.location_id
        )
      ) ORDER BY f.slot_date, f.start_time), '[]'::jsonb)
      FROM from_slots f
      JOIN to_slots t
        ON t.employee_id = f.employee_id
       AND t.slot_date = f.slot_date
      WHERE NOT EXISTS (SELECT 1 FROM matched m WHERE m.from_id = f.id)
        AND NOT EXISTS (SELECT 1 FROM matched m WHERE m.to_id = t.id)
        AND (
          t.start_time IS DISTINCT FROM f.start_time
          OR t.end_time IS DISTINCT FROM f.end_time
          OR t.location_id IS DISTINCT FROM f.location_id
        )
        -- only pair 1:1 greedily by closest start
        AND t.id = (
          SELECT t2.id FROM to_slots t2
          WHERE t2.employee_id = f.employee_id
            AND t2.slot_date = f.slot_date
            AND NOT EXISTS (SELECT 1 FROM matched m WHERE m.to_id = t2.id)
          ORDER BY abs(extract(epoch from (t2.start_time - f.start_time)))
          LIMIT 1
        )
    )
  INTO v_added, v_removed, v_changed;

  -- Avoid double-counting: remove changed pairs from added/removed
  IF jsonb_array_length(COALESCE(v_changed, '[]'::jsonb)) > 0 THEN
    SELECT COALESCE(jsonb_agg(a), '[]'::jsonb)
    INTO v_added
    FROM jsonb_array_elements(COALESCE(v_added, '[]'::jsonb)) a
    WHERE NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_changed) c
      WHERE c->>'to_slot_id' = a->>'slot_id'
    );

    SELECT COALESCE(jsonb_agg(r), '[]'::jsonb)
    INTO v_removed
    FROM jsonb_array_elements(COALESCE(v_removed, '[]'::jsonb)) r
    WHERE NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_changed) c
      WHERE c->>'from_slot_id' = r->>'slot_id'
    );
  END IF;

  RETURN jsonb_build_object(
    'from_publication_id', p_from_publication_id,
    'to_publication_id', p_to_publication_id,
    'from_version', v_from.version,
    'to_version', v_to.version,
    'week_start', v_to.week_start,
    'added', COALESCE(v_added, '[]'::jsonb),
    'removed', COALESCE(v_removed, '[]'::jsonb),
    'changed', COALESCE(v_changed, '[]'::jsonb),
    'counts', jsonb_build_object(
      'added', jsonb_array_length(COALESCE(v_added, '[]'::jsonb)),
      'removed', jsonb_array_length(COALESCE(v_removed, '[]'::jsonb)),
      'changed', jsonb_array_length(COALESCE(v_changed, '[]'::jsonb))
    )
  );
END;
$$;

COMMENT ON FUNCTION api.diff_shift_publications(uuid, uuid) IS
  'EX-04.3: diff slot-level entre dos lots de publicació.';

GRANT EXECUTE ON FUNCTION api.diff_shift_publications(uuid, uuid) TO authenticated, service_role;

-- ─── 5. Guards a assign / bulk_delete ────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.assign_shift_slot(
  p_employee_id uuid,
  p_slot_date date,
  p_shift_id uuid,
  p_notes text DEFAULT NULL,
  p_location_id uuid DEFAULT NULL
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
  v_location_id uuid;
  v_site_id uuid;
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

  PERFORM data.assert_shift_pairs_mutable(
    jsonb_build_array(jsonb_build_object(
      'employee_id', p_employee_id,
      'work_date', p_slot_date
    ))
  );

  SELECT ws.* INTO v_shift
  FROM data.work_shifts ws
  WHERE ws.id = p_shift_id
    AND ws.tenant_id = v_emp.tenant_id
    AND ws.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shift_not_found_or_inactive: %', p_shift_id USING ERRCODE = 'P0002';
  END IF;

  v_site_id := COALESCE(v_shift.site_id, v_emp.site_id);
  v_location_id := COALESCE(p_location_id, v_shift.default_location_id);

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
    tenant_id, site_id, employee_id, shift_id, slot_date, status, notes, created_by,
    start_time, end_time, location_id
  ) VALUES (
    v_emp.tenant_id, v_site_id, p_employee_id, p_shift_id,
    p_slot_date, 'draft', p_notes, auth.uid(),
    v_shift.start_time, v_shift.end_time, v_location_id
  )
  RETURNING id INTO v_slot_id;

  PERFORM data.log_audit_event(
    v_emp.tenant_id, auth.uid(), v_site_id,
    'SHIFT_SLOT_ASSIGNED', 'shift_slot', v_slot_id,
    jsonb_build_object(
      'employee_id', p_employee_id,
      'shift_id', p_shift_id,
      'slot_date', p_slot_date,
      'location_id', v_location_id,
      'anomalies', v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'slot_id', v_slot_id,
    'status', 'draft',
    'location_id', v_location_id,
    'anomalies', v_anomalies
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.bulk_delete_shift_slots(
  p_slot_ids  uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id  uuid;
  v_count      int;
  v_pairs      jsonb;
BEGIN
  IF p_slot_ids IS NULL OR array_length(p_slot_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('cancelled_count', 0);
  END IF;

  SELECT tenant_id INTO v_tenant_id
  FROM data.shift_slots
  WHERE id = ANY(p_slot_ids)
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('cancelled_count', 0);
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
    'employee_id', ss.employee_id,
    'work_date', ss.slot_date
  )), '[]'::jsonb)
  INTO v_pairs
  FROM data.shift_slots ss
  WHERE ss.id = ANY(p_slot_ids)
    AND ss.tenant_id = v_tenant_id
    AND ss.status <> 'cancelled';

  PERFORM data.assert_shift_pairs_mutable(v_pairs);

  UPDATE data.shift_slots
  SET status       = 'cancelled',
      cancelled_at = now(),
      updated_at   = now()
  WHERE id        = ANY(p_slot_ids)
    AND tenant_id = v_tenant_id
    AND status   <> 'cancelled';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  DELETE FROM data.calendar_events
  WHERE entity_type = 'shift_slot'
    AND entity_id   = ANY(p_slot_ids);

  RETURN jsonb_build_object('cancelled_count', v_count);
END;
$$;

NOTIFY pgrst, 'reload schema';
