-- =============================================================================
-- Field Service: work_notes_html on projects
-- (visit_checklist_templates removed — replaced by checklist_* engine)
-- =============================================================================

-- 1. Work notes on projects (HTML, TipTap-compatible)
ALTER TABLE data.projects
  ADD COLUMN IF NOT EXISTS work_notes_html text;

COMMENT ON COLUMN data.projects.work_notes_html
  IS 'Notes de feina (HTML). Editables durant la visita; es mostren al close-out.';

-- Append column to api.projects (CREATE OR REPLACE cannot reorder existing cols)
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
    p.work_notes_html
  FROM data.projects p;

GRANT SELECT ON api.projects TO authenticated;

CREATE RULE "api_projects_insert" AS ON INSERT TO api.projects
  DO INSTEAD
  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, asset_id, client_id, contact_site_id,
    planned_start, planned_end, created_by, work_notes_html
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
    NEW.work_notes_html
  );

GRANT INSERT ON api.projects TO authenticated;
REVOKE UPDATE ON api.projects FROM authenticated;

CREATE RULE "api_projects_delete" AS ON DELETE TO api.projects
  DO INSTEAD
  DELETE FROM data.projects WHERE id = OLD.id;

GRANT DELETE ON api.projects TO authenticated;

-- Members with project access can update notes (field techs are not always managers)
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

  UPDATE data.projects
  SET
    work_notes_html = NULLIF(btrim(COALESCE(p_html, '')), ''),
    updated_at      = now()
  WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_project_work_notes(uuid, text) TO authenticated, service_role;
