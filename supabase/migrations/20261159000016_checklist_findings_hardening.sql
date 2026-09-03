-- =============================================================================
-- Checklist findings hardening (answer partial patches, auth, closeout, orphans)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.assert_project_writer(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_role text;
  v_active uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_active IS NOT NULL AND v_active IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'active_tenant_mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'member') THEN
    RAISE EXCEPTION 'forbidden: writer role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION data.assert_project_writer(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Partial-patch answer RPC (set_* flags preserve unset fields)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.answer_checklist_run_item(uuid, boolean, uuid, numeric, text, text, text);

CREATE OR REPLACE FUNCTION api.answer_checklist_run_item(
  p_item_id uuid,
  p_value_bool boolean DEFAULT NULL,
  p_value_option_id uuid DEFAULT NULL,
  p_value_number numeric DEFAULT NULL,
  p_value_text text DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_client_mutation_id text DEFAULT NULL,
  p_set_value_bool boolean DEFAULT false,
  p_set_value_option_id boolean DEFAULT false,
  p_set_value_number boolean DEFAULT false,
  p_set_value_text boolean DEFAULT false,
  p_set_note boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_item data.checklist_run_items%ROWTYPE;
  v_run data.checklist_runs%ROWTYPE;
  v_option data.checklist_response_options%ROWTYPE;
  v_mutation text := NULLIF(btrim(COALESCE(p_client_mutation_id, '')), '');
  v_is_fail boolean := false;
  v_next_bool boolean;
  v_next_option_id uuid;
  v_next_number numeric;
  v_next_text text;
  v_next_note text;
  v_had_fail boolean;
  v_option_changed boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT COALESCE(p_set_value_bool, false)
     AND NOT COALESCE(p_set_value_option_id, false)
     AND NOT COALESCE(p_set_value_number, false)
     AND NOT COALESCE(p_set_value_text, false)
     AND NOT COALESCE(p_set_note, false) THEN
    RAISE EXCEPTION 'empty_answer_patch' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_item FROM data.checklist_run_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'item_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_mutation IS NOT NULL AND v_item.client_mutation_id IS NOT DISTINCT FROM v_mutation THEN
    RETURN p_item_id;
  END IF;

  SELECT * INTO v_run FROM data.checklist_runs WHERE id = v_item.run_id;
  IF NOT data.can_execute_project(v_run.project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_run.status = 'superseded' THEN
    RAISE EXCEPTION 'run_superseded' USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  v_had_fail := (
    v_item.answer_semantic = 'fail'
    OR COALESCE(v_item.answer_blocks_closeout, false)
  );

  v_next_bool := CASE WHEN COALESCE(p_set_value_bool, false) THEN p_value_bool ELSE v_item.value_bool END;
  v_next_option_id := CASE
    WHEN COALESCE(p_set_value_option_id, false) THEN p_value_option_id
    ELSE v_item.value_option_id
  END;
  v_next_number := CASE
    WHEN COALESCE(p_set_value_number, false) THEN p_value_number
    ELSE v_item.value_number
  END;
  v_next_text := CASE
    WHEN COALESCE(p_set_value_text, false)
      THEN NULLIF(btrim(COALESCE(p_value_text, '')), '')
    ELSE v_item.value_text
  END;
  v_next_note := CASE
    WHEN COALESCE(p_set_note, false)
      THEN NULLIF(btrim(COALESCE(p_note, '')), '')
    ELSE v_item.note
  END;

  v_option_changed := COALESCE(p_set_value_option_id, false)
    AND v_next_option_id IS DISTINCT FROM v_item.value_option_id;

  IF v_next_option_id IS NOT NULL THEN
    SELECT * INTO v_option
    FROM data.checklist_response_options
    WHERE id = v_next_option_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'option_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_item.response_set_id IS NOT NULL
       AND v_option.response_set_id IS DISTINCT FROM v_item.response_set_id THEN
      RAISE EXCEPTION 'option_response_set_mismatch' USING ERRCODE = 'check_violation';
    END IF;
    v_is_fail := (v_option.semantics = 'fail' OR v_option.blocks_closeout);
  END IF;

  UPDATE data.checklist_run_items
  SET
    value_bool = v_next_bool,
    value_option_id = v_next_option_id,
    value_number = v_next_number,
    value_text = v_next_text,
    note = v_next_note,
    answer_label = CASE
      WHEN v_next_option_id IS NULL THEN NULL
      ELSE v_option.label
    END,
    answer_color_token = CASE
      WHEN v_next_option_id IS NULL THEN NULL
      ELSE v_option.color_token
    END,
    answer_semantic = CASE
      WHEN v_next_option_id IS NULL THEN NULL
      ELSE v_option.semantics
    END,
    answer_blocks_closeout = CASE
      WHEN v_next_option_id IS NULL THEN NULL
      ELSE v_option.blocks_closeout
    END,
    resolution_status = CASE
      WHEN v_next_option_id IS NULL THEN NULL
      WHEN NOT v_is_fail THEN NULL
      WHEN v_option_changed THEN 'open'
      ELSE COALESCE(resolution_status, 'open')
    END,
    resolution_reason = CASE
      WHEN v_next_option_id IS NULL OR NOT v_is_fail OR v_option_changed THEN NULL
      ELSE resolution_reason
    END,
    resolution_note = CASE
      WHEN v_next_option_id IS NULL OR NOT v_is_fail OR v_option_changed THEN NULL
      ELSE resolution_note
    END,
    resolved_at = CASE
      WHEN v_next_option_id IS NULL OR NOT v_is_fail OR v_option_changed THEN NULL
      WHEN resolution_status IS NOT NULL AND resolution_status <> 'open' THEN resolved_at
      ELSE NULL
    END,
    resolved_by = CASE
      WHEN v_next_option_id IS NULL OR NOT v_is_fail OR v_option_changed THEN NULL
      WHEN resolution_status IS NOT NULL AND resolution_status <> 'open' THEN resolved_by
      ELSE NULL
    END,
    client_mutation_id = COALESCE(v_mutation, client_mutation_id),
    answered_at = now(),
    answered_by = auth.uid(),
    updated_at = now()
  WHERE id = p_item_id;

  -- Clear orphan follow-up tasks when finding is cleared or option replaced
  IF v_had_fail AND (NOT v_is_fail OR v_option_changed) THEN
    DELETE FROM data.tasks
    WHERE source_checklist_run_item_id = p_item_id
      AND status IS DISTINCT FROM 'done';
  END IF;

  IF v_run.status = 'pending' THEN
    UPDATE data.checklist_runs
    SET status = 'in_progress', started_at = COALESCE(started_at, now()), updated_at = now()
    WHERE id = v_run.id;
  END IF;

  RETURN p_item_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.answer_checklist_run_item(
  uuid, boolean, uuid, numeric, text, text, text,
  boolean, boolean, boolean, boolean, boolean
) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Ensure deferred task: DEFINER + writer check
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Follow-up WO: writer role + active tenant
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
  v_max_pos int;
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

  v_name := NULLIF(btrim(COALESCE(p_name, '')), '');
  IF v_name IS NULL THEN
    v_name := left(
      CASE COALESCE(v_source.visit_intent, 'generic')
        WHEN 'inspection' THEN 'Reparació: '
        ELSE 'Seguiment: '
      END || COALESCE(NULLIF(btrim(v_source.name), ''), 'OS'),
      200
    );
  END IF;

  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, asset_id, client_id, contact_site_id,
    planned_start, planned_end, created_by,
    source_project_id, source_run_id, visit_intent
  )
  VALUES (
    v_source.tenant_id,
    'work_order',
    v_name,
    left(
      COALESCE(
        NULLIF(btrim(COALESCE(v_source.description, '')), ''),
        'Ordre de reparació / seguiment generada des de la visita origen.'
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
    SELECT COALESCE(MAX(position), -1) INTO v_max_pos
    FROM data.tasks
    WHERE project_id = v_new_id;

    WITH ranked AS (
      SELECT
        t.id,
        v_max_pos + ROW_NUMBER() OVER (ORDER BY t.position, t.created_at, t.id) AS new_pos
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

  IF COALESCE(v_source.visit_intent, 'generic') = 'generic' THEN
    UPDATE data.projects
    SET visit_intent = 'inspection', updated_at = now()
    WHERE id = p_source_project_id;
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

-- Visit intent: writers only
CREATE OR REPLACE FUNCTION api.set_project_visit_intent(
  p_id uuid,
  p_intent text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_intent text := NULLIF(btrim(COALESCE(p_intent, '')), '');
  v_tenant uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_intent IS NULL OR v_intent NOT IN ('inspection', 'corrective', 'generic') THEN
    RAISE EXCEPTION 'invalid_visit_intent' USING ERRCODE = 'check_violation';
  END IF;

  SELECT tenant_id INTO v_tenant FROM data.projects WHERE id = p_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM data.assert_project_writer(v_tenant);

  IF NOT data.can_execute_project(p_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.projects
  SET visit_intent = v_intent, updated_at = now()
  WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_project_visit_intent(uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Closeout blockers: open task (not done) OR follow-up WO
-- ---------------------------------------------------------------------------
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
                 OR (
                   i.response_type NOT IN ('checkbox', 'single_choice')
                   AND i.value_bool IS NULL
                   AND i.value_option_id IS NULL
                   AND i.value_number IS NULL
                   AND NULLIF(btrim(COALESCE(i.value_text, '')), '') IS NULL
                 )
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
                   AND t.status IS DISTINCT FROM 'done'
               )
            THEN 'deferred_without_task'
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
            OR (
              i.response_type NOT IN ('checkbox', 'single_choice')
              AND i.value_bool IS NULL
              AND i.value_option_id IS NULL
              AND i.value_number IS NULL
              AND NULLIF(btrim(COALESCE(i.value_text, '')), '') IS NULL
            )
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
              AND t.status IS DISTINCT FROM 'done'
          )
        )
      )
  ) x
  WHERE x.obj->>'reason' IS NOT NULL;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.checklist_closeout_blockers(uuid) TO authenticated, service_role;

-- Report: promote in_progress → completed
CREATE OR REPLACE FUNCTION api.build_checklist_public_report(
  p_project_id uuid,
  p_locale text DEFAULT NULL,
  p_bypass_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_locale text;
  v_contact_locale text;
  v_run_locale text;
  v_blockers jsonb;
  v_payload jsonb;
  v_intent text;
  v_labels jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(cs.preferred_locale, c.preferred_locale), COALESCE(p.visit_intent, 'generic')
  INTO v_contact_locale, v_intent
  FROM data.projects p
  LEFT JOIN data.contact_sites cs ON cs.id = p.contact_site_id
  LEFT JOIN data.contacts c ON c.id = p.client_id
  WHERE p.id = p_project_id;

  SELECT i.locale
  INTO v_run_locale
  FROM data.checklist_runs r
  JOIN data.checklist_run_items i ON i.run_id = r.id
  WHERE r.project_id = p_project_id
    AND i.locale IS NOT NULL
  ORDER BY r.sort_order, r.created_at, i.position
  LIMIT 1;

  v_locale := COALESCE(NULLIF(btrim(COALESCE(p_locale, '')), ''), v_contact_locale, v_run_locale, 'ca');
  IF v_locale NOT IN ('ca','es','en') THEN
    v_locale := 'ca';
  END IF;

  v_intent := COALESCE(NULLIF(btrim(COALESCE(v_intent, '')), ''), 'generic');
  IF v_intent NOT IN ('inspection', 'corrective', 'generic') THEN
    v_intent := 'generic';
  END IF;

  v_labels := CASE
    WHEN v_intent = 'inspection' AND v_locale = 'es' THEN jsonb_build_object(
      'report_title', 'Informe de inspección',
      'findings_heading', 'Hallazgos',
      'disposition_heading', 'Disposición',
      'closeout_hint', 'Cierre de visita de inspección'
    )
    WHEN v_intent = 'inspection' AND v_locale = 'en' THEN jsonb_build_object(
      'report_title', 'Inspection report',
      'findings_heading', 'Findings',
      'disposition_heading', 'Disposition',
      'closeout_hint', 'Inspection visit close-out'
    )
    WHEN v_intent = 'inspection' THEN jsonb_build_object(
      'report_title', 'Informe d''inspecció',
      'findings_heading', 'Troballes',
      'disposition_heading', 'Disposició',
      'closeout_hint', 'Tancament de visita d''inspecció'
    )
    WHEN v_intent = 'corrective' AND v_locale = 'es' THEN jsonb_build_object(
      'report_title', 'Informe de intervención correctiva',
      'findings_heading', 'Trabajo realizado',
      'disposition_heading', 'Estado',
      'closeout_hint', 'Cierre de intervención'
    )
    WHEN v_intent = 'corrective' AND v_locale = 'en' THEN jsonb_build_object(
      'report_title', 'Corrective work report',
      'findings_heading', 'Work performed',
      'disposition_heading', 'Status',
      'closeout_hint', 'Corrective visit close-out'
    )
    WHEN v_intent = 'corrective' THEN jsonb_build_object(
      'report_title', 'Informe d''intervenció correctiva',
      'findings_heading', 'Feina realitzada',
      'disposition_heading', 'Estat',
      'closeout_hint', 'Tancament d''intervenció'
    )
    WHEN v_locale = 'es' THEN jsonb_build_object(
      'report_title', 'Informe de visita',
      'findings_heading', 'Checklist',
      'disposition_heading', 'Disposición',
      'closeout_hint', 'Cierre de visita'
    )
    WHEN v_locale = 'en' THEN jsonb_build_object(
      'report_title', 'Visit report',
      'findings_heading', 'Checklist',
      'disposition_heading', 'Disposition',
      'closeout_hint', 'Visit close-out'
    )
    ELSE jsonb_build_object(
      'report_title', 'Informe de visita',
      'findings_heading', 'Checklist',
      'disposition_heading', 'Disposició',
      'closeout_hint', 'Tancament de visita'
    )
  END;

  v_blockers := api.checklist_closeout_blockers(p_project_id);
  IF jsonb_array_length(v_blockers) > 0
     AND NULLIF(btrim(COALESCE(p_bypass_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'closeout_blocked: %', v_blockers::text
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  SELECT jsonb_build_object(
    'schema_version', 4,
    'locale', v_locale,
    'visit_intent', v_intent,
    'labels', v_labels,
    'project_id', p_project_id,
    'generated_at', now(),
    'bypass_reason', NULLIF(btrim(COALESCE(p_bypass_reason, '')), ''),
    'items', COALESCE(jsonb_agg(s.item ORDER BY s.sort_order, s.run_created_at, s.position), '[]'::jsonb)
  )
  INTO v_payload
  FROM (
    SELECT
      r.sort_order AS sort_order,
      r.created_at AS run_created_at,
      i.position AS position,
      jsonb_build_object(
        'run_id', r.id,
        'run_name', r.name_snapshot,
        'version_number', r.version_number,
        'position', i.position,
        'title', i.title,
        'description_public', COALESCE(i.description_public, ''),
        'response_type', i.response_type,
        'value_bool', i.value_bool,
        'value_number', i.value_number,
        'value_text', i.value_text,
        'option_label', i.answer_label,
        'option_semantics', i.answer_semantic,
        'option_color_token', i.answer_color_token,
        'note', i.note,
        'resolution_status', i.resolution_status,
        'resolution_reason', i.resolution_reason,
        'resolution_note', i.resolution_note
      ) AS item
    FROM data.checklist_runs r
    JOIN data.checklist_run_items i ON i.run_id = r.id
    WHERE r.project_id = p_project_id
      AND r.status IN ('pending','in_progress','completed')
      AND i.include_in_report
  ) s;

  UPDATE data.checklist_runs
  SET public_report_payload = v_payload,
      status = CASE
        WHEN status IN ('pending', 'in_progress') THEN 'completed'
        ELSE status
      END,
      completed_at = COALESCE(completed_at, now()),
      completed_by = COALESCE(completed_by, auth.uid()),
      updated_at = now()
  WHERE project_id = p_project_id
    AND status IN ('pending','in_progress','completed');

  RETURN v_payload;
END;
$$;

GRANT EXECUTE ON FUNCTION api.build_checklist_public_report(uuid, text, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
