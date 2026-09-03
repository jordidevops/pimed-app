-- =============================================================================
-- M-ES-04 — Dispatch eligibility + pilot gate a start_work_log
-- =============================================================================

INSERT INTO data.feature_flags (key, description, is_enabled, rollout_percentage)
VALUES (
  'employee_readiness_gate_enabled',
  'Pilotcional: api.start_work_log exigeix dispatch eligibility (lifecycle active + readiness).',
  false,
  0
)
ON CONFLICT (key) DO NOTHING;

-- ─── compute / assert ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.compute_employee_dispatch_eligibility(
  p_employee_id uuid,
  p_as_of       date DEFAULT CURRENT_DATE,
  p_required_requirement_codes text[] DEFAULT NULL,
  p_required_asset_type_codes  text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id       uuid := data.active_tenant_id();
  v_lifecycle_state text;
  v_readiness       jsonb;
  v_reasons         text[] := '{}';
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Guarda de tenant (ES-D9)
  SELECT e.lifecycle_state INTO v_lifecycle_state
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = v_tenant_id;

  IF v_lifecycle_state IS NULL THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_lifecycle_state <> 'active' THEN
    v_reasons := array_append(v_reasons, 'LIFECYCLE_STATE_' || upper(v_lifecycle_state));
  END IF;

  -- Delegació a CR — sense reimplementar certificacions.
  -- p_required_asset_type_codes reservat per EA (ignorat al MVP).
  v_readiness := data.compute_employee_readiness(
    p_employee_id,
    p_as_of,
    p_required_requirement_codes
  );

  IF NOT (v_readiness->>'is_ready')::boolean THEN
    v_reasons := v_reasons || ARRAY(
      SELECT jsonb_array_elements_text(v_readiness->'blocking_reasons')
    );
  END IF;

  -- Evita warning de paràmetre no usat fins EA
  IF p_required_asset_type_codes IS NOT NULL AND cardinality(p_required_asset_type_codes) > 0 THEN
    NULL; -- no-op MVP
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'as_of', p_as_of,
    'is_eligible', (cardinality(v_reasons) = 0),
    'lifecycle_state', v_lifecycle_state,
    'blocking_reasons', to_jsonb(v_reasons),
    'configuration_status', v_readiness->>'configuration_status'
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.assert_employee_dispatch_eligible(
  p_employee_id uuid,
  p_as_of       date DEFAULT CURRENT_DATE,
  p_required_requirement_codes text[] DEFAULT NULL,
  p_required_asset_type_codes  text[] DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := data.compute_employee_dispatch_eligibility(
    p_employee_id,
    p_as_of,
    p_required_requirement_codes,
    p_required_asset_type_codes
  );

  IF NOT (v_result->>'is_eligible')::boolean THEN
    RAISE EXCEPTION 'employee_not_dispatch_eligible: %', (v_result->'blocking_reasons')::text
      USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION data.compute_employee_dispatch_eligibility(uuid, date, text[], text[])
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION data.assert_employee_dispatch_eligible(uuid, date, text[], text[]) FROM PUBLIC;
-- Només cridable des de RPCs internes (owner = postgres / SECURITY DEFINER callers)

CREATE OR REPLACE FUNCTION api.get_employee_dispatch_status(
  p_employee_id uuid,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = api, data
AS $$
  SELECT data.compute_employee_dispatch_eligibility(p_employee_id, COALESCE(p_as_of, CURRENT_DATE));
$$;

GRANT EXECUTE ON FUNCTION api.get_employee_dispatch_status(uuid, date)
  TO authenticated, service_role;

-- ─── Pilot: gate opcional dins start_work_log ────────────────────────────────

CREATE OR REPLACE FUNCTION api.start_work_log(
  p_client_op_id   uuid,
  p_project_id     uuid,
  p_task_id        uuid        DEFAULT NULL,
  p_check_in       timestamptz DEFAULT now(),
  p_geo            jsonb       DEFAULT NULL,
  p_location_perm  text        DEFAULT 'notrequired',
  p_notes          text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_tenant_id    uuid;
  v_site_id      uuid;
  v_log_id       uuid;
  v_anomalies    text[];
  v_employee_id  uuid;
BEGIN
  SELECT p.tenant_id, p.site_id
    INTO v_tenant_id, v_site_id
  FROM data.projects p
  WHERE p.id = p_project_id
    AND data.can_access_project(p_project_id);

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_project_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_site_id IS NULL THEN
    RAISE EXCEPTION
      'El projecte % no té site_id. work_logs requereixen ubicació física.',
      p_project_id
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT id INTO v_log_id
  FROM data.work_logs
  WHERE tenant_id    = v_tenant_id
    AND client_op_id = p_client_op_id;

  IF v_log_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'work_log_id', v_log_id,
      'status',      'duplicate'
    );
  END IF;

  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);

  -- ES-1 pilot: gate opcional (flag off = zero regressió)
  IF data.is_feature_enabled(v_tenant_id, 'employee_readiness_gate_enabled') THEN
    SELECT e.id INTO v_employee_id
    FROM data.employees e
    WHERE e.user_id = v_user_id
      AND e.tenant_id = v_tenant_id
      AND e.status <> 'terminated'
    ORDER BY e.created_at ASC
    LIMIT 1;

    -- Sense mapping user→employee: no es bloqueja (limitació documentada fins ES-3)
    IF v_employee_id IS NOT NULL THEN
      PERFORM data.assert_employee_dispatch_eligible(
        v_employee_id,
        COALESCE((p_check_in AT TIME ZONE 'UTC')::date, CURRENT_DATE)
      );
    END IF;
  END IF;

  INSERT INTO data.work_logs (
    tenant_id, site_id, project_id, task_id,
    worker_id, client_op_id, status,
    check_in, check_in_geo, check_in_received_at,
    location_permission, anomaly_codes, notes
  )
  VALUES (
    v_tenant_id, v_site_id, p_project_id, p_task_id,
    v_user_id, p_client_op_id, 'open',
    p_check_in, p_geo, now(),
    p_location_perm, v_anomalies, p_notes
  )
  RETURNING id INTO v_log_id;

  PERFORM data.log_audit_event(
    v_tenant_id,
    v_user_id,
    v_site_id,
    'WORK_LOG_STARTED',
    'work_log',
    v_log_id,
    jsonb_build_object(
      'project_id',    p_project_id,
      'task_id',       p_task_id,
      'check_in',      p_check_in,
      'anomaly_codes', v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'work_log_id', v_log_id,
    'status',      'created'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.start_work_log(uuid, uuid, uuid, timestamptz, jsonb, text, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
