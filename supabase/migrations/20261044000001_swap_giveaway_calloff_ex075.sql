-- =============================================================================
-- EX-07.5 — Swap / give-away / call-off end-to-end
-- Reaprofita shift_swap_requests; afegeix kind, eligibility i call-off → vacant.
-- No-objectius: push (EX-07.6), ranked matching, UI drag-and-drop.
-- =============================================================================

-- ─── 1. Kind + estats ────────────────────────────────────────────────────────

ALTER TABLE data.shift_swap_requests
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'swap';

ALTER TABLE data.shift_swap_requests
  DROP CONSTRAINT IF EXISTS chk_swap_kind;

ALTER TABLE data.shift_swap_requests
  ADD CONSTRAINT chk_swap_kind CHECK (kind IN ('swap', 'give_away', 'call_off'));

ALTER TABLE data.shift_swap_requests
  DROP CONSTRAINT IF EXISTS chk_swap_status;

ALTER TABLE data.shift_swap_requests
  ADD CONSTRAINT chk_swap_status CHECK (
    status IN ('pending', 'approved', 'rejected', 'cancelled', 'accepted')
  );

COMMENT ON COLUMN data.shift_swap_requests.kind IS
  'EX-07.5: swap (intercanvi), give_away (cessió), call_off (baixa → vacant).';

-- Access log portal
ALTER TABLE data.employee_portal_access_logs
  DROP CONSTRAINT IF EXISTS employee_portal_access_logs_action_check;

ALTER TABLE data.employee_portal_access_logs
  ADD CONSTRAINT employee_portal_access_logs_action_check CHECK (action IN (
    'view_schedule',
    'view_my_shifts',
    'view_openings',
    'claim_opening',
    'withdraw_opening_claim',
    'view_swaps',
    'request_swap',
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

-- ─── 2. Eligibility ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.evaluate_swap_request_eligibility(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_req data.shift_swap_requests;
  v_slot record;
  v_tgt_slot record;
  v_target uuid;
  v_blocks text[] := '{}';
  v_warnings text[] := '{}';
  v_avail text;
BEGIN
  SELECT * INTO v_req FROM data.shift_swap_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'blocks', jsonb_build_array('request_not_found'), 'warnings', '[]'::jsonb);
  END IF;

  SELECT ss.id, ss.employee_id, ss.status, ss.slot_date, ss.start_time, ss.end_time,
         ss.site_id, ss.role_id, ss.tenant_id
  INTO v_slot
  FROM data.shift_slots ss WHERE ss.id = v_req.requester_slot_id;

  IF NOT FOUND OR v_slot.status = 'cancelled' THEN
    v_blocks := array_append(v_blocks, 'requester_slot_inactive');
  ELSIF v_slot.employee_id IS DISTINCT FROM v_req.requester_id THEN
    v_blocks := array_append(v_blocks, 'requester_slot_owner_changed');
  END IF;

  IF v_req.kind = 'call_off' THEN
    RETURN jsonb_build_object(
      'ok', cardinality(v_blocks) = 0,
      'blocks', to_jsonb(v_blocks),
      'warnings', to_jsonb(v_warnings),
      'kind', v_req.kind
    );
  END IF;

  v_target := v_req.target_employee_id;
  IF v_target IS NULL THEN
    v_blocks := array_append(v_blocks, 'target_required');
    RETURN jsonb_build_object(
      'ok', false,
      'blocks', to_jsonb(v_blocks),
      'warnings', to_jsonb(v_warnings),
      'kind', v_req.kind
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = v_target AND e.tenant_id = v_req.tenant_id AND e.status = 'active'
  ) THEN
    v_blocks := array_append(v_blocks, 'target_not_active');
  END IF;

  -- Absència del destinatari el dia del slot del requester
  IF v_slot.slot_date IS NOT NULL AND EXISTS (
    SELECT 1 FROM data.employee_absences ea
    WHERE ea.employee_id = v_target
      AND ea.status IN ('approved', 'active', 'closed')
      AND ea.start_date <= v_slot.slot_date
      AND COALESCE(ea.end_date, ea.start_date) >= v_slot.slot_date
  ) THEN
    v_blocks := array_append(v_blocks, 'target_on_absence');
  END IF;

  -- Rol / quals del slot a cedir
  IF v_slot.role_id IS NOT NULL AND v_slot.slot_date IS NOT NULL THEN
    IF NOT data.employee_meets_role_qualifications(v_target, v_slot.role_id, v_slot.slot_date) THEN
      v_blocks := array_append(v_blocks, 'role_qualifications_unmet');
    END IF;
  END IF;

  -- Solapament: el target no pot tenir un altre slot que solapi el requester
  -- (excepte el target_slot si és un swap)
  IF v_slot.slot_date IS NOT NULL AND EXISTS (
    SELECT 1 FROM data.shift_slots ss
    WHERE ss.employee_id = v_target
      AND ss.status <> 'cancelled'
      AND ss.id IS DISTINCT FROM v_req.target_slot_id
      AND ss.slot_date BETWEEN v_slot.slot_date - 1 AND v_slot.slot_date + 1
      AND data.shift_slots_overlap(
        v_slot.slot_date, v_slot.start_time, v_slot.end_time,
        ss.slot_date, ss.start_time, ss.end_time
      )
  ) THEN
    v_blocks := array_append(v_blocks, 'SHIFT_OVERLAP');
  END IF;

  -- Disponibilitat
  IF v_slot.slot_date IS NOT NULL THEN
    v_avail := data.employee_availability_for_window(
      v_target, v_slot.slot_date, v_slot.start_time, v_slot.end_time
    );
    IF v_avail = 'unavailable' THEN
      v_blocks := array_append(v_blocks, 'availability_unavailable');
    ELSIF v_avail = 'unknown' THEN
      v_warnings := array_append(v_warnings, 'availability_unknown');
    END IF;
  END IF;

  -- Swap bidireccional: el requester ha de poder assumir el target_slot
  IF v_req.kind = 'swap' AND v_req.target_slot_id IS NOT NULL THEN
    SELECT ss.id, ss.employee_id, ss.status, ss.slot_date, ss.start_time, ss.end_time, ss.role_id
    INTO v_tgt_slot
    FROM data.shift_slots ss WHERE ss.id = v_req.target_slot_id;

    IF NOT FOUND OR v_tgt_slot.status = 'cancelled' THEN
      v_blocks := array_append(v_blocks, 'target_slot_inactive');
    ELSIF v_tgt_slot.employee_id IS DISTINCT FROM v_target THEN
      v_blocks := array_append(v_blocks, 'target_slot_owner_changed');
    ELSE
      IF EXISTS (
        SELECT 1 FROM data.employee_absences ea
        WHERE ea.employee_id = v_req.requester_id
          AND ea.status IN ('approved', 'active', 'closed')
          AND ea.start_date <= v_tgt_slot.slot_date
          AND COALESCE(ea.end_date, ea.start_date) >= v_tgt_slot.slot_date
      ) THEN
        v_blocks := array_append(v_blocks, 'requester_on_absence');
      END IF;

      IF v_tgt_slot.role_id IS NOT NULL
         AND NOT data.employee_meets_role_qualifications(
           v_req.requester_id, v_tgt_slot.role_id, v_tgt_slot.slot_date
         )
      THEN
        v_blocks := array_append(v_blocks, 'requester_role_qualifications_unmet');
      END IF;

      IF EXISTS (
        SELECT 1 FROM data.shift_slots ss
        WHERE ss.employee_id = v_req.requester_id
          AND ss.status <> 'cancelled'
          AND ss.id IS DISTINCT FROM v_req.requester_slot_id
          AND ss.slot_date BETWEEN v_tgt_slot.slot_date - 1 AND v_tgt_slot.slot_date + 1
          AND data.shift_slots_overlap(
            v_tgt_slot.slot_date, v_tgt_slot.start_time, v_tgt_slot.end_time,
            ss.slot_date, ss.start_time, ss.end_time
          )
      ) THEN
        v_blocks := array_append(v_blocks, 'SHIFT_OVERLAP_REVERSE');
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', cardinality(v_blocks) = 0,
    'blocks', to_jsonb(v_blocks),
    'warnings', to_jsonb(v_warnings),
    'kind', v_req.kind,
    'availability', v_avail
  );
END;
$$;

REVOKE ALL ON FUNCTION data.evaluate_swap_request_eligibility(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.evaluate_swap_request_eligibility(uuid) TO authenticated, service_role;

-- ─── 3. request_shift_swap amb kind ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.request_shift_swap(
  p_requester_slot_id   uuid,
  p_target_employee_id  uuid  DEFAULT NULL,
  p_target_slot_id      uuid  DEFAULT NULL,
  p_notes               text  DEFAULT NULL,
  p_kind                text  DEFAULT 'swap'
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_slot       record;
  v_request_id uuid;
  v_kind       text;
BEGIN
  v_kind := COALESCE(NULLIF(btrim(p_kind), ''), 'swap');
  IF v_kind NOT IN ('swap', 'give_away', 'call_off') THEN
    RAISE EXCEPTION 'invalid_swap_kind: %', v_kind
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT ss.tenant_id, ss.employee_id, ss.status, ss.site_id
  INTO v_slot
  FROM data.shift_slots ss
  WHERE ss.id = p_requester_slot_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'slot_not_found: %', p_requester_slot_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_slot.status <> 'published' THEN
    RAISE EXCEPTION 'slot_not_published: el slot ha d''estar published (status=%)',
      v_slot.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = v_slot.employee_id AND e.user_id = auth.uid()
  ) THEN
    IF NOT COALESCE(data.jwt_has_permission(v_slot.tenant_id, 'labor_calendar.manage', v_slot.site_id), false) THEN
      RAISE EXCEPTION 'insufficient_privilege: has de ser el propietari del slot o tenir labor_calendar.manage'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  IF v_kind = 'call_off' THEN
    IF p_target_employee_id IS NOT NULL OR p_target_slot_id IS NOT NULL THEN
      RAISE EXCEPTION 'call_off_no_target: call_off no accepta target'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;
  ELSIF v_kind = 'give_away' THEN
    IF p_target_slot_id IS NOT NULL THEN
      RAISE EXCEPTION 'give_away_no_target_slot: usa swap per intercanviar dos slots'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;
  END IF;

  IF p_target_employee_id IS NOT NULL THEN
    IF p_target_employee_id = v_slot.employee_id THEN
      RAISE EXCEPTION 'swap_same_employee: no es pot bescanviar un torn amb un mateix'
        USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM data.employees te
      WHERE te.id = p_target_employee_id
        AND te.tenant_id = v_slot.tenant_id
        AND te.status <> 'terminated'
    ) THEN
      RAISE EXCEPTION 'target_employee_not_found_or_invalid: %', p_target_employee_id
        USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF p_target_slot_id IS NOT NULL THEN
    IF p_target_employee_id IS NULL THEN
      RAISE EXCEPTION 'target_slot_requires_target_employee'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM data.shift_slots ss2
      WHERE ss2.id = p_target_slot_id
        AND ss2.employee_id = p_target_employee_id
        AND ss2.tenant_id = v_slot.tenant_id
        AND ss2.status = 'published'
    ) THEN
      RAISE EXCEPTION 'target_slot_not_found_or_invalid: %', p_target_slot_id
        USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.shift_swap_requests ssr
    WHERE ssr.requester_slot_id = p_requester_slot_id
      AND ssr.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'swap_request_already_pending'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  INSERT INTO data.shift_swap_requests (
    tenant_id, requester_slot_id, target_slot_id,
    requester_id, target_employee_id,
    status, requester_notes, kind
  )
  VALUES (
    v_slot.tenant_id, p_requester_slot_id, p_target_slot_id,
    v_slot.employee_id, p_target_employee_id,
    'pending', NULLIF(btrim(p_notes), ''), v_kind
  )
  RETURNING id INTO v_request_id;

  PERFORM data.log_audit_event(
    p_tenant_id   => v_slot.tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => v_slot.site_id,
    p_action      => 'SHIFT_SWAP_REQUESTED',
    p_entity_type => 'shift_swap_request',
    p_entity_id   => v_request_id,
    p_payload     => jsonb_build_object(
      'kind', v_kind,
      'requester_slot_id', p_requester_slot_id,
      'target_employee_id', p_target_employee_id,
      'target_slot_id', p_target_slot_id
    )
  );

  RETURN jsonb_build_object(
    'request_id', v_request_id,
    'status', 'pending',
    'kind', v_kind
  );
END;
$$;

-- Drop old 4-param overload if present so PostgREST sees the 5-param version cleanly
DROP FUNCTION IF EXISTS api.request_shift_swap(uuid, uuid, uuid, text);

GRANT EXECUTE ON FUNCTION api.request_shift_swap(uuid, uuid, uuid, text, text) TO authenticated, service_role;

-- ─── 4. approve amb eligibility + call_off → opening ─────────────────────────

CREATE OR REPLACE FUNCTION api.approve_shift_swap(
  p_request_id           uuid,
  p_new_status           text,
  p_comment              text DEFAULT NULL,
  p_target_employee_id   uuid DEFAULT NULL,
  p_accept_warnings      boolean DEFAULT false,
  p_create_opening       boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_req              data.shift_swap_requests;
  v_req_slot         record;
  v_tgt_slot         record;
  v_effective_target uuid;
  v_elig             jsonb;
  v_opening_id       uuid;
  v_role_name        text;
BEGIN
  SELECT * INTO v_req FROM data.shift_swap_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'swap_request_not_found: %', p_request_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    COALESCE(data.jwt_has_permission(v_req.tenant_id, 'attendance.approve'), false)
    OR COALESCE(data.jwt_has_permission(v_req.tenant_id, 'labor_calendar.manage'), false)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve o labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_new_status NOT IN ('approved', 'rejected', 'cancelled') THEN
    RAISE EXCEPTION 'invalid_status: %', p_new_status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'swap_not_actionable: status actual = %', v_req.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_new_status = 'approved' THEN
    IF v_req.kind = 'call_off' THEN
      SELECT ss.* INTO v_req_slot FROM data.shift_slots ss WHERE ss.id = v_req.requester_slot_id FOR UPDATE;
      IF NOT FOUND OR v_req_slot.status = 'cancelled' THEN
        RAISE EXCEPTION 'requester_slot_cancelled_or_missing'
          USING ERRCODE = 'check_violation';
      END IF;
      IF v_req_slot.employee_id <> v_req.requester_id THEN
        RAISE EXCEPTION 'requester_slot_changed'
          USING ERRCODE = 'check_violation';
      END IF;

      PERFORM data.assert_shift_pairs_mutable(
        jsonb_build_array(jsonb_build_object(
          'employee_id', v_req.requester_id,
          'work_date', v_req_slot.slot_date
        ))
      );

      UPDATE data.shift_slots
      SET status = 'cancelled', updated_at = now()
      WHERE id = v_req.requester_slot_id;

      IF COALESCE(p_create_opening, true) THEN
        v_role_name := COALESCE(
          v_req_slot.role_name_snapshot,
          (SELECT wr.name FROM data.work_roles wr WHERE wr.id = v_req_slot.role_id)
        );

        INSERT INTO data.shift_openings (
          tenant_id, site_id, location_id, role_id, shift_id,
          opening_date, start_time, end_time,
          places_total, places_filled, claim_policy, status,
          title, notes, role_name_snapshot, location_name_snapshot,
          published_at, created_by
        ) VALUES (
          v_req.tenant_id,
          v_req_slot.site_id,
          v_req_slot.location_id,
          v_req_slot.role_id,
          v_req_slot.shift_id,
          v_req_slot.slot_date,
          v_req_slot.start_time,
          v_req_slot.end_time,
          1, 0, 'manager_approval', 'open',
          format('Substitució %s', to_char(v_req_slot.slot_date, 'YYYY-MM-DD')),
          format('call_off:%s', p_request_id),
          v_role_name,
          v_req_slot.location_name_snapshot,
          now(),
          auth.uid()
        )
        RETURNING id INTO v_opening_id;
      END IF;
    ELSE
      -- Persist target abans d'avaluar
      IF v_req.target_employee_id IS NULL AND p_target_employee_id IS NOT NULL THEN
        UPDATE data.shift_swap_requests
        SET target_employee_id = p_target_employee_id, updated_at = now()
        WHERE id = p_request_id
        RETURNING * INTO v_req;
      END IF;

      v_effective_target := COALESCE(v_req.target_employee_id, p_target_employee_id);
      IF v_effective_target IS NULL THEN
        RAISE EXCEPTION 'swap_open_requires_target'
          USING ERRCODE = 'invalid_parameter_value';
      END IF;

      v_elig := data.evaluate_swap_request_eligibility(p_request_id);
      IF jsonb_array_length(COALESCE(v_elig->'blocks', '[]'::jsonb)) > 0 THEN
        RAISE EXCEPTION 'swap_not_eligible: %', (v_elig->'blocks')::text
          USING ERRCODE = 'check_violation';
      END IF;
      IF jsonb_array_length(COALESCE(v_elig->'warnings', '[]'::jsonb)) > 0
         AND NOT COALESCE(p_accept_warnings, false)
      THEN
        RAISE EXCEPTION 'warnings_require_acceptance: %', (v_elig->'warnings')::text
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT ss.employee_id, ss.status, ss.slot_date, ss.shift_id, ss.site_id
      INTO v_req_slot
      FROM data.shift_slots ss
      WHERE ss.id = v_req.requester_slot_id;

      IF NOT FOUND OR v_req_slot.status = 'cancelled' THEN
        RAISE EXCEPTION 'requester_slot_cancelled_or_missing'
          USING ERRCODE = 'check_violation';
      END IF;
      IF v_req_slot.employee_id <> v_req.requester_id THEN
        RAISE EXCEPTION 'requester_slot_changed'
          USING ERRCODE = 'check_violation';
      END IF;

      PERFORM data.assert_shift_pairs_mutable(
        jsonb_build_array(
          jsonb_build_object('employee_id', v_req.requester_id, 'work_date', v_req_slot.slot_date),
          jsonb_build_object('employee_id', v_effective_target, 'work_date', v_req_slot.slot_date)
        )
      );

      PERFORM set_config('app.shift_slot_allow_reassign', '1', true);

      UPDATE data.shift_slots
      SET employee_id = v_effective_target, updated_at = now()
      WHERE id = v_req.requester_slot_id;

      IF v_req.kind = 'swap' AND v_req.target_slot_id IS NOT NULL THEN
        SELECT ss.employee_id, ss.status, ss.slot_date
        INTO v_tgt_slot
        FROM data.shift_slots ss
        WHERE ss.id = v_req.target_slot_id;

        IF NOT FOUND OR v_tgt_slot.status = 'cancelled' THEN
          RAISE EXCEPTION 'target_slot_cancelled_or_missing'
            USING ERRCODE = 'check_violation';
        END IF;

        UPDATE data.shift_slots
        SET employee_id = v_req.requester_id, updated_at = now()
        WHERE id = v_req.target_slot_id;
      END IF;

      PERFORM set_config('app.shift_slot_allow_reassign', '', true);

      UPDATE data.calendar_events
      SET metadata = metadata || jsonb_build_object('employee_id', v_effective_target),
          updated_at = now()
      WHERE entity_type = 'shift_slot' AND entity_id = v_req.requester_slot_id;

      IF v_req.kind = 'swap' AND v_req.target_slot_id IS NOT NULL THEN
        UPDATE data.calendar_events
        SET metadata = metadata || jsonb_build_object('employee_id', v_req.requester_id),
            updated_at = now()
        WHERE entity_type = 'shift_slot' AND entity_id = v_req.target_slot_id;
      END IF;
    END IF;
  END IF;

  UPDATE data.shift_swap_requests
  SET status = p_new_status,
      review_comment = p_comment,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  WHERE id = p_request_id
  RETURNING * INTO v_req;

  PERFORM data.log_audit_event(
    p_tenant_id   => v_req.tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => NULL,
    p_action      => 'SHIFT_SWAP_' || upper(p_new_status),
    p_entity_type => 'shift_swap_request',
    p_entity_id   => p_request_id,
    p_payload     => jsonb_build_object(
      'kind', v_req.kind,
      'request_id', p_request_id,
      'opening_id', v_opening_id,
      'eligibility', v_elig,
      'new_status', p_new_status
    )
  );

  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'status', p_new_status,
    'kind', v_req.kind,
    'opening_id', v_opening_id,
    'eligibility', v_elig
  );
END;
$$;

DROP FUNCTION IF EXISTS api.approve_shift_swap(uuid, text, text, uuid);
GRANT EXECUTE ON FUNCTION api.approve_shift_swap(uuid, text, text, uuid, boolean, boolean)
  TO authenticated, service_role;

-- ─── 5. list + evaluate RPC ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_shift_swap_requests(
  p_site_id uuid,
  p_status  text DEFAULT 'pending',
  p_from    date DEFAULT NULL,
  p_to      date DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  kind text,
  status text,
  requester_id uuid,
  requester_name text,
  target_employee_id uuid,
  target_employee_name text,
  requester_slot_id uuid,
  target_slot_id uuid,
  slot_date date,
  start_time time,
  end_time time,
  requester_notes text,
  review_comment text,
  created_at timestamptz,
  eligibility jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  SELECT s.tenant_id INTO v_tenant FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id), false)
    OR COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.view', p_site_id), false)
    OR COALESCE(data.jwt_has_permission(v_tenant, 'attendance.approve'), false)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.kind,
    r.status,
    r.requester_id,
    er.full_name,
    r.target_employee_id,
    et.full_name,
    r.requester_slot_id,
    r.target_slot_id,
    ss.slot_date,
    ss.start_time,
    ss.end_time,
    r.requester_notes,
    r.review_comment,
    r.created_at,
    CASE WHEN r.status = 'pending'
      THEN data.evaluate_swap_request_eligibility(r.id)
      ELSE NULL
    END
  FROM data.shift_swap_requests r
  JOIN data.shift_slots ss ON ss.id = r.requester_slot_id
  JOIN data.employees er ON er.id = r.requester_id
  LEFT JOIN data.employees et ON et.id = r.target_employee_id
  WHERE r.tenant_id = v_tenant
    AND ss.site_id = p_site_id
    AND (p_status IS NULL OR r.status = p_status)
    AND (p_from IS NULL OR ss.slot_date >= p_from)
    AND (p_to IS NULL OR ss.slot_date <= p_to)
  ORDER BY r.created_at DESC
  LIMIT 200;
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_shift_swap_requests(uuid, text, date, date)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.evaluate_shift_swap_request(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_req data.shift_swap_requests;
  v_site uuid;
BEGIN
  SELECT * INTO v_req FROM data.shift_swap_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'swap_request_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT ss.site_id INTO v_site FROM data.shift_slots ss WHERE ss.id = v_req.requester_slot_id;

  IF NOT (
    COALESCE(data.jwt_has_permission(v_req.tenant_id, 'labor_calendar.manage', v_site), false)
    OR COALESCE(data.jwt_has_permission(v_req.tenant_id, 'attendance.approve'), false)
    OR EXISTS (SELECT 1 FROM data.employees e WHERE e.id = v_req.requester_id AND e.user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM data.employees e WHERE e.id = v_req.target_employee_id AND e.user_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.evaluate_swap_request_eligibility(p_request_id)
    || jsonb_build_object('request_id', p_request_id, 'status', v_req.status);
END;
$$;

GRANT EXECUTE ON FUNCTION api.evaluate_shift_swap_request(uuid) TO authenticated, service_role;

-- ─── 6. Portal RPCs ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.request_shift_swap_for_employee(
  p_employee_id uuid,
  p_requester_slot_id uuid,
  p_kind text,
  p_target_employee_id uuid DEFAULT NULL,
  p_target_slot_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_slot record;
  v_emp record;
  v_request_id uuid;
  v_kind text;
BEGIN
  v_kind := COALESCE(NULLIF(btrim(p_kind), ''), 'give_away');
  IF v_kind NOT IN ('swap', 'give_away', 'call_off') THEN
    RAISE EXCEPTION 'invalid_swap_kind' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_emp FROM data.employees WHERE id = p_employee_id;
  IF NOT FOUND OR v_emp.status <> 'active' THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT ss.tenant_id, ss.employee_id, ss.status, ss.site_id
  INTO v_slot FROM data.shift_slots ss WHERE ss.id = p_requester_slot_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'slot_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_slot.status <> 'published' THEN
    RAISE EXCEPTION 'slot_not_published' USING ERRCODE = 'check_violation';
  END IF;
  IF v_slot.employee_id IS DISTINCT FROM p_employee_id
     OR v_slot.tenant_id IS DISTINCT FROM v_emp.tenant_id
  THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_kind = 'call_off' AND (p_target_employee_id IS NOT NULL OR p_target_slot_id IS NOT NULL) THEN
    RAISE EXCEPTION 'call_off_no_target' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_kind = 'give_away' AND p_target_slot_id IS NOT NULL THEN
    RAISE EXCEPTION 'give_away_no_target_slot' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.shift_swap_requests ssr
    WHERE ssr.requester_slot_id = p_requester_slot_id AND ssr.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'swap_request_already_pending' USING ERRCODE = 'exclusion_violation';
  END IF;

  INSERT INTO data.shift_swap_requests (
    tenant_id, requester_slot_id, target_slot_id,
    requester_id, target_employee_id, status, requester_notes, kind
  ) VALUES (
    v_slot.tenant_id, p_requester_slot_id, p_target_slot_id,
    p_employee_id, p_target_employee_id, 'pending', NULLIF(btrim(p_notes), ''), v_kind
  )
  RETURNING id INTO v_request_id;

  RETURN jsonb_build_object('request_id', v_request_id, 'status', 'pending', 'kind', v_kind);
END;
$$;

REVOKE ALL ON FUNCTION data.request_shift_swap_for_employee(uuid, uuid, text, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.request_shift_swap_for_employee(uuid, uuid, text, uuid, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION api.employee_portal_list_shift_swaps(
  p_employee_id uuid,
  p_tenant_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_items jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      r.id,
      r.kind,
      r.status,
      r.requester_slot_id,
      r.target_slot_id,
      r.target_employee_id,
      r.requester_notes,
      r.created_at,
      ss.slot_date,
      ss.start_time,
      ss.end_time,
      (r.requester_id = p_employee_id) AS is_mine,
      (r.target_employee_id = p_employee_id) AS is_target
    FROM data.shift_swap_requests r
    JOIN data.shift_slots ss ON ss.id = r.requester_slot_id
    WHERE r.tenant_id = p_tenant_id
      AND (r.requester_id = p_employee_id OR r.target_employee_id = p_employee_id)
    ORDER BY r.created_at DESC
    LIMIT 100
  ) x;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'requests', COALESCE(v_items, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_list_shift_swaps(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_list_shift_swaps(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.employee_portal_request_shift_swap(
  p_employee_id uuid,
  p_tenant_id uuid,
  p_requester_slot_id uuid,
  p_kind text,
  p_notes text DEFAULT NULL,
  p_target_employee_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_res jsonb;
BEGIN
  SELECT e.id, e.tenant_id, e.status INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND OR v_emp.status <> 'active' THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Portal: només give_away / call_off (swap 1:1 amb target_slot via JWT/tenant UI)
  IF COALESCE(p_kind, '') NOT IN ('give_away', 'call_off') THEN
    RAISE EXCEPTION 'invalid_swap_kind_for_portal' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_res := data.request_shift_swap_for_employee(
    p_employee_id, p_requester_slot_id, p_kind,
    p_target_employee_id, NULL, p_notes
  );

  RETURN v_res || jsonb_build_object('employee_id', p_employee_id, 'tenant_id', p_tenant_id);
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_request_shift_swap(uuid, uuid, uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_request_shift_swap(uuid, uuid, uuid, text, text, uuid) TO service_role;

-- ─── 7. Integrity: ownership del target_slot només en pending ────────────────
-- Després d'aprovar un swap els employee_id ja han canviat; no cal revalidar-los.

CREATE OR REPLACE FUNCTION data.trg_validate_shift_swap_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_req_slot record;
  v_target_slot record;
  v_target_emp_tenant uuid;
BEGIN
  SELECT tenant_id, employee_id, status INTO v_req_slot FROM data.shift_slots WHERE id = NEW.requester_slot_id;
  IF NOT FOUND OR v_req_slot.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: invalid requester slot for swap'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.status = 'pending' AND v_req_slot.employee_id <> NEW.requester_id THEN
    RAISE EXCEPTION 'integrity_violation: invalid requester slot for pending swap'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.target_employee_id IS NOT NULL THEN
    SELECT tenant_id INTO v_target_emp_tenant FROM data.employees WHERE id = NEW.target_employee_id;
    IF v_target_emp_tenant IS NULL OR v_target_emp_tenant <> NEW.tenant_id THEN
      RAISE EXCEPTION 'integrity_violation: invalid target employee for swap'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  IF NEW.target_slot_id IS NOT NULL THEN
    SELECT tenant_id, employee_id, status INTO v_target_slot FROM data.shift_slots WHERE id = NEW.target_slot_id;
    IF NOT FOUND OR v_target_slot.tenant_id <> NEW.tenant_id THEN
      RAISE EXCEPTION 'integrity_violation: invalid target slot for swap'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    -- Només pending: un cop aprovat, el slot ja pot tenir l'altre empleat
    IF NEW.status = 'pending'
       AND NEW.target_employee_id IS NOT NULL
       AND v_target_slot.employee_id <> NEW.target_employee_id
    THEN
      RAISE EXCEPTION 'integrity_violation: target slot employee mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';
