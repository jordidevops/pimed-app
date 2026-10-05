-- Project calendar events: stop leaking titles via empty required_permissions.
-- 1) Backfill '{}' → projects.view for entity_type=project
-- 2) Force non-empty perms on insert/update for project entities
-- 3) SELECT RLS also requires can_access_project for project-linked rows

-- ---------------------------------------------------------------------------
-- Trigger: never persist public ('{}') perms on project calendar rows
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_calendar_events_project_perms()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.entity_type = 'project'
     AND (NEW.required_permissions IS NULL OR cardinality(NEW.required_permissions) = 0) THEN
    NEW.required_permissions := ARRAY['projects.view']::text[];
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_calendar_events_project_perms ON data.calendar_events;
CREATE TRIGGER trg_calendar_events_project_perms
  BEFORE INSERT OR UPDATE ON data.calendar_events
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_calendar_events_project_perms();

COMMENT ON FUNCTION data.trg_calendar_events_project_perms IS
  'Ensures project-linked calendar_events never use empty required_permissions (tenant-public).';

-- ---------------------------------------------------------------------------
-- Backfill existing project events
-- ---------------------------------------------------------------------------
UPDATE data.calendar_events
SET
  required_permissions = ARRAY['projects.view']::text[],
  updated_at = now()
WHERE entity_type = 'project'
  AND cardinality(required_permissions) = 0;

-- ---------------------------------------------------------------------------
-- RLS: project events also require project access (not only permission tokens)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "calendar_events: veure per permisos i context de site"
  ON data.calendar_events;

CREATE POLICY "calendar_events: veure per permisos i context de site"
  ON data.calendar_events FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_see_calendar_event(
      tenant_id,
      required_permissions,
      site_id,
      owner_id
    )
    AND (
      entity_type IS DISTINCT FROM 'project'
      OR entity_id IS NULL
      OR data.can_access_project(entity_id)
    )
  );
