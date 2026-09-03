-- E4 UI: upsert_calendar_group accepta attendance_geo_enabled + registre settings

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('attendance_geo_enabled', 'tenant', 'settings.manage', false, true,
   'Registra geolocalització als fitxatges per defecte (cascada tenant/site)')
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope,
  description = EXCLUDED.description,
  updated_at = now();

DROP FUNCTION IF EXISTS api.upsert_calendar_group(text, text, text, uuid, boolean, integer, uuid);

CREATE OR REPLACE FUNCTION api.upsert_calendar_group(
  p_name                     text,
  p_color                    text    DEFAULT '#6366f1',
  p_description              text    DEFAULT NULL,
  p_site_id                  uuid    DEFAULT NULL,
  p_is_active                boolean DEFAULT true,
  p_sort_order               int     DEFAULT 0,
  p_id                       uuid    DEFAULT NULL,
  p_attendance_geo_enabled   boolean DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id        uuid := COALESCE(p_id, gen_random_uuid());
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required';
  END IF;

  INSERT INTO data.calendar_groups (
    id, tenant_id, site_id, name, color, description,
    is_active, sort_order, attendance_geo_enabled
  )
  VALUES (
    v_id, v_tenant_id, p_site_id, p_name, p_color, p_description,
    p_is_active, p_sort_order, p_attendance_geo_enabled
  )
  ON CONFLICT (id) DO UPDATE SET
    name                     = EXCLUDED.name,
    color                    = EXCLUDED.color,
    description              = EXCLUDED.description,
    site_id                  = EXCLUDED.site_id,
    is_active                = EXCLUDED.is_active,
    sort_order               = EXCLUDED.sort_order,
    attendance_geo_enabled   = EXCLUDED.attendance_geo_enabled,
    updated_at               = now();

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_calendar_group(text, text, text, uuid, boolean, integer, uuid, boolean) TO authenticated;
