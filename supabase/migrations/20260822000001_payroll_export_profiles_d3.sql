-- D3.1: Perfils d'exportació nòmina (A3 / Sage / CSV custom) per tenant.

CREATE TABLE data.payroll_export_profiles (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name             text NOT NULL,
  connector        text NOT NULL,
  output_format    text NOT NULL DEFAULT 'csv',
  source_mode      text NOT NULL DEFAULT 'aggregate',
  column_mapping   jsonb NOT NULL DEFAULT '{"columns":[]}'::jsonb,
  concept_mapping  jsonb NOT NULL DEFAULT '[]'::jsonb,
  header_row       int NOT NULL DEFAULT 1,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT payroll_export_profiles_connector_chk
    CHECK (connector IN ('a3_variables', 'sage_concepts', 'csv_custom')),
  CONSTRAINT payroll_export_profiles_output_format_chk
    CHECK (output_format IN ('csv', 'xlsx')),
  CONSTRAINT payroll_export_profiles_source_mode_chk
    CHECK (source_mode IN ('daily', 'aggregate')),
  CONSTRAINT payroll_export_profiles_header_row_chk
    CHECK (header_row >= 1)
);

CREATE INDEX idx_payroll_export_profiles_tenant
  ON data.payroll_export_profiles (tenant_id, is_active);

CREATE TRIGGER trg_payroll_export_profiles_updated_at
  BEFORE UPDATE ON data.payroll_export_profiles
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.payroll_export_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "payroll_export_profiles_select"
  ON data.payroll_export_profiles FOR SELECT
  TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.export')
      OR data.jwt_has_permission(tenant_id, 'attendance.manage')
    )
  );

CREATE POLICY "payroll_export_profiles_write"
  ON data.payroll_export_profiles FOR ALL
  TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND data.jwt_has_permission(tenant_id, 'attendance.manage')
  )
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND data.jwt_has_permission(tenant_id, 'attendance.manage')
  );

CREATE OR REPLACE VIEW api.payroll_export_profiles
WITH (security_invoker = true) AS
SELECT
  id,
  tenant_id,
  name,
  connector,
  output_format,
  source_mode,
  column_mapping,
  concept_mapping,
  header_row,
  is_active,
  created_at,
  updated_at
FROM data.payroll_export_profiles;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.payroll_export_profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.payroll_export_profiles TO authenticated;

-- ─── RPC: export amb perfil ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.export_payroll_period_profile(
  p_site_id     uuid,
  p_from        date,
  p_to          date,
  p_profile_id  uuid,
  p_employee_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_profile   data.payroll_export_profiles%ROWTYPE;
  v_export    jsonb;
BEGIN
  SELECT s.tenant_id INTO v_tenant_id
  FROM data.sites s
  WHERE s.id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.export', p_site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.export required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_profile
  FROM data.payroll_export_profiles p
  WHERE p.id = p_profile_id
    AND p.tenant_id = v_tenant_id
    AND p.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile_not_found: %', p_profile_id USING ERRCODE = 'no_data_found';
  END IF;

  v_export := api.export_payroll_period(
    p_site_id,
    p_from,
    p_to,
    p_employee_id,
    v_profile.source_mode
  );

  RETURN jsonb_build_object(
    'profile', jsonb_build_object(
      'id',              v_profile.id,
      'tenant_id',       v_profile.tenant_id,
      'name',            v_profile.name,
      'connector',       v_profile.connector,
      'source_mode',     v_profile.source_mode,
      'output_format',   v_profile.output_format,
      'column_mapping',  v_profile.column_mapping,
      'concept_mapping', v_profile.concept_mapping,
      'header_row',      v_profile.header_row,
      'is_active',       v_profile.is_active
    ),
    'export', v_export
  );
END;
$$;

COMMENT ON FUNCTION api.export_payroll_period_profile(uuid, date, date, uuid, uuid) IS
  'D3.1: Export nòmina aplicant un perfil tenant (column_mapping + concept_mapping).';

GRANT EXECUTE ON FUNCTION api.export_payroll_period_profile(uuid, date, date, uuid, uuid) TO authenticated;

-- Plantilles exemple per Acme (dev seed)
INSERT INTO data.payroll_export_profiles (
  id,
  tenant_id,
  name,
  connector,
  output_format,
  source_mode,
  column_mapping,
  concept_mapping,
  header_row,
  is_active
)
SELECT
  '30000000-0000-0000-0000-000000000001'::uuid,
  '10000000-0000-0000-0000-000000000001'::uuid,
  'A3 — conceptes variables (agregat mensual)',
  'a3_variables',
  'csv',
  'aggregate',
  '{
    "columns": [
      {"header": "NIF", "source": "document_id"},
      {"header": "Nombre", "source": "employee_name"},
      {"header": "PeriodoDesde", "source": "period_from", "format": "date_dd_mm_yyyy"},
      {"header": "PeriodoHasta", "source": "period_to", "format": "date_dd_mm_yyyy"},
      {"header": "HorasExtra", "concept_key": "overtime_hours", "format": "hours_hh_mm"},
      {"header": "DiasIT", "concept_key": "it_day"}
    ],
    "csv_delimiter": ";"
  }'::jsonb,
  '[
    {"concept_key": "overtime_hours", "external_code": "HEX", "unit": "hours", "source_field": "total_overtime_minutes", "label": "Hores extra"},
    {"concept_key": "it_day", "external_code": "IT", "unit": "days", "source_field": "it_days", "label": "Dies IT"}
  ]'::jsonb,
  1,
  true
WHERE EXISTS (
  SELECT 1 FROM data.tenants WHERE id = '10000000-0000-0000-0000-000000000001'::uuid
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.payroll_export_profiles (
  id,
  tenant_id,
  name,
  connector,
  output_format,
  source_mode,
  column_mapping,
  concept_mapping,
  header_row,
  is_active
)
SELECT
  '30000000-0000-0000-0000-000000000002'::uuid,
  '10000000-0000-0000-0000-000000000001'::uuid,
  'Sage — conceptos salariales masivos (agregat)',
  'sage_concepts',
  'csv',
  'aggregate',
  '{
    "columns": [
      {"header": "CodigoEmpleado", "source": "document_id"},
      {"header": "Empleado", "source": "employee_name"},
      {"header": "Mes", "source": "period_from", "format": "date_dd_mm_yyyy"},
      {"header": "CuantiaHorasExtra", "concept_key": "overtime_hours", "format": "minutes_decimal"},
      {"header": "DiasAbsentismoIT", "concept_key": "it_day"}
    ],
    "csv_delimiter": ";"
  }'::jsonb,
  '[
    {"concept_key": "overtime_hours", "external_code": "CONCEPTO_HEX", "unit": "minutes", "source_field": "total_overtime_minutes"},
    {"concept_key": "it_day", "external_code": "CONCEPTO_IT", "unit": "days", "source_field": "it_days"}
  ]'::jsonb,
  1,
  true
WHERE EXISTS (
  SELECT 1 FROM data.tenants WHERE id = '10000000-0000-0000-0000-000000000001'::uuid
)
ON CONFLICT (id) DO NOTHING;
