-- =============================================================================
-- Deferred tasks: short title + dedicated finding / disposition note columns
-- =============================================================================

ALTER TABLE data.tasks
  ADD COLUMN IF NOT EXISTS source_finding_note text,
  ADD COLUMN IF NOT EXISTS source_disposition_note text;

COMMENT ON COLUMN data.tasks.source_finding_note IS
  'Checklist answer note copied when the deferred finding task was created/refreshed.';
COMMENT ON COLUMN data.tasks.source_disposition_note IS
  'Checklist resolution_note copied when the deferred finding task was created/refreshed.';

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
    source_checklist_run_item_id,
    notes_html,
    source_finding_note,
    source_disposition_note
  FROM data.tasks;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.tasks TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.ensure_deferred_task_for_item(p_item_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_item data.checklist_run_items%ROWTYPE;
  v_run data.checklist_runs%ROWTYPE;
  v_task_id uuid;
  v_title text;
  v_finding_note text;
  v_disp_note text;
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

  PERFORM data.assert_project_writer(v_run.tenant_id);

  IF NOT data.can_execute_project(v_run.project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_item.answer_semantic IS DISTINCT FROM 'fail'
     AND NOT COALESCE(v_item.answer_blocks_closeout, false) THEN
    RAISE EXCEPTION 'task_only_for_findings' USING ERRCODE = 'check_violation';
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

  v_finding_note := NULLIF(btrim(COALESCE(v_item.note, '')), '');
  v_disp_note := NULLIF(btrim(COALESCE(v_item.resolution_note, '')), '');

  SELECT t.id INTO v_task_id
  FROM data.tasks t
  WHERE t.source_checklist_run_item_id = p_item_id
  LIMIT 1;

  IF v_task_id IS NOT NULL THEN
    UPDATE data.tasks
    SET title = v_title,
        source_finding_note = v_finding_note,
        source_disposition_note = v_disp_note,
        updated_at = now()
    WHERE id = v_task_id
      AND (
        title IS DISTINCT FROM v_title
        OR source_finding_note IS DISTINCT FROM v_finding_note
        OR source_disposition_note IS DISTINCT FROM v_disp_note
      );
    RETURN v_task_id;
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
    source_checklist_run_item_id,
    source_finding_note,
    source_disposition_note
  )
  VALUES (
    v_run.tenant_id,
    v_run.project_id,
    v_title,
    'pending',
    v_pos,
    p_item_id,
    v_finding_note,
    v_disp_note
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

NOTIFY pgrst, 'reload schema';
