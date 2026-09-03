-- =============================================================================
-- Automation Engine V1 — Core Schema
-- Motor d'automatització V1: workflows, runs, step runs, aprovacions humans,
-- cues PGMQ, trigger audit_logs → workflow_trigger_queue, RLS, vistes i RPCs.
-- =============================================================================

-- ===== 1. ENUMS ===============================================================

DO $$ BEGIN
  CREATE TYPE data.automation_run_status AS ENUM (
    'PENDING', 'RUNNING', 'WAITING_HUMAN', 'WAITING_TIMER',
    'COMPLETED', 'FAILED', 'CANCELLED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE data.automation_step_status AS ENUM (
    'PENDING', 'RUNNING', 'COMPLETED', 'FAILED', 'SKIPPED',
    'WAITING_HUMAN', 'WAITING_TIMER', 'CANCELLED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE data.automation_approval_status AS ENUM (
    'PENDING', 'APPROVED', 'REJECTED', 'EXPIRED', 'REASSIGNED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ===== 2. TAULA data.automation_workflows =====================================

CREATE TABLE IF NOT EXISTS data.automation_workflows (
  id                  uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid         REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id             uuid         REFERENCES data.sites(id) ON DELETE SET NULL,
  name                text         NOT NULL,
  description         text,
  trigger_event       text         NOT NULL,
  trigger_filters     jsonb        NOT NULL DEFAULT '{}',
  steps               jsonb        NOT NULL DEFAULT '[]',
  is_active           boolean      NOT NULL DEFAULT false,
  is_blueprint        boolean      NOT NULL DEFAULT false,
  source_blueprint_id uuid         REFERENCES data.automation_workflows(id) ON DELETE SET NULL,
  version             integer      NOT NULL DEFAULT 1,
  created_by          uuid         REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at          timestamptz  NOT NULL DEFAULT now(),
  updated_at          timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT automation_workflows_blueprint_check
    CHECK (
      (is_blueprint = true  AND tenant_id IS NULL)
      OR
      (is_blueprint = false AND tenant_id IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS automation_workflows_tenant_active_idx
  ON data.automation_workflows (tenant_id, is_active)
  WHERE tenant_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS automation_workflows_trigger_active_idx
  ON data.automation_workflows (trigger_event, is_active);

CREATE INDEX IF NOT EXISTS automation_workflows_blueprint_idx
  ON data.automation_workflows (is_blueprint);

DROP TRIGGER IF EXISTS trg_automation_workflows_updated_at ON data.automation_workflows;
CREATE TRIGGER trg_automation_workflows_updated_at
  BEFORE UPDATE ON data.automation_workflows
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

-- ===== 3. TAULA data.automation_runs ==========================================

CREATE TABLE IF NOT EXISTS data.automation_runs (
  id                  uuid                      PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id         uuid                      NOT NULL REFERENCES data.automation_workflows(id) ON DELETE RESTRICT,
  tenant_id           uuid                      NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id             uuid                      REFERENCES data.sites(id) ON DELETE SET NULL,
  status              data.automation_run_status NOT NULL DEFAULT 'RUNNING',
  trigger_event       text                      NOT NULL,
  trigger_entity_type text,
  trigger_entity_id   uuid,
  context             jsonb                     NOT NULL DEFAULT '{}',
  current_step_id     text,
  error               text,
  started_at          timestamptz               NOT NULL DEFAULT now(),
  completed_at        timestamptz,
  created_at          timestamptz               NOT NULL DEFAULT now(),
  updated_at          timestamptz               NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS automation_runs_tenant_status_created_idx
  ON data.automation_runs (tenant_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS automation_runs_workflow_created_idx
  ON data.automation_runs (workflow_id, created_at DESC);

CREATE INDEX IF NOT EXISTS automation_runs_trigger_entity_idx
  ON data.automation_runs (trigger_entity_id)
  WHERE trigger_entity_id IS NOT NULL;

DROP TRIGGER IF EXISTS trg_automation_runs_updated_at ON data.automation_runs;
CREATE TRIGGER trg_automation_runs_updated_at
  BEFORE UPDATE ON data.automation_runs
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

-- ===== 4. TAULA data.automation_step_runs =====================================

CREATE TABLE IF NOT EXISTS data.automation_step_runs (
  id               uuid                       PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_run_id  uuid                       NOT NULL REFERENCES data.automation_runs(id) ON DELETE CASCADE,
  tenant_id        uuid                       NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  step_id          text                       NOT NULL,
  step_name        text,
  step_type        text                       NOT NULL,
  status           data.automation_step_status NOT NULL DEFAULT 'PENDING',
  input            jsonb                      NOT NULL DEFAULT '{}',
  output           jsonb                      NOT NULL DEFAULT '{}',
  error            text,
  attempt_number   integer                    NOT NULL DEFAULT 0,
  started_at       timestamptz,
  completed_at     timestamptz,
  approved_by      uuid                       REFERENCES data.profiles(id) ON DELETE SET NULL,
  approved_at      timestamptz,
  approval_comment text,
  created_at       timestamptz                NOT NULL DEFAULT now(),
  updated_at       timestamptz                NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS automation_step_runs_run_step_idx
  ON data.automation_step_runs (workflow_run_id, step_id);

CREATE INDEX IF NOT EXISTS automation_step_runs_tenant_status_idx
  ON data.automation_step_runs (tenant_id, status);

CREATE INDEX IF NOT EXISTS automation_step_runs_step_type_idx
  ON data.automation_step_runs (step_type);

DROP TRIGGER IF EXISTS trg_automation_step_runs_updated_at ON data.automation_step_runs;
CREATE TRIGGER trg_automation_step_runs_updated_at
  BEFORE UPDATE ON data.automation_step_runs
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

-- ===== 5. TAULA data.automation_pending_approvals =============================

CREATE TABLE IF NOT EXISTS data.automation_pending_approvals (
  id                  uuid                         PRIMARY KEY DEFAULT gen_random_uuid(),
  step_run_id         uuid                         NOT NULL REFERENCES data.automation_step_runs(id) ON DELETE CASCADE UNIQUE,
  workflow_run_id     uuid                         NOT NULL REFERENCES data.automation_runs(id) ON DELETE CASCADE,
  tenant_id           uuid                         NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  assigned_to_user_id uuid                         REFERENCES data.profiles(id) ON DELETE SET NULL,
  assigned_to_role    text,
  context_preview     jsonb                        NOT NULL DEFAULT '{}',
  title               text,
  description         text,
  status              data.automation_approval_status NOT NULL DEFAULT 'PENDING',
  due_at              timestamptz,
  resolved_by         uuid                         REFERENCES data.profiles(id) ON DELETE SET NULL,
  resolved_at         timestamptz,
  resolution_comment  text,
  created_at          timestamptz                  NOT NULL DEFAULT now(),
  updated_at          timestamptz                  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS automation_pending_approvals_tenant_status_created_idx
  ON data.automation_pending_approvals (tenant_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS automation_pending_approvals_user_status_idx
  ON data.automation_pending_approvals (assigned_to_user_id, status)
  WHERE assigned_to_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS automation_pending_approvals_run_idx
  ON data.automation_pending_approvals (workflow_run_id);

DROP TRIGGER IF EXISTS trg_automation_pending_approvals_updated_at ON data.automation_pending_approvals;
CREATE TRIGGER trg_automation_pending_approvals_updated_at
  BEFORE UPDATE ON data.automation_pending_approvals
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

-- ===== 6. PGMQ: CREA LES CUES =================================================

DO $$ BEGIN
  PERFORM pgmq.create('workflow_trigger_queue');
EXCEPTION WHEN others THEN NULL;
END $$;

DO $$ BEGIN
  PERFORM pgmq.create('automation_queue');
EXCEPTION WHEN others THEN NULL;
END $$;

-- ===== 7. TRIGGER audit_logs → workflow_trigger_queue =========================
-- Encua cada insert d'audit_log com a trigger potencial de workflows.
-- L'excepció interna evita trencar la transacció principal si la cua falla.

CREATE OR REPLACE FUNCTION data.trg_audit_log_to_workflow_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
BEGIN
  IF NEW.tenant_id IS NULL THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM pgmq.send(
      'workflow_trigger_queue',
      jsonb_build_object(
        'task',            'process_workflow_trigger',
        'tenant_id',       NEW.tenant_id,
        'idempotency_key', 'audit:' || NEW.id::text,
        'event_type',      NEW.action,
        'entity_type',     NEW.entity_type,
        'entity_id',       NEW.entity_id,
        'actor_user_id',   NEW.user_id,
        'site_id',         NEW.site_id,
        'payload',         NEW.payload,
        'enqueued_at',     now()
      )
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_log_to_workflow_trigger ON data.audit_logs;
CREATE TRIGGER trg_audit_log_to_workflow_trigger
  AFTER INSERT ON data.audit_logs
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_log_to_workflow_trigger();

-- ===== 8. RLS =================================================================

ALTER TABLE data.automation_workflows          ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.automation_runs               ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.automation_step_runs          ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.automation_pending_approvals  ENABLE ROW LEVEL SECURITY;

-- --- automation_workflows -----------------------------------------------------

DROP POLICY IF EXISTS automation_workflows_select ON data.automation_workflows;
CREATE POLICY automation_workflows_select
  ON data.automation_workflows FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id() OR is_blueprint = true);

DROP POLICY IF EXISTS automation_workflows_insert ON data.automation_workflows;
CREATE POLICY automation_workflows_insert
  ON data.automation_workflows FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() -> data.active_tenant_id()::text ->> 'global_role') IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS automation_workflows_update ON data.automation_workflows;
CREATE POLICY automation_workflows_update
  ON data.automation_workflows FOR UPDATE TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() -> data.active_tenant_id()::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() -> data.active_tenant_id()::text ->> 'global_role') IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS automation_workflows_delete ON data.automation_workflows;
CREATE POLICY automation_workflows_delete
  ON data.automation_workflows FOR DELETE TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() -> data.active_tenant_id()::text ->> 'global_role') IN ('owner', 'manager')
  );

-- --- automation_runs ----------------------------------------------------------

DROP POLICY IF EXISTS automation_runs_select ON data.automation_runs;
CREATE POLICY automation_runs_select
  ON data.automation_runs FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id());

DROP POLICY IF EXISTS automation_runs_update ON data.automation_runs;
CREATE POLICY automation_runs_update
  ON data.automation_runs FOR UPDATE TO authenticated
  USING (tenant_id = data.active_tenant_id())
  WITH CHECK (tenant_id = data.active_tenant_id());

-- INSERT: cap política → authenticated no pot inserir directament (service_role bypassa RLS)

-- --- automation_step_runs -----------------------------------------------------

DROP POLICY IF EXISTS automation_step_runs_select ON data.automation_step_runs;
CREATE POLICY automation_step_runs_select
  ON data.automation_step_runs FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id());

-- INSERT/UPDATE: cap política → only service_role via RPC

-- --- automation_pending_approvals ---------------------------------------------

DROP POLICY IF EXISTS automation_pending_approvals_select ON data.automation_pending_approvals;
CREATE POLICY automation_pending_approvals_select
  ON data.automation_pending_approvals FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id());

DROP POLICY IF EXISTS automation_pending_approvals_update ON data.automation_pending_approvals;
CREATE POLICY automation_pending_approvals_update
  ON data.automation_pending_approvals FOR UPDATE TO authenticated
  USING (tenant_id = data.active_tenant_id())
  WITH CHECK (tenant_id = data.active_tenant_id());

-- ===== 9. GRANTS service_role =================================================

GRANT SELECT, INSERT, UPDATE ON data.automation_workflows         TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.automation_runs              TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.automation_step_runs         TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.automation_pending_approvals TO service_role;

-- Grants SELECT a authenticated necessaris per a les vistes security_invoker
GRANT SELECT ON data.automation_workflows         TO authenticated;
GRANT SELECT ON data.automation_runs              TO authenticated;
GRANT SELECT ON data.automation_step_runs         TO authenticated;
GRANT SELECT ON data.automation_pending_approvals TO authenticated;

-- ===== 10. VISTA api.automation_workflows =====================================

CREATE OR REPLACE VIEW api.automation_workflows
  WITH (security_invoker = true)
AS
  SELECT
    id, tenant_id, site_id, name, description,
    trigger_event, trigger_filters, steps,
    is_active, is_blueprint, source_blueprint_id,
    version, created_by, created_at, updated_at
  FROM data.automation_workflows;

GRANT SELECT ON api.automation_workflows TO authenticated, service_role;

-- ===== 11. VISTA api.automation_runs ==========================================

CREATE OR REPLACE VIEW api.automation_runs
  WITH (security_invoker = true)
AS
  SELECT *
  FROM data.automation_runs;

GRANT SELECT ON api.automation_runs TO authenticated, service_role;

-- ===== 12. VISTA api.automation_step_runs =====================================

CREATE OR REPLACE VIEW api.automation_step_runs
  WITH (security_invoker = true)
AS
  SELECT *
  FROM data.automation_step_runs;

GRANT SELECT ON api.automation_step_runs TO authenticated, service_role;

-- ===== 13. VISTA api.automation_pending_approvals =============================

CREATE OR REPLACE VIEW api.automation_pending_approvals
  WITH (security_invoker = true)
AS
  SELECT *
  FROM data.automation_pending_approvals;

GRANT SELECT ON api.automation_pending_approvals TO authenticated, service_role;

-- ===== 14. RPC api.upsert_automation_workflow ==================================
-- INSERT o UPDATE d'un workflow al tenant actiu. Requereix rol owner o manager.

CREATE OR REPLACE FUNCTION api.upsert_automation_workflow(
  p_id              uuid    DEFAULT NULL,
  p_name            text    DEFAULT NULL,
  p_description     text    DEFAULT NULL,
  p_trigger_event   text    DEFAULT NULL,
  p_trigger_filters jsonb   DEFAULT '{}',
  p_steps           jsonb   DEFAULT '[]',
  p_is_active       boolean DEFAULT false,
  p_site_id         uuid    DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_user_id   uuid := auth.uid();
  v_result_id uuid;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_id IS NULL THEN
    IF COALESCE(trim(p_name), '') = '' THEN
      RAISE EXCEPTION 'name_required';
    END IF;
    IF COALESCE(trim(p_trigger_event), '') = '' THEN
      RAISE EXCEPTION 'trigger_event_required';
    END IF;

    INSERT INTO data.automation_workflows (
      tenant_id, site_id, name, description,
      trigger_event, trigger_filters, steps,
      is_active, is_blueprint, created_by
    ) VALUES (
      v_tenant_id, p_site_id, p_name, p_description,
      p_trigger_event,
      COALESCE(p_trigger_filters, '{}'),
      COALESCE(p_steps, '[]'),
      COALESCE(p_is_active, false), false, v_user_id
    )
    RETURNING id INTO v_result_id;
  ELSE
    UPDATE data.automation_workflows
    SET
      name            = COALESCE(p_name, name),
      description     = COALESCE(p_description, description),
      trigger_event   = COALESCE(p_trigger_event, trigger_event),
      trigger_filters = COALESCE(p_trigger_filters, trigger_filters),
      steps           = COALESCE(p_steps, steps),
      is_active       = COALESCE(p_is_active, is_active),
      site_id         = COALESCE(p_site_id, site_id),
      version         = version + 1
    WHERE id = p_id
      AND tenant_id = v_tenant_id
      AND is_blueprint = false
    RETURNING id INTO v_result_id;

    IF v_result_id IS NULL THEN
      RAISE EXCEPTION 'not_found';
    END IF;
  END IF;

  RETURN v_result_id;
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_automation_workflow(uuid, text, text, text, jsonb, jsonb, boolean, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_automation_workflow(uuid, text, text, text, jsonb, jsonb, boolean, uuid) TO authenticated;

-- ===== 15. RPC api.delete_automation_workflow ==================================
-- DELETE real d'un workflow del tenant actiu. Requereix owner o manager.

CREATE OR REPLACE FUNCTION api.delete_automation_workflow(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  DELETE FROM data.automation_workflows
  WHERE id = p_id
    AND tenant_id = v_tenant_id
    AND is_blueprint = false;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.delete_automation_workflow(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.delete_automation_workflow(uuid) TO authenticated;

-- ===== 16. RPC api.install_blueprint ==========================================
-- Clona un blueprint de plataforma per al tenant actiu aplicant p_config.

CREATE OR REPLACE FUNCTION api.install_blueprint(
  p_blueprint_id uuid,
  p_config       jsonb DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_user_id   uuid := auth.uid();
  v_blueprint data.automation_workflows%ROWTYPE;
  v_new_steps jsonb;
  v_new_id    uuid;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_blueprint
  FROM data.automation_workflows
  WHERE id = p_blueprint_id AND is_blueprint = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'blueprint_not_found';
  END IF;

  -- Aplica p_config als steps que tinguin blueprint_var_key
  SELECT COALESCE(jsonb_agg(
    CASE
      WHEN (step ->> 'blueprint_var_key') IS NOT NULL
           AND p_config ? (step ->> 'blueprint_var_key')
      THEN jsonb_set(
             step,
             '{config}',
             COALESCE(step -> 'config', '{}') || (p_config -> (step ->> 'blueprint_var_key'))
           )
      ELSE step
    END
  ), v_blueprint.steps)
  INTO v_new_steps
  FROM jsonb_array_elements(v_blueprint.steps) AS step;

  INSERT INTO data.automation_workflows (
    tenant_id, site_id, name, description,
    trigger_event, trigger_filters, steps,
    is_active, is_blueprint, source_blueprint_id,
    version, created_by
  ) VALUES (
    v_tenant_id, NULL, v_blueprint.name, v_blueprint.description,
    v_blueprint.trigger_event, v_blueprint.trigger_filters, v_new_steps,
    true, false, p_blueprint_id,
    1, v_user_id
  )
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;

REVOKE ALL ON FUNCTION api.install_blueprint(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.install_blueprint(uuid, jsonb) TO authenticated;

-- ===== 17. RPC api.get_automation_dashboard ===================================
-- Dashboard agregat del motor d'automatització per al tenant actiu.

CREATE OR REPLACE FUNCTION api.get_automation_dashboard()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_result    jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  SELECT jsonb_build_object(
    'runs_running',         (
      SELECT count(*)::int FROM data.automation_runs
      WHERE tenant_id = v_tenant_id AND status = 'RUNNING'
    ),
    'runs_waiting_human',   (
      SELECT count(*)::int FROM data.automation_runs
      WHERE tenant_id = v_tenant_id AND status = 'WAITING_HUMAN'
    ),
    'runs_failed',          (
      SELECT count(*)::int FROM data.automation_runs
      WHERE tenant_id = v_tenant_id AND status = 'FAILED'
    ),
    'runs_completed_today', (
      SELECT count(*)::int FROM data.automation_runs
      WHERE tenant_id = v_tenant_id
        AND status = 'COMPLETED'
        AND completed_at >= current_date::timestamptz
    ),
    'pending_approvals',    (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id',                  ap.id,
          'title',               COALESCE(ap.title, 'Aprovació requerida'),
          'workflow_name',       w.name,
          'workflow_run_id',     ap.workflow_run_id,
          'step_run_id',         ap.step_run_id,
          'assigned_to_role',    ap.assigned_to_role,
          'assigned_to_user_id', ap.assigned_to_user_id,
          'created_at',          ap.created_at,
          'due_at',              ap.due_at
        ) ORDER BY ap.created_at DESC
      ), '[]'::jsonb)
      FROM (
        SELECT ap.*
        FROM data.automation_pending_approvals ap
        WHERE ap.tenant_id = v_tenant_id AND ap.status = 'PENDING'
        ORDER BY ap.created_at DESC
        LIMIT 10
      ) ap
      JOIN data.automation_runs      r ON r.id = ap.workflow_run_id
      JOIN data.automation_workflows w ON w.id = r.workflow_id
    ),
    'recent_failures',      (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id',                  r.id,
          'workflow_name',       w.name,
          'error',               r.error,
          'trigger_entity_type', r.trigger_entity_type,
          'trigger_entity_id',   r.trigger_entity_id,
          'updated_at',          r.updated_at
        ) ORDER BY r.updated_at DESC
      ), '[]'::jsonb)
      FROM (
        SELECT r.*
        FROM data.automation_runs r
        WHERE r.tenant_id = v_tenant_id AND r.status = 'FAILED'
        ORDER BY r.updated_at DESC
        LIMIT 5
      ) r
      JOIN data.automation_workflows w ON w.id = r.workflow_id
    ),
    'recent_runs',          (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id',                  r.id,
          'workflow_name',       w.name,
          'status',              r.status,
          'trigger_event',       r.trigger_event,
          'trigger_entity_type', r.trigger_entity_type,
          'created_at',          r.created_at,
          'completed_at',        r.completed_at
        ) ORDER BY r.created_at DESC
      ), '[]'::jsonb)
      FROM (
        SELECT r.*
        FROM data.automation_runs r
        WHERE r.tenant_id = v_tenant_id
        ORDER BY r.created_at DESC
        LIMIT 20
      ) r
      JOIN data.automation_workflows w ON w.id = r.workflow_id
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION api.get_automation_dashboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_automation_dashboard() TO authenticated;

-- ===== 18. RPCs de workflow run (service_role only) ===========================

-- ---- api.create_automation_run_service ---------------------------------------

CREATE OR REPLACE FUNCTION api.create_automation_run_service(
  p_workflow_id         uuid,
  p_tenant_id           uuid,
  p_site_id             uuid,
  p_trigger_event       text,
  p_trigger_entity_type text,
  p_trigger_entity_id   uuid,
  p_context             jsonb DEFAULT '{}'
)
RETURNS uuid
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
    workflow_id, tenant_id, site_id,
    trigger_event, trigger_entity_type, trigger_entity_id,
    context, status
  ) VALUES (
    p_workflow_id, p_tenant_id, p_site_id,
    p_trigger_event, p_trigger_entity_type, p_trigger_entity_id,
    COALESCE(p_context, '{}'), 'RUNNING'
  )
  RETURNING id INTO v_run_id;

  RETURN v_run_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_automation_run_service(uuid, uuid, uuid, text, text, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_automation_run_service(uuid, uuid, uuid, text, text, uuid, jsonb) TO service_role;

-- ---- api.create_automation_step_run_service ----------------------------------

CREATE OR REPLACE FUNCTION api.create_automation_step_run_service(
  p_workflow_run_id uuid,
  p_tenant_id       uuid,
  p_step_id         text,
  p_step_name       text,
  p_step_type       text,
  p_input           jsonb DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_step_run_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  INSERT INTO data.automation_step_runs (
    workflow_run_id, tenant_id,
    step_id, step_name, step_type,
    input, status, started_at
  ) VALUES (
    p_workflow_run_id, p_tenant_id,
    p_step_id, p_step_name, p_step_type,
    COALESCE(p_input, '{}'), 'RUNNING', now()
  )
  RETURNING id INTO v_step_run_id;

  RETURN v_step_run_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_automation_step_run_service(uuid, uuid, text, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_automation_step_run_service(uuid, uuid, text, text, text, jsonb) TO service_role;

-- ---- api.update_automation_step_run_service ----------------------------------

CREATE OR REPLACE FUNCTION api.update_automation_step_run_service(
  p_step_run_id    uuid,
  p_status         data.automation_step_status,
  p_output         jsonb   DEFAULT NULL,
  p_error          text    DEFAULT NULL,
  p_attempt_number integer DEFAULT NULL
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
    status         = p_status,
    output         = COALESCE(p_output, output),
    error          = COALESCE(p_error, error),
    attempt_number = COALESCE(p_attempt_number, attempt_number),
    started_at     = CASE
                       WHEN p_status = 'RUNNING' AND started_at IS NULL THEN now()
                       ELSE started_at
                     END,
    completed_at   = CASE
                       WHEN p_status IN ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED') THEN now()
                       ELSE completed_at
                     END
  WHERE id = p_step_run_id;
END;
$$;

REVOKE ALL ON FUNCTION api.update_automation_step_run_service(uuid, data.automation_step_status, jsonb, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_automation_step_run_service(uuid, data.automation_step_status, jsonb, text, integer) TO service_role;

-- ---- api.update_automation_run_service ---------------------------------------

CREATE OR REPLACE FUNCTION api.update_automation_run_service(
  p_run_id          uuid,
  p_status          data.automation_run_status,
  p_current_step_id text DEFAULT NULL,
  p_error           text DEFAULT NULL
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
    status          = p_status,
    current_step_id = COALESCE(p_current_step_id, current_step_id),
    error           = COALESCE(p_error, error),
    completed_at    = CASE
                        WHEN p_status IN ('COMPLETED', 'FAILED', 'CANCELLED') THEN now()
                        ELSE completed_at
                      END
  WHERE id = p_run_id;
END;
$$;

REVOKE ALL ON FUNCTION api.update_automation_run_service(uuid, data.automation_run_status, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_automation_run_service(uuid, data.automation_run_status, text, text) TO service_role;

-- ===== 19. RPC api.resolve_automation_approval ================================
-- Aprova, rebutja o reassigna una aprovació pendent.

CREATE OR REPLACE FUNCTION api.resolve_automation_approval(
  p_approval_id         uuid,
  p_resolution          text,
  p_comment             text DEFAULT NULL,
  p_reassign_to_user_id uuid DEFAULT NULL
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
  v_global_role text;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF p_resolution NOT IN ('approved', 'rejected', 'reassigned') THEN
    RAISE EXCEPTION 'invalid_resolution: %', p_resolution;
  END IF;

  SELECT * INTO v_approval
  FROM data.automation_pending_approvals
  WHERE id = p_approval_id
    AND tenant_id = v_tenant_id
    AND status = 'PENDING';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'approval_not_found';
  END IF;

  v_global_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';

  -- L'usuari ha de ser el designat o tenir rol owner/manager
  IF v_approval.assigned_to_user_id IS NOT NULL
     AND v_approval.assigned_to_user_id <> v_user_id
     AND v_global_role NOT IN ('owner', 'manager')
  THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF v_approval.assigned_to_user_id IS NULL AND v_global_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  -- Reassignació: actualitza el designat sense tancar l'aprovació
  IF p_resolution = 'reassigned' THEN
    IF p_reassign_to_user_id IS NULL THEN
      RAISE EXCEPTION 'reassign_user_required';
    END IF;

    UPDATE data.automation_pending_approvals
    SET
      assigned_to_user_id = p_reassign_to_user_id,
      resolution_comment  = COALESCE(p_comment, resolution_comment),
      status              = 'PENDING'
    WHERE id = p_approval_id;

    RETURN;
  END IF;

  -- Approved | Rejected: tanca l'aprovació
  UPDATE data.automation_pending_approvals
  SET
    status             = CASE p_resolution
                           WHEN 'approved' THEN 'APPROVED'
                           ELSE                 'REJECTED'
                         END::data.automation_approval_status,
    resolved_by        = v_user_id,
    resolved_at        = now(),
    resolution_comment = p_comment
  WHERE id = p_approval_id;

  UPDATE data.automation_step_runs
  SET
    status           = CASE p_resolution
                         WHEN 'approved' THEN 'COMPLETED'
                         ELSE                 'FAILED'
                       END::data.automation_step_status,
    approved_by      = v_user_id,
    approved_at      = now(),
    approval_comment = p_comment,
    completed_at     = now()
  WHERE id = v_approval.step_run_id;

  IF p_resolution = 'approved' THEN
    UPDATE data.automation_runs
    SET status = 'RUNNING'
    WHERE id = v_approval.workflow_run_id;

    -- Encua la represa del run per al worker
    PERFORM pgmq.send(
      'automation_queue',
      jsonb_build_object(
        'task',          'resume_run',
        'run_id',        v_approval.workflow_run_id,
        'tenant_id',     v_tenant_id,
        'approved_step', v_approval.step_run_id,
        'enqueued_at',   now()
      )
    );
  ELSE
    -- Rejected: marca el run com FAILED
    UPDATE data.automation_runs
    SET
      status       = 'FAILED',
      error        = 'Approval rejected by ' || v_user_id::text
                     || COALESCE(': ' || p_comment, ''),
      completed_at = now()
    WHERE id = v_approval.workflow_run_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_automation_approval(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_automation_approval(uuid, text, text, uuid) TO authenticated;

-- ===== 20. RPC api.retry_automation_run =======================================
-- Reseteja un run FAILED i reencua el darrer step fallat.

CREATE OR REPLACE FUNCTION api.retry_automation_run(p_run_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_tenant_id  uuid := data.active_tenant_id();
  v_user_id    uuid := auth.uid();
  v_run        data.automation_runs%ROWTYPE;
  v_failed_step data.automation_step_runs%ROWTYPE;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_run
  FROM data.automation_runs
  WHERE id = p_run_id AND tenant_id = v_tenant_id AND status = 'FAILED';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'run_not_found_or_not_failed';
  END IF;

  UPDATE data.automation_runs
  SET status = 'RUNNING', error = NULL
  WHERE id = p_run_id;

  -- Troba el darrer step fallat
  SELECT * INTO v_failed_step
  FROM data.automation_step_runs
  WHERE workflow_run_id = p_run_id AND status = 'FAILED'
  ORDER BY created_at DESC
  LIMIT 1;

  IF FOUND THEN
    UPDATE data.automation_step_runs
    SET status = 'PENDING', error = NULL, completed_at = NULL
    WHERE id = v_failed_step.id;

    PERFORM pgmq.send(
      'automation_queue',
      jsonb_build_object(
        'task',        'execute_step',
        'run_id',      p_run_id,
        'tenant_id',   v_tenant_id,
        'step_run_id', v_failed_step.id,
        'step_id',     v_failed_step.step_id,
        'step_type',   v_failed_step.step_type,
        'retry',       true,
        'enqueued_at', now()
      )
    );
  ELSE
    -- Cap step fallat, reencua el run des del principi
    PERFORM pgmq.send(
      'automation_queue',
      jsonb_build_object(
        'task',        'resume_run',
        'run_id',      p_run_id,
        'tenant_id',   v_tenant_id,
        'retry',       true,
        'enqueued_at', now()
      )
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.retry_automation_run(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.retry_automation_run(uuid) TO authenticated;

-- ===== 21. RPC api.cancel_automation_run =====================================
-- Cancel·la un run actiu i tots els step runs pendents.

CREATE OR REPLACE FUNCTION api.cancel_automation_run(p_run_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.automation_runs
  SET
    status       = 'CANCELLED',
    completed_at = now()
  WHERE id = p_run_id
    AND tenant_id = v_tenant_id
    AND status NOT IN ('COMPLETED', 'CANCELLED', 'FAILED');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'run_not_found_or_not_cancellable';
  END IF;

  -- Marca tots els step runs actius com CANCELLED
  UPDATE data.automation_step_runs
  SET
    status       = 'CANCELLED',
    completed_at = now()
  WHERE workflow_run_id = p_run_id
    AND status IN ('PENDING', 'RUNNING', 'WAITING_HUMAN', 'WAITING_TIMER');
END;
$$;

REVOKE ALL ON FUNCTION api.cancel_automation_run(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.cancel_automation_run(uuid) TO authenticated;

-- ===== 22. pg_cron: dispatcher diari de triggers de data =====================
-- Programa 'automation_date_triggers' cada dia a les 07:00 UTC.
-- La Edge Function 'process-date-triggers' s'implementa per separat.

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'automation_date_triggers') THEN
      PERFORM cron.unschedule('automation_date_triggers');
    END IF;

    PERFORM cron.schedule(
      'automation_date_triggers',
      '0 7 * * *',
      $cron$
        SELECT net.http_post(
          url     := current_setting('app.supabase_url', true) || '/functions/v1/process-date-triggers',
          headers := jsonb_build_object(
            'Authorization', 'Bearer ' || current_setting('app.service_role_key', true)
          ),
          body    := '{}'::jsonb
        );
      $cron$
    );
  END IF;
END $$;

-- ===== 23. RPC api.pgmq_send — wrapper segur per a Edge Functions ============
-- Permet encuar a automation_queue i workflow_trigger_queue sense expor PGMQ.

CREATE OR REPLACE FUNCTION api.pgmq_send(p_queue text, p_message jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgmq, data, public
AS $$
BEGIN
  IF p_queue NOT IN ('automation_queue', 'workflow_trigger_queue') THEN
    RAISE EXCEPTION 'pgmq_send: queue % not allowed', p_queue;
  END IF;
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  RETURN pgmq.send(p_queue, p_message);
END;
$$;

REVOKE ALL ON FUNCTION api.pgmq_send(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.pgmq_send(text, jsonb) TO service_role;

-- ===== 24. NOTIFY =============================================================

NOTIFY pgrst, 'reload schema';
