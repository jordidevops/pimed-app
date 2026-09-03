-- =============================================================================
-- EX-08.3 — Heurístiques explicables fatiga / equitat / risc de gap (AP-09)
-- Sense scoring opac per sancionar, ordenar o excloure empleats.
-- Només senyals amb explanation + fets mesurables.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.slot_hours(p_start time, p_end time)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ROUND((EXTRACT(EPOCH FROM CASE
    WHEN p_end > p_start THEN p_end - p_start
    ELSE interval '24 hours' + (p_end - p_start)
  END) / 3600.0)::numeric, 2);
$$;

CREATE OR REPLACE FUNCTION data.is_night_shift_start(p_start time)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_start >= TIME '22:00' OR p_start < TIME '06:00';
$$;

-- ─── Core heuristics (SECURITY DEFINER, sense JWT) ───────────────────────────

CREATE OR REPLACE FUNCTION data.compute_site_planning_heuristics(
  p_site_id uuid,
  p_as_of date DEFAULT CURRENT_DATE,
  p_lookback_days int DEFAULT 28
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid;
  v_lookback int := GREATEST(7, LEAST(COALESCE(p_lookback_days, 28), 90));
  v_from date;
  v_tomorrow date;
  v_fatigue jsonb := '[]'::jsonb;
  v_equity jsonb := '[]'::jsonb;
  v_absence jsonb := '[]'::jsonb;
  v_late jsonb := '[]'::jsonb;
  v_gap jsonb;
  v_emp record;
  v_consec int;
  v_d date;
  v_has boolean;
  v_rule_consec numeric;
  v_rule_rest numeric;
  v_prev_end timestamp;
  v_next_start timestamp;
  v_gap_h numeric;
  v_avg_h numeric;
  v_req int := 0;
  v_planned int := 0;
  v_open_places int := 0;
  v_gap_n int;
  v_risk text;
  v_suggestions jsonb := '[]'::jsonb;
  v_dow int;
BEGIN
  SELECT s.tenant_id INTO v_tenant FROM data.sites s WHERE s.id = p_site_id;
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'site_not_found');
  END IF;

  v_from := p_as_of - v_lookback;
  v_tomorrow := p_as_of + 1;

  SELECT value_numeric INTO v_rule_consec
  FROM data.resolve_labor_rule(v_tenant, p_site_id, 'max_consecutive_work_days');
  v_rule_consec := COALESCE(v_rule_consec, 6);

  SELECT value_numeric INTO v_rule_rest
  FROM data.resolve_labor_rule(v_tenant, p_site_id, 'min_rest_between_shifts_hours');
  v_rule_rest := COALESCE(v_rule_rest, 11);

  -- ── Fatiga: dies consecutius prop del límit + descans curt recent ──────────
  FOR v_emp IN
    SELECT e.id, e.full_name
    FROM data.employees e
    WHERE e.site_id = p_site_id AND e.tenant_id = v_tenant AND e.status = 'active'
  LOOP
    -- Consecutius acabant a as_of (cap enrere)
    v_consec := 0;
    v_d := p_as_of;
    LOOP
      SELECT EXISTS (
        SELECT 1 FROM data.shift_slots ss
        WHERE ss.employee_id = v_emp.id
          AND ss.slot_date = v_d
          AND ss.status <> 'cancelled'
      ) INTO v_has;
      EXIT WHEN NOT v_has;
      v_consec := v_consec + 1;
      v_d := v_d - 1;
      EXIT WHEN v_consec > (v_rule_consec::int + 3);
    END LOOP;

    IF v_consec >= GREATEST(v_rule_consec::int - 1, 1) THEN
      v_fatigue := v_fatigue || jsonb_build_array(jsonb_build_object(
        'code', CASE WHEN v_consec > v_rule_consec THEN 'MAX_CONSECUTIVE_WORK_DAYS'
                     ELSE 'NEAR_MAX_CONSECUTIVE_DAYS' END,
        'employee_id', v_emp.id,
        'employee_name', v_emp.full_name,
        'actual_days', v_consec,
        'rule_limit', v_rule_consec,
        'explanation', format(
          '%s: %s dies consecutius amb torn (límit configurat %s).',
          v_emp.full_name, v_consec, v_rule_consec
        )
      ));
    END IF;

    -- Descans curt entre dos slots dels darrers 3 dies
    SELECT
      data.shift_slot_end_ts(ss1.slot_date, ss1.start_time, ss1.end_time),
      data.shift_slot_start_ts(ss2.slot_date, ss2.start_time)
    INTO v_prev_end, v_next_start
    FROM data.shift_slots ss1
    JOIN data.shift_slots ss2
      ON ss2.employee_id = ss1.employee_id
     AND ss2.id <> ss1.id
     AND ss2.status <> 'cancelled'
     AND data.shift_slot_start_ts(ss2.slot_date, ss2.start_time)
         > data.shift_slot_end_ts(ss1.slot_date, ss1.start_time, ss1.end_time)
    WHERE ss1.employee_id = v_emp.id
      AND ss1.status <> 'cancelled'
      AND ss1.slot_date BETWEEN p_as_of - 3 AND p_as_of + 1
      AND ss2.slot_date BETWEEN p_as_of - 3 AND p_as_of + 1
    ORDER BY data.shift_slot_end_ts(ss1.slot_date, ss1.start_time, ss1.end_time) DESC
    LIMIT 1;

    IF v_prev_end IS NOT NULL AND v_next_start IS NOT NULL THEN
      v_gap_h := ROUND((EXTRACT(EPOCH FROM (v_next_start - v_prev_end)) / 3600.0)::numeric, 2);
      IF v_gap_h < v_rule_rest THEN
        v_fatigue := v_fatigue || jsonb_build_array(jsonb_build_object(
          'code', 'SHORT_REST_BETWEEN_SHIFTS',
          'employee_id', v_emp.id,
          'employee_name', v_emp.full_name,
          'actual_hours', v_gap_h,
          'rule_limit', v_rule_rest,
          'explanation', format(
            '%s: descans de %s h entre torns (mínim configurat %s h).',
            v_emp.full_name, v_gap_h, v_rule_rest
          )
        ));
      END IF;
    END IF;
  END LOOP;

  -- ── Equitat: hores / caps de setmana / nits vs mitjana del centre ──────────
  SELECT COALESCE(AVG(x.hours), 0) INTO v_avg_h
  FROM (
    SELECT ss.employee_id,
           SUM(data.slot_hours(ss.start_time, ss.end_time)) AS hours
    FROM data.shift_slots ss
    WHERE ss.site_id = p_site_id
      AND ss.status <> 'cancelled'
      AND ss.slot_date BETWEEN v_from AND p_as_of
    GROUP BY ss.employee_id
  ) x;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY abs(r.delta_vs_avg_hours) DESC), '[]'::jsonb)
  INTO v_equity
  FROM (
    SELECT
      e.id AS employee_id,
      e.full_name AS employee_name,
      COALESCE(SUM(data.slot_hours(ss.start_time, ss.end_time)), 0) AS hours,
      COUNT(*) FILTER (
        WHERE EXTRACT(DOW FROM ss.slot_date)::int IN (0, 6)
      )::int AS weekend_shifts,
      COUNT(*) FILTER (
        WHERE data.is_night_shift_start(ss.start_time)
      )::int AS night_shifts,
      ROUND(
        COALESCE(SUM(data.slot_hours(ss.start_time, ss.end_time)), 0) - v_avg_h,
        2
      ) AS delta_vs_avg_hours,
      format(
        '%s: %s h en %s dies (mitjana centre %s h; delta %s). Caps de setmana: %s. Nits: %s.',
        e.full_name,
        COALESCE(SUM(data.slot_hours(ss.start_time, ss.end_time)), 0),
        v_lookback,
        ROUND(v_avg_h, 2),
        ROUND(COALESCE(SUM(data.slot_hours(ss.start_time, ss.end_time)), 0) - v_avg_h, 2),
        COUNT(*) FILTER (WHERE EXTRACT(DOW FROM ss.slot_date)::int IN (0, 6)),
        COUNT(*) FILTER (WHERE data.is_night_shift_start(ss.start_time))
      ) AS explanation
    FROM data.employees e
    LEFT JOIN data.shift_slots ss
      ON ss.employee_id = e.id
     AND ss.site_id = p_site_id
     AND ss.status <> 'cancelled'
     AND ss.slot_date BETWEEN v_from AND p_as_of
    WHERE e.site_id = p_site_id AND e.tenant_id = v_tenant AND e.status = 'active'
    GROUP BY e.id, e.full_name
    HAVING COALESCE(SUM(data.slot_hours(ss.start_time, ss.end_time)), 0) > 0
       OR COUNT(ss.id) > 0
  ) r;

  -- ── Patrons d'absència per dia de la setmana (agregat) ─────────────────────
  SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.absence_count DESC), '[]'::jsonb)
  INTO v_absence
  FROM (
    SELECT
      EXTRACT(DOW FROM d)::int AS day_of_week,
      count(*)::int AS absence_count,
      count(DISTINCT ea.employee_id)::int AS employee_count,
      format(
        'DOW %s: %s absències (%s empleats) en %s dies.',
        EXTRACT(DOW FROM d)::int,
        count(*),
        count(DISTINCT ea.employee_id),
        v_lookback
      ) AS explanation
    FROM data.employee_absences ea
    CROSS JOIN LATERAL generate_series(
      GREATEST(ea.start_date, v_from),
      LEAST(ea.end_date, p_as_of),
      interval '1 day'
    ) AS g(d)
    WHERE ea.tenant_id = v_tenant
      AND ea.status IN ('approved', 'active', 'closed')
      AND ea.start_date <= p_as_of
      AND ea.end_date >= v_from
      AND EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = ea.employee_id AND e.site_id = p_site_id
      )
    GROUP BY EXTRACT(DOW FROM d)::int
  ) a;

  -- ── Retards agregats per DOW (entrada >15 min després de l'inici del slot) ─
  SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.late_count DESC), '[]'::jsonb)
  INTO v_late
  FROM (
    SELECT
      EXTRACT(DOW FROM ss.slot_date)::int AS day_of_week,
      count(*)::int AS late_count,
      format(
        'DOW %s: %s entrades >15 min després de l''inici planificat (agregat, %s dies).',
        EXTRACT(DOW FROM ss.slot_date)::int,
        count(*),
        v_lookback
      ) AS explanation
    FROM data.shift_slots ss
    JOIN LATERAL (
      SELECT MIN(tp.occurred_at) AS first_in
      FROM data.time_punches tp
      WHERE tp.employee_id = ss.employee_id
        AND tp.punch_type = 'in'
        AND (tp.occurred_at AT TIME ZONE COALESCE(data.get_site_timezone(p_site_id, v_tenant), 'Europe/Madrid'))::date
            = ss.slot_date
    ) punch ON true
    WHERE ss.site_id = p_site_id
      AND ss.status IN ('published', 'confirmed')
      AND ss.slot_date BETWEEN v_from AND p_as_of
      AND punch.first_in IS NOT NULL
      AND punch.first_in > (
        (ss.slot_date + ss.start_time)
          AT TIME ZONE COALESCE(data.get_site_timezone(p_site_id, v_tenant), 'Europe/Madrid')
        + interval '15 minutes'
      )
    GROUP BY EXTRACT(DOW FROM ss.slot_date)::int
  ) l;

  -- ── Risc de gap demà ───────────────────────────────────────────────────────
  v_dow := EXTRACT(DOW FROM v_tomorrow)::int;

  SELECT COALESCE(SUM(cd.required_target), 0)::int INTO v_req
  FROM data.coverage_demands cd
  WHERE cd.site_id = p_site_id
    AND cd.is_active
    AND cd.effective_from <= v_tomorrow
    AND (cd.effective_to IS NULL OR cd.effective_to > v_tomorrow)
    AND (
      (cd.kind = 'extraordinary' AND cd.demand_date = v_tomorrow)
      OR (cd.kind = 'recurring' AND cd.day_of_week = v_dow)
    );

  SELECT COUNT(*)::int INTO v_planned
  FROM data.shift_slots ss
  WHERE ss.site_id = p_site_id
    AND ss.slot_date = v_tomorrow
    AND ss.status IN ('published', 'confirmed', 'draft');

  SELECT COALESCE(SUM(o.places_total - o.places_filled), 0)::int INTO v_open_places
  FROM data.shift_openings o
  WHERE o.site_id = p_site_id
    AND o.opening_date = v_tomorrow
    AND o.status = 'open'
    AND o.places_filled < o.places_total;

  v_gap_n := GREATEST(0, v_req - v_planned);
  v_risk := CASE
    WHEN v_req = 0 AND v_open_places = 0 THEN 'none'
    WHEN v_gap_n >= 3 OR (v_open_places >= 2 AND v_gap_n >= 1) THEN 'high'
    WHEN v_gap_n >= 1 OR v_open_places >= 1 THEN 'medium'
    ELSE 'none'
  END;

  IF v_gap_n > 0 THEN
    v_suggestions := v_suggestions || jsonb_build_array(jsonb_build_object(
      'kind', 'assign_or_publish',
      'message', format(
        'Falten ~%s places vs demanda demà: assignar torns o publicar vacant.',
        v_gap_n
      )
    ));
  END IF;
  IF v_open_places > 0 THEN
    v_suggestions := v_suggestions || jsonb_build_array(jsonb_build_object(
      'kind', 'fill_openings',
      'message', format(
        'Hi ha %s places en vacants obertes per demà: revisar claims / fan-out.',
        v_open_places
      )
    ));
  END IF;
  IF v_req = 0 AND v_planned = 0 THEN
    v_suggestions := v_suggestions || jsonb_build_array(jsonb_build_object(
      'kind', 'review_demand',
      'message', 'Sense demanda ni slots demà: revisar si cal demanda recurrent.'
    ));
  END IF;

  v_gap := jsonb_build_object(
    'date', v_tomorrow,
    'risk_level', v_risk,
    'required_target_sum', v_req,
    'planned_slots', v_planned,
    'open_vacancy_places', v_open_places,
    'gap', v_gap_n,
    'explanation', format(
      'Demà %s: demanda(target sum)=%s, slots planificats=%s, places vacant obertes=%s, gap≈%s. (La suma de targets pot sobrecomptar franges solapades.)',
      v_tomorrow, v_req, v_planned, v_open_places, v_gap_n
    ),
    'reinforce_suggestions', v_suggestions
  );

  RETURN jsonb_build_object(
    'ok', true,
    'site_id', p_site_id,
    'tenant_id', v_tenant,
    'as_of', p_as_of,
    'lookback_days', v_lookback,
    'disclaimer',
      'Heurístiques explicables (AP-09). No són scoring per sancionar, ordenar ni excloure empleats.',
    'fatigue_alerts', COALESCE(v_fatigue, '[]'::jsonb),
    'equity_snapshot', jsonb_build_object(
      'window_days', v_lookback,
      'site_avg_hours', ROUND(v_avg_h, 2),
      'employees', COALESCE(v_equity, '[]'::jsonb)
    ),
    'absence_patterns', COALESCE(v_absence, '[]'::jsonb),
    'late_patterns', COALESCE(v_late, '[]'::jsonb),
    'gap_risk_tomorrow', v_gap
  );
END;
$$;

REVOKE ALL ON FUNCTION data.compute_site_planning_heuristics(uuid, date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.compute_site_planning_heuristics(uuid, date, int)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.get_site_planning_heuristics(
  p_site_id uuid,
  p_as_of date DEFAULT CURRENT_DATE,
  p_lookback_days int DEFAULT 28
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  IF p_site_id IS NULL THEN
    RAISE EXCEPTION 'site_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.view', p_site_id), false)
    OR COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id), false)
    OR COALESCE(data.jwt_has_permission(v_tenant, 'attendance.view_all', p_site_id), false)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.compute_site_planning_heuristics(p_site_id, COALESCE(p_as_of, CURRENT_DATE), p_lookback_days);
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_site_planning_heuristics(uuid, date, int)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.get_site_planning_heuristics IS
  'EX-08.3 / AP-09: fatiga, equitat, patrons absència/retard i risc de gap demà (explicable).';

NOTIFY pgrst, 'reload schema';
