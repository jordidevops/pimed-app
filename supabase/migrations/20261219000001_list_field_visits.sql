-- Field visits agenda: list work_order/maintenance with members (RLS via SECURITY INVOKER).

CREATE INDEX IF NOT EXISTS idx_projects_tenant_planned_start
  ON data.projects (tenant_id, planned_start);

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

REVOKE ALL ON FUNCTION api.list_field_visits(
  uuid, timestamptz, timestamptz, text[], uuid[], text[], boolean, boolean, integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.list_field_visits(
  uuid, timestamptz, timestamptz, text[], uuid[], text[], boolean, boolean, integer
) FROM anon;
GRANT EXECUTE ON FUNCTION api.list_field_visits(
  uuid, timestamptz, timestamptz, text[], uuid[], text[], boolean, boolean, integer
) TO authenticated, service_role;

COMMENT ON FUNCTION api.list_field_visits IS
  'Agenda de visites FSM: work_order/maintenance amb membres. RLS via SECURITY INVOKER sobre data.projects.';

NOTIFY pgrst, 'reload schema';
