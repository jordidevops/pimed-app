-- =============================================================================
-- EX-07.3 — Eligibility + acceptació transaccional de claim → shift_slot published
-- No-objectius: portal vacants (EX-07.4), notificacions push (EX-07.6), ranked_window UI.
-- =============================================================================

-- ─── 1. Assegura plantilla work_shift per a la vacant ─────────────────────────

CREATE OR REPLACE FUNCTION data.ensure_opening_work_shift(p_opening data.shift_openings)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_shift_id uuid;
  v_name text;
BEGIN
  IF p_opening.shift_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM data.work_shifts ws
      WHERE ws.id = p_opening.shift_id
        AND ws.tenant_id = p_opening.tenant_id
        AND ws.is_active = true
    ) THEN
      RETURN p_opening.shift_id;
    END IF;
  END IF;

  v_name := COALESCE(
    NULLIF(btrim(p_opening.title), ''),
    format('Vacant %s–%s', to_char(p_opening.start_time, 'HH24:MI'), to_char(p_opening.end_time, 'HH24:MI'))
  );

  SELECT ws.id INTO v_shift_id
  FROM data.work_shifts ws
  WHERE ws.tenant_id = p_opening.tenant_id
    AND ws.site_id = p_opening.site_id
    AND ws.is_active = true
    AND ws.start_time = p_opening.start_time
    AND ws.end_time = p_opening.end_time
    AND ws.name = v_name
  LIMIT 1;

  IF v_shift_id IS NOT NULL THEN
    RETURN v_shift_id;
  END IF;

  INSERT INTO data.work_shifts (
    tenant_id, site_id, name, color, start_time, end_time, is_active, default_role_id, default_location_id
  ) VALUES (
    p_opening.tenant_id,
    p_opening.site_id,
    v_name,
    '#0ea5e9',
    p_opening.start_time,
    p_opening.end_time,
    true,
    p_opening.role_id,
    p_opening.location_id
  )
  RETURNING id INTO v_shift_id;

  RETURN v_shift_id;
END;
$$;

REVOKE ALL ON FUNCTION data.ensure_opening_work_shift(data.shift_openings) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.ensure_opening_work_shift(data.shift_openings) TO service_role;

-- ─── 2. Eligibility ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.evaluate_opening_claim_eligibility(
  p_opening_id  uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_opening data.shift_openings;
  v_emp record;
  v_blocks text[] := '{}';
  v_warnings text[] := '{}';
  v_avail text;
  v_week_start date;
  v_shift_min int;
  v_week_min int;
BEGIN
  SELECT * INTO v_opening FROM data.shift_openings WHERE id = p_opening_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'blocks', jsonb_build_array('opening_not_found'), 'warnings', '[]'::jsonb);
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.status, e.weekly_hours, e.full_name
  INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    v_blocks := array_append(v_blocks, 'employee_not_found');
  ELSIF v_emp.status <> 'active' THEN
    v_blocks := array_append(v_blocks, 'employee_not_active');
  ELSIF v_emp.site_id IS DISTINCT FROM v_opening.site_id THEN
    v_blocks := array_append(v_blocks, 'employee_wrong_site');
  END IF;

  IF v_opening.status <> 'open' THEN
    v_blocks := array_append(v_blocks, 'opening_not_open');
  END IF;

  IF v_opening.places_filled >= v_opening.places_total THEN
    v_blocks := array_append(v_blocks, 'opening_full');
  END IF;

  IF v_opening.opens_at IS NOT NULL AND v_opening.opens_at > clock_timestamp() THEN
    v_blocks := array_append(v_blocks, 'opening_not_yet_open');
  END IF;

  IF v_opening.closes_at IS NOT NULL AND v_opening.closes_at < clock_timestamp() THEN
    v_blocks := array_append(v_blocks, 'opening_closed');
  END IF;

  -- Absència total cobrint el dia
  IF EXISTS (
    SELECT 1
    FROM data.employee_absences ea
    WHERE ea.employee_id = p_employee_id
      AND ea.status IN ('approved', 'active', 'closed')
      AND ea.start_date <= v_opening.opening_date
      AND COALESCE(ea.end_date, ea.start_date) >= v_opening.opening_date
  ) THEN
    v_blocks := array_append(v_blocks, 'employee_on_absence');
  END IF;

  -- Rol / quals
  IF v_opening.role_id IS NOT NULL AND v_emp.id IS NOT NULL THEN
    IF NOT data.employee_meets_role_qualifications(p_employee_id, v_opening.role_id, v_opening.opening_date) THEN
      v_blocks := array_append(v_blocks, 'role_qualifications_unmet');
    END IF;
  END IF;

  -- Solapament amb slots existents
  IF v_emp.id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.status <> 'cancelled'
      AND ss.slot_date BETWEEN v_opening.opening_date - 1 AND v_opening.opening_date + 1
      AND data.shift_slots_overlap(
        v_opening.opening_date, v_opening.start_time, v_opening.end_time,
        ss.slot_date, ss.start_time, ss.end_time
      )
  ) THEN
    v_blocks := array_append(v_blocks, 'SHIFT_OVERLAP');
  END IF;

  -- Disponibilitat
  IF v_emp.id IS NOT NULL THEN
    v_avail := data.employee_availability_for_window(
      p_employee_id, v_opening.opening_date, v_opening.start_time, v_opening.end_time
    );
    IF v_avail = 'unavailable' THEN
      v_blocks := array_append(v_blocks, 'availability_unavailable');
    ELSIF v_avail = 'unknown' THEN
      v_warnings := array_append(v_warnings, 'availability_unknown');
    END IF;
  END IF;

  -- Hores setmanals
  IF v_emp.id IS NOT NULL THEN
    v_week_start := date_trunc('week', v_opening.opening_date::timestamptz)::date;
    v_shift_min := ROUND(EXTRACT(EPOCH FROM CASE
      WHEN v_opening.end_time > v_opening.start_time THEN v_opening.end_time - v_opening.start_time
      ELSE interval '24 hours' + (v_opening.end_time - v_opening.start_time)
    END) / 60)::int;

    SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM CASE
      WHEN ss.end_time > ss.start_time THEN ss.end_time - ss.start_time
      ELSE interval '24 hours' + (ss.end_time - ss.start_time)
    END) / 60)), 0)::int
    INTO v_week_min
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.slot_date >= v_week_start
      AND ss.slot_date <= v_week_start + 6
      AND ss.status <> 'cancelled';

    IF v_emp.weekly_hours IS NOT NULL
       AND (v_week_min + v_shift_min) > (v_emp.weekly_hours * 60)
    THEN
      v_warnings := array_append(v_warnings, 'WEEKLY_HOURS_EXCEEDED');
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', cardinality(v_blocks) = 0,
    'blocks', to_jsonb(v_blocks),
    'warnings', to_jsonb(v_warnings),
    'availability', v_avail,
    'opening_id', p_opening_id,
    'employee_id', p_employee_id
  );
END;
$$;

REVOKE ALL ON FUNCTION data.evaluate_opening_claim_eligibility(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.evaluate_opening_claim_eligibility(uuid, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.evaluate_shift_opening_claim(p_claim_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_claim data.shift_opening_claims;
  v_opening data.shift_openings;
BEGIN
  SELECT * INTO v_claim FROM data.shift_opening_claims WHERE id = p_claim_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'claim_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_opening FROM data.shift_openings WHERE id = v_claim.opening_id;

  IF NOT (
    COALESCE(data.jwt_has_permission(v_claim.tenant_id, 'labor_calendar.manage', v_opening.site_id), false)
    OR COALESCE(data.jwt_has_permission(v_claim.tenant_id, 'labor_calendar.view', v_opening.site_id), false)
    OR EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = v_claim.employee_id AND e.user_id = auth.uid()
    )
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.evaluate_opening_claim_eligibility(v_claim.opening_id, v_claim.employee_id)
    || jsonb_build_object('claim_id', p_claim_id, 'claim_status', v_claim.status);
END;
$$;

GRANT EXECUTE ON FUNCTION api.evaluate_shift_opening_claim(uuid) TO authenticated, service_role;

-- ─── 3. Accept transaccional ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.accept_shift_opening_claim(
  p_claim_id uuid,
  p_accept_warnings boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_claim data.shift_opening_claims;
  v_opening data.shift_openings;
  v_elig jsonb;
  v_blocks jsonb;
  v_warnings jsonb;
  v_shift_id uuid;
  v_slot_id uuid;
  v_role_name text;
BEGIN
  IF p_claim_id IS NULL THEN
    RAISE EXCEPTION 'claim_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_claim FROM data.shift_opening_claims WHERE id = p_claim_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'claim_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_opening FROM data.shift_openings WHERE id = v_claim.opening_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opening_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_opening.tenant_id, 'labor_calendar.manage', v_opening.site_id),
    false
  ) THEN
    -- first_eligible: l'empleat titular del claim pot auto-acceptar-se
    IF NOT (
      v_opening.claim_policy = 'first_eligible'
      AND EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = v_claim.employee_id AND e.user_id = auth.uid()
      )
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  IF v_claim.status <> 'pending' THEN
    RAISE EXCEPTION 'claim_not_pending' USING ERRCODE = 'check_violation';
  END IF;

  PERFORM data.refresh_shift_opening_status(v_opening.id);
  SELECT * INTO v_opening FROM data.shift_openings WHERE id = v_opening.id;

  v_elig := data.evaluate_opening_claim_eligibility(v_opening.id, v_claim.employee_id);
  v_blocks := COALESCE(v_elig->'blocks', '[]'::jsonb);
  v_warnings := COALESCE(v_elig->'warnings', '[]'::jsonb);

  IF jsonb_array_length(v_blocks) > 0 THEN
    RAISE EXCEPTION 'claim_not_eligible: %', v_blocks::text
      USING ERRCODE = 'check_violation';
  END IF;

  IF jsonb_array_length(v_warnings) > 0 AND NOT COALESCE(p_accept_warnings, false) THEN
    RAISE EXCEPTION 'warnings_require_acceptance: %', v_warnings::text
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM data.assert_shift_pairs_mutable(
    jsonb_build_array(jsonb_build_object(
      'employee_id', v_claim.employee_id,
      'work_date', v_opening.opening_date
    ))
  );

  -- Re-check places sota lock (race)
  IF v_opening.places_filled >= v_opening.places_total OR v_opening.status <> 'open' THEN
    RAISE EXCEPTION 'opening_full_or_closed' USING ERRCODE = 'check_violation';
  END IF;

  v_shift_id := data.ensure_opening_work_shift(v_opening);

  -- Link shift_id a l'opening si no en tenia
  IF v_opening.shift_id IS NULL THEN
    UPDATE data.shift_openings SET shift_id = v_shift_id, updated_at = now()
    WHERE id = v_opening.id;
    v_opening.shift_id := v_shift_id;
  END IF;

  v_role_name := COALESCE(
    v_opening.role_name_snapshot,
    (SELECT wr.name FROM data.work_roles wr WHERE wr.id = v_opening.role_id)
  );

  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id, slot_date, status, notes, created_by,
    start_time, end_time, location_id, role_id, role_name_snapshot,
    published_at
  ) VALUES (
    v_opening.tenant_id,
    v_opening.site_id,
    v_claim.employee_id,
    v_shift_id,
    v_opening.opening_date,
    'published',
    format('claim:%s opening:%s', v_claim.id, v_opening.id),
    auth.uid(),
    v_opening.start_time,
    v_opening.end_time,
    v_opening.location_id,
    v_opening.role_id,
    v_role_name,
    now()
  )
  RETURNING id INTO v_slot_id;

  UPDATE data.shift_opening_claims
  SET status = 'accepted',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      resulting_slot_id = v_slot_id,
      updated_at = now()
  WHERE id = p_claim_id
  RETURNING * INTO v_claim;

  UPDATE data.shift_openings
  SET places_filled = places_filled + 1,
      status = CASE
        WHEN places_filled + 1 >= places_total THEN 'filled'
        ELSE status
      END,
      updated_at = now()
  WHERE id = v_opening.id
  RETURNING * INTO v_opening;

  -- Si ja no queden places, expira la resta de pending
  IF v_opening.status = 'filled' THEN
    UPDATE data.shift_opening_claims
    SET status = 'expired', updated_at = now()
    WHERE opening_id = v_opening.id AND status = 'pending';
  END IF;

  PERFORM data.log_audit_event(
    v_opening.tenant_id, auth.uid(), v_opening.site_id,
    'SHIFT_OPENING_CLAIM_ACCEPTED', 'shift_opening_claim', v_claim.id,
    jsonb_build_object(
      'opening_id', v_opening.id,
      'employee_id', v_claim.employee_id,
      'slot_id', v_slot_id,
      'warnings', v_warnings
    )
  );

  RETURN jsonb_build_object(
    'claim_id', v_claim.id,
    'claim_status', 'accepted',
    'slot_id', v_slot_id,
    'opening_id', v_opening.id,
    'opening_status', v_opening.status,
    'places_filled', v_opening.places_filled,
    'places_total', v_opening.places_total,
    'warnings', v_warnings,
    'eligibility', v_elig
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.accept_shift_opening_claim(uuid, boolean) TO authenticated, service_role;

COMMENT ON FUNCTION api.accept_shift_opening_claim IS
  'EX-07.3: accepta claim pending → crea shift_slot published atòmicament (sense placeholder).';

-- ─── 4. first_eligible: auto-accept després del claim ────────────────────────

CREATE OR REPLACE FUNCTION api.claim_shift_opening(
  p_opening_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_opening data.shift_openings;
  v_emp record;
  v_claim data.shift_opening_claims;
  v_pending int;
  v_accept jsonb;
  v_elig jsonb;
BEGIN
  IF p_opening_id IS NULL THEN
    RAISE EXCEPTION 'opening_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_opening FROM data.shift_openings WHERE id = p_opening_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opening_not_found' USING ERRCODE = 'P0002';
  END IF;

  PERFORM data.refresh_shift_opening_status(p_opening_id);
  SELECT * INTO v_opening FROM data.shift_openings WHERE id = p_opening_id;

  IF v_opening.status <> 'open' THEN
    RAISE EXCEPTION 'opening_not_open' USING ERRCODE = 'check_violation';
  END IF;

  IF v_opening.opens_at IS NOT NULL AND v_opening.opens_at > clock_timestamp() THEN
    RAISE EXCEPTION 'opening_not_yet_open' USING ERRCODE = 'check_violation';
  END IF;

  IF v_opening.closes_at IS NOT NULL AND v_opening.closes_at < clock_timestamp() THEN
    RAISE EXCEPTION 'opening_closed' USING ERRCODE = 'check_violation';
  END IF;

  IF v_opening.places_filled >= v_opening.places_total THEN
    RAISE EXCEPTION 'opening_full' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.status, e.full_name
  INTO v_emp
  FROM data.employees e
  WHERE e.user_id = auth.uid()
    AND e.tenant_id = v_opening.tenant_id
    AND e.status = 'active'
  LIMIT 1;

  IF v_emp.id IS NULL THEN
    RAISE EXCEPTION 'employee_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_emp.site_id IS DISTINCT FROM v_opening.site_id THEN
    RAISE EXCEPTION 'employee_wrong_site' USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.shift_opening_claims c
    WHERE c.opening_id = p_opening_id
      AND c.employee_id = v_emp.id
      AND c.status IN ('pending', 'accepted')
  ) THEN
    RAISE EXCEPTION 'claim_already_exists' USING ERRCODE = 'unique_violation';
  END IF;

  -- Pre-check eligibility for first_eligible (hard blocks)
  IF v_opening.claim_policy = 'first_eligible' THEN
    v_elig := data.evaluate_opening_claim_eligibility(p_opening_id, v_emp.id);
    IF jsonb_array_length(COALESCE(v_elig->'blocks', '[]'::jsonb)) > 0 THEN
      RAISE EXCEPTION 'claim_not_eligible: %', (v_elig->'blocks')::text
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  INSERT INTO data.shift_opening_claims (
    tenant_id, opening_id, employee_id, status, notes
  ) VALUES (
    v_opening.tenant_id, p_opening_id, v_emp.id, 'pending', NULLIF(btrim(p_notes), '')
  )
  RETURNING * INTO v_claim;

  SELECT count(*)::int INTO v_pending
  FROM data.shift_opening_claims
  WHERE opening_id = p_opening_id AND status = 'pending';

  IF v_opening.claim_policy = 'first_eligible' THEN
    -- Auto-accept (accepta warnings per no bloquejar first_eligible)
    v_accept := api.accept_shift_opening_claim(v_claim.id, true);
    RETURN jsonb_build_object(
      'claim', to_jsonb(v_claim) || jsonb_build_object('status', 'accepted'),
      'employee_name', v_emp.full_name,
      'pending_claims', 0,
      'places_remaining', (v_accept->>'places_total')::int - (v_accept->>'places_filled')::int,
      'auto_accepted', true,
      'slot_id', v_accept->>'slot_id',
      'accept', v_accept
    );
  END IF;

  RETURN jsonb_build_object(
    'claim', to_jsonb(v_claim),
    'employee_name', v_emp.full_name,
    'pending_claims', v_pending,
    'places_remaining', v_opening.places_total - v_opening.places_filled,
    'auto_accepted', false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.claim_shift_opening(uuid, text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
