-- =============================================================================
-- Migration: 20260511000001_update_project_rpc_v2.sql
--
-- Fase 0-A: api.update_project → signatura p_patch jsonb
-- Pas 7:    create_project    → validació type-aware + NULL-safe fix
--
-- Motivació de la migració:
--   La signatura antiga (21 params, 8 booleans p_*_set) no escala: cada camp
--   nou requeria +2 paràmetres i una signatura de DROP FUNCTION exacta fràgil.
--   El nou patró usa un únic p_patch jsonb on la presència d'una clau indica
--   "actualitza" i l'absència indica "no toquis". Escala O(1) per camp nou.
--
-- Idempotent: DROP IF EXISTS per ambdues signatures antigues + CREATE OR REPLACE.
-- Auditoria: coberta pel trigger data.trg_projects_audit sobre data.projects.
-- =============================================================================

-- =============================================================================
-- 1. Eliminar signatures antigues de api.update_project
-- =============================================================================

DROP FUNCTION IF EXISTS api.update_project(
  uuid, text, text, text, text, text, uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz,
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean
);

DROP FUNCTION IF EXISTS api.update_project(
  uuid, text, text, text, text, text, uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz
);

-- =============================================================================
-- 2. Nova funció api.update_project amb p_patch jsonb
--
-- Semàntica del patch:
--   { "name": "Nou nom" }                → actualitza només name
--   { "site_id": null }                  → neteja site_id (posa NULL)
--   { "name": "A", "description": null } → actualitza name, neteja description
--   {}                                   → no canvia res
-- =============================================================================

CREATE OR REPLACE FUNCTION api.update_project(
  p_id    uuid,
  p_patch jsonb
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
  v_current_type        data.project_type;
  v_current_site_id     uuid;
  v_new_type            data.project_type;
  v_new_site_id         uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT p.tenant_id, p.type, p.site_id
    INTO v_tenant_id, v_current_type, v_current_site_id
  FROM data.projects p
  WHERE p.id = p_id
    AND data.can_access_project(p_id);

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Permís: NULL-safe — evitar bypass via semàntica tri-valued de NOT IN
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

  -- Validació type-aware: work_order requereix site_id
  -- Evalua el tipus i site_id finals (actuals o el que arriba al patch)
  v_new_type    := COALESCE((p_patch->>'type')::data.project_type, v_current_type);
  v_new_site_id := CASE
    WHEN p_patch ? 'site_id' THEN (p_patch->>'site_id')::uuid
    ELSE v_current_site_id
  END;

  IF v_new_type = 'work_order' AND v_new_site_id IS NULL THEN
    RAISE EXCEPTION 'work_order_requires_site_id'
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.projects SET
    name          = CASE WHEN p_patch ? 'name'          THEN p_patch->>'name'                                           ELSE name          END,
    type          = CASE WHEN p_patch ? 'type'          THEN (p_patch->>'type')::data.project_type                      ELSE type          END,
    description   = CASE WHEN p_patch ? 'description'   THEN p_patch->>'description'                                    ELSE description   END,
    status        = CASE WHEN p_patch ? 'status'        THEN p_patch->>'status'                                         ELSE status        END,
    visibility    = CASE WHEN p_patch ? 'visibility'    THEN (p_patch->>'visibility')::data.project_visibility           ELSE visibility    END,
    department_id = CASE WHEN p_patch ? 'department_id' THEN (p_patch->>'department_id')::uuid                          ELSE department_id END,
    site_id       = CASE WHEN p_patch ? 'site_id'       THEN (p_patch->>'site_id')::uuid                                ELSE site_id       END,
    location_id   = CASE WHEN p_patch ? 'location_id'   THEN (p_patch->>'location_id')::uuid                            ELSE location_id   END,
    asset_id      = CASE WHEN p_patch ? 'asset_id'      THEN (p_patch->>'asset_id')::uuid                               ELSE asset_id      END,
    client_id     = CASE WHEN p_patch ? 'client_id'     THEN (p_patch->>'client_id')::uuid                              ELSE client_id     END,
    planned_start = CASE WHEN p_patch ? 'planned_start' THEN (p_patch->>'planned_start')::timestamptz                   ELSE planned_start END,
    planned_end   = CASE WHEN p_patch ? 'planned_end'   THEN (p_patch->>'planned_end')::timestamptz                     ELSE planned_end   END
  WHERE id = p_id;
END;
$$;

REVOKE ALL ON FUNCTION api.update_project(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_project(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION api.update_project(uuid, jsonb) IS
  'Actualitza un projecte amb semàntica de patch jsonb (v2).
   La presència d''una clau a p_patch indica "actualitza"; l''absència = "no toquis".
   Inclou null per netejar camps nullables (ex: { "site_id": null }).
   Escala O(1) per camp nou. Substitueix la signatura v1 amb booleans p_*_set.
   Autorització: owner/manager global OR manager explícit de projecte (NULL-safe).
   Auditoria: trigger data.trg_projects_audit sobre data.projects.';

-- =============================================================================
-- 3. Reescriure api.create_project: NULL-safe + type-aware
--
-- Fixes:
--   a) v_role NOT IN (...) era vulnerable a NULL bypass (NULL NOT IN = NULL → fals en SQL)
--   b) Afegir validació: work_order sense site_id rebutjat en creació
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_project(
  p_tenant_id     uuid,
  p_name          text,
  p_type          data.project_type       DEFAULT 'internal',
  p_description   text                    DEFAULT NULL,
  p_status        varchar                 DEFAULT 'draft',
  p_visibility    data.project_visibility DEFAULT 'company',
  p_department_id uuid                    DEFAULT NULL,
  p_site_id       uuid                    DEFAULT NULL,
  p_location_id   uuid                    DEFAULT NULL,
  p_client_id     uuid                    DEFAULT NULL,
  p_planned_start timestamptz             DEFAULT NULL,
  p_planned_end   timestamptz             DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_project_id uuid;
  v_role       text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- NULL-safe: v_role IS NULL cobreix el cas de JWT sense claim per aquest tenant
  v_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'member') THEN
    RAISE EXCEPTION 'forbidden: el rol ''%'' no pot crear projectes al tenant %', v_role, p_tenant_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validació type-aware: work_order requereix site_id
  IF p_type = 'work_order' AND p_site_id IS NULL THEN
    RAISE EXCEPTION 'work_order_requires_site_id'
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, client_id,
    planned_start, planned_end, created_by
  )
  VALUES (
    p_tenant_id, p_type, p_name, p_description,
    COALESCE(p_status, 'draft'), COALESCE(p_visibility, 'company'),
    p_department_id, p_site_id, p_location_id, p_client_id,
    p_planned_start, p_planned_end, v_user_id
  )
  RETURNING id INTO v_project_id;

  INSERT INTO data.project_members (project_id, user_id, role)
  VALUES (v_project_id, v_user_id, 'manager');

  IF p_planned_start IS NOT NULL THEN
    PERFORM pgmq.send(
      'project_events',
      jsonb_build_object(
        'event',         'PROJECT_CREATED',
        'project_id',    v_project_id,
        'tenant_id',     p_tenant_id,
        'name',          p_name,
        'type',          p_type,
        'planned_start', p_planned_start,
        'created_by',    v_user_id
      )
    );
  END IF;

  RETURN v_project_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_project(
  uuid, text, data.project_type, text, varchar, data.project_visibility,
  uuid, uuid, uuid, uuid, timestamptz, timestamptz
) TO authenticated;

COMMENT ON FUNCTION api.create_project(
  uuid, text, data.project_type, text, varchar, data.project_visibility,
  uuid, uuid, uuid, uuid, timestamptz, timestamptz
) IS
  'Crea un projecte de forma transaccional (v2).
   Fixes: rol NULL-safe (evita bypass via tri-valued SQL), validació type-aware
   (work_order requereix site_id). Manté la lògica original d''event asíncron pgmq.';

-- =============================================================================
-- 4. Notificar PostgREST per recarregar l'schema
-- =============================================================================
NOTIFY pgrst, 'reload schema';
