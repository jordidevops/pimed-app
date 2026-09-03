-- EP-ACC-5: settings de política pública del portal + RPC allowlist per bootstrap de sessió.

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('employee_portal.default_pin_required', 'tenant', 'settings.manage', false, true,
   'Per defecte, els nous enllaços del portal d''empleat requereixen PIN'),
  ('employee_portal.shared_device_idle_timeout_minutes', 'tenant', 'settings.manage', false, true,
   'Minuts sense interacció abans de tancar sessió en dispositiu compartit (QR taulell)')
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope,
  description = EXCLUDED.description,
  updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{
  "employee_portal.default_pin_required": true,
  "employee_portal.shared_device_idle_timeout_minutes": 10
}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

CREATE OR REPLACE FUNCTION api.get_employee_portal_public_policy(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp      record;
  v_settings jsonb;
  v_idle     int;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);

  v_idle := COALESCE(
    NULLIF((v_settings->>'employee_portal.shared_device_idle_timeout_minutes')::int, 0),
    10
  );
  v_idle := LEAST(60, GREATEST(1, v_idle));

  RETURN jsonb_build_object(
    'default_pin_required',
      COALESCE((v_settings->>'employee_portal.default_pin_required')::boolean, true),
    'shared_device_idle_timeout_minutes', v_idle
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_employee_portal_public_policy(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_employee_portal_public_policy(uuid) TO service_role;
