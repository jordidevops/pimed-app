-- =============================================================================
-- M-ES-06 / ES-2b — Reconciliador de transicions programades
-- Accepta p_effective_on futur; no muta estat fins al dia; event derivat idempotent.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Trigger: events d'aplicació programada també muten (ja filtrats pel reconciliador)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.sync_employee_lifecycle_state()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  -- ES-D2bis: només events ja efectius.
  -- ES-2b: l'event derivat scheduled_transition_applied s'aplica sempre
  -- (el reconciliador ja ha filtrat effective_on <= as_of).
  IF NEW.effective_on <= CURRENT_DATE
     OR (
       NEW.source = 'automation'
       AND NEW.reason_code = 'scheduled_transition_applied'
     )
  THEN
    PERFORM set_config('data.lifecycle_state_write', '1', true);

    UPDATE data.employees
    SET lifecycle_state = NEW.to_state,
        lifecycle_since = NEW.effective_on,
        lifecycle_updated_at = now()
    WHERE id = NEW.employee_id;

    PERFORM data.log_audit_event(
      NEW.tenant_id,
      NEW.triggered_by,
      NULL,
      'EMPLOYEE_LIFECYCLE_CHANGED',
      'employee',
      NEW.employee_id,
      jsonb_build_object(
        'from', NEW.from_state,
        'to', NEW.to_state,
        'reason_code', NEW.reason_code,
        'event_id', NEW.id
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Índex per a cues pendents + unicitat d'aplicació
CREATE INDEX IF NOT EXISTS idx_lifecycle_events_scheduled_pending
  ON data.employee_lifecycle_events (effective_on)
  WHERE (metadata->>'scheduled') = 'true';

CREATE UNIQUE INDEX IF NOT EXISTS uq_lifecycle_scheduled_applied
  ON data.employee_lifecycle_events ((metadata->>'scheduled_event_id'))
  WHERE reason_code = 'scheduled_transition_applied'
    AND metadata ? 'scheduled_event_id';

-- ---------------------------------------------------------------------------
-- 1. transition_employee_lifecycle: accepta dates futures (marca scheduled)
-- ---------------------------------------------------------------------------
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
  v_on        date := coalesce(p_effective_on, CURRENT_DATE);
  v_meta      jsonb := coalesce(p_metadata, '{}'::jsonb);
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT lifecycle_state, site_id INTO v_from, v_site_id
  FROM data.employees
  WHERE id = p_employee_id AND tenant_id = v_tenant_id
  FOR UPDATE;

  IF v_from IS NULL THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  -- ES-2b: dates futures es programen (metadata.scheduled); el trigger no muta fins al dia.
  IF v_on > CURRENT_DATE THEN
    v_meta := v_meta || jsonb_build_object('scheduled', true);
  END IF;

  SELECT * INTO v_rule
  FROM data.employee_lifecycle_transition_rules
  WHERE from_state = v_from AND to_state = p_to_state;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_transition: % -> %', v_from, p_to_state
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT (
    coalesce(data.jwt_has_permission(v_tenant_id, v_rule.requires_permission, v_site_id), false)
    OR coalesce(data.jwt_has_permission(v_tenant_id, v_rule.requires_permission), false)
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
    v_on, auth.uid(), 'manual',
    v_meta
  )
  RETURNING * INTO v_event;

  SELECT * INTO v_out FROM api.employee_lifecycle_events WHERE id = v_event.id;
  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION api.transition_employee_lifecycle(uuid, text, text, date, jsonb) IS
  'ES-2b: transició manual; effective_on futur = programada (scheduled) sense mutar estat avui.';

-- ---------------------------------------------------------------------------
-- 2. Reconciliador: aplica events scheduled amb effective_on <= as_of
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.reconcile_scheduled_lifecycle_events(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_as_of date := coalesce(p_as_of, CURRENT_DATE);
  v_sched record;
  v_current text;
  v_rule_ok boolean;
  v_applied int := 0;
  v_skipped_state int := 0;
  v_skipped_dup int := 0;
  v_skipped_rule int := 0;
BEGIN
  FOR v_sched IN
    SELECT e.*
    FROM data.employee_lifecycle_events e
    WHERE (e.metadata->>'scheduled') = 'true'
      AND e.effective_on <= v_as_of
      AND e.reason_code IS DISTINCT FROM 'scheduled_transition_applied'
      AND NOT EXISTS (
        SELECT 1
        FROM data.employee_lifecycle_events a
        WHERE a.reason_code = 'scheduled_transition_applied'
          AND a.metadata->>'scheduled_event_id' = e.id::text
      )
    ORDER BY e.effective_on ASC, e.created_at ASC
  LOOP
    -- Ja aplicat concurrentment
    IF EXISTS (
      SELECT 1
      FROM data.employee_lifecycle_events a
      WHERE a.reason_code = 'scheduled_transition_applied'
        AND a.metadata->>'scheduled_event_id' = v_sched.id::text
    ) THEN
      v_skipped_dup := v_skipped_dup + 1;
      CONTINUE;
    END IF;

    SELECT lifecycle_state INTO v_current
    FROM data.employees
    WHERE id = v_sched.employee_id
    FOR UPDATE;

    IF v_current IS NULL THEN
      CONTINUE;
    END IF;

    -- Només aplica si l'empleat encara és a l'estat previst al programar
    IF v_current IS DISTINCT FROM v_sched.from_state THEN
      v_skipped_state := v_skipped_state + 1;
      CONTINUE;
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM data.employee_lifecycle_transition_rules r
      WHERE r.from_state = v_current AND r.to_state = v_sched.to_state
    ) INTO v_rule_ok;

    IF NOT v_rule_ok THEN
      v_skipped_rule := v_skipped_rule + 1;
      CONTINUE;
    END IF;

    BEGIN
      INSERT INTO data.employee_lifecycle_events (
        tenant_id, employee_id, from_state, to_state, reason_code,
        effective_on, triggered_by, source, metadata
      ) VALUES (
        v_sched.tenant_id,
        v_sched.employee_id,
        v_current,
        v_sched.to_state,
        'scheduled_transition_applied',
        v_sched.effective_on,
        NULL,
        'automation',
        jsonb_build_object(
          'scheduled_event_id', v_sched.id,
          'original_reason_code', v_sched.reason_code
        )
      );
      v_applied := v_applied + 1;
    EXCEPTION
      WHEN unique_violation THEN
        v_skipped_dup := v_skipped_dup + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'as_of', v_as_of,
    'applied', v_applied,
    'skipped_state_mismatch', v_skipped_state,
    'skipped_duplicate', v_skipped_dup,
    'skipped_invalid_rule', v_skipped_rule
  );
END;
$$;

COMMENT ON FUNCTION data.reconcile_scheduled_lifecycle_events(date) IS
  'ES-2b: aplica events scheduled (effective_on <= as_of) via event derivat automation; idempotent.';

GRANT EXECUTE ON FUNCTION data.reconcile_scheduled_lifecycle_events(date) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. API manual / cron wrapper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.run_reconcile_scheduled_lifecycle_events(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  -- Cron / service_role: sense JWT tenant
  IF auth.uid() IS NULL THEN
    RETURN data.reconcile_scheduled_lifecycle_events(coalesce(p_as_of, CURRENT_DATE));
  END IF;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT (
    coalesce(data.jwt_has_permission(v_tenant_id, 'employees.lifecycle.manage'), false)
    OR coalesce(data.jwt_has_permission(v_tenant_id, 'employees.lifecycle.manage_automation'), false)
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.reconcile_scheduled_lifecycle_events(coalesce(p_as_of, CURRENT_DATE));
END;
$$;

REVOKE ALL ON FUNCTION api.run_reconcile_scheduled_lifecycle_events(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.run_reconcile_scheduled_lifecycle_events(date)
  TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION api.transition_employee_lifecycle(uuid, text, text, date, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Cron diari
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('employee-lifecycle-scheduled-reconcile');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    PERFORM cron.schedule(
      'employee-lifecycle-scheduled-reconcile',
      '20 3 * * *',
      $cron$SELECT api.run_reconcile_scheduled_lifecycle_events(CURRENT_DATE)$cron$
    );
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
