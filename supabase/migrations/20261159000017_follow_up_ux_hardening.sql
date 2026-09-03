-- =============================================================================
-- Follow-up WO UX: numbered names, finding notes on deferred tasks, description
-- =============================================================================

-- Deferred task title/body includes answer note + disposition note
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

  SELECT t.id INTO v_task_id
  FROM data.tasks t
  WHERE t.source_checklist_run_item_id = p_item_id
  LIMIT 1;

  IF v_task_id IS NOT NULL THEN
    -- Refresh title if notes were added after first create
    v_title := left(
      trim(
        BOTH ' —'
        FROM concat_ws(
          ' — ',
          COALESCE(NULLIF(btrim(COALESCE(v_item.answer_label, '')), ''), 'NC'),
          NULLIF(btrim(COALESCE(v_item.title, '')), ''),
          NULLIF(btrim(COALESCE(v_item.note, '')), ''),
          CASE
            WHEN NULLIF(btrim(COALESCE(v_item.resolution_note, '')), '') IS NULL THEN NULL
            ELSE 'Disp: ' || btrim(v_item.resolution_note)
          END
        )
      ),
      200
    );
    UPDATE data.tasks
    SET title = COALESCE(NULLIF(btrim(v_title), ''), title),
        updated_at = now()
    WHERE id = v_task_id
      AND title IS DISTINCT FROM COALESCE(NULLIF(btrim(v_title), ''), title);
    RETURN v_task_id;
  END IF;

  v_title := left(
    trim(
      BOTH ' —'
      FROM concat_ws(
        ' — ',
        COALESCE(NULLIF(btrim(COALESCE(v_item.answer_label, '')), ''), 'NC'),
        NULLIF(btrim(COALESCE(v_item.title, '')), ''),
        NULLIF(btrim(COALESCE(v_item.note, '')), ''),
        CASE
          WHEN NULLIF(btrim(COALESCE(v_item.resolution_note, '')), '') IS NULL THEN NULL
          ELSE 'Disp: ' || btrim(v_item.resolution_note)
        END
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

-- Numbered follow-up names + description listing moved findings
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
  v_desc text;
  v_moved int := 0;
  v_seq int := 1;
  v_member record;
  v_task_titles text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_source FROM data.projects WHERE id = p_source_project_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM data.assert_project_writer(v_source.tenant_id);

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

  SELECT COUNT(*)::int + 1
  INTO v_seq
  FROM data.projects fp
  WHERE fp.source_project_id = p_source_project_id
    AND fp.status IS DISTINCT FROM 'cancelled';

  v_name := NULLIF(btrim(COALESCE(p_name, '')), '');
  IF v_name IS NULL THEN
    v_name := left(
      format(
        'Reparació #%s: %s',
        v_seq,
        COALESCE(NULLIF(btrim(v_source.name), ''), 'OS')
      ),
      200
    );
  END IF;

  -- Snapshot open finding task titles before move (for WO description)
  SELECT string_agg(t.title, E'\n• ' ORDER BY t.position, t.created_at)
  INTO v_task_titles
  FROM data.tasks t
  WHERE t.project_id = p_source_project_id
    AND t.source_checklist_run_item_id IS NOT NULL
    AND t.status IS DISTINCT FROM 'done';

  v_desc := left(
    concat_ws(
      E'\n\n',
      NULLIF(btrim(COALESCE(v_source.description, '')), ''),
      CASE
        WHEN v_task_titles IS NULL THEN 'Ordre de reparació generada des de la visita origen.'
        ELSE 'Troballes traslladades:' || E'\n• ' || v_task_titles
      END
    ),
    2000
  );

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
    source_run_id,
    visit_intent
  )
  VALUES (
    v_source.tenant_id,
    'work_order',
    v_name,
    v_desc,
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
    p_source_run_id,
    'corrective'
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
    WITH ranked AS (
      SELECT
        t.id,
        row_number() OVER (ORDER BY t.position, t.created_at) - 1 AS new_pos
      FROM data.tasks t
      WHERE t.project_id = p_source_project_id
        AND t.source_checklist_run_item_id IS NOT NULL
        AND t.status IS DISTINCT FROM 'done'
    ),
    moved AS (
      UPDATE data.tasks t
      SET
        project_id = v_new_id,
        position = ranked.new_pos,
        updated_at = now()
      FROM ranked
      WHERE t.id = ranked.id
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
    'source_project_id', p_source_project_id,
    'name', v_name
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_follow_up_work_order(uuid, text, boolean, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
