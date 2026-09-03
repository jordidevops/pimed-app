-- =============================================================================
-- Field Service hotfix: list_projects_paginated sort + open/mine filters + enrich
-- =============================================================================

DROP FUNCTION IF EXISTS api.list_projects_paginated(
  uuid, integer, integer, text, text, text, uuid, uuid, timestamptz, timestamptz, text, text
);

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
  p_sort_direction text DEFAULT 'desc',
  p_created_by uuid DEFAULT NULL,
  p_open_only boolean DEFAULT false
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
      AND (
        v_query IS NULL
        OR p.name ILIKE '%' || v_query || '%'
        OR COALESCE(p.description, '') ILIKE '%' || v_query || '%'
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
          CASE WHEN v_sort_field = 'task_count' AND v_sort_direction = 'asc' THEN (
            SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = f.id
          ) END ASC,
          CASE WHEN v_sort_field = 'task_count' AND v_sort_direction = 'desc' THEN (
            SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = f.id
          ) END DESC,
          CASE WHEN v_sort_field = 'pending_task_count' AND v_sort_direction = 'asc' THEN (
            SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = f.id AND t.status <> 'done'
          ) END ASC,
          CASE WHEN v_sort_field = 'pending_task_count' AND v_sort_direction = 'desc' THEN (
            SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = f.id AND t.status <> 'done'
          ) END DESC,
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
  uuid, integer, integer, text, text, text, uuid, uuid, timestamptz, timestamptz, text, text, uuid, boolean
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.count_projects(
  p_tenant_id uuid,
  p_type text DEFAULT NULL,
  p_open_only boolean DEFAULT false,
  p_planned_start_from timestamptz DEFAULT NULL,
  p_planned_start_to timestamptz DEFAULT NULL
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
    AND (p_planned_start_to IS NULL OR p.planned_start <= p_planned_start_to);
$$;

GRANT EXECUTE ON FUNCTION api.count_projects(uuid, text, boolean, timestamptz, timestamptz)
  TO authenticated, service_role;
