-- CF: commercial quick flows (tenant-configured orphan quote launchers)

CREATE TABLE IF NOT EXISTS data.commercial_quick_flows (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name                        text NOT NULL,
  description                 text,
  status                      text NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft', 'active', 'archived')),
  calculator_definition_id    uuid REFERENCES data.calculator_definitions(id) ON DELETE RESTRICT,
  pricing_template_id         uuid REFERENCES data.pricing_templates(id) ON DELETE RESTRICT,
  quote_template_id           uuid NOT NULL REFERENCES data.document_templates(id) ON DELETE RESTRICT,
  formalization_mode          text NOT NULL
                              CHECK (formalization_mode IN ('signed_quote', 'separate_agreement')),
  agreement_template_id       uuid REFERENCES data.document_templates(id) ON DELETE RESTRICT,
  sort_order                  int NOT NULL DEFAULT 0,
  created_by                  uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commercial_quick_flows_source_xor CHECK (
    (calculator_definition_id IS NOT NULL AND pricing_template_id IS NULL)
    OR (calculator_definition_id IS NULL AND pricing_template_id IS NOT NULL)
    OR (status <> 'active')
  ),
  CONSTRAINT commercial_quick_flows_agreement_required CHECK (
    formalization_mode <> 'separate_agreement'
    OR agreement_template_id IS NOT NULL
    OR status <> 'active'
  )
);

CREATE INDEX IF NOT EXISTS idx_commercial_quick_flows_tenant_status
  ON data.commercial_quick_flows (tenant_id, status, sort_order);

DROP TRIGGER IF EXISTS trg_commercial_quick_flows_updated_at ON data.commercial_quick_flows;
CREATE TRIGGER trg_commercial_quick_flows_updated_at
  BEFORE UPDATE ON data.commercial_quick_flows
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.commercial_quick_flows ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "commercial_quick_flows: select tenant" ON data.commercial_quick_flows;
CREATE POLICY "commercial_quick_flows: select tenant"
  ON data.commercial_quick_flows FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "commercial_quick_flows: write owner manager" ON data.commercial_quick_flows;
CREATE POLICY "commercial_quick_flows: write owner manager"
  ON data.commercial_quick_flows FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE OR REPLACE VIEW api.commercial_quick_flows
WITH (security_invoker = true)
AS
SELECT *
FROM data.commercial_quick_flows;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.commercial_quick_flows TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_quick_flows TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_quick_flows TO service_role;

COMMENT ON TABLE data.commercial_quick_flows IS
  'Tenant-defined orphan quote launchers: calculator XOR habit + quote template + formalization.';
