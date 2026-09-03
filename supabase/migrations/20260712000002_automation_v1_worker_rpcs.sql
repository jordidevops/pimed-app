-- =============================================================================
-- Automation Engine V1 — Worker RPCs
-- RPCs de servei (service_role only) usades per les Edge Functions
-- process-workflow-triggers i process-automation-queue.
--
-- Depèn de: 20260712000001_automation_v1_core.sql
-- =============================================================================

-- =============================================================================
-- 1. api.get_active_automation_workflows
--    Retorna els workflows actius d'un tenant per a un event_type donat.
--    Usada per process-workflow-triggers.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_active_automation_workflows(
  p_tenant_id  uuid,
  p_event_type text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN (
    SELECT jsonb_agg(
      jsonb_build_object(
        'id',              w.id,
        'name',            w.name,
        'trigger_filters', COALESCE(w.trigger_filters, '{}'),
        'steps',           COALESCE(w.steps, '[]'),
        'site_id',         w.site_id
      )
    )
    FROM data.automation_workflows w
    WHERE w.tenant_id    = p_tenant_id
      AND w.trigger_event = p_event_type
      AND w.is_active     = true
      AND w.is_blueprint  = false
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_active_automation_workflows(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_active_automation_workflows(uuid, text) TO service_role;

-- =============================================================================
-- 2. api.create_automation_step_runs_service
--    Crea tots els step_runs d'un run de cop (un per step del workflow).
--    Retorna array de { step_id, step_run_id, step_type }.
--    Usada per process-workflow-triggers.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_automation_step_runs_service(
  p_run_id  uuid,
  p_steps   jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id  uuid;
  v_step       jsonb;
  v_step_run_id uuid;
  v_results    jsonb := '[]'::jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT tenant_id INTO v_tenant_id
  FROM data.automation_runs
  WHERE id = p_run_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'run_not_found: %', p_run_id;
  END IF;

  FOR v_step IN SELECT * FROM jsonb_array_elements(p_steps)
  LOOP
    INSERT INTO data.automation_step_runs (
      workflow_run_id, tenant_id,
      step_id, step_name, step_type,
      input, status
    ) VALUES (
      p_run_id,
      v_tenant_id,
      v_step->>'id',
      v_step->>'name',
      v_step->>'type',
      COALESCE(v_step->'input', '{}'),
      'PENDING'
    )
    RETURNING id INTO v_step_run_id;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'step_id',     v_step->>'id',
      'step_run_id', v_step_run_id,
      'step_type',   v_step->>'type'
    ));
  END LOOP;

  RETURN v_results;
END;
$$;

REVOKE ALL ON FUNCTION api.create_automation_step_runs_service(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_automation_step_runs_service(uuid, jsonb) TO service_role;

-- =============================================================================
-- 3. api.enqueue_automation_step
--    Encua un step a automation_queue via pgmq.send.
--    Usada tant per process-workflow-triggers com per process-automation-queue.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.enqueue_automation_step(
  p_tenant_id      uuid,
  p_run_id         uuid,
  p_step_run_id    uuid,
  p_step_id        text,
  p_step_type      text,
  p_attempt_number integer DEFAULT 1
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgmq, data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM pgmq.send(
    'automation_queue',
    jsonb_build_object(
      'task',            'execute_step',
      'tenant_id',       p_tenant_id,
      'idempotency_key', 'step:' || p_step_run_id::text || ':' || p_attempt_number::text,
      'workflow_run_id', p_run_id,
      'step_run_id',     p_step_run_id,
      'step_id',         p_step_id,
      'step_type',       p_step_type,
      'attempt_number',  p_attempt_number,
      'enqueued_at',     now()
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.enqueue_automation_step(uuid, uuid, uuid, text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.enqueue_automation_step(uuid, uuid, uuid, text, text, integer) TO service_role;

-- =============================================================================
-- 4. api.get_automation_execution_context
--    Retorna el context complet per executar un step:
--    { step_run, workflow_run, step_definition, context, all_step_runs }
--    Usada per process-automation-queue.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_automation_execution_context(
  p_step_run_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_step_run   data.automation_step_runs%ROWTYPE;
  v_run        data.automation_runs%ROWTYPE;
  v_workflow   data.automation_workflows%ROWTYPE;
  v_step_def   jsonb;
  v_all_steps  jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_step_run
  FROM data.automation_step_runs
  WHERE id = p_step_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'step_run_not_found: %', p_step_run_id;
  END IF;

  SELECT * INTO v_run
  FROM data.automation_runs
  WHERE id = v_step_run.workflow_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'run_not_found: %', v_step_run.workflow_run_id;
  END IF;

  SELECT * INTO v_workflow
  FROM data.automation_workflows
  WHERE id = v_run.workflow_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'workflow_not_found: %', v_run.workflow_id;
  END IF;

  -- Trobar el step definition dins el JSONB steps
  SELECT elem INTO v_step_def
  FROM jsonb_array_elements(COALESCE(v_workflow.steps, '[]'::jsonb)) AS elem
  WHERE elem->>'id' = v_step_run.step_id
  LIMIT 1;

  IF v_step_def IS NULL THEN
    RAISE EXCEPTION 'step_definition_not_found: step_id=% in workflow=%',
      v_step_run.step_id, v_run.workflow_id;
  END IF;

  -- Tots els step_runs del run (per resoldre next_step)
  SELECT jsonb_agg(jsonb_build_object(
    'step_id',     sr.step_id,
    'step_run_id', sr.id,
    'step_type',   sr.step_type,
    'status',      sr.status
  ) ORDER BY sr.created_at)
  INTO v_all_steps
  FROM data.automation_step_runs sr
  WHERE sr.workflow_run_id = v_run.id;

  -- Construïm el context enriquit amb els outputs dels steps anteriors
  RETURN jsonb_build_object(
    'step_run',        row_to_json(v_step_run)::jsonb,
    'workflow_run',    row_to_json(v_run)::jsonb,
    'step_definition', v_step_def,
    'context',         COALESCE(v_run.context, '{}'),
    'all_step_runs',   COALESCE(v_all_steps, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_automation_execution_context(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_automation_execution_context(uuid) TO service_role;

-- =============================================================================
-- 5. api.start_automation_step_run
--    Marca un step_run com a RUNNING i incrementa attempt_number.
--    Usada per process-automation-queue.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.start_automation_step_run(
  p_step_run_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.automation_step_runs
  SET
    status         = 'RUNNING',
    attempt_number = attempt_number + 1,
    started_at     = COALESCE(started_at, now())
  WHERE id = p_step_run_id
    AND status IN ('PENDING', 'FAILED');
END;
$$;

REVOKE ALL ON FUNCTION api.start_automation_step_run(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.start_automation_step_run(uuid) TO service_role;

-- =============================================================================
-- 6. api.complete_automation_step_run
--    Actualitza l'estat final d'un step_run.
--    Usada per process-automation-queue.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.complete_automation_step_run(
  p_step_run_id uuid,
  p_status      text,
  p_output      jsonb DEFAULT NULL,
  p_error       text  DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.automation_step_runs
  SET
    status       = p_status::data.automation_step_status,
    output       = COALESCE(p_output, output),
    error        = p_error,
    completed_at = CASE
                     WHEN p_status IN ('COMPLETED','FAILED','SKIPPED','CANCELLED','WAITING_HUMAN','WAITING_TIMER')
                     THEN now()
                     ELSE completed_at
                   END
  WHERE id = p_step_run_id;
END;
$$;

REVOKE ALL ON FUNCTION api.complete_automation_step_run(uuid, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.complete_automation_step_run(uuid, text, jsonb, text) TO service_role;

-- =============================================================================
-- 7. api.complete_automation_run
--    Actualitza l'estat final d'un workflow_run.
--    Usada per process-automation-queue.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.complete_automation_run(
  p_run_id uuid,
  p_status text,
  p_error  text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.automation_runs
  SET
    status       = p_status::data.automation_run_status,
    error        = p_error,
    completed_at = CASE
                     WHEN p_status IN ('COMPLETED','FAILED','CANCELLED') THEN now()
                     ELSE completed_at
                   END
  WHERE id = p_run_id;
END;
$$;

REVOKE ALL ON FUNCTION api.complete_automation_run(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.complete_automation_run(uuid, text, text) TO service_role;

-- =============================================================================
-- 8. api.update_automation_run_status
--    Actualitza l'estat d'un workflow_run (WAITING_HUMAN, etc.)
--    sense marcar-lo com completat.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.update_automation_run_status(
  p_run_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.automation_runs
  SET status = p_status::data.automation_run_status
  WHERE id = p_run_id;
END;
$$;

REVOKE ALL ON FUNCTION api.update_automation_run_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_automation_run_status(uuid, text) TO service_role;

-- =============================================================================
-- 9. Correcció: api.create_automation_run_service wrapper simplificat
--    El process-workflow-triggers crida amb menys params que el definit.
--    Creem un overload simplificat que accepta els 4 paràmetres principals.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_automation_run_service(
  p_workflow_id   uuid,
  p_tenant_id     uuid,
  p_trigger_event text,
  p_context       jsonb DEFAULT '{}'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_run_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  INSERT INTO data.automation_runs (
    workflow_id, tenant_id,
    trigger_event,
    context, status
  ) VALUES (
    p_workflow_id, p_tenant_id,
    p_trigger_event,
    COALESCE(p_context, '{}'), 'RUNNING'
  )
  RETURNING id INTO v_run_id;

  RETURN jsonb_build_object('run_id', v_run_id);
END;
$$;

REVOKE ALL ON FUNCTION api.create_automation_run_service(uuid, uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_automation_run_service(uuid, uuid, text, jsonb) TO service_role;

-- =============================================================================
-- 10. NOTIFY
-- =============================================================================

NOTIFY pgrst, 'reload schema';
