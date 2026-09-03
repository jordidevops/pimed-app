-- =============================================================================
-- Phase 3: follow-up work orders from inspection visits
-- =============================================================================

ALTER TABLE data.projects
  ADD COLUMN IF NOT EXISTS source_project_id uuid
    REFERENCES data.projects(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source_run_id uuid
    REFERENCES data.checklist_runs(id) ON DELETE SET NULL;

ALTER TABLE data.projects
  DROP CONSTRAINT IF EXISTS projects_source_project_not_self;

ALTER TABLE data.projects
  ADD CONSTRAINT projects_source_project_not_self
  CHECK (source_project_id IS NULL OR source_project_id IS DISTINCT FROM id);

CREATE INDEX IF NOT EXISTS idx_projects_source_project_id
  ON data.projects (source_project_id)
  WHERE source_project_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_projects_source_run_id
  ON data.projects (source_run_id)
  WHERE source_run_id IS NOT NULL;

COMMENT ON COLUMN data.projects.source_project_id IS
  'Parent visit / work order this project follows up (corrective WO from inspection).';

COMMENT ON COLUMN data.projects.source_run_id IS
  'Optional checklist run that motivated the follow-up work order.';

-- Refresh api.projects (append columns at end; preserve insert/delete rules)
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
    p.source_run_id
  FROM data.projects p;

GRANT SELECT ON api.projects TO authenticated;

CREATE RULE "api_projects_insert" AS ON INSERT TO api.projects
  DO INSTEAD
  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, asset_id, client_id, contact_site_id,
    planned_start, planned_end, created_by, work_notes_html,
    source_project_id, source_run_id
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
    NEW.source_run_id
  );

GRANT INSERT ON api.projects TO authenticated;
REVOKE UPDATE ON api.projects FROM authenticated;

CREATE RULE "api_projects_delete" AS ON DELETE TO api.projects
  DO INSTEAD
  DELETE FROM data.projects WHERE id = OLD.id;

GRANT DELETE ON api.projects TO authenticated;

-- ---------------------------------------------------------------------------
-- Create follow-up WO: copy context, optionally move open finding tasks
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_follow_up_work_order(
  p_source_project_id uuid,
  p_name text DEFAULT NULL,
  p_move_open_tasks boolean DEFAULT true,
  p_source_run_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_source data.projects%ROWTYPE;
  v_new_id uuid;
  v_name text;
  v_moved int := 0;
  v_member record;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_source FROM data.projects WHERE id = p_source_project_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.can_execute_project(p_source_project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_source.type NOT IN ('work_order', 'maintenance') THEN
    RAISE EXCEPTION 'follow_up_requires_field_project' USING ERRCODE = 'check_violation';
  END IF;

  IF v_source.site_id IS NULL THEN
    RAISE EXCEPTION 'work_order_requires_site_id' USING ERRCODE = 'check_violation';
  END IF;

  IF p_source_run_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM data.checklist_runs r
      WHERE r.id = p_source_run_id
        AND r.project_id = p_source_project_id
    ) THEN
      RAISE EXCEPTION 'source_run_mismatch' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  v_name := NULLIF(btrim(COALESCE(p_name, '')), '');
  IF v_name IS NULL THEN
    v_name := left('Seguiment: ' || COALESCE(NULLIF(btrim(v_source.name), ''), 'OS'), 200);
  END IF;

  INSERT INTO data.projects (
    tenant_id,
    type,
    name,
    description,
    status,
    visibility,
    department_id,
    site_id,
    location_id,
    asset_id,
    client_id,
    contact_site_id,
    planned_start,
    planned_end,
    created_by,
    source_project_id,
    source_run_id
  )
  VALUES (
    v_source.tenant_id,
    'work_order',
    v_name,
    left(
      COALESCE(
        NULLIF(btrim(COALESCE(v_source.description, '')), ''),
        'Ordre de seguiment generada des de la visita origen.'
      ),
      2000
    ),
    'in_progress',
    COALESCE(v_source.visibility, 'company'),
    v_source.department_id,
    v_source.site_id,
    v_source.location_id,
    v_source.asset_id,
    v_source.client_id,
    v_source.contact_site_id,
    NULL,
    NULL,
    v_user_id,
    p_source_project_id,
    p_source_run_id
  )
  RETURNING id INTO v_new_id;

  INSERT INTO data.project_members (project_id, user_id, role)
  VALUES (v_new_id, v_user_id, 'manager')
  ON CONFLICT (project_id, user_id) DO NOTHING;

  FOR v_member IN
    SELECT user_id, role
    FROM data.project_members
    WHERE project_id = p_source_project_id
      AND user_id IS DISTINCT FROM v_user_id
  LOOP
    INSERT INTO data.project_members (project_id, user_id, role)
    VALUES (v_new_id, v_member.user_id, v_member.role)
    ON CONFLICT (project_id, user_id) DO NOTHING;
  END LOOP;

  IF COALESCE(p_move_open_tasks, true) THEN
    WITH moved AS (
      UPDATE data.tasks t
      SET
        project_id = v_new_id,
        updated_at = now()
      WHERE t.project_id = p_source_project_id
        AND t.source_checklist_run_item_id IS NOT NULL
        AND t.status IS DISTINCT FROM 'done'
      RETURNING t.id
    )
    SELECT COUNT(*)::int INTO v_moved FROM moved;
  END IF;

  IF v_source.status IS DISTINCT FROM 'cancelled'
     AND v_source.status IS DISTINCT FROM 'completed' THEN
    UPDATE data.projects
    SET status = 'on_hold', updated_at = now()
    WHERE id = p_source_project_id
      AND status IS DISTINCT FROM 'on_hold';
  END IF;

  RETURN jsonb_build_object(
    'project_id', v_new_id,
    'moved_task_count', COALESCE(v_moved, 0),
    'source_project_id', p_source_project_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_follow_up_work_order(uuid, text, boolean, uuid)
  TO authenticated, service_role;

-- Closeout: deferred OK if linked task OR any non-cancelled follow-up WO exists
CREATE OR REPLACE FUNCTION api.checklist_closeout_blockers(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_result jsonb;
  v_has_follow_up boolean;
BEGIN
  IF NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM data.projects fp
    WHERE fp.source_project_id = p_project_id
      AND fp.status IS DISTINCT FROM 'cancelled'
  )
  INTO v_has_follow_up;

  SELECT COALESCE(jsonb_agg(x.obj ORDER BY x.run_name, x.position), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      r.name_snapshot AS run_name,
      i.position AS position,
      jsonb_build_object(
        'run_id', r.id,
        'run_name', r.name_snapshot,
        'item_id', i.id,
        'title', i.title,
        'reason', CASE
          WHEN i.is_required
               AND (
                 (i.response_type = 'checkbox' AND i.value_bool IS NULL)
                 OR (i.response_type = 'single_choice' AND i.value_option_id IS NULL)
               )
            THEN 'required_empty'
          WHEN i.value_option_id IS NOT NULL
               AND EXISTS (
                 SELECT 1
                 FROM data.checklist_response_options o
                 WHERE o.id = i.value_option_id
                   AND o.requires_note
               )
               AND NULLIF(btrim(COALESCE(i.note, '')), '') IS NULL
            THEN 'missing_note'
          WHEN (
                 i.answer_semantic = 'fail'
                 OR COALESCE(i.answer_blocks_closeout, false)
               )
               AND COALESCE(i.resolution_status, 'open') = 'open'
            THEN 'open_fail'
          WHEN (
                 i.answer_semantic = 'fail'
                 OR COALESCE(i.answer_blocks_closeout, false)
               )
               AND i.resolution_status = 'closed_unresolved'
               AND NULLIF(btrim(COALESCE(i.resolution_note, '')), '') IS NULL
            THEN 'missing_resolution_note'
          WHEN (
                 i.answer_semantic = 'fail'
                 OR COALESCE(i.answer_blocks_closeout, false)
               )
               AND i.resolution_status = 'deferred'
               AND NOT v_has_follow_up
               AND NOT EXISTS (
                 SELECT 1
                 FROM data.tasks t
                 WHERE t.source_checklist_run_item_id = i.id
               )
            THEN 'deferred_without_task'
          ELSE 'blocking_fail'
        END
      ) AS obj
    FROM data.checklist_runs r
    JOIN data.checklist_run_items i ON i.run_id = r.id
    WHERE r.project_id = p_project_id
      AND r.status IN ('pending','in_progress','completed')
      AND (
        (
          i.is_required
          AND (
            (i.response_type = 'checkbox' AND i.value_bool IS NULL)
            OR (i.response_type = 'single_choice' AND i.value_option_id IS NULL)
          )
        )
        OR (
          i.value_option_id IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM data.checklist_response_options o
            WHERE o.id = i.value_option_id
              AND o.requires_note
          )
          AND NULLIF(btrim(COALESCE(i.note, '')), '') IS NULL
        )
        OR (
          (i.answer_semantic = 'fail' OR COALESCE(i.answer_blocks_closeout, false))
          AND COALESCE(i.resolution_status, 'open') = 'open'
        )
        OR (
          (i.answer_semantic = 'fail' OR COALESCE(i.answer_blocks_closeout, false))
          AND i.resolution_status = 'closed_unresolved'
          AND NULLIF(btrim(COALESCE(i.resolution_note, '')), '') IS NULL
        )
        OR (
          (i.answer_semantic = 'fail' OR COALESCE(i.answer_blocks_closeout, false))
          AND i.resolution_status = 'deferred'
          AND NOT v_has_follow_up
          AND NOT EXISTS (
            SELECT 1
            FROM data.tasks t
            WHERE t.source_checklist_run_item_id = i.id
          )
        )
      )
  ) x;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.checklist_closeout_blockers(uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
