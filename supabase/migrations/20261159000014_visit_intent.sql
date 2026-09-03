-- =============================================================================
-- Phase 4: visit intent (inspection vs corrective) + report/closeout copy
-- =============================================================================

ALTER TABLE data.checklist_templates
  ADD COLUMN IF NOT EXISTS intent text NOT NULL DEFAULT 'generic'
    CHECK (intent IN ('inspection', 'corrective', 'generic'));

COMMENT ON COLUMN data.checklist_templates.intent IS
  'Visit intent suggested by this template: inspection, corrective, or generic.';

ALTER TABLE data.projects
  ADD COLUMN IF NOT EXISTS visit_intent text NOT NULL DEFAULT 'generic'
    CHECK (visit_intent IN ('inspection', 'corrective', 'generic'));

COMMENT ON COLUMN data.projects.visit_intent IS
  'Intent of this work order: inspection, corrective, or generic. Drives closeout/report copy.';

CREATE INDEX IF NOT EXISTS idx_projects_visit_intent
  ON data.projects (tenant_id, visit_intent)
  WHERE type IN ('work_order', 'maintenance');

-- Templates view: append intent
DROP VIEW IF EXISTS api.checklist_templates CASCADE;
CREATE VIEW api.checklist_templates
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, name, description, kind, locale, category, vertical, archetype,
    metadata, is_default, is_active, is_archived, created_by, created_at, updated_at,
    intent
  FROM data.checklist_templates;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.checklist_templates TO authenticated, service_role;

-- Projects view: append visit_intent (keep prior columns including source_*)
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
    p.visit_intent
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

-- Lightweight setter (field techs may execute projects but not always update_project)
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_intent IS NULL OR v_intent NOT IN ('inspection', 'corrective', 'generic') THEN
    RAISE EXCEPTION 'invalid_visit_intent' USING ERRCODE = 'check_violation';
  END IF;
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

-- Apply checklist: inherit template intent onto generic projects
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

  IF COALESCE(v_project.visit_intent, 'generic') = 'generic'
     AND v_template.intent IN ('inspection', 'corrective') THEN
    UPDATE data.projects
    SET visit_intent = v_template.intent, updated_at = now()
    WHERE id = p_project_id;
  END IF;

  RETURN v_run_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.apply_checklist_to_project(uuid, uuid, uuid)
  TO authenticated, service_role;

-- Follow-up WO is always corrective
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
    v_name := left(
      CASE COALESCE(v_source.visit_intent, 'generic')
        WHEN 'inspection' THEN 'Reparació: '
        ELSE 'Seguiment: '
      END || COALESCE(NULLIF(btrim(v_source.name), ''), 'OS'),
      200
    );
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
    source_run_id,
    visit_intent
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

  -- Source visit that produced repair stays inspection if still generic
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

-- Public report: schema_version 4 + visit intent + copy presets
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
