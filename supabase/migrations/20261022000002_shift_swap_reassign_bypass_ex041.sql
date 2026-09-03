-- EX-04.1 follow-up: permetre reassignació d'empleat via approve_shift_swap
-- sense reobrir mutació silenciosa d'horari/ubicació/publication_id.

CREATE OR REPLACE FUNCTION data.trg_validate_shift_slot_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp record;
  v_shift record;
  v_site_tenant uuid;
  v_loc record;
  v_snap record;
  v_allow_reassign boolean :=
    COALESCE(current_setting('app.shift_slot_allow_reassign', true), '') = '1';
BEGIN
  SELECT tenant_id, site_id, status INTO v_emp FROM data.employees WHERE id = NEW.employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'integrity_violation: employee not found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_emp.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot employee tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT tenant_id, site_id, start_time, end_time, default_location_id
  INTO v_shift
  FROM data.work_shifts
  WHERE id = NEW.shift_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'integrity_violation: work_shift not found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_shift.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot shift tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT tenant_id INTO v_site_tenant FROM data.sites WHERE id = NEW.site_id;
  IF v_site_tenant IS NULL OR v_site_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot site tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_shift.site_id IS NOT NULL AND v_shift.site_id <> NEW.site_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot shift site mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.start_time IS NULL THEN
    NEW.start_time := v_shift.start_time;
  END IF;
  IF NEW.end_time IS NULL THEN
    NEW.end_time := v_shift.end_time;
  END IF;

  IF TG_OP = 'INSERT' AND NEW.location_id IS NULL THEN
    NEW.location_id := v_shift.default_location_id;
  END IF;

  IF NEW.location_id IS NOT NULL THEN
    SELECT tenant_id, site_id INTO v_loc FROM data.locations WHERE id = NEW.location_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'integrity_violation: shift_slot location not found'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_loc.tenant_id <> NEW.tenant_id THEN
      RAISE EXCEPTION 'integrity_violation: shift_slot location tenant mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_loc.site_id <> NEW.site_id THEN
      RAISE EXCEPTION 'integrity_violation: shift_slot location site mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  IF TG_OP = 'INSERT'
     OR NEW.location_id IS DISTINCT FROM OLD.location_id
     OR (OLD.status = 'draft' AND NEW.status = 'published')
  THEN
    IF NEW.location_id IS NULL THEN
      NEW.location_name_snapshot := NULL;
      NEW.location_path_snapshot := NULL;
    ELSE
      SELECT * INTO v_snap FROM data.shift_slot_fill_location_snapshots(NEW.location_id);
      NEW.location_name_snapshot := v_snap.o_name;
      NEW.location_path_snapshot := v_snap.o_path;
    END IF;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status = 'published' AND NEW.status = 'published' THEN
    IF NEW.start_time IS DISTINCT FROM OLD.start_time
       OR NEW.end_time IS DISTINCT FROM OLD.end_time
       OR NEW.location_id IS DISTINCT FROM OLD.location_id
       OR NEW.location_name_snapshot IS DISTINCT FROM OLD.location_name_snapshot
       OR NEW.location_path_snapshot IS DISTINCT FROM OLD.location_path_snapshot
       OR NEW.slot_date IS DISTINCT FROM OLD.slot_date
       OR NEW.shift_id IS DISTINCT FROM OLD.shift_id
       OR NEW.publication_id IS DISTINCT FROM OLD.publication_id
       OR (
         NEW.employee_id IS DISTINCT FROM OLD.employee_id
         AND NOT v_allow_reassign
       )
    THEN
      RAISE EXCEPTION 'integrity_violation: cannot mutate published shift_slot schedule/location snapshots'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION api.approve_shift_swap(
  p_request_id           uuid,
  p_new_status           text,
  p_comment              text DEFAULT NULL,
  p_target_employee_id   uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_req              record;
  v_req_slot         record;
  v_tgt_slot         record;
  v_effective_target uuid;
BEGIN
  SELECT ssr.* INTO v_req
  FROM data.shift_swap_requests ssr
  WHERE ssr.id = p_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'swap_request_not_found: %', p_request_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_req.tenant_id, 'attendance.approve'), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_new_status NOT IN ('approved', 'rejected', 'cancelled') THEN
    RAISE EXCEPTION 'invalid_status: % — valid: approved, rejected, cancelled', p_new_status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'swap_not_actionable: status actual = %', v_req.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_new_status = 'approved' THEN
    v_effective_target := COALESCE(v_req.target_employee_id, p_target_employee_id);

    IF v_effective_target IS NULL THEN
      RAISE EXCEPTION 'swap_open_requires_target: cal p_target_employee_id per aprovar un swap obert'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF v_effective_target = v_req.requester_id THEN
      RAISE EXCEPTION 'swap_same_employee: target i requester no poden ser el mateix'
        USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM data.employees te
      WHERE te.id = v_effective_target
        AND te.tenant_id = v_req.tenant_id
        AND te.status <> 'terminated'
    ) THEN
      RAISE EXCEPTION 'target_employee_not_found_or_invalid: %', v_effective_target
        USING ERRCODE = 'P0002';
    END IF;

    SELECT ss.employee_id, ss.status, ss.slot_date, ss.shift_id
    INTO v_req_slot
    FROM data.shift_slots ss
    WHERE ss.id = v_req.requester_slot_id;

    IF NOT FOUND OR v_req_slot.status = 'cancelled' THEN
      RAISE EXCEPTION 'requester_slot_cancelled_or_missing: el slot del sol·licitant ja no és actiu'
        USING ERRCODE = 'check_violation';
    END IF;

    IF v_req_slot.employee_id <> v_req.requester_id THEN
      RAISE EXCEPTION 'requester_slot_changed: el slot ha canviat de propietari des de la sol·licitud'
        USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
      SELECT 1 FROM data.shift_slots dup
      WHERE dup.employee_id = v_effective_target
        AND dup.slot_date = v_req_slot.slot_date
        AND dup.shift_id = v_req_slot.shift_id
        AND dup.id <> v_req.requester_slot_id
        AND dup.status <> 'cancelled'
    ) THEN
      RAISE EXCEPTION 'swap_conflict: el destinatari ja té un slot actiu per la mateixa data i torn'
        USING ERRCODE = 'exclusion_violation';
    END IF;

    IF v_req.target_slot_id IS NOT NULL THEN
      SELECT ss.employee_id, ss.status, ss.slot_date, ss.shift_id
      INTO v_tgt_slot
      FROM data.shift_slots ss
      WHERE ss.id = v_req.target_slot_id;

      IF NOT FOUND OR v_tgt_slot.status = 'cancelled' THEN
        RAISE EXCEPTION 'target_slot_cancelled_or_missing: el slot del destinatari ja no és actiu'
          USING ERRCODE = 'check_violation';
      END IF;

      IF v_tgt_slot.employee_id <> v_effective_target THEN
        RAISE EXCEPTION 'target_slot_changed: el slot del destinatari ha canviat de propietari'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1 FROM data.shift_slots dup
        WHERE dup.employee_id = v_req.requester_id
          AND dup.slot_date = v_tgt_slot.slot_date
          AND dup.shift_id = v_tgt_slot.shift_id
          AND dup.id <> v_req.target_slot_id
          AND dup.status <> 'cancelled'
      ) THEN
        RAISE EXCEPTION 'swap_conflict_reverse: el sol·licitant ja té un slot actiu per la data i torn del destinatari'
          USING ERRCODE = 'exclusion_violation';
      END IF;
    END IF;

    IF v_req.target_employee_id IS NULL AND p_target_employee_id IS NOT NULL THEN
      UPDATE data.shift_swap_requests
      SET target_employee_id = p_target_employee_id,
          updated_at = now()
      WHERE id = p_request_id;
    END IF;

    -- Bypass controlat del freeze només per reassignació d'empleat (swap aprovat)
    PERFORM set_config('app.shift_slot_allow_reassign', '1', true);

    UPDATE data.shift_slots
    SET employee_id = v_effective_target,
        updated_at = now()
    WHERE id = v_req.requester_slot_id;

    IF v_req.target_slot_id IS NOT NULL THEN
      UPDATE data.shift_slots
      SET employee_id = v_req.requester_id,
          updated_at = now()
      WHERE id = v_req.target_slot_id;
    END IF;

    PERFORM set_config('app.shift_slot_allow_reassign', '', true);

    UPDATE data.calendar_events
    SET metadata = metadata || jsonb_build_object('employee_id', v_effective_target),
        updated_at = now()
    WHERE entity_type = 'shift_slot'
      AND entity_id = v_req.requester_slot_id;

    IF v_req.target_slot_id IS NOT NULL THEN
      UPDATE data.calendar_events
      SET metadata = metadata || jsonb_build_object('employee_id', v_req.requester_id),
          updated_at = now()
      WHERE entity_type = 'shift_slot'
        AND entity_id = v_req.target_slot_id;
    END IF;
  END IF;

  UPDATE data.shift_swap_requests
  SET status = p_new_status,
      review_comment = p_comment,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  WHERE id = p_request_id;

  PERFORM data.log_audit_event(
    p_tenant_id   => v_req.tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => NULL,
    p_action      => 'SHIFT_SWAP_' || upper(p_new_status),
    p_entity_type => 'shift_swap_request',
    p_entity_id   => p_request_id,
    p_payload     => jsonb_build_object(
      'request_id',         p_request_id,
      'requester_slot_id',  v_req.requester_slot_id,
      'target_slot_id',     v_req.target_slot_id,
      'effective_target',   v_effective_target,
      'new_status',         p_new_status
    )
  );

  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'status', p_new_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_shift_swap(uuid, text, text, uuid) TO authenticated;
