-- Fase 1 (plan-period-employee-confirm): model attendance_period_confirmations + setting cycle.

CREATE TABLE IF NOT EXISTS data.attendance_period_confirmations (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id       uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  period_from       date        NOT NULL,
  period_to         date        NOT NULL,
  cycle_type        text        NOT NULL
                    CHECK (cycle_type IN ('calendar_month', 'iso_week', 'manual')),
  calendar_year     int,
  calendar_month    int         CHECK (calendar_month IS NULL OR calendar_month BETWEEN 1 AND 12),
  confirmed_at      timestamptz NOT NULL DEFAULT now(),
  confirmed_via     text        NOT NULL
                    CHECK (confirmed_via IN ('employee_portal', 'tenant_app')),
  source_session_id uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT attendance_period_confirmations_period_range
    CHECK (period_from <= period_to),
  CONSTRAINT attendance_period_confirmations_employee_period_unique
    UNIQUE (employee_id, period_from, period_to)
);

CREATE INDEX IF NOT EXISTS idx_attendance_period_confirmations_employee
  ON data.attendance_period_confirmations (employee_id, period_from DESC);

CREATE INDEX IF NOT EXISTS idx_attendance_period_confirmations_legal_month
  ON data.attendance_period_confirmations (employee_id, calendar_year, calendar_month)
  WHERE calendar_year IS NOT NULL AND calendar_month IS NOT NULL;

ALTER TABLE data.attendance_period_confirmations ENABLE ROW LEVEL SECURITY;

CREATE POLICY attendance_period_confirmations_select
  ON data.attendance_period_confirmations
  FOR SELECT
  USING (
    tenant_id = data.active_tenant_id()
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR employee_id IN (SELECT id FROM data.employees WHERE user_id = auth.uid())
    )
  );

CREATE OR REPLACE VIEW api.attendance_period_confirmations
  WITH (security_invoker = true) AS
  SELECT * FROM data.attendance_period_confirmations;

GRANT SELECT ON data.attendance_period_confirmations TO authenticated;
GRANT SELECT ON api.attendance_period_confirmations TO authenticated;

COMMENT ON TABLE data.attendance_period_confirmations IS
  'Confirmació empleat per període de dates (mes natural, setmana ISO o manual). Fase 1 schema; RPCs a Fase 2.';

-- Setting tenant: cicle de confirmació empleat
INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  (
    'attendance_employee_confirm_cycle',
    'tenant',
    'settings.manage',
    false,
    true,
    'Cicle de confirmació del registre per l''empleat: mes natural o setmana ISO (dilluns–diumenge, Europe/Madrid)'
  )
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope,
  description = EXCLUDED.description,
  updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{"attendance_employee_confirm_cycle": "calendar_month"}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

NOTIFY pgrst, 'reload schema';
