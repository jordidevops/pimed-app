-- =============================================================================
-- Field Service FS-1: contact_site_id on projects + writable api.contact_sites
-- =============================================================================

-- 1. Column + FK
ALTER TABLE data.projects
  ADD COLUMN IF NOT EXISTS contact_site_id uuid
    REFERENCES data.contact_sites(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_projects_contact_site_id
  ON data.projects (contact_site_id)
  WHERE contact_site_id IS NOT NULL;

COMMENT ON COLUMN data.projects.contact_site_id
  IS 'Adreça d''obra del client (data.contact_sites). Prioritari a Field Service V1.';

-- 2. Tenant + ownership consistency trigger
CREATE OR REPLACE FUNCTION data.validate_project_contact_site_tenant()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_site_tenant uuid;
  v_site_contact uuid;
BEGIN
  IF NEW.contact_site_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT cs.tenant_id, cs.contact_id
    INTO v_site_tenant, v_site_contact
  FROM data.contact_sites cs
  WHERE cs.id = NEW.contact_site_id;

  IF v_site_tenant IS NULL THEN
    RAISE EXCEPTION 'contact_site % not found', NEW.contact_site_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_site_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION
      'contact_site % does not belong to tenant % (cross-tenant FK on projects.contact_site_id)',
      NEW.contact_site_id, NEW.tenant_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.client_id IS NOT NULL AND v_site_contact <> NEW.client_id THEN
    RAISE EXCEPTION
      'contact_site % does not belong to client %',
      NEW.contact_site_id, NEW.client_id
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_project_contact_site_tenant ON data.projects;
CREATE TRIGGER trg_validate_project_contact_site_tenant
  BEFORE INSERT OR UPDATE OF contact_site_id, client_id ON data.projects
  FOR EACH ROW
  WHEN (NEW.contact_site_id IS NOT NULL)
  EXECUTE FUNCTION data.validate_project_contact_site_tenant();

-- 3. Refresh api.projects view (include contact_site_id)
DROP RULE IF EXISTS "api_projects_insert" ON api.projects;
DROP RULE IF EXISTS "api_projects_delete" ON api.projects;

-- IMPORTANT: CREATE OR REPLACE VIEW no pot reordenar/renombrar columnes.
-- contact_site_id s'afegeix al FINAL (després d'asset_id), igual que asset_id.
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
    p.contact_site_id
  FROM data.projects p;

GRANT SELECT ON api.projects TO authenticated;

CREATE RULE "api_projects_insert" AS ON INSERT TO api.projects
  DO INSTEAD
  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, asset_id, client_id, contact_site_id,
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
    NEW.contact_site_id,
    NEW.planned_start,
    NEW.planned_end,
    COALESCE(NEW.created_by, auth.uid())
  );

GRANT INSERT ON api.projects TO authenticated;
REVOKE UPDATE ON api.projects FROM authenticated;

CREATE RULE "api_projects_delete" AS ON DELETE TO api.projects
  DO INSTEAD
  DELETE FROM data.projects WHERE id = OLD.id;

GRANT DELETE ON api.projects TO authenticated;

-- 4. Writable api.contact_sites
GRANT INSERT, UPDATE, DELETE ON api.contact_sites TO authenticated;

-- 5. create_project — add p_contact_site_id
DROP FUNCTION IF EXISTS api.create_project(
  uuid, text, data.project_type, text, varchar, data.project_visibility,
  uuid, uuid, uuid, uuid, timestamptz, timestamptz
);

CREATE OR REPLACE FUNCTION api.create_project(
  p_tenant_id       uuid,
  p_name            text,
  p_type            data.project_type       DEFAULT 'internal',
  p_description     text                    DEFAULT NULL,
  p_status          varchar                 DEFAULT 'draft',
  p_visibility      data.project_visibility DEFAULT 'company',
  p_department_id   uuid                    DEFAULT NULL,
  p_site_id         uuid                    DEFAULT NULL,
  p_location_id     uuid                    DEFAULT NULL,
  p_client_id       uuid                    DEFAULT NULL,
  p_planned_start   timestamptz             DEFAULT NULL,
  p_planned_end     timestamptz             DEFAULT NULL,
  p_contact_site_id uuid                    DEFAULT NULL
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

  v_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'member') THEN
    RAISE EXCEPTION 'forbidden: el rol ''%'' no pot crear projectes al tenant %', v_role, p_tenant_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_type = 'work_order' AND p_site_id IS NULL THEN
    RAISE EXCEPTION 'work_order_requires_site_id'
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, client_id, contact_site_id,
    planned_start, planned_end, created_by
  )
  VALUES (
    p_tenant_id, p_type, p_name, p_description,
    COALESCE(p_status, 'draft'), COALESCE(p_visibility, 'company'),
    p_department_id, p_site_id, p_location_id, p_client_id, p_contact_site_id,
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
  uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid
) TO authenticated, service_role;

-- 6. update_project — patch contact_site_id
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
  v_user_id               uuid := auth.uid();
  v_tenant_id             uuid;
  v_global_role           text;
  v_is_project_manager    boolean := false;
  v_current_type          data.project_type;
  v_current_site_id       uuid;
  v_current_planned_start timestamptz;
  v_new_type              data.project_type;
  v_new_site_id           uuid;
  v_new_planned_start     timestamptz;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT p.tenant_id, p.type, p.site_id, p.planned_start
    INTO v_tenant_id, v_current_type, v_current_site_id, v_current_planned_start
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

  v_new_type    := COALESCE((p_patch->>'type')::data.project_type, v_current_type);
  v_new_site_id := CASE
    WHEN p_patch ? 'site_id' THEN (p_patch->>'site_id')::uuid
    ELSE v_current_site_id
  END;

  IF v_new_type = 'work_order' AND v_new_site_id IS NULL THEN
    RAISE EXCEPTION 'work_order_requires_site_id'
      USING ERRCODE = 'check_violation';
  END IF;

  v_new_planned_start := CASE
    WHEN p_patch ? 'planned_start' THEN (p_patch->>'planned_start')::timestamptz
    ELSE v_current_planned_start
  END;

  UPDATE data.projects SET
    name            = CASE WHEN p_patch ? 'name'            THEN p_patch->>'name'                                            ELSE name            END,
    type            = CASE WHEN p_patch ? 'type'            THEN (p_patch->>'type')::data.project_type                       ELSE type            END,
    description     = CASE WHEN p_patch ? 'description'     THEN p_patch->>'description'                                     ELSE description     END,
    status          = CASE WHEN p_patch ? 'status'          THEN p_patch->>'status'                                          ELSE status          END,
    visibility      = CASE WHEN p_patch ? 'visibility'      THEN (p_patch->>'visibility')::data.project_visibility            ELSE visibility      END,
    department_id   = CASE WHEN p_patch ? 'department_id'   THEN (p_patch->>'department_id')::uuid                           ELSE department_id   END,
    site_id         = CASE WHEN p_patch ? 'site_id'         THEN (p_patch->>'site_id')::uuid                                 ELSE site_id         END,
    location_id     = CASE WHEN p_patch ? 'location_id'     THEN (p_patch->>'location_id')::uuid                             ELSE location_id     END,
    asset_id        = CASE WHEN p_patch ? 'asset_id'        THEN (p_patch->>'asset_id')::uuid                                ELSE asset_id        END,
    client_id       = CASE WHEN p_patch ? 'client_id'       THEN (p_patch->>'client_id')::uuid                               ELSE client_id       END,
    contact_site_id = CASE WHEN p_patch ? 'contact_site_id' THEN (p_patch->>'contact_site_id')::uuid                         ELSE contact_site_id END,
    planned_start   = CASE WHEN p_patch ? 'planned_start'   THEN (p_patch->>'planned_start')::timestamptz                    ELSE planned_start   END,
    planned_end     = CASE WHEN p_patch ? 'planned_end'     THEN (p_patch->>'planned_end')::timestamptz                      ELSE planned_end     END
  WHERE id = p_id;

  IF p_patch ? 'planned_start' OR p_patch ? 'planned_end' OR p_patch ? 'name' OR p_patch ? 'site_id' THEN
    IF v_current_planned_start IS NULL AND v_new_planned_start IS NOT NULL THEN
      PERFORM pgmq.send(
        'project_events',
        jsonb_build_object(
          'task',            'PROJECT_DATES_SET',
          'project_id',      p_id,
          'tenant_id',       v_tenant_id,
          'idempotency_key', 'dates-set-' || p_id::text || '-' || txid_current()::text
        )
      );
    ELSIF v_current_planned_start IS NOT NULL AND v_new_planned_start IS NULL THEN
      DELETE FROM data.calendar_events
      WHERE entity_type = 'project'
        AND entity_id   = p_id;
    ELSIF v_current_planned_start IS NOT NULL AND v_new_planned_start IS NOT NULL THEN
      UPDATE data.calendar_events SET
        title      = CASE WHEN p_patch ? 'name' THEN p_patch->>'name' ELSE title END,
        site_id    = CASE
                       WHEN p_patch ? 'site_id' THEN (p_patch->>'site_id')::uuid
                       ELSE site_id
                     END,
        start_at   = v_new_planned_start,
        end_at     = CASE
                       WHEN p_patch ? 'planned_end' THEN (p_patch->>'planned_end')::timestamptz
                       ELSE end_at
                     END,
        updated_at = now()
      WHERE entity_type = 'project'
        AND entity_id   = p_id;

      IF NOT FOUND THEN
        INSERT INTO data.calendar_events (
          tenant_id, site_id, entity_type, entity_id, title, start_at, end_at
        )
        SELECT
          v_tenant_id,
          COALESCE(v_new_site_id, v_current_site_id),
          'project',
          p_id,
          COALESCE(p_patch->>'name', (SELECT name FROM data.projects WHERE id = p_id)),
          v_new_planned_start,
          CASE
            WHEN p_patch ? 'planned_end' THEN (p_patch->>'planned_end')::timestamptz
            ELSE (SELECT planned_end FROM data.projects WHERE id = p_id)
          END;
      END IF;
    END IF;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_project(uuid, jsonb) TO authenticated, service_role;

-- 7. list_projects_paginated — include contact_site_id in items
CREATE OR REPLACE FUNCTION api.list_projects_paginated(
  p_tenant_id uuid,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20,
  p_query text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_type text DEFAULT NULL,
  p_site_id uuid DEFAULT NULL,
  p_department_id uuid DEFAULT NULL,
  p_planned_start_from timestamptz DEFAULT NULL,
  p_planned_start_to timestamptz DEFAULT NULL,
  p_sort_field text DEFAULT 'created_at',
  p_sort_direction text DEFAULT 'desc'
)
RETURNS TABLE (
  items jsonb,
  total_count bigint,
  page integer,
  page_size integer
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_page integer := GREATEST(COALESCE(p_page, 1), 1);
  v_page_size integer := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_query text := NULLIF(btrim(p_query), '');
  v_status text := NULLIF(btrim(p_status), '');
  v_type text := NULLIF(btrim(p_type), '');
  v_sort_field text := lower(COALESCE(NULLIF(btrim(p_sort_field), ''), 'created_at'));
  v_sort_direction text := CASE WHEN lower(COALESCE(NULLIF(btrim(p_sort_direction), ''), 'desc')) = 'asc' THEN 'asc' ELSE 'desc' END;
BEGIN
  RETURN QUERY
  WITH filtered AS (
    SELECT p.*
    FROM data.projects p
    WHERE p.tenant_id = p_tenant_id
      AND (
        v_query IS NULL
        OR p.name ILIKE '%' || v_query || '%'
        OR COALESCE(p.description, '') ILIKE '%' || v_query || '%'
      )
      AND (v_status IS NULL OR p.status = v_status)
      AND (v_type IS NULL OR p.type = v_type::data.project_type)
      AND (p_site_id IS NULL OR p.site_id = p_site_id)
      AND (p_department_id IS NULL OR p.department_id = p_department_id)
      AND (p_planned_start_from IS NULL OR p.planned_start >= p_planned_start_from)
      AND (p_planned_start_to IS NULL OR p.planned_start <= p_planned_start_to)
  ),
  total AS (
    SELECT COUNT(*)::bigint AS total_count
    FROM filtered
  ),
  paged AS (
    SELECT *
    FROM filtered
    ORDER BY
      CASE WHEN v_sort_field = 'name' AND v_sort_direction = 'asc' THEN name END ASC,
      CASE WHEN v_sort_field = 'name' AND v_sort_direction = 'desc' THEN name END DESC,
      CASE WHEN v_sort_field = 'type' AND v_sort_direction = 'asc' THEN type END ASC,
      CASE WHEN v_sort_field = 'type' AND v_sort_direction = 'desc' THEN type END DESC,
      CASE WHEN v_sort_field = 'status' AND v_sort_direction = 'asc' THEN status END ASC,
      CASE WHEN v_sort_field = 'status' AND v_sort_direction = 'desc' THEN status END DESC,
      CASE WHEN v_sort_field = 'planned_start' AND v_sort_direction = 'asc' THEN planned_start END ASC NULLS LAST,
      CASE WHEN v_sort_field = 'planned_start' AND v_sort_direction = 'desc' THEN planned_start END DESC NULLS LAST,
      CASE WHEN v_sort_field = 'task_count' AND v_sort_direction = 'asc' THEN (
        SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = id
      ) END ASC,
      CASE WHEN v_sort_field = 'task_count' AND v_sort_direction = 'desc' THEN (
        SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = id
      ) END DESC,
      CASE WHEN v_sort_field = 'pending_task_count' AND v_sort_direction = 'asc' THEN (
        SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = id AND t.status <> 'done'
      ) END ASC,
      CASE WHEN v_sort_field = 'pending_task_count' AND v_sort_direction = 'desc' THEN (
        SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = id AND t.status <> 'done'
      ) END DESC,
      created_at DESC,
      id DESC
    LIMIT v_page_size
    OFFSET (v_page - 1) * v_page_size
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'tenant_id', p.tenant_id,
          'type', p.type,
          'name', p.name,
          'description', p.description,
          'status', p.status,
          'visibility', p.visibility,
          'department_id', p.department_id,
          'site_id', p.site_id,
          'location_id', p.location_id,
          'client_id', p.client_id,
          'contact_site_id', p.contact_site_id,
          'planned_start', p.planned_start,
          'planned_end', p.planned_end,
          'created_by', p.created_by,
          'created_at', p.created_at,
          'updated_at', p.updated_at,
          'task_count', (
            SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = p.id
          ),
          'pending_task_count', (
            SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = p.id AND t.status <> 'done'
          ),
          'member_count', (
            SELECT COUNT(*)::int FROM data.project_members pm WHERE pm.project_id = p.id
          ),
          'asset_id', p.asset_id
        )
        ORDER BY p.created_at DESC, p.id DESC
      )
      FROM paged p
    ), '[]'::jsonb) AS items,
    total.total_count,
    v_page,
    v_page_size
  FROM total;
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_projects_paginated(
  uuid, integer, integer, text, text, text, uuid, uuid, timestamptz, timestamptz, text, text
) TO authenticated, service_role;
