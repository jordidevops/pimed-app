-- =============================================================================
-- M-EC-ELM — Contract activate/end → api lifecycle with source='contract' (D9)
-- + helper to install EC platform blueprints per tenant
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Reason codes documentats a auto_reason_codes
-- ---------------------------------------------------------------------------
UPDATE data.employee_lifecycle_transition_rules
SET auto_reason_codes = ARRAY[
  'onboarding_completed',
  'first_contract_activated'
]
WHERE from_state = 'onboarding' AND to_state = 'active';

UPDATE data.employee_lifecycle_transition_rules
SET auto_reason_codes = ARRAY[
  'resignation',
  'dismissal',
  'contract_end',
  'contract_ended_without_renewal'
]
WHERE from_state = 'active' AND to_state = 'departure';

-- ---------------------------------------------------------------------------
-- 1. Helper: side-effects ELM des del domini de contractes (mai UPDATE employees)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.apply_contract_employee_lifecycle(
  p_contract_id  uuid,
  p_effect       text,
  p_as_of        date DEFAULT CURRENT_DATE,
  p_triggered_by uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_c data.employment_contracts%ROWTYPE;
  v_emp data.employees%ROWTYPE;
  v_on date := coalesce(p_as_of, CURRENT_DATE);
  v_effect text := lower(btrim(coalesce(p_effect, '')));
  v_to text;
  v_reason text;
  v_has_successor boolean;
  v_event_id uuid;
BEGIN
  IF v_effect NOT IN ('activated', 'ended') THEN
    RAISE EXCEPTION 'invalid_contract_lifecycle_effect: %', p_effect
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_c
  FROM data.employment_contracts
  WHERE id = p_contract_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'contract_not_found');
  END IF;

  IF NOT coalesce(v_c.is_primary, false) THEN
    RETURN jsonb_build_object(
      'applied', false,
      'reason', 'not_primary',
      'contract_id', v_c.id,
      'effect', v_effect
    );
  END IF;

  SELECT * INTO v_emp
  FROM data.employees
  WHERE id = v_c.employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'employee_not_found');
  END IF;

  IF v_effect = 'activated' THEN
    IF v_emp.lifecycle_state IS DISTINCT FROM 'onboarding' THEN
      RETURN jsonb_build_object(
        'applied', false,
        'reason', 'employee_not_onboarding',
        'lifecycle_state', v_emp.lifecycle_state,
        'contract_id', v_c.id
      );
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM data.employee_lifecycle_transition_rules r
      WHERE r.from_state = 'onboarding' AND r.to_state = 'active'
    ) THEN
      RETURN jsonb_build_object('applied', false, 'reason', 'invalid_transition_rule');
    END IF;

    v_to := 'active';
    v_reason := 'first_contract_activated';

  ELSE
    -- ended: només si no hi ha successor actiu/programat
    SELECT EXISTS (
      SELECT 1
      FROM data.employment_contracts s
      WHERE s.tenant_id = v_c.tenant_id
        AND s.employee_id = v_c.employee_id
        AND s.id <> v_c.id
        AND s.lifecycle_status IN ('active', 'scheduled')
    ) INTO v_has_successor;

    IF v_has_successor THEN
      RETURN jsonb_build_object(
        'applied', false,
        'reason', 'has_successor_contract',
        'contract_id', v_c.id
      );
    END IF;

    IF v_emp.lifecycle_state NOT IN ('active', 'on_leave') THEN
      RETURN jsonb_build_object(
        'applied', false,
        'reason', 'employee_not_active_or_on_leave',
        'lifecycle_state', v_emp.lifecycle_state,
        'contract_id', v_c.id
      );
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM data.employee_lifecycle_transition_rules r
      WHERE r.from_state = v_emp.lifecycle_state AND r.to_state = 'departure'
    ) THEN
      RETURN jsonb_build_object('applied', false, 'reason', 'invalid_transition_rule');
    END IF;

    v_to := 'departure';
    v_reason := 'contract_ended_without_renewal';
  END IF;

  INSERT INTO data.employee_lifecycle_events (
    tenant_id, employee_id, from_state, to_state, reason_code,
    effective_on, triggered_by, source, metadata
  ) VALUES (
    v_c.tenant_id,
    v_c.employee_id,
    v_emp.lifecycle_state,
    v_to,
    v_reason,
    v_on,
    p_triggered_by,
    'contract',
    jsonb_build_object(
      'contract_id', v_c.id,
      'contract_number', v_c.contract_number,
      'effect', v_effect,
      'as_of', v_on
    )
  )
  RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'applied', true,
    'event_id', v_event_id,
    'from_state', v_emp.lifecycle_state,
    'to_state', v_to,
    'reason_code', v_reason,
    'source', 'contract',
    'contract_id', v_c.id,
    'employee_id', v_c.employee_id
  );
END;
$$;

COMMENT ON FUNCTION data.apply_contract_employee_lifecycle(uuid, text, date, uuid) IS
  'EC↔ELM D9: activa (onboarding→active) o finalitza (active/on_leave→departure) amb source=contract.';

REVOKE ALL ON FUNCTION data.apply_contract_employee_lifecycle(uuid, text, date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.apply_contract_employee_lifecycle(uuid, text, date, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Reconcile tenant: crida ELM després d''activar/finalitzar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.reconcile_employment_contracts_for_tenant(
  p_tenant_id uuid,
  p_as_of     date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_on date := coalesce(p_as_of, CURRENT_DATE);
  v_activated int := 0;
  v_ended int := 0;
  v_blocked int := 0;
  v_skipped_sig int := 0;
  v_elm_activated int := 0;
  v_elm_departed int := 0;
  r record;
  v_site uuid;
  v_elm jsonb;
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOR r IN
    SELECT c.*
    FROM data.employment_contracts c
    WHERE c.tenant_id = p_tenant_id
      AND c.lifecycle_status = 'scheduled'
      AND c.starts_on <= v_on
      AND (c.ends_on IS NULL OR c.ends_on >= v_on)
    ORDER BY c.starts_on, c.id
  LOOP
    IF data.employment_contract_signature_blocks_activation(
         r.signature_requirement, r.signature_status
       ) THEN
      v_skipped_sig := v_skipped_sig + 1;
      SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
      IF data.try_employment_contract_notice(
           p_tenant_id, r.id, v_site, 'activation_blocked', 0,
           'CONTRACT_ACTIVATION_BLOCKED',
           jsonb_build_object(
             'employee_id', r.employee_id,
             'starts_on', r.starts_on,
             'reason', 'signature_blocked',
             'signature_status', r.signature_status,
             'as_of', v_on
           )
         ) THEN
        v_blocked := v_blocked + 1;
      END IF;
      CONTINUE;
    END IF;

    UPDATE data.employment_contracts
    SET lifecycle_status = 'active',
        activated_at = coalesce(activated_at, now()),
        updated_at = now()
    WHERE id = r.id;

    PERFORM data.project_employment_contract_onto_employee(r.id);
    v_activated := v_activated + 1;

    v_elm := data.apply_contract_employee_lifecycle(r.id, 'activated', v_on, NULL);
    IF coalesce((v_elm ->> 'applied')::boolean, false) THEN
      v_elm_activated := v_elm_activated + 1;
    END IF;

    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
    PERFORM data.try_employment_contract_notice(
      p_tenant_id, r.id, v_site, 'activated', 0,
      'CONTRACT_ACTIVATED',
      jsonb_build_object(
        'employee_id', r.employee_id,
        'starts_on', r.starts_on,
        'as_of', v_on,
        'elm', v_elm
      )
    );
  END LOOP;

  FOR r IN
    SELECT c.*
    FROM data.employment_contracts c
    WHERE c.tenant_id = p_tenant_id
      AND c.lifecycle_status = 'draft'
      AND c.starts_on <= v_on
    ORDER BY c.starts_on, c.id
  LOOP
    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
    IF data.try_employment_contract_notice(
         p_tenant_id, r.id, v_site, 'activation_blocked', 0,
         'CONTRACT_ACTIVATION_BLOCKED',
         jsonb_build_object(
           'employee_id', r.employee_id,
           'starts_on', r.starts_on,
           'reason', 'draft_past_starts_on',
           'as_of', v_on
         )
       ) THEN
      v_blocked := v_blocked + 1;
    END IF;
  END LOOP;

  FOR r IN
    SELECT c.*
    FROM data.employment_contracts c
    WHERE c.tenant_id = p_tenant_id
      AND c.lifecycle_status = 'active'
      AND c.ends_on IS NOT NULL
      AND c.ends_on < v_on
    ORDER BY c.ends_on, c.id
  LOOP
    UPDATE data.employment_contracts
    SET lifecycle_status = 'ended',
        ended_at = coalesce(ended_at, now()),
        updated_at = now()
    WHERE id = r.id;

    v_ended := v_ended + 1;

    v_elm := data.apply_contract_employee_lifecycle(r.id, 'ended', v_on, NULL);
    IF coalesce((v_elm ->> 'applied')::boolean, false) THEN
      v_elm_departed := v_elm_departed + 1;
    END IF;

    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
    PERFORM data.try_employment_contract_notice(
      p_tenant_id, r.id, v_site, 'ended', 0,
      'CONTRACT_ENDED',
      jsonb_build_object(
        'employee_id', r.employee_id,
        'ends_on', r.ends_on,
        'as_of', v_on,
        'elm', v_elm
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    'as_of', v_on,
    'activated', v_activated,
    'ended', v_ended,
    'blocked_notices', v_blocked,
    'skipped_signature_blocked', v_skipped_sig,
    'elm_activated', v_elm_activated,
    'elm_departed', v_elm_departed
  );
END;
$$;

REVOKE ALL ON FUNCTION data.reconcile_employment_contracts_for_tenant(uuid, date) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 3. API interactive reconcile (employee-scoped) + ELM
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.reconcile_employment_contracts(
  p_employee_id uuid DEFAULT NULL,
  p_on date DEFAULT CURRENT_DATE
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_on date := coalesce(p_on, CURRENT_DATE);
  v_count int := 0;
  v_res jsonb;
  r record;
  v_site uuid;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT data.jwt_can_manage_employment_contracts(v_tenant_id, NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_employee_id IS NULL THEN
    v_res := data.reconcile_employment_contracts_for_tenant(v_tenant_id, v_on);
    RETURN coalesce((v_res ->> 'activated')::int, 0)
         + coalesce((v_res ->> 'ended')::int, 0);
  END IF;

  FOR r IN
    SELECT c.*
    FROM data.employment_contracts c
    WHERE c.tenant_id = v_tenant_id
      AND c.employee_id = p_employee_id
      AND c.lifecycle_status = 'scheduled'
      AND c.starts_on <= v_on
      AND (c.ends_on IS NULL OR c.ends_on >= v_on)
  LOOP
    IF data.employment_contract_signature_blocks_activation(
         r.signature_requirement, r.signature_status
       ) THEN
      SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
      PERFORM data.try_employment_contract_notice(
        v_tenant_id, r.id, v_site, 'activation_blocked', 0,
        'CONTRACT_ACTIVATION_BLOCKED',
        jsonb_build_object(
          'employee_id', r.employee_id,
          'starts_on', r.starts_on,
          'reason', 'signature_blocked',
          'signature_status', r.signature_status,
          'as_of', v_on
        )
      );
      CONTINUE;
    END IF;

    UPDATE data.employment_contracts
    SET lifecycle_status = 'active',
        activated_at = coalesce(activated_at, now()),
        updated_at = now()
    WHERE id = r.id;

    PERFORM data.project_employment_contract_onto_employee(r.id);
    PERFORM data.apply_contract_employee_lifecycle(r.id, 'activated', v_on, auth.uid());
    v_count := v_count + 1;

    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
    PERFORM data.try_employment_contract_notice(
      v_tenant_id, r.id, v_site, 'activated', 0,
      'CONTRACT_ACTIVATED',
      jsonb_build_object('employee_id', r.employee_id, 'starts_on', r.starts_on, 'as_of', v_on)
    );
  END LOOP;

  FOR r IN
    SELECT c.*
    FROM data.employment_contracts c
    WHERE c.tenant_id = v_tenant_id
      AND c.employee_id = p_employee_id
      AND c.lifecycle_status = 'active'
      AND c.ends_on IS NOT NULL
      AND c.ends_on < v_on
  LOOP
    UPDATE data.employment_contracts
    SET lifecycle_status = 'ended',
        ended_at = coalesce(ended_at, now()),
        updated_at = now()
    WHERE id = r.id;

    PERFORM data.apply_contract_employee_lifecycle(r.id, 'ended', v_on, auth.uid());
    v_count := v_count + 1;

    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
    PERFORM data.try_employment_contract_notice(
      v_tenant_id, r.id, v_site, 'ended', 0,
      'CONTRACT_ENDED',
      jsonb_build_object('employee_id', r.employee_id, 'ends_on', r.ends_on, 'as_of', v_on)
    );
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.reconcile_employment_contracts(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reconcile_employment_contracts(uuid, date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Interactive transition_employment_contract + ELM
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.transition_employment_contract(
  p_contract_id uuid,
  p_to_status text,
  p_reason text DEFAULT NULL
)
RETURNS api.employment_contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_c data.employment_contracts%ROWTYPE;
  v_emp data.employees%ROWTYPE;
  v_out api.employment_contracts;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_c FROM data.employment_contracts WHERE id = p_contract_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_emp FROM data.employees WHERE id = v_c.employee_id;
  IF NOT data.jwt_can_manage_employment_contracts(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_to_status IN ('scheduled', 'active')
     AND v_c.signature_requirement <> 'none'
     AND v_c.signature_status IN ('rejected', 'expired') THEN
    RAISE EXCEPTION 'signature_blocked' USING ERRCODE = 'check_violation';
  END IF;

  IF p_to_status = 'scheduled' THEN
    IF v_c.lifecycle_status <> 'draft' THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    IF v_c.signature_requirement <> 'none' AND v_c.signature_status <> 'completed' THEN
      RAISE EXCEPTION 'signature_required' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'scheduled',
      approval_status = CASE WHEN approval_status = 'pending' THEN 'approved' ELSE approval_status END,
      approved_by = coalesce(approved_by, auth.uid()),
      approved_at = coalesce(approved_at, now()),
      updated_at = now()
    WHERE id = v_c.id;

  ELSIF p_to_status = 'active' THEN
    IF v_c.lifecycle_status NOT IN ('scheduled', 'draft') THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    IF v_c.lifecycle_status = 'draft'
       AND v_c.signature_requirement <> 'none'
       AND v_c.signature_status <> 'completed' THEN
      RAISE EXCEPTION 'signature_required' USING ERRCODE = 'check_violation';
    END IF;
    IF v_c.starts_on > CURRENT_DATE THEN
      RAISE EXCEPTION 'contract_not_started' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'active',
      activated_at = coalesce(activated_at, now()),
      updated_at = now()
    WHERE id = v_c.id;

    PERFORM data.project_employment_contract_onto_employee(v_c.id);
    PERFORM data.apply_contract_employee_lifecycle(v_c.id, 'activated', CURRENT_DATE, auth.uid());

  ELSIF p_to_status = 'ended' THEN
    IF v_c.lifecycle_status NOT IN ('active', 'scheduled') THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'ended',
      ended_at = coalesce(ended_at, now()),
      ends_on = coalesce(ends_on, CURRENT_DATE),
      termination_notes = coalesce(p_reason, termination_notes),
      updated_at = now()
    WHERE id = v_c.id;

    PERFORM data.apply_contract_employee_lifecycle(v_c.id, 'ended', CURRENT_DATE, auth.uid());

  ELSIF p_to_status = 'cancelled' THEN
    IF v_c.lifecycle_status IN ('ended', 'cancelled') THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'cancelled',
      cancelled_at = now(),
      cancellation_reason = p_reason,
      updated_at = now()
    WHERE id = v_c.id;

  ELSE
    RAISE EXCEPTION 'invalid_contract_status' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_out FROM api.employment_contracts WHERE id = v_c.id;
  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.transition_employment_contract(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.transition_employment_contract(uuid, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Install EC platform blueprints for a tenant (idempotent)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.install_ec_platform_blueprints_for_tenant(
  p_tenant_id  uuid,
  p_created_by uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_bp record;
  v_new_id uuid;
  v_installed int := 0;
  v_skipped int := 0;
  v_names text[] := ARRAY[]::text[];
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOR v_bp IN
    SELECT w.*
    FROM data.automation_workflows w
    WHERE w.is_blueprint = true
      AND w.tenant_id IS NULL
      AND w.is_active = true
      AND (
        w.trigger_event IN (
          'CONTRACT_ACTIVATION_BLOCKED',
          'CONTRACT_ACTIVATED',
          'CONTRACT_EXPIRING',
          'CONTRACT_ENDED'
        )
        OR w.name = 'Onboarding d''empleats'
      )
    ORDER BY w.trigger_event NULLS LAST, w.name
  LOOP
    IF EXISTS (
      SELECT 1
      FROM data.automation_workflows t
      WHERE t.tenant_id = p_tenant_id
        AND t.is_blueprint = false
        AND (
          t.source_blueprint_id = v_bp.id
          OR (t.name = v_bp.name AND t.trigger_event = v_bp.trigger_event)
        )
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO data.automation_workflows (
      tenant_id, site_id, name, description,
      trigger_event, trigger_filters, steps,
      is_active, is_blueprint, source_blueprint_id,
      version, created_by
    ) VALUES (
      p_tenant_id, NULL, v_bp.name, v_bp.description,
      v_bp.trigger_event, v_bp.trigger_filters, v_bp.steps,
      true, false, v_bp.id,
      1, p_created_by
    )
    RETURNING id INTO v_new_id;

    v_installed := v_installed + 1;
    v_names := array_append(v_names, v_bp.name);
  END LOOP;

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    'installed', v_installed,
    'skipped', v_skipped,
    'names', to_jsonb(v_names)
  );
END;
$$;

COMMENT ON FUNCTION data.install_ec_platform_blueprints_for_tenant(uuid, uuid) IS
  'Instal·la blueprints EC + Onboarding al tenant si encara no hi són (idempotent).';

REVOKE ALL ON FUNCTION data.install_ec_platform_blueprints_for_tenant(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.install_ec_platform_blueprints_for_tenant(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.install_ec_platform_blueprints()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.install_ec_platform_blueprints_for_tenant(v_tenant_id, auth.uid());
END;
$$;

REVOKE EXECUTE ON FUNCTION api.install_ec_platform_blueprints() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.install_ec_platform_blueprints() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
