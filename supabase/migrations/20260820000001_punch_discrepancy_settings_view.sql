-- E5: vista API discrepàncies + setting tolerància horària per tenant

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  (
    'attendance_punch_discrepancy_tolerance_minutes',
    'tenant',
    'settings.manage',
    false,
    true,
    'Marge en minuts per detectar fitxatge fora d''horari (diàleg incidències E5)'
  )
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope,
  description = EXCLUDED.description,
  updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{"attendance_punch_discrepancy_tolerance_minutes": 15}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

CREATE OR REPLACE VIEW api.attendance_punch_discrepancies
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    employee_id,
    punch_id,
    resolution,
    note,
    context,
    created_at
  FROM data.attendance_punch_discrepancies;

GRANT SELECT ON api.attendance_punch_discrepancies TO authenticated;

NOTIFY pgrst, 'reload schema';
