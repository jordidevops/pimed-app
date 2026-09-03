-- =============================================================================
-- M-ES-05 — RPC api.transition_employee_lifecycle (single-writer via trigger)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.transition_employee_lifecycle(
  p_employee_id  uuid,
  p_to_state     text,
  p_reason_code  text,
  p_effective_on date DEFAULT CURRENT_DATE,
  p_metadata     jsonb DEFAULT '{}'::jsonb
)
RETURNS api.employee_lifecycle_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_site_id   uuid;
  v_from      text;
  v_rule      data.employee_lifecycle_transition_rules;
  v_event     data.employee_lifecycle_events;
  v_out       api.employee_lifecycle_events;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  -- FOR UPDATE serialitza transicions concurrents sobre el mateix empleat.
  SELECT lifecycle_state, site_id INTO v_from, v_site_id
  FROM data.employees
  WHERE id = p_employee_id AND tenant_id = v_tenant_id
  FOR UPDATE;

  IF v_from IS NULL THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_effective_on > CURRENT_DATE THEN
    -- MVP (ES-2): no s'admeten transicions programades fins ES-2b.
    RAISE EXCEPTION 'future_effective_on_not_supported' USING ERRCODE = 'feature_not_supported';
  END IF;

  SELECT * INTO v_rule
  FROM data.employee_lifecycle_transition_rules
  WHERE from_state = v_from AND to_state = p_to_state;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_transition: % -> %', v_from, p_to_state
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_tenant_id, v_rule.requires_permission, v_site_id)
    OR data.jwt_has_permission(v_tenant_id, v_rule.requires_permission)
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_rule.requires_reason AND (p_reason_code IS NULL OR btrim(p_reason_code) = '') THEN
    RAISE EXCEPTION 'reason_code_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO data.employee_lifecycle_events (
    tenant_id, employee_id, from_state, to_state, reason_code,
    effective_on, triggered_by, source, metadata
  ) VALUES (
    v_tenant_id, p_employee_id, v_from, p_to_state, btrim(p_reason_code),
    COALESCE(p_effective_on, CURRENT_DATE), auth.uid(), 'manual',
    COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING * INTO v_event;

  -- No UPDATE directe: trg_sync_employee_lifecycle_state és l'únic escriptor.

  SELECT * INTO v_out FROM api.employee_lifecycle_events WHERE id = v_event.id;
  RETURN v_out;
END;
$$;

GRANT EXECUTE ON FUNCTION api.transition_employee_lifecycle(
  uuid, text, text, date, jsonb
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
