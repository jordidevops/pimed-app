-- =============================================================================
-- Migration: 20260506000004_project_extensions.sql
-- Propòsit : Extensions del mòdul de Projectes — fase 1a:
--            · Habilita btree_gist (necessari per EXCLUDE gist a work_logs)
--            · Afegeix asset_id FK a data.projects (vinculació EAM)
--            · Trigger de consistència de tenant per asset_id
--            · Recrea api.projects incloent-hi asset_id
--            · Defineix RPC canònica api.update_project per a escriptures
--
-- Conté:
--   1. EXTENSION : btree_gist
--   2. ALTER     : data.projects + asset_id
--   3. Trigger   : data.validate_project_asset_tenant
--   4. Vista     : api.projects (redefinida amb asset_id)
--   5. RPC       : api.update_project (SECURITY DEFINER + patch semantics)
--   6. NOTIFY    : pgrst reload schema
--
-- Forward-only: tota l'SQL és idempotent o usa IF NOT EXISTS / DROP ... IF EXISTS.
-- =============================================================================

-- =============================================================================
-- 1. Extension btree_gist
--    Requerida per a EXCLUDE USING gist amb columnes de tipus uuid (=)
--    i tstzrange (&&) a la taula data.work_logs (migració 000005).
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- =============================================================================
-- 2. ALTER data.projects: columna asset_id
-- =============================================================================
ALTER TABLE data.projects
  ADD COLUMN IF NOT EXISTS asset_id uuid
    REFERENCES data.assets(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_projects_asset_id
  ON data.projects (asset_id)
  WHERE asset_id IS NOT NULL;

COMMENT ON COLUMN data.projects.asset_id
  IS 'Actiu físic principal associat al projecte o ordre de treball (EAM/CAFM). '
     'Ha de pertànyer al mateix tenant que el projecte (validat per trigger).';

-- =============================================================================
-- 3. Trigger de consistència: asset_id ha de pertànyer al mateix tenant
-- =============================================================================
CREATE OR REPLACE FUNCTION data.validate_project_asset_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.asset_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM data.assets a
      WHERE a.id        = NEW.asset_id
        AND a.tenant_id = NEW.tenant_id
    ) THEN
      RAISE EXCEPTION
        'asset_id % no pertany al tenant % del projecte',
        NEW.asset_id, NEW.tenant_id
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_project_asset_tenant ON data.projects;
CREATE TRIGGER trg_validate_project_asset_tenant
  BEFORE INSERT OR UPDATE ON data.projects
  FOR EACH ROW
  EXECUTE FUNCTION data.validate_project_asset_tenant();

-- =============================================================================
-- 4. Vista api.projects — redefinida per incloure asset_id
--
-- Les RULES no suporten CREATE OR REPLACE; cal eliminar-les primer.
-- CREATE OR REPLACE VIEW és segur: preserva el nom i els permisos existents.
--
-- Nota d'arquitectura:
--   api.projects és un model de lectura i d'INSERT/DELETE.
--   L'UPDATE es fa via RPC (api.update_project) per evitar el problema
--   "UPDATE RETURNING" de PostgREST sobre vistes amb RULE DO INSTEAD.
-- =============================================================================

-- 4a. Eliminar rules existents (es recrearan a sota)
DROP RULE IF EXISTS "api_projects_insert" ON api.projects;
DROP RULE IF EXISTS "api_projects_update" ON api.projects;
DROP RULE IF EXISTS "api_projects_delete" ON api.projects;

-- 4b. Vista actualitzada (ara inclou asset_id)
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
    -- Camps virtuals calculats
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
    p.asset_id
  FROM data.projects p;

GRANT SELECT ON api.projects TO authenticated;

-- 4c. RULE INSERT — inclou asset_id
CREATE RULE "api_projects_insert" AS ON INSERT TO api.projects
  DO INSTEAD
  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, asset_id, client_id,
    planned_start, planned_end, created_by
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
    NEW.planned_start,
    NEW.planned_end,
    COALESCE(NEW.created_by, auth.uid())
  );

GRANT INSERT ON api.projects TO authenticated;

-- 4d. UPDATE deshabilitat a la vista.
--     Es deixa explícit per evitar regressions i malentesos.
REVOKE UPDATE ON api.projects FROM authenticated;

-- 4e. RULE DELETE (sense canvis)
CREATE RULE "api_projects_delete" AS ON DELETE TO api.projects
  DO INSTEAD
  DELETE FROM data.projects WHERE id = OLD.id;

GRANT DELETE ON api.projects TO authenticated;

-- =============================================================================
-- 5. RPC canònica d'UPDATE: api.update_project
--
-- Objectiu:
--   Garantir updates parcials segurs i compatibles amb PostgREST, evitant
--   l'UPDATE directe sobre la vista api.projects.
--
-- Semàntica de patch:
--   - Camps no nullables: COALESCE(valor_entrada, valor_actual)
--   - Camps nullables: s'usa parella (p_<camp>, p_<camp>_set)
--       * p_<camp>_set = false i p_<camp> NULL  -> no canvia
--       * p_<camp>_set = true  i p_<camp> NULL  -> neteja (NULL)
--       * p_<camp>_set = true  i p_<camp> valor -> actualitza
--
-- Autorització:
--   owner/manager global OR manager explícit de projecte.
-- =============================================================================

DROP FUNCTION IF EXISTS api.update_project(
  uuid, text, text, text, text, text, uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz
);

DROP FUNCTION IF EXISTS api.update_project(
  uuid, text, text, text, text, text, uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz,
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean
);

CREATE OR REPLACE FUNCTION api.update_project(
  p_id            uuid,
  p_name          text                    DEFAULT NULL,
  p_type          text                    DEFAULT NULL,
  p_description   text                    DEFAULT NULL,
  p_status        text                    DEFAULT NULL,
  p_visibility    text                    DEFAULT NULL,
  p_department_id uuid                    DEFAULT NULL,
  p_site_id       uuid                    DEFAULT NULL,
  p_location_id   uuid                    DEFAULT NULL,
  p_asset_id      uuid                    DEFAULT NULL,
  p_client_id     uuid                    DEFAULT NULL,
  p_planned_start timestamptz             DEFAULT NULL,
  p_planned_end   timestamptz             DEFAULT NULL,
  p_description_set   boolean             DEFAULT false,
  p_department_id_set boolean             DEFAULT false,
  p_site_id_set       boolean             DEFAULT false,
  p_location_id_set   boolean             DEFAULT false,
  p_asset_id_set      boolean             DEFAULT false,
  p_client_id_set     boolean             DEFAULT false,
  p_planned_start_set boolean             DEFAULT false,
  p_planned_end_set   boolean             DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_user_id             uuid := auth.uid();
  v_tenant_id           uuid;
  v_global_role         text;
  v_is_project_manager  boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT p.tenant_id
    INTO v_tenant_id
  FROM data.projects p
  WHERE p.id = p_id
    AND data.can_access_project(p_id);

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_global_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_global_role IS NULL OR v_global_role NOT IN ('owner', 'manager') THEN
    SELECT EXISTS (
      SELECT 1
      FROM data.project_members pm
      WHERE pm.project_id = p_id
        AND pm.user_id    = v_user_id
        AND pm.role       = 'manager'
    ) INTO v_is_project_manager;

    IF NOT v_is_project_manager THEN
      RAISE EXCEPTION 'forbidden: cal ser owner/manager global o manager del projecte'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  UPDATE data.projects SET
    name          = COALESCE(p_name,                   name),
    type          = COALESCE(p_type::data.project_type, type),
    description   = CASE
      WHEN p_description_set OR p_description IS NOT NULL THEN p_description
      ELSE description
    END,
    status        = COALESCE(p_status,                 status),
    visibility    = COALESCE(p_visibility::data.project_visibility, visibility),
    department_id = CASE
      WHEN p_department_id_set OR p_department_id IS NOT NULL THEN p_department_id
      ELSE department_id
    END,
    site_id       = CASE
      WHEN p_site_id_set OR p_site_id IS NOT NULL THEN p_site_id
      ELSE site_id
    END,
    location_id   = CASE
      WHEN p_location_id_set OR p_location_id IS NOT NULL THEN p_location_id
      ELSE location_id
    END,
    asset_id      = CASE
      WHEN p_asset_id_set OR p_asset_id IS NOT NULL THEN p_asset_id
      ELSE asset_id
    END,
    client_id     = CASE
      WHEN p_client_id_set OR p_client_id IS NOT NULL THEN p_client_id
      ELSE client_id
    END,
    planned_start = CASE
      WHEN p_planned_start_set OR p_planned_start IS NOT NULL THEN p_planned_start
      ELSE planned_start
    END,
    planned_end   = CASE
      WHEN p_planned_end_set OR p_planned_end IS NOT NULL THEN p_planned_end
      ELSE planned_end
    END
  WHERE id = p_id;
END;
$$;

REVOKE ALL ON FUNCTION api.update_project(
  uuid, text, text, text, text, text, uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz,
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.update_project(
  uuid, text, text, text, text, text, uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz,
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean
) TO authenticated;

COMMENT ON FUNCTION api.update_project(
  uuid, text, text, text, text, text, uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz,
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean
) IS
  'Actualitza un projecte existent amb semàntica de patch segura i control d''accés explícit.
   Substitueix l''UPDATE sobre api.projects (incompatible amb UPDATE RETURNING de PostgREST).
   L''auditoria queda coberta pel trigger data.trg_projects_audit sobre data.projects.';

-- =============================================================================
-- 6. Notificació PostgREST per recarregar l'schema
-- =============================================================================
NOTIFY pgrst, 'reload schema';
