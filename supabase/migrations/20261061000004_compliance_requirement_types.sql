-- =============================================================================
-- M-CR-01 — Catàleg compliance_requirement_types + RPCs
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.compliance_requirement_types (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid        REFERENCES data.tenants(id) ON DELETE CASCADE,
  code                    text        NOT NULL,
  name                    text        NOT NULL,
  category                text        NOT NULL
    CHECK (category IN ('legal', 'medical', 'technical', 'other')),
  default_validity_months int,
  renewal_notice_days     int[]       NOT NULL DEFAULT '{90,30,7}',
  is_active               boolean     NOT NULL DEFAULT true,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT compliance_requirement_types_code_nonempty CHECK (length(btrim(code)) > 0),
  CONSTRAINT compliance_requirement_types_name_nonempty CHECK (length(btrim(name)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_compliance_requirement_types_tenant_code
  ON data.compliance_requirement_types (COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(code));

CREATE INDEX IF NOT EXISTS idx_compliance_requirement_types_tenant_active
  ON data.compliance_requirement_types (tenant_id, is_active);

DROP TRIGGER IF EXISTS trg_compliance_requirement_types_updated_at ON data.compliance_requirement_types;
CREATE TRIGGER trg_compliance_requirement_types_updated_at
  BEFORE UPDATE ON data.compliance_requirement_types
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.compliance_requirement_types ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS compliance_requirement_types_select ON data.compliance_requirement_types;
CREATE POLICY compliance_requirement_types_select ON data.compliance_requirement_types
  FOR SELECT TO authenticated
  USING (
    tenant_id IS NULL
    OR (
      data.jwt_user_tenants() ? tenant_id::text
      AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    )
  );

GRANT SELECT ON data.compliance_requirement_types TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.compliance_requirement_types TO service_role;

CREATE OR REPLACE VIEW api.compliance_requirement_types
  WITH (security_invoker = true) AS
SELECT * FROM data.compliance_requirement_types;

GRANT SELECT ON api.compliance_requirement_types TO authenticated, service_role;

-- Seed de plataforma (clonable per tenants)
INSERT INTO data.compliance_requirement_types (
  tenant_id, code, name, category, default_validity_months, renewal_notice_days
)
SELECT v.tenant_id, v.code, v.name, v.category, v.default_validity_months, v.renewal_notice_days
FROM (VALUES
  (NULL::uuid, 'PRL_BASIC',   'Formació PRL bàsica',         'legal',     12, '{90,30,7}'::int[]),
  (NULL::uuid, 'MEDICAL_FIT', 'Reconeixement mèdic aptitud', 'medical',   12, '{90,30,7}'::int[]),
  (NULL::uuid, 'HEIGHT_WORK', 'Treball en alçada',           'technical', 24, '{90,30,7}'::int[])
) AS v(tenant_id, code, name, category, default_validity_months, renewal_notice_days)
WHERE NOT EXISTS (
  SELECT 1 FROM data.compliance_requirement_types crt
  WHERE crt.tenant_id IS NULL AND lower(crt.code) = lower(v.code)
);

-- ─── RPCs ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_compliance_requirement_types(
  p_include_inactive boolean DEFAULT false
)
RETURNS SETOF api.compliance_requirement_types
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = api, data
AS $$
  SELECT crt.*
  FROM api.compliance_requirement_types crt
  WHERE (
    crt.tenant_id IS NULL
    OR crt.tenant_id = data.active_tenant_id()
  )
  AND (p_include_inactive OR crt.is_active = true)
  ORDER BY crt.category, crt.name;
$$;

CREATE OR REPLACE FUNCTION api.upsert_compliance_requirement_type(
  p_id                      uuid DEFAULT NULL,
  p_code                    text DEFAULT NULL,
  p_name                    text DEFAULT NULL,
  p_category                text DEFAULT NULL,
  p_default_validity_months int DEFAULT NULL,
  p_renewal_notice_days     int[] DEFAULT NULL,
  p_is_active               boolean DEFAULT true
)
RETURNS api.compliance_requirement_types
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_row       data.compliance_requirement_types;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_tenant_id, 'compliance.requirements.manage')
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.compliance_requirement_types
    WHERE id = p_id AND tenant_id = v_tenant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'requirement_type_not_found' USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE data.compliance_requirement_types
    SET
      code = COALESCE(p_code, code),
      name = COALESCE(p_name, name),
      category = COALESCE(p_category, category),
      default_validity_months = COALESCE(p_default_validity_months, default_validity_months),
      renewal_notice_days = COALESCE(p_renewal_notice_days, renewal_notice_days),
      is_active = COALESCE(p_is_active, is_active)
    WHERE id = p_id
    RETURNING * INTO v_row;
  ELSE
    IF p_code IS NULL OR p_name IS NULL OR p_category IS NULL THEN
      RAISE EXCEPTION 'code_name_category_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO data.compliance_requirement_types (
      tenant_id, code, name, category,
      default_validity_months, renewal_notice_days, is_active
    ) VALUES (
      v_tenant_id, upper(btrim(p_code)), btrim(p_name), p_category,
      p_default_validity_months, COALESCE(p_renewal_notice_days, '{90,30,7}'), COALESCE(p_is_active, true)
    )
    RETURNING * INTO v_row;
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_compliance_requirement_types(boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_compliance_requirement_type(
  uuid, text, text, text, int, int[], boolean
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
