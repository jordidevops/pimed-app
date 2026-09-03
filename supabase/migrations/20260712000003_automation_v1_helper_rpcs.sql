-- =============================================================================
-- Automation Engine V1 — Helper RPCs
-- RPCs de suport per al context-builder i els handlers.
--
-- Depèn de: 20260712000002_automation_v1_worker_rpcs.sql
-- =============================================================================

-- =============================================================================
-- 1. api.get_tenant_basic
--    Retorna el nom i slug d'un tenant (per al context-builder).
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_tenant_basic(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT jsonb_build_object('id', id, 'name', name, 'slug', slug)
  INTO v_result
  FROM data.tenants
  WHERE id = p_tenant_id;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION api.get_tenant_basic(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_tenant_basic(uuid) TO service_role;

-- =============================================================================
-- 2. api.get_site_basic
--    Retorna el nom d'un site (per al context-builder).
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_site_basic(p_site_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT jsonb_build_object('id', id, 'name', name)
  INTO v_result
  FROM data.sites
  WHERE id = p_site_id;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION api.get_site_basic(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_site_basic(uuid) TO service_role;

-- =============================================================================
-- 3. api.create_automation_pending_approval_service
--    Crea una aprovació pendent vinculada a un step_run i workflow_run.
--    Usada per l'handler HUMAN_APPROVAL.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_automation_pending_approval_service(
  p_step_run_id          uuid,
  p_workflow_run_id      uuid,
  p_tenant_id            uuid,
  p_site_id              uuid     DEFAULT NULL,
  p_assigned_to_role     text     DEFAULT NULL,
  p_assigned_to_user_id  uuid     DEFAULT NULL,
  p_due_hours            integer  DEFAULT 24,
  p_context_preview      jsonb    DEFAULT '{}'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_approval_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  INSERT INTO data.automation_pending_approvals (
    step_run_id,
    workflow_run_id,
    tenant_id,
    assigned_to_user_id,
    assigned_to_role,
    context_preview,
    status,
    due_at
  ) VALUES (
    p_step_run_id,
    p_workflow_run_id,
    p_tenant_id,
    p_assigned_to_user_id,
    p_assigned_to_role,
    COALESCE(p_context_preview, '{}'),
    'PENDING',
    now() + (p_due_hours || ' hours')::interval
  )
  RETURNING id INTO v_approval_id;

  RETURN jsonb_build_object('approval_id', v_approval_id);
END;
$$;

REVOKE ALL ON FUNCTION api.create_automation_pending_approval_service(uuid, uuid, uuid, uuid, text, uuid, integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_automation_pending_approval_service(uuid, uuid, uuid, uuid, text, uuid, integer, jsonb) TO service_role;

-- =============================================================================
-- 4. Correccions a api.resolve_automation_approval
--    La implementació actual no encua el next step quan s'aprova.
--    Corregim per encuar via api.enqueue_automation_step.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.resolve_automation_approval(
  p_approval_id          uuid,
  p_resolution           text,
  p_comment              text DEFAULT NULL,
  p_reassign_to_user_id  uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_tenant_id   uuid := data.active_tenant_id();
  v_user_id     uuid := auth.uid();
  v_approval    data.automation_pending_approvals%ROWTYPE;
  v_step_run    data.automation_step_runs%ROWTYPE;
  v_run         data.automation_runs%ROWTYPE;
  v_workflow    data.automation_workflows%ROWTYPE;
  v_step_def    jsonb;
  v_next_step_id text;
  v_next_step_run data.automation_step_runs%ROWTYPE;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  SELECT * INTO v_approval
  FROM data.automation_pending_approvals
  WHERE id = p_approval_id AND tenant_id = v_tenant_id AND status = 'PENDING';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'approval_not_found_or_not_pending';
  END IF;

  IF p_resolution NOT IN ('approved', 'rejected', 'reassigned') THEN
    RAISE EXCEPTION 'invalid_resolution: %', p_resolution;
  END IF;

  -- Reassign
  IF p_resolution = 'reassigned' THEN
    IF p_reassign_to_user_id IS NULL THEN
      RAISE EXCEPTION 'reassign_requires_user_id';
    END IF;
    UPDATE data.automation_pending_approvals
    SET
      assigned_to_user_id = p_reassign_to_user_id,
      status              = 'REASSIGNED',
      resolution_comment  = p_comment
    WHERE id = p_approval_id;
    -- Tornem a PENDING per al nou assignat
    UPDATE data.automation_pending_approvals
    SET status = 'PENDING', assigned_to_user_id = p_reassign_to_user_id
    WHERE id = p_approval_id;
    RETURN;
  END IF;

  -- Approved o Rejected: tanquem l'aprovació
  UPDATE data.automation_pending_approvals
  SET
    status             = CASE WHEN p_resolution = 'approved' THEN 'APPROVED' ELSE 'REJECTED' END,
    resolved_by        = v_user_id,
    resolved_at        = now(),
    resolution_comment = p_comment
  WHERE id = p_approval_id;

  -- Actualitzar el step_run
  SELECT * INTO v_step_run FROM data.automation_step_runs WHERE id = v_approval.step_run_id;
  SELECT * INTO v_run      FROM data.automation_runs       WHERE id = v_approval.workflow_run_id;

  UPDATE data.automation_step_runs
  SET
    status           = CASE WHEN p_resolution = 'approved' THEN 'COMPLETED' ELSE 'FAILED' END::data.automation_step_status,
    approved_by      = v_user_id,
    approved_at      = now(),
    approval_comment = p_comment,
    completed_at     = now()
  WHERE id = v_approval.step_run_id;

  IF p_resolution = 'rejected' THEN
    UPDATE data.automation_runs
    SET status = 'FAILED', error = 'Human approval rejected', completed_at = now()
    WHERE id = v_approval.workflow_run_id;
    RETURN;
  END IF;

  -- Approved: buscar next step per encuar
  SELECT * INTO v_workflow FROM data.automation_workflows WHERE id = v_run.workflow_id;

  SELECT elem INTO v_step_def
  FROM jsonb_array_elements(COALESCE(v_workflow.steps, '[]'::jsonb)) AS elem
  WHERE elem->>'id' = v_step_run.step_id
  LIMIT 1;

  v_next_step_id := v_step_def->>'on_success';

  IF v_next_step_id IS NULL OR v_next_step_id = 'END_OK' THEN
    -- Workflow completat
    UPDATE data.automation_runs
    SET status = 'COMPLETED', completed_at = now()
    WHERE id = v_approval.workflow_run_id;
    RETURN;
  END IF;

  IF v_next_step_id = 'END_FAIL' THEN
    UPDATE data.automation_runs
    SET status = 'FAILED', error = 'on_success=END_FAIL', completed_at = now()
    WHERE id = v_approval.workflow_run_id;
    RETURN;
  END IF;

  SELECT * INTO v_next_step_run
  FROM data.automation_step_runs
  WHERE workflow_run_id = v_approval.workflow_run_id AND step_id = v_next_step_id
  LIMIT 1;

  IF NOT FOUND THEN
    UPDATE data.automation_runs
    SET status = 'FAILED', error = 'next_step_run_not_found: ' || v_next_step_id
    WHERE id = v_approval.workflow_run_id;
    RETURN;
  END IF;

  -- Reactivar el run i encuar el proper step
  UPDATE data.automation_runs
  SET status = 'RUNNING', current_step_id = v_next_step_id
  WHERE id = v_approval.workflow_run_id;

  PERFORM pgmq.send(
    'automation_queue',
    jsonb_build_object(
      'task',            'execute_step',
      'tenant_id',       v_tenant_id,
      'idempotency_key', 'step:' || v_next_step_run.id::text || ':1',
      'workflow_run_id', v_approval.workflow_run_id,
      'step_run_id',     v_next_step_run.id,
      'step_id',         v_next_step_id,
      'step_type',       v_next_step_run.step_type,
      'attempt_number',  1,
      'enqueued_at',     now()
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_automation_approval(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_automation_approval(uuid, text, text, uuid) TO authenticated;

-- =============================================================================
-- 5. NOTIFY
-- =============================================================================

NOTIFY pgrst, 'reload schema';
