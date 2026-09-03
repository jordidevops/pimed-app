-- =============================================================================
-- Close ≠ Publish: client report publish timestamp + RPC
-- Snapshot is generated only on publish; Feina mutations blocked thereafter.
-- =============================================================================

ALTER TABLE data.projects
  ADD COLUMN IF NOT EXISTS client_report_published_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS client_report_published_by uuid NULL
    REFERENCES auth.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN data.projects.client_report_published_at IS
  'When the client intervention report (part públic) was published; NULL = not published yet.';
COMMENT ON COLUMN data.projects.client_report_published_by IS
  'User who published the client report.';

CREATE INDEX IF NOT EXISTS idx_projects_client_report_published
  ON data.projects (tenant_id, client_report_published_at)
  WHERE client_report_published_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Helper: project work is locked after client report publish
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.project_work_is_locked(p_project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.projects p
    WHERE p.id = p_project_id
      AND p.client_report_published_at IS NOT NULL
  );
$$;

GRANT EXECUTE ON FUNCTION data.project_work_is_locked(uuid) TO authenticated, service_role;

-- Execute right: access + not cancelled + not published
CREATE OR REPLACE FUNCTION data.can_execute_project(p_project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT data.can_access_project(p_project_id)
    AND EXISTS (
      SELECT 1 FROM data.projects p
      WHERE p.id = p_project_id
        AND p.status IS DISTINCT FROM 'cancelled'
        AND p.client_report_published_at IS NULL
    );
$$;

GRANT EXECUTE ON FUNCTION data.can_execute_project(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- api.projects: expose publish columns
-- ---------------------------------------------------------------------------
DROP RULE IF EXISTS "api_projects_insert" ON api.projects;
DROP RULE IF EXISTS "api_projects_delete" ON api.projects;

CREATE OR REPLACE VIEW api.projects
  WITH (security_invoker = true) AS
  SELECT
    p.id,
    p.tenant_id,
    p.type,
    p.name,
    p.description,
    p.status,
    p.visibility,
    p.department_id,
    p.site_id,
    p.location_id,
    p.client_id,
    p.planned_start,
    p.planned_end,
    p.created_by,
    p.created_at,
    p.updated_at,
    (
      SELECT COUNT(*)::int
      FROM data.tasks t
      WHERE t.project_id = p.id
    ) AS task_count,
    (
      SELECT COUNT(*)::int
      FROM data.tasks t
      WHERE t.project_id = p.id
        AND t.status     <> 'done'
    ) AS pending_task_count,
    (
      SELECT COUNT(*)::int
      FROM data.project_members pm
      WHERE pm.project_id = p.id
    ) AS member_count,
    p.asset_id,
    p.contact_site_id,
    p.work_notes_html,
    p.source_project_id,
    p.source_run_id,
    p.visit_intent,
    p.client_report_published_at,
    p.client_report_published_by
  FROM data.projects p;

GRANT SELECT ON api.projects TO authenticated;

CREATE RULE "api_projects_insert" AS ON INSERT TO api.projects
  DO INSTEAD
  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, asset_id, client_id, contact_site_id,
    planned_start, planned_end, created_by, work_notes_html,
    source_project_id, source_run_id, visit_intent
  )
  VALUES (
    NEW.tenant_id,
    COALESCE(NEW.type, 'internal'),
    NEW.name,
    NEW.description,
    COALESCE(NEW.status, 'draft'),
    COALESCE(NEW.visibility, 'company'),
    NEW.department_id,
    NEW.site_id,
    NEW.location_id,
    NEW.asset_id,
    NEW.client_id,
    NEW.contact_site_id,
    NEW.planned_start,
    NEW.planned_end,
    COALESCE(NEW.created_by, auth.uid()),
    NEW.work_notes_html,
    NEW.source_project_id,
    NEW.source_run_id,
    COALESCE(NEW.visit_intent, 'generic')
  );

GRANT INSERT ON api.projects TO authenticated;
REVOKE UPDATE ON api.projects FROM authenticated;

CREATE RULE "api_projects_delete" AS ON DELETE TO api.projects
  DO INSTEAD
  DELETE FROM data.projects WHERE id = OLD.id;

GRANT DELETE ON api.projects TO authenticated;

-- ---------------------------------------------------------------------------
-- Publish RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.publish_project_client_report(
  p_project_id uuid,
  p_locale text DEFAULT NULL,
  p_bypass_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public, api
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_payload jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_project.client_report_published_at IS NOT NULL THEN
    RAISE EXCEPTION 'client_report_already_published'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF v_project.status NOT IN ('completed', 'on_hold') THEN
    RAISE EXCEPTION 'client_report_publish_requires_closed_visit'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Still mutable here (published_at is null) so can_execute_project passes.
  v_payload := api.build_and_persist_checklist_public_report(
    p_project_id,
    p_locale,
    p_bypass_reason
  );

  UPDATE data.projects
  SET
    client_report_published_at = now(),
    client_report_published_by = auth.uid(),
    updated_at = now()
  WHERE id = p_project_id;

  RETURN v_payload || jsonb_build_object(
    'published_at', now(),
    'published_by', auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION api.publish_project_client_report(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.publish_project_client_report(uuid, text, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Work notes: block after publish
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_project_work_notes(
  p_id   uuid,
  p_html text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT data.can_access_project(p_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF data.project_work_is_locked(p_id) THEN
    RAISE EXCEPTION 'project_work_locked_after_publish'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  UPDATE data.projects
  SET
    work_notes_html = NULLIF(btrim(COALESCE(p_html, '')), ''),
    updated_at      = now()
  WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_project_work_notes(uuid, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- start_work_log: block punch on closed / published visits
-- ---------------------------------------------------------------------------
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
  v_status       text;
  v_published_at timestamptz;
  v_log_id       uuid;
  v_anomalies    text[];
  v_employee_id  uuid;
BEGIN
  SELECT p.tenant_id, p.site_id, p.status, p.client_report_published_at
    INTO v_tenant_id, v_site_id, v_status, v_published_at
  FROM data.projects p
  WHERE p.id = p_project_id
    AND data.can_access_project(p_project_id);

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_project_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_status IN ('completed', 'cancelled', 'on_hold')
     OR v_published_at IS NOT NULL THEN
    RAISE EXCEPTION 'work_log_blocked_visit_closed'
      USING ERRCODE = 'check_violation';
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

  v_employee_id := data.resolve_employee_id_for_user(v_tenant_id, v_user_id);

  IF data.is_feature_enabled(v_tenant_id, 'employee_readiness_gate_enabled') THEN
    IF v_employee_id IS NOT NULL THEN
      PERFORM data.assert_employee_dispatch_eligible(
        v_employee_id,
        COALESCE((p_check_in AT TIME ZONE 'UTC')::date, CURRENT_DATE)
      );
    END IF;
  END IF;

  INSERT INTO data.work_logs (
    tenant_id, site_id, project_id, task_id,
    worker_id, employee_id, client_op_id, status,
    check_in, check_in_geo, check_in_received_at,
    location_permission, anomaly_codes, notes
  )
  VALUES (
    v_tenant_id, v_site_id, p_project_id, p_task_id,
    v_user_id, v_employee_id, p_client_op_id, 'open',
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
      'employee_id',   v_employee_id,
      'check_in',      p_check_in,
      'anomaly_codes', v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'work_log_id', v_log_id,
    'status',      'created',
    'employee_id', v_employee_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.start_work_log(uuid, uuid, uuid, timestamptz, jsonb, text, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
