-- =============================================================================
-- EX-07.4 — Portal empleat: llistar / reclamar / retirar vacants
-- No-objectius: push (EX-07.6), swaps (EX-07.5), ranked_window UI.
-- =============================================================================

-- ─── 1. Access log actions ───────────────────────────────────────────────────

ALTER TABLE data.employee_portal_access_logs
  DROP CONSTRAINT IF EXISTS employee_portal_access_logs_action_check;

ALTER TABLE data.employee_portal_access_logs
  ADD CONSTRAINT employee_portal_access_logs_action_check CHECK (action IN (
    'view_schedule',
    'view_my_shifts',
    'view_openings',
    'claim_opening',
    'withdraw_opening_claim',
    'view_history',
    'view_monthly_report',
    'monthly_confirm',
    'period_confirm',
    'view_access_logs',
    'request_absence',
    'push_subscribe',
    'punch_in',
    'punch_out',
    'pause_start',
    'pause_end',
    'pin_failed',
    'pin_locked',
    'pin_setup',
    'pin_changed',
    'pin_reset',
    'batch_start',
    'batch_fetch',
    'batch_ack',
    'identity_verify_failed',
    'identity_rejected',
    'identity_confirmed',
    'token_invalid',
    'token_expired',
    'session_create',
    'session_refresh'
  ));

-- ─── 2. Accept core (sense JWT; cridat per api + portal) ─────────────────────

CREATE OR REPLACE FUNCTION data.accept_shift_opening_claim_core(
  p_claim_id uuid,
  p_accept_warnings boolean DEFAULT false,
  p_reviewed_by uuid DEFAULT NULL,
  p_created_by uuid DEFAULT NULL
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

  IF v_opening.places_filled >= v_opening.places_total OR v_opening.status <> 'open' THEN
    RAISE EXCEPTION 'opening_full_or_closed' USING ERRCODE = 'check_violation';
  END IF;

  v_shift_id := data.ensure_opening_work_shift(v_opening);

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
    p_created_by,
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
      reviewed_by = p_reviewed_by,
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

  IF v_opening.status = 'filled' THEN
    UPDATE data.shift_opening_claims
    SET status = 'expired', updated_at = now()
    WHERE opening_id = v_opening.id AND status = 'pending';
  END IF;

  PERFORM data.log_audit_event(
    v_opening.tenant_id, p_reviewed_by, v_opening.site_id,
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

REVOKE ALL ON FUNCTION data.accept_shift_opening_claim_core(uuid, boolean, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.accept_shift_opening_claim_core(uuid, boolean, uuid, uuid) TO service_role;

-- ─── 3. Claim core per employee_id ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.claim_shift_opening_for_employee(
  p_opening_id uuid,
  p_employee_id uuid,
  p_notes text DEFAULT NULL,
  p_auto_accept_warnings boolean DEFAULT true
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
  IF p_opening_id IS NULL OR p_employee_id IS NULL THEN
    RAISE EXCEPTION 'opening_and_employee_required' USING ERRCODE = 'invalid_parameter_value';
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

  SELECT e.id, e.tenant_id, e.site_id, e.status, e.full_name, e.user_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND OR v_emp.status <> 'active' THEN
    RAISE EXCEPTION 'employee_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_emp.tenant_id IS DISTINCT FROM v_opening.tenant_id THEN
    RAISE EXCEPTION 'employee_wrong_tenant' USING ERRCODE = 'check_violation';
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

  -- Hard blocks always; first_eligible also blocks before insert
  v_elig := data.evaluate_opening_claim_eligibility(p_opening_id, v_emp.id);
  IF jsonb_array_length(COALESCE(v_elig->'blocks', '[]'::jsonb)) > 0 THEN
    RAISE EXCEPTION 'claim_not_eligible: %', (v_elig->'blocks')::text
      USING ERRCODE = 'check_violation';
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
    v_accept := data.accept_shift_opening_claim_core(
      v_claim.id,
      COALESCE(p_auto_accept_warnings, true),
      v_emp.user_id,
      v_emp.user_id
    );
    RETURN jsonb_build_object(
      'claim', to_jsonb(v_claim) || jsonb_build_object('status', 'accepted'),
      'employee_name', v_emp.full_name,
      'pending_claims', 0,
      'places_remaining', (v_accept->>'places_total')::int - (v_accept->>'places_filled')::int,
      'auto_accepted', true,
      'slot_id', v_accept->>'slot_id',
      'accept', v_accept,
      'eligibility', v_elig
    );
  END IF;

  RETURN jsonb_build_object(
    'claim', to_jsonb(v_claim),
    'employee_name', v_emp.full_name,
    'pending_claims', v_pending,
    'places_remaining', v_opening.places_total - v_opening.places_filled,
    'auto_accepted', false,
    'eligibility', v_elig
  );
END;
$$;

REVOKE ALL ON FUNCTION data.claim_shift_opening_for_employee(uuid, uuid, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.claim_shift_opening_for_employee(uuid, uuid, text, boolean) TO service_role;

-- ─── 4. Re-wire api.accept / api.claim ───────────────────────────────────────

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
BEGIN
  IF p_claim_id IS NULL THEN
    RAISE EXCEPTION 'claim_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_claim FROM data.shift_opening_claims WHERE id = p_claim_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'claim_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_opening FROM data.shift_openings WHERE id = v_claim.opening_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opening_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_opening.tenant_id, 'labor_calendar.manage', v_opening.site_id),
    false
  ) THEN
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

  RETURN data.accept_shift_opening_claim_core(
    p_claim_id,
    p_accept_warnings,
    auth.uid(),
    auth.uid()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.accept_shift_opening_claim(uuid, boolean) TO authenticated, service_role;

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
  v_emp_id uuid;
BEGIN
  IF p_opening_id IS NULL THEN
    RAISE EXCEPTION 'opening_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_opening FROM data.shift_openings WHERE id = p_opening_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opening_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT e.id INTO v_emp_id
  FROM data.employees e
  WHERE e.user_id = auth.uid()
    AND e.tenant_id = v_opening.tenant_id
    AND e.status = 'active'
  LIMIT 1;

  IF v_emp_id IS NULL THEN
    RAISE EXCEPTION 'employee_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.claim_shift_opening_for_employee(p_opening_id, v_emp_id, p_notes, true);
END;
$$;

GRANT EXECUTE ON FUNCTION api.claim_shift_opening(uuid, text) TO authenticated, service_role;

-- ─── 5. Portal RPCs ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_list_shift_openings(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_from        date,
  p_to          date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_items jsonb := '[]'::jsonb;
  v_row record;
  v_elig jsonb;
  v_my_claim record;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RAISE EXCEPTION 'invalid_date_range' USING ERRCODE = 'check_violation';
  END IF;

  IF (p_to - p_from) > 90 THEN
    RAISE EXCEPTION 'date_range_too_large' USING ERRCODE = 'check_violation';
  END IF;

  FOR v_row IN
    SELECT o.*
    FROM data.shift_openings o
    WHERE o.tenant_id = p_tenant_id
      AND o.site_id = v_emp.site_id
      AND o.status = 'open'
      AND o.opening_date BETWEEN p_from AND p_to
      AND (o.opens_at IS NULL OR o.opens_at <= clock_timestamp())
      AND (o.closes_at IS NULL OR o.closes_at >= clock_timestamp())
      AND o.places_filled < o.places_total
    ORDER BY o.opening_date ASC, o.start_time ASC, o.id ASC
  LOOP
    v_elig := data.evaluate_opening_claim_eligibility(v_row.id, p_employee_id);

    SELECT c.id, c.status, c.claimed_at, c.notes
    INTO v_my_claim
    FROM data.shift_opening_claims c
    WHERE c.opening_id = v_row.id
      AND c.employee_id = p_employee_id
      AND c.status IN ('pending', 'accepted')
    ORDER BY c.claimed_at DESC
    LIMIT 1;

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'id', v_row.id,
      'opening_date', v_row.opening_date,
      'start_time', v_row.start_time,
      'end_time', v_row.end_time,
      'spans_midnight', (v_row.end_time < v_row.start_time),
      'places_total', v_row.places_total,
      'places_filled', v_row.places_filled,
      'places_remaining', v_row.places_total - v_row.places_filled,
      'claim_policy', v_row.claim_policy,
      'title', v_row.title,
      'notes', v_row.notes,
      'compensation_label', v_row.compensation_label,
      'role_id', v_row.role_id,
      'role_name', v_row.role_name_snapshot,
      'location_id', v_row.location_id,
      'location_name', v_row.location_name_snapshot,
      'site_id', v_row.site_id,
      'closes_at', v_row.closes_at,
      'eligible', COALESCE((v_elig->>'ok')::boolean, false),
      'eligibility', v_elig,
      'my_claim', CASE WHEN v_my_claim.id IS NULL THEN NULL ELSE jsonb_build_object(
        'id', v_my_claim.id,
        'status', v_my_claim.status,
        'claimed_at', v_my_claim.claimed_at,
        'notes', v_my_claim.notes
      ) END
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'site_id', v_emp.site_id,
    'from', p_from,
    'to', p_to,
    'openings', v_items
  );
END;
$$;

COMMENT ON FUNCTION api.employee_portal_list_shift_openings(uuid, uuid, date, date) IS
  'EX-07.4: vacants open del centre de l''empleat amb eligibility + my_claim (service_role).';

REVOKE ALL ON FUNCTION api.employee_portal_list_shift_openings(uuid, uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_list_shift_openings(uuid, uuid, date, date) TO service_role;

CREATE OR REPLACE FUNCTION api.employee_portal_claim_shift_opening(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_opening_id  uuid,
  p_notes       text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_opening data.shift_openings;
  v_res jsonb;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND OR v_emp.status <> 'active' THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_opening FROM data.shift_openings WHERE id = p_opening_id;
  IF NOT FOUND OR v_opening.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'opening_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF v_opening.site_id IS DISTINCT FROM v_emp.site_id THEN
    RAISE EXCEPTION 'employee_wrong_site' USING ERRCODE = 'check_violation';
  END IF;

  v_res := data.claim_shift_opening_for_employee(p_opening_id, p_employee_id, p_notes, true);

  RETURN v_res || jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id
  );
END;
$$;

COMMENT ON FUNCTION api.employee_portal_claim_shift_opening(uuid, uuid, uuid, text) IS
  'EX-07.4: reclamació de vacant des del portal (service_role).';

REVOKE ALL ON FUNCTION api.employee_portal_claim_shift_opening(uuid, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_claim_shift_opening(uuid, uuid, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION api.employee_portal_withdraw_shift_opening_claim(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_claim_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_claim data.shift_opening_claims;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id AND e.status = 'active'
  ) THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_claim FROM data.shift_opening_claims WHERE id = p_claim_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'claim_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF v_claim.tenant_id IS DISTINCT FROM p_tenant_id
     OR v_claim.employee_id IS DISTINCT FROM p_employee_id
  THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_claim.status <> 'pending' THEN
    RAISE EXCEPTION 'claim_not_pending' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.shift_opening_claims
  SET status = 'withdrawn', updated_at = now()
  WHERE id = p_claim_id
  RETURNING * INTO v_claim;

  RETURN to_jsonb(v_claim);
END;
$$;

COMMENT ON FUNCTION api.employee_portal_withdraw_shift_opening_claim(uuid, uuid, uuid) IS
  'EX-07.4: retirada de claim pending des del portal (service_role).';

REVOKE ALL ON FUNCTION api.employee_portal_withdraw_shift_opening_claim(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_withdraw_shift_opening_claim(uuid, uuid, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
