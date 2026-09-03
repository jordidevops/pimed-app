-- Restaura list_calendar_groups després del DROP CASCADE de api.calendar_groups (E4).

CREATE OR REPLACE FUNCTION api.list_calendar_groups(
  p_site_id uuid DEFAULT NULL
)
RETURNS SETOF api.calendar_groups
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = api, data, public
AS $$
  SELECT id, tenant_id, site_id, name, color, description, is_active, sort_order, attendance_geo_enabled, created_at, updated_at
  FROM data.calendar_groups
  WHERE tenant_id = data.active_tenant_id()
    AND is_active = true
    AND (p_site_id IS NULL OR site_id IS NULL OR site_id = p_site_id)
  ORDER BY sort_order, name;
$$;

GRANT EXECUTE ON FUNCTION api.list_calendar_groups(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
