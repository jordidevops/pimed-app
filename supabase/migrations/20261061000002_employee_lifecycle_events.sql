-- =============================================================================
-- M-ES-02 — Ledger lifecycle + regles de transició + backfill idempotent
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.employee_lifecycle_events (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id   uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  from_state    text,
  to_state      text        NOT NULL,
  reason_code   text        NOT NULL,
  effective_on  date        NOT NULL DEFAULT CURRENT_DATE,
  triggered_by  uuid        REFERENCES data.profiles(id),
  source        text        NOT NULL DEFAULT 'manual'
                CHECK (source IN ('manual', 'contract', 'automation', 'import')),
  metadata      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_lifecycle_events_employee
  ON data.employee_lifecycle_events (employee_id, effective_on DESC);

CREATE INDEX IF NOT EXISTS idx_lifecycle_events_tenant_recent
  ON data.employee_lifecycle_events (tenant_id, created_at DESC);

CREATE TABLE IF NOT EXISTS data.employee_lifecycle_transition_rules (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_state          text NOT NULL,
  to_state            text NOT NULL,
  requires_permission text NOT NULL DEFAULT 'employees.lifecycle.manage',
  requires_reason     boolean NOT NULL DEFAULT true,
  auto_reason_codes   text[] NOT NULL DEFAULT '{}'::text[],
  UNIQUE (from_state, to_state)
);

INSERT INTO data.employee_lifecycle_transition_rules (
  from_state, to_state, requires_permission, requires_reason, auto_reason_codes
) VALUES
  ('onboarding', 'active',    'employees.lifecycle.manage', true, ARRAY['onboarding_completed']),
  ('active',     'on_leave',  'employees.lifecycle.manage', true, ARRAY['leave_started']),
  ('on_leave',   'active',    'employees.lifecycle.manage', true, ARRAY['leave_ended']),
  ('active',     'departure', 'employees.lifecycle.manage', true, ARRAY['resignation', 'dismissal', 'contract_end']),
  ('on_leave',   'departure', 'employees.lifecycle.manage', true, ARRAY['resignation', 'dismissal']),
  ('departure',  'offboarding', 'employees.lifecycle.manage', true, ARRAY['offboarding_started']),
  ('offboarding','terminated', 'employees.lifecycle.manage', true, ARRAY['offboarding_completed']),
  ('terminated', 'onboarding', 'employees.lifecycle.manage', true, ARRAY['rehire'])
ON CONFLICT (from_state, to_state) DO NOTHING;

ALTER TABLE data.employee_lifecycle_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employee_lifecycle_transition_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lifecycle_events_select ON data.employee_lifecycle_events;
CREATE POLICY lifecycle_events_select ON data.employee_lifecycle_events
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'employees.lifecycle.view')
      OR data.jwt_has_permission(tenant_id, 'employees.lifecycle.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_can_view_employee(
        tenant_id,
        (SELECT site_id FROM data.employees e WHERE e.id = employee_id),
        (SELECT user_id FROM data.employees e WHERE e.id = employee_id)
      )
    )
  );

DROP POLICY IF EXISTS lifecycle_transition_rules_select ON data.employee_lifecycle_transition_rules;
CREATE POLICY lifecycle_transition_rules_select ON data.employee_lifecycle_transition_rules
  FOR SELECT TO authenticated
  USING (true);

GRANT SELECT ON data.employee_lifecycle_events TO authenticated, service_role;
GRANT INSERT ON data.employee_lifecycle_events TO service_role;
GRANT SELECT ON data.employee_lifecycle_transition_rules TO authenticated, service_role;

CREATE OR REPLACE VIEW api.employee_lifecycle_events
  WITH (security_invoker = true) AS
SELECT
  id,
  tenant_id,
  employee_id,
  from_state,
  to_state,
  reason_code,
  effective_on,
  triggered_by,
  source,
  metadata,
  created_at
FROM data.employee_lifecycle_events;

CREATE OR REPLACE VIEW api.employee_lifecycle_transition_rules
  WITH (security_invoker = true) AS
SELECT
  id,
  from_state,
  to_state,
  requires_permission,
  requires_reason,
  auto_reason_codes
FROM data.employee_lifecycle_transition_rules;

GRANT SELECT ON api.employee_lifecycle_events TO authenticated;
GRANT SELECT ON api.employee_lifecycle_transition_rules TO authenticated;

-- Backfill idempotent: un event inicial per empleats sense historial
INSERT INTO data.employee_lifecycle_events (
  tenant_id, employee_id, from_state, to_state, reason_code,
  effective_on, source, metadata
)
SELECT
  e.tenant_id,
  e.id,
  NULL,
  e.lifecycle_state,
  'initial_backfill',
  COALESCE(e.starts_on, CURRENT_DATE),
  'import',
  jsonb_build_object('backfill', true)
FROM data.employees e
WHERE NOT EXISTS (
  SELECT 1 FROM data.employee_lifecycle_events ev WHERE ev.employee_id = e.id
);

NOTIFY pgrst, 'reload schema';
