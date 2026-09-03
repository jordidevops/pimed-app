-- =============================================================================
-- Phase 2: tasks linked to deferred checklist findings
-- =============================================================================

ALTER TABLE data.tasks
  ADD COLUMN IF NOT EXISTS source_checklist_run_item_id uuid
    REFERENCES data.checklist_run_items(id) ON DELETE SET NULL;

COMMENT ON COLUMN data.tasks.source_checklist_run_item_id IS
  'Checklist run item (finding) that originated this follow-up task. '
  'One open follow-up task per item (unique when not null).';

CREATE UNIQUE INDEX IF NOT EXISTS uq_tasks_source_checklist_run_item
  ON data.tasks (source_checklist_run_item_id)
  WHERE source_checklist_run_item_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tasks_project_source_checklist
  ON data.tasks (project_id)
  WHERE source_checklist_run_item_id IS NOT NULL;

DROP VIEW IF EXISTS api.tasks CASCADE;
CREATE VIEW api.tasks
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    project_id,
    title,
    status,
    assignee_id,
    position,
    due_date,
    created_at,
    updated_at,
    assignee_employee_id,
    source_checklist_run_item_id
  FROM data.tasks;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.tasks TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Ensure a follow-up task exists for a deferred finding (idempotent)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.ensure_deferred_task_for_item(p_item_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_item data.checklist_run_items%ROWTYPE;
  v_run data.checklist_runs%ROWTYPE;
  v_task_id uuid;
  v_title text;
  v_pos int;
BEGIN
  SELECT * INTO v_item FROM data.checklist_run_items WHERE id = p_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'item_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_run FROM data.checklist_runs WHERE id = v_item.run_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'run_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_item.answer_semantic IS DISTINCT FROM 'fail'
     AND NOT COALESCE(v_item.answer_blocks_closeout, false) THEN
    RAISE EXCEPTION 'task_only_for_findings' USING ERRCODE = 'check_violation';
  END IF;

  SELECT t.id INTO v_task_id
  FROM data.tasks t
  WHERE t.source_checklist_run_item_id = p_item_id
  LIMIT 1;

  IF v_task_id IS NOT NULL THEN
    RETURN v_task_id;
  END IF;

  v_title := left(
    trim(
      BOTH ' —'
      FROM concat_ws(
        ' — ',
        COALESCE(NULLIF(btrim(COALESCE(v_item.answer_label, '')), ''), 'NC'),
        NULLIF(btrim(COALESCE(v_item.title, '')), '')
      )
    ),
    200
  );
  IF v_title IS NULL OR btrim(v_title) = '' THEN
    v_title := 'Troballa diferida';
  END IF;

  SELECT COALESCE(MAX(position), -1) + 1
  INTO v_pos
  FROM data.tasks
  WHERE project_id = v_run.project_id;

  INSERT INTO data.tasks (
    tenant_id,
    project_id,
    title,
    status,
    position,
    source_checklist_run_item_id
  )
  VALUES (
    v_run.tenant_id,
    v_run.project_id,
    v_title,
    'pending',
    v_pos,
    p_item_id
  )
  RETURNING id INTO v_task_id;

  RETURN v_task_id;
EXCEPTION
  WHEN unique_violation THEN
    SELECT t.id INTO v_task_id
    FROM data.tasks t
    WHERE t.source_checklist_run_item_id = p_item_id
    LIMIT 1;
    RETURN v_task_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.ensure_checklist_deferred_task(p_item_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_item data.checklist_run_items%ROWTYPE;
  v_run data.checklist_runs%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_item FROM data.checklist_run_items WHERE id = p_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'item_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_run FROM data.checklist_runs WHERE id = v_item.run_id;
  IF NOT data.can_execute_project(v_run.project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_run.status = 'superseded' THEN
    RAISE EXCEPTION 'run_superseded' USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF COALESCE(v_item.resolution_status, 'open') IS DISTINCT FROM 'deferred' THEN
    RAISE EXCEPTION 'resolution_must_be_deferred' USING ERRCODE = 'check_violation';
  END IF;

  RETURN data.ensure_deferred_task_for_item(p_item_id);
END;
$$;

GRANT EXECUTE ON FUNCTION api.ensure_checklist_deferred_task(uuid)
  TO authenticated, service_role;

-- When marking deferred, create the follow-up task atomically
CREATE OR REPLACE FUNCTION api.set_checklist_run_item_resolution(
  p_item_id uuid,
  p_resolution_status text,
  p_resolution_reason text DEFAULT NULL,
  p_resolution_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_item data.checklist_run_items%ROWTYPE;
  v_run data.checklist_runs%ROWTYPE;
  v_status text := NULLIF(btrim(COALESCE(p_resolution_status, '')), '');
  v_note text := NULLIF(btrim(COALESCE(p_resolution_note, '')), '');
  v_reason text := NULLIF(btrim(COALESCE(p_resolution_reason, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_status IS NULL OR v_status NOT IN (
    'open', 'resolved_same_visit', 'deferred', 'closed_unresolved'
  ) THEN
    RAISE EXCEPTION 'invalid_resolution_status' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_item FROM data.checklist_run_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'item_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_run FROM data.checklist_runs WHERE id = v_item.run_id;
  IF NOT data.can_execute_project(v_run.project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_run.status = 'superseded' THEN
    RAISE EXCEPTION 'run_superseded' USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF v_item.answer_semantic IS DISTINCT FROM 'fail'
     AND NOT COALESCE(v_item.answer_blocks_closeout, false) THEN
    RAISE EXCEPTION 'resolution_only_for_findings' USING ERRCODE = 'check_violation';
  END IF;

  IF v_status = 'closed_unresolved' AND v_note IS NULL THEN
    RAISE EXCEPTION 'resolution_note_required' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.checklist_run_items
  SET
    resolution_status = v_status,
    resolution_reason = v_reason,
    resolution_note = v_note,
    resolved_at = CASE WHEN v_status = 'open' THEN NULL ELSE now() END,
    resolved_by = CASE WHEN v_status = 'open' THEN NULL ELSE auth.uid() END,
    updated_at = now()
  WHERE id = p_item_id;

  IF v_status = 'deferred' THEN
    PERFORM data.ensure_deferred_task_for_item(p_item_id);
  END IF;

  RETURN p_item_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_checklist_run_item_resolution(uuid, text, text, text)
  TO authenticated, service_role;

-- Closeout: deferred findings require a linked task
CREATE OR REPLACE FUNCTION api.checklist_closeout_blockers(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

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
