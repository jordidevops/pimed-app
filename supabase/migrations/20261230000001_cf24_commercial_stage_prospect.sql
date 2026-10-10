-- CF-24 Option C: commercial_stage prospect | execute (not assessment).
-- Prospect OS: quote prep only; excluded from field queues by default.

-- 1. Column
ALTER TABLE data.projects
  ADD COLUMN IF NOT EXISTS commercial_stage text;

UPDATE data.projects
SET commercial_stage = 'execute'
WHERE commercial_stage IS NULL;

ALTER TABLE data.projects
  ALTER COLUMN commercial_stage SET DEFAULT 'execute',
  ALTER COLUMN commercial_stage SET NOT NULL;

ALTER TABLE data.projects DROP CONSTRAINT IF EXISTS projects_commercial_stage_check;
ALTER TABLE data.projects
  ADD CONSTRAINT projects_commercial_stage_check
  CHECK (commercial_stage IN ('prospect', 'execute'));

COMMENT ON COLUMN data.projects.commercial_stage IS
  'execute = feina operativa; prospect = OS comercial (Preparar/pressupost) fora de cues de camp. ≠ service_mode assessment.';

CREATE INDEX IF NOT EXISTS idx_projects_commercial_stage
  ON data.projects (tenant_id, commercial_stage)
  WHERE commercial_stage = 'prospect';

-- 2. api.projects view
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
    p.visit_intent,
    p.client_report_published_at,
    p.client_report_published_by,
    p.authorized_total,
    p.commercial_regime,
    p.service_mode,
    p.commercial_stage
  FROM data.projects p;

GRANT SELECT ON api.projects TO authenticated, service_role;

-- 3. Create prospect work order (quote-first shell)
CREATE OR REPLACE FUNCTION api.create_prospect_work_order(
  p_tenant_id uuid,
  p_name text,
  p_client_id uuid,
  p_contact_site_id uuid DEFAULT NULL,
  p_site_id uuid DEFAULT NULL,
  p_description text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_project_id uuid;
  v_role text;
  v_name text := NULLIF(btrim(p_name), '');
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_tenant_id IS NULL OR p_client_id IS NULL OR v_name IS NULL THEN
    RAISE EXCEPTION 'prospect_requires_client_and_name' USING ERRCODE = '22023';
  END IF;

  v_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'member') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.contacts c
    WHERE c.id = p_client_id AND c.tenant_id = p_tenant_id AND c.is_archived = false
  ) THEN
    RAISE EXCEPTION 'client_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    site_id, client_id, contact_site_id, created_by,
    commercial_stage, service_mode
  )
  VALUES (
    p_tenant_id, 'work_order', v_name, p_description,
    'draft', 'company',
    p_site_id, p_client_id, p_contact_site_id, v_user_id,
    'prospect', 'execute'
  )
  RETURNING id INTO v_project_id;

  INSERT INTO data.project_members (project_id, user_id, role)
  VALUES (v_project_id, v_user_id, 'manager');

  RETURN v_project_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_prospect_work_order(uuid, text, uuid, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_prospect_work_order(uuid, text, uuid, uuid, uuid, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.promote_project_to_execute(p_project_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_role text;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context' USING ERRCODE = 'P0001';
  END IF;
  v_role := data.jwt_user_tenants() -> v_tenant::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'member') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.projects
  SET commercial_stage = 'execute',
      status = CASE WHEN status = 'draft' THEN 'active' ELSE status END,
      updated_at = now()
  WHERE id = p_project_id
    AND tenant_id = v_tenant
    AND commercial_stage = 'prospect';

  IF NOT FOUND THEN
    -- Idempotent if already execute
    IF NOT EXISTS (
      SELECT 1 FROM data.projects
      WHERE id = p_project_id AND tenant_id = v_tenant AND commercial_stage = 'execute'
    ) THEN
      RAISE EXCEPTION 'project_not_found_or_not_prospect' USING ERRCODE = 'P0001';
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.promote_project_to_execute(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.promote_project_to_execute(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.cancel_prospect_project(p_project_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_role text;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context' USING ERRCODE = 'P0001';
  END IF;
  v_role := data.jwt_user_tenants() -> v_tenant::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'member') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.projects
  SET status = 'cancelled', updated_at = now()
  WHERE id = p_project_id
    AND tenant_id = v_tenant
    AND commercial_stage = 'prospect'
    AND status IS DISTINCT FROM 'cancelled';
END;
$$;

REVOKE ALL ON FUNCTION api.cancel_prospect_project(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.cancel_prospect_project(uuid)
  TO authenticated, service_role;

-- 4. Field queues: exclude prospect
CREATE OR REPLACE FUNCTION api.list_field_visits(
  p_tenant_id uuid,
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_types text[] DEFAULT ARRAY['work_order', 'maintenance'],
  p_member_ids uuid[] DEFAULT NULL,
  p_statuses text[] DEFAULT NULL,
  p_open_only boolean DEFAULT true,
  p_unscheduled boolean DEFAULT false,
  p_limit integer DEFAULT 500
)
RETURNS TABLE (
  id uuid,
  type text,
  name text,
  status text,
  planned_start timestamptz,
  planned_end timestamptz,
  client_display_name text,
  contact_site_name text,
  contact_site_city text,
  service_mode text,
  commercial_regime text,
  members jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 1000);
  v_types text[] := COALESCE(NULLIF(p_types, ARRAY[]::text[]), ARRAY['work_order', 'maintenance']);
BEGIN
  IF NOT COALESCE(p_unscheduled, false) THEN
    IF p_from IS NULL OR p_to IS NULL THEN
      RAISE EXCEPTION 'p_from and p_to are required when p_unscheduled is false'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'forbidden'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.type::text AS type,
    p.name::text AS name,
    p.status::text AS status,
    p.planned_start,
    p.planned_end,
    c.display_name::text AS client_display_name,
    cs.name::text AS contact_site_name,
    cs.city::text AS contact_site_city,
    p.service_mode::text AS service_mode,
    p.commercial_regime::text AS commercial_regime,
    COALESCE(mem.members, '[]'::jsonb) AS members
  FROM data.projects p
  LEFT JOIN data.contacts c ON c.id = p.client_id
  LEFT JOIN data.contact_sites cs ON cs.id = p.contact_site_id
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_build_object(
        'user_id', pm.user_id,
        'display_name', COALESCE(NULLIF(btrim(pr.full_name), ''), pr.email, pm.user_id::text),
        'role', pm.role
      )
      ORDER BY pr.full_name NULLS LAST, pr.email
    ) AS members
    FROM data.project_members pm
    LEFT JOIN data.profiles pr ON pr.id = pm.user_id
    WHERE pm.project_id = p.id
  ) mem ON true
  WHERE p.tenant_id = p_tenant_id
    AND COALESCE(p.commercial_stage, 'execute') = 'execute'
    AND p.type::text = ANY (v_types)
    AND (
      NOT COALESCE(p_open_only, true)
      OR p.status NOT IN ('completed', 'cancelled')
    )
    AND (
      p_statuses IS NULL
      OR cardinality(p_statuses) = 0
      OR p.status = ANY (p_statuses)
    )
    AND (
      CASE
        WHEN COALESCE(p_unscheduled, false) THEN p.planned_start IS NULL
        ELSE p.planned_start IS NOT NULL
          AND p.planned_start >= p_from
          AND p.planned_start < p_to
      END
    )
    AND (
      p_member_ids IS NULL
      OR cardinality(p_member_ids) = 0
      OR EXISTS (
        SELECT 1
        FROM data.project_members pmf
        WHERE pmf.project_id = p.id
          AND pmf.user_id = ANY (p_member_ids)
      )
    )
  ORDER BY
    CASE WHEN COALESCE(p_unscheduled, false) THEN p.updated_at END DESC NULLS LAST,
    p.planned_start ASC NULLS LAST,
    p.name ASC
  LIMIT v_limit;
END;
$$;

CREATE OR REPLACE FUNCTION api.count_projects(
  p_tenant_id uuid,
  p_type text DEFAULT NULL,
  p_open_only boolean DEFAULT false,
  p_planned_start_from timestamptz DEFAULT NULL,
  p_planned_start_to timestamptz DEFAULT NULL,
  p_include_prospect boolean DEFAULT false
)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
  SELECT COUNT(*)::bigint
  FROM data.projects p
  WHERE p.tenant_id = p_tenant_id
    AND (p_type IS NULL OR p.type = p_type::data.project_type)
    AND (
      NOT COALESCE(p_open_only, false)
      OR p.status NOT IN ('completed', 'cancelled')
    )
    AND (p_planned_start_from IS NULL OR p.planned_start >= p_planned_start_from)
    AND (p_planned_start_to IS NULL OR p.planned_start <= p_planned_start_to)
    AND (
      COALESCE(p_include_prospect, false)
      OR COALESCE(p.commercial_stage, 'execute') = 'execute'
    );
$$;

DROP FUNCTION IF EXISTS api.count_projects(uuid, text, boolean, timestamptz, timestamptz);
GRANT EXECUTE ON FUNCTION api.count_projects(uuid, text, boolean, timestamptz, timestamptz, boolean)
  TO authenticated, service_role;

-- list_projects_paginated: exclude prospect unless p_include_prospect
DROP FUNCTION IF EXISTS api.list_projects_paginated(
  uuid, integer, integer, text, text, text, uuid, uuid, timestamptz, timestamptz, text, text, uuid, boolean, uuid
);

CREATE FUNCTION api.list_projects_paginated(
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
  p_sort_direction text DEFAULT 'desc',
  p_created_by uuid DEFAULT NULL,
  p_open_only boolean DEFAULT false,
  p_client_id uuid DEFAULT NULL,
  p_include_prospect boolean DEFAULT false
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
    SELECT
      p.*,
      c.display_name AS client_display_name,
      cs.name AS contact_site_name,
      cs.address AS contact_site_address,
      cs.city AS contact_site_city,
      cs.postal_code AS contact_site_postal_code
    FROM data.projects p
    LEFT JOIN data.contacts c ON c.id = p.client_id
    LEFT JOIN data.contact_sites cs ON cs.id = p.contact_site_id
    WHERE p.tenant_id = p_tenant_id
      AND (p_client_id IS NULL OR p.client_id = p_client_id)
      AND (
        COALESCE(p_include_prospect, false)
        OR COALESCE(p.commercial_stage, 'execute') = 'execute'
        OR p_client_id IS NOT NULL
      )
      AND (
        v_query IS NULL
        OR p.name ILIKE '%' || v_query || '%'
        OR COALESCE(p.description, '') ILIKE '%' || v_query || '%'
        OR COALESCE(c.display_name, '') ILIKE '%' || v_query || '%'
        OR COALESCE(cs.name, '') ILIKE '%' || v_query || '%'
        OR COALESCE(cs.city, '') ILIKE '%' || v_query || '%'
      )
      AND (v_status IS NULL OR p.status = v_status)
      AND (
        NOT COALESCE(p_open_only, false)
        OR p.status NOT IN ('completed', 'cancelled')
      )
      AND (v_type IS NULL OR p.type = v_type::data.project_type)
      AND (p_site_id IS NULL OR p.site_id = p_site_id)
      AND (p_department_id IS NULL OR p.department_id = p_department_id)
      AND (p_created_by IS NULL OR p.created_by = p_created_by)
      AND (p_planned_start_from IS NULL OR p.planned_start >= p_planned_start_from)
      AND (p_planned_start_to IS NULL OR p.planned_start <= p_planned_start_to)
  ),
  total AS (
    SELECT COUNT(*)::bigint AS total_count
    FROM filtered
  ),
  ranked AS (
    SELECT
      f.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN v_sort_field = 'name' AND v_sort_direction = 'asc' THEN f.name END ASC,
          CASE WHEN v_sort_field = 'name' AND v_sort_direction = 'desc' THEN f.name END DESC,
          CASE WHEN v_sort_field = 'type' AND v_sort_direction = 'asc' THEN f.type END ASC,
          CASE WHEN v_sort_field = 'type' AND v_sort_direction = 'desc' THEN f.type END DESC,
          CASE WHEN v_sort_field = 'status' AND v_sort_direction = 'asc' THEN f.status END ASC,
          CASE WHEN v_sort_field = 'status' AND v_sort_direction = 'desc' THEN f.status END DESC,
          CASE WHEN v_sort_field = 'planned_start' AND v_sort_direction = 'asc' THEN f.planned_start END ASC NULLS LAST,
          CASE WHEN v_sort_field = 'planned_start' AND v_sort_direction = 'desc' THEN f.planned_start END DESC NULLS LAST,
          f.created_at DESC,
          f.id DESC
      ) AS rn
    FROM filtered f
  ),
  paged AS (
    SELECT *
    FROM ranked
    WHERE rn > (v_page - 1) * v_page_size
      AND rn <= v_page * v_page_size
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
          'client_display_name', p.client_display_name,
          'contact_site_name', p.contact_site_name,
          'contact_site_address', p.contact_site_address,
          'contact_site_city', p.contact_site_city,
          'contact_site_postal_code', p.contact_site_postal_code,
          'planned_start', p.planned_start,
          'planned_end', p.planned_end,
          'created_by', p.created_by,
          'created_at', p.created_at,
          'updated_at', p.updated_at,
          'commercial_stage', p.commercial_stage,
          'service_mode', p.service_mode,
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
        ORDER BY p.rn
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
  uuid, integer, integer, text, text, text, uuid, uuid, timestamptz, timestamptz, text, text, uuid, boolean, uuid, boolean
) TO authenticated, service_role;

-- 5. On quote accept/decline: promote or cancel prospect shell
CREATE OR REPLACE FUNCTION data.sync_prospect_project_on_quote_decision(
  p_project_id uuid,
  p_outcome text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_project_id IS NULL THEN
    RETURN;
  END IF;

  IF p_outcome = 'accepted' THEN
    UPDATE data.projects
    SET commercial_stage = 'execute',
        status = CASE WHEN status = 'draft' THEN 'active' ELSE status END,
        updated_at = now()
    WHERE id = p_project_id
      AND commercial_stage = 'prospect';
  ELSIF p_outcome IN ('declined', 'rejected', 'expired', 'cancelled') THEN
    UPDATE data.projects
    SET status = 'cancelled', updated_at = now()
    WHERE id = p_project_id
      AND commercial_stage = 'prospect'
      AND status IS DISTINCT FROM 'cancelled';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.sync_prospect_project_on_quote_decision(uuid, text) FROM PUBLIC;

NOTIFY pgrst, 'reload schema';
