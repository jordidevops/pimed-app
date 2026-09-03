-- =============================================================================
-- Checklist runs: explicit display order for visit UI and public reports
-- =============================================================================

ALTER TABLE data.checklist_runs
  ADD COLUMN IF NOT EXISTS sort_order int NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_checklist_runs_project_sort
  ON data.checklist_runs (project_id, sort_order, created_at)
  WHERE status IS DISTINCT FROM 'superseded';

-- Backfill: preserve current chronological order per project
WITH ordered AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      PARTITION BY project_id
      ORDER BY created_at ASC, id ASC
    ) - 1 AS rn
  FROM data.checklist_runs
)
UPDATE data.checklist_runs r
SET sort_order = ordered.rn
FROM ordered
WHERE r.id = ordered.id
  AND r.sort_order = 0;

-- REPLACE VIEW fails when dependents / column set changes; drop + recreate.
DROP VIEW IF EXISTS api.checklist_runs CASCADE;
CREATE VIEW api.checklist_runs
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, project_id, template_id, template_version_id, name_snapshot,
    version_number, status, supersedes_run_id, sort_order,
    started_at, completed_at,
    started_by, completed_by, public_report_payload, created_at, updated_at
  FROM data.checklist_runs;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.checklist_runs TO authenticated, service_role;

-- Apply: assign next sort_order for the project
CREATE OR REPLACE FUNCTION api.apply_checklist_to_project(
  p_project_id uuid,
  p_template_id uuid,
  p_supersede_run_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_template data.checklist_templates%ROWTYPE;
  v_version data.checklist_template_versions%ROWTYPE;
  v_run_id uuid;
  v_has_answers boolean := false;
  v_sort int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT data.can_execute_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;

  SELECT * INTO v_template
  FROM data.checklist_templates
  WHERE id = p_template_id AND is_active AND NOT is_archived;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_template.tenant_id IS NULL THEN
    RAISE EXCEPTION 'platform_template_must_be_cloned'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_template.tenant_id IS DISTINCT FROM v_project.tenant_id THEN
    RAISE EXCEPTION 'template_tenant_mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_version
  FROM data.checklist_template_versions
  WHERE template_id = p_template_id AND status = 'published'
  ORDER BY version_number DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_published_version' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_supersede_run_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM data.checklist_run_items i
      WHERE i.run_id = p_supersede_run_id
        AND (
          i.value_bool IS NOT NULL
          OR i.value_option_id IS NOT NULL
          OR i.value_number IS NOT NULL
          OR NULLIF(btrim(COALESCE(i.value_text, '')), '') IS NOT NULL
          OR NULLIF(btrim(COALESCE(i.note, '')), '') IS NOT NULL
        )
    ) INTO v_has_answers;

    IF NOT v_has_answers THEN
      SELECT sort_order INTO v_sort
      FROM data.checklist_runs
      WHERE id = p_supersede_run_id AND project_id = p_project_id;
      DELETE FROM data.checklist_run_items WHERE run_id = p_supersede_run_id;
      DELETE FROM data.checklist_runs WHERE id = p_supersede_run_id AND project_id = p_project_id;
      p_supersede_run_id := NULL;
    ELSE
      SELECT sort_order INTO v_sort
      FROM data.checklist_runs
      WHERE id = p_supersede_run_id AND project_id = p_project_id;
      UPDATE data.checklist_runs
      SET status = 'superseded', updated_at = now()
      WHERE id = p_supersede_run_id AND project_id = p_project_id;
    END IF;
  ELSE
    SELECT COALESCE(MAX(sort_order), -1) + 1 INTO v_sort
    FROM data.checklist_runs
    WHERE project_id = p_project_id
      AND status IS DISTINCT FROM 'superseded';
  END IF;

  INSERT INTO data.checklist_runs (
    tenant_id, project_id, template_id, template_version_id,
    name_snapshot, version_number, status, supersedes_run_id, sort_order, started_by
  ) VALUES (
    v_project.tenant_id, p_project_id, p_template_id, v_version.id,
    v_template.name, v_version.version_number, 'pending', p_supersede_run_id,
    COALESCE(v_sort, 0), auth.uid()
  )
  RETURNING id INTO v_run_id;

  INSERT INTO data.checklist_run_items (
    tenant_id, run_id, template_item_id, review_point_id, position, title,
    description_internal, description_public, locale, category,
    include_in_report, is_required, response_type, response_set_id, evidence_required
  )
  SELECT
    v_project.tenant_id, v_run_id, i.id, i.review_point_id, i.position, i.title,
    i.description_internal, i.description_public,
    COALESCE(i.locale, v_template.locale), COALESCE(i.category, v_template.category),
    i.include_in_report, i.is_required, i.response_type,
    COALESCE(i.response_set_id, v_version.default_response_set_id), i.evidence_required
  FROM data.checklist_template_items i
  WHERE i.version_id = v_version.id
  ORDER BY i.position;

  RETURN v_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.reorder_checklist_runs(
  p_project_id uuid,
  p_run_ids uuid[]
)
RETURNS int
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
  v_pos int := 0;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT data.can_execute_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_run_ids IS NULL OR cardinality(p_run_ids) = 0 THEN
    RETURN 0;
  END IF;

  FOREACH v_id IN ARRAY p_run_ids
  LOOP
    UPDATE data.checklist_runs
    SET sort_order = v_pos, updated_at = now()
    WHERE id = v_id
      AND project_id = p_project_id
      AND status IS DISTINCT FROM 'superseded';
    IF FOUND THEN
      v_count := v_count + 1;
      v_pos := v_pos + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.reorder_checklist_runs(uuid, uuid[])
  TO authenticated, service_role;

-- Public report: honour sort_order (payload shape unchanged)
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
    'schema_version', 2,
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
        'note', i.note
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

GRANT EXECUTE ON FUNCTION api.apply_checklist_to_project(uuid, uuid, uuid)
  TO authenticated, service_role;

-- Service apply also assigns next sort_order
CREATE OR REPLACE FUNCTION api.apply_checklist_to_project_service(
  p_project_id uuid,
  p_template_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_template data.checklist_templates%ROWTYPE;
  v_version data.checklist_template_versions%ROWTYPE;
  v_run_id uuid;
  v_sort int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_template
  FROM data.checklist_templates
  WHERE id = p_template_id AND is_active AND NOT is_archived;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_template.tenant_id IS NULL THEN
    RAISE EXCEPTION 'platform_template_must_be_cloned'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_template.tenant_id IS DISTINCT FROM v_project.tenant_id THEN
    RAISE EXCEPTION 'template_tenant_mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_version
  FROM data.checklist_template_versions
  WHERE template_id = p_template_id AND status = 'published'
  ORDER BY version_number DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_published_version' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT COALESCE(MAX(sort_order), -1) + 1 INTO v_sort
  FROM data.checklist_runs
  WHERE project_id = p_project_id
    AND status IS DISTINCT FROM 'superseded';

  INSERT INTO data.checklist_runs (
    tenant_id, project_id, template_id, template_version_id,
    name_snapshot, version_number, status, sort_order
  ) VALUES (
    v_project.tenant_id, p_project_id, p_template_id, v_version.id,
    v_template.name, v_version.version_number, 'pending', COALESCE(v_sort, 0)
  )
  RETURNING id INTO v_run_id;

  INSERT INTO data.checklist_run_items (
    tenant_id, run_id, template_item_id, review_point_id, position, title,
    description_internal, description_public, locale, category,
    include_in_report, is_required, response_type, response_set_id, evidence_required
  )
  SELECT
    v_project.tenant_id, v_run_id, i.id, i.review_point_id, i.position, i.title,
    i.description_internal, i.description_public,
    COALESCE(i.locale, v_template.locale), COALESCE(i.category, v_template.category),
    i.include_in_report, i.is_required, i.response_type,
    COALESCE(i.response_set_id, v_version.default_response_set_id), i.evidence_required
  FROM data.checklist_template_items i
  WHERE i.version_id = v_version.id
  ORDER BY i.position;

  RETURN v_run_id;
END;
$$;

REVOKE ALL ON FUNCTION api.apply_checklist_to_project_service(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_checklist_to_project_service(uuid, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
