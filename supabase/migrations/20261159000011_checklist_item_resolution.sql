-- =============================================================================
-- Checklist run item dispositions (finding vs resolution) — Phase 1
-- =============================================================================

ALTER TABLE data.checklist_run_items
  ADD COLUMN IF NOT EXISTS resolution_status text
    CHECK (
      resolution_status IS NULL
      OR resolution_status IN (
        'open',
        'resolved_same_visit',
        'deferred',
        'closed_unresolved'
      )
    ),
  ADD COLUMN IF NOT EXISTS resolution_reason text,
  ADD COLUMN IF NOT EXISTS resolution_note text,
  ADD COLUMN IF NOT EXISTS resolved_at timestamptz,
  ADD COLUMN IF NOT EXISTS resolved_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

DROP VIEW IF EXISTS api.checklist_run_items CASCADE;
CREATE VIEW api.checklist_run_items
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, run_id, template_item_id, review_point_id, position,
    title, description_internal, description_public, locale, category,
    include_in_report, is_required, response_type, response_set_id,
    evidence_required,
    value_bool, value_option_id, value_number, value_text, note,
    answer_label, answer_color_token, answer_semantic, answer_blocks_closeout,
    resolution_status, resolution_reason, resolution_note, resolved_at, resolved_by,
    client_mutation_id, answered_at, answered_by, created_at, updated_at
  FROM data.checklist_run_items;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.checklist_run_items TO authenticated, service_role;

-- When answering: fail → open disposition; non-fail → clear disposition
CREATE OR REPLACE FUNCTION api.answer_checklist_run_item(
  p_item_id uuid,
  p_value_bool boolean DEFAULT NULL,
  p_value_option_id uuid DEFAULT NULL,
  p_value_number numeric DEFAULT NULL,
  p_value_text text DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_client_mutation_id text DEFAULT NULL
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
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

  IF p_value_option_id IS NOT NULL THEN
    SELECT * INTO v_option
    FROM data.checklist_response_options
    WHERE id = p_value_option_id;

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
    value_bool = p_value_bool,
    value_option_id = p_value_option_id,
    value_number = p_value_number,
    value_text = NULLIF(btrim(COALESCE(p_value_text, '')), ''),
    note = NULLIF(btrim(COALESCE(p_note, '')), ''),
    answer_label = CASE WHEN p_value_option_id IS NULL THEN NULL ELSE v_option.label END,
    answer_color_token = CASE WHEN p_value_option_id IS NULL THEN NULL ELSE v_option.color_token END,
    answer_semantic = CASE WHEN p_value_option_id IS NULL THEN NULL ELSE v_option.semantics END,
    answer_blocks_closeout = CASE WHEN p_value_option_id IS NULL THEN NULL ELSE v_option.blocks_closeout END,
    resolution_status = CASE
      WHEN p_value_option_id IS NULL THEN NULL
      WHEN v_is_fail THEN COALESCE(resolution_status, 'open')
      ELSE NULL
    END,
    resolution_reason = CASE
      WHEN p_value_option_id IS NULL OR NOT v_is_fail THEN NULL
      ELSE resolution_reason
    END,
    resolution_note = CASE
      WHEN p_value_option_id IS NULL OR NOT v_is_fail THEN NULL
      ELSE resolution_note
    END,
    resolved_at = CASE
      WHEN p_value_option_id IS NULL OR NOT v_is_fail THEN NULL
      WHEN resolution_status IS NOT NULL AND resolution_status <> 'open' THEN resolved_at
      ELSE NULL
    END,
    resolved_by = CASE
      WHEN p_value_option_id IS NULL OR NOT v_is_fail THEN NULL
      WHEN resolution_status IS NOT NULL AND resolution_status <> 'open' THEN resolved_by
      ELSE NULL
    END,
    client_mutation_id = COALESCE(v_mutation, client_mutation_id),
    answered_at = now(),
    answered_by = auth.uid(),
    updated_at = now()
  WHERE id = p_item_id;

  IF v_run.status = 'pending' THEN
    UPDATE data.checklist_runs
    SET status = 'in_progress', started_at = COALESCE(started_at, now()), updated_at = now()
    WHERE id = v_run.id;
  END IF;

  RETURN p_item_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.answer_checklist_run_item(uuid, boolean, uuid, numeric, text, text, text)
  TO authenticated, service_role;

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

  RETURN p_item_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_checklist_run_item_resolution(uuid, text, text, text)
  TO authenticated, service_role;

-- Closeout: fail blocks only when disposition is missing/open; enforce requires_note
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
      )
  ) x;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.checklist_closeout_blockers(uuid) TO authenticated, service_role;

-- Public report includes disposition fields
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(cs.preferred_locale, c.preferred_locale)
  INTO v_contact_locale
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

  v_blockers := api.checklist_closeout_blockers(p_project_id);
  IF jsonb_array_length(v_blockers) > 0
     AND NULLIF(btrim(COALESCE(p_bypass_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'closeout_blocked: %', v_blockers::text
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  SELECT jsonb_build_object(
    'schema_version', 3,
    'locale', v_locale,
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
      status = CASE WHEN status = 'pending' THEN 'completed' ELSE status END,
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
