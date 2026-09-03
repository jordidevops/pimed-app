-- =============================================================================
-- ES-4 — Registre canònic data.entity_types (M-ES-08)
--
-- MVP: taula + seed + vista API + helper soft.
-- NO afegeix FK/CHECK a documents/timeline/signing (deute documentat).
-- Regla d'equip: qualsevol taula polimòrfica NOVA ha de tenir fila aquí.
--
-- Nota naming: el pla deia `employee_asset`; el codi EA usa
-- `employee_asset_assignment` (l'actiu físic ja és `asset`).
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.entity_types (
  code                     text PRIMARY KEY,
  label_key                text NOT NULL,
  supports_timeline        boolean NOT NULL DEFAULT false,
  supports_documents       boolean NOT NULL DEFAULT false,
  supports_signing         boolean NOT NULL DEFAULT false,
  supports_subscriptions   boolean NOT NULL DEFAULT false,
  created_at               timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.entity_types IS
  'ES-4 canonical polymorphic entity_type registry. Soft reference only in MVP; '
  'existing CHECKs (timeline/signing) migrate gradually. New polymorphic tables '
  'must register a code here before use.';

COMMENT ON COLUMN data.entity_types.supports_timeline IS
  'Intent flag. Timeline CHECKs may still reject until a follow-up widens them.';

COMMENT ON COLUMN data.entity_types.supports_signing IS
  'True when used as signing role/context entity (tenant_role_defaults) or as '
  'document entity_type for signed domain docs (contract, medical clearance).';

ALTER TABLE data.entity_types ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS entity_types_select ON data.entity_types;
CREATE POLICY entity_types_select ON data.entity_types
  FOR SELECT TO authenticated
  USING (true);

GRANT SELECT ON data.entity_types TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.entity_types TO service_role;

-- Soft validator for NEW writers only (not wired to existing RPCs in this migration)
CREATE OR REPLACE FUNCTION data.assert_entity_type_registered(p_code text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF p_code IS NULL OR btrim(p_code) = '' THEN
    RAISE EXCEPTION 'entity_type_required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.entity_types et WHERE et.code = p_code
  ) THEN
    RAISE EXCEPTION 'unknown_entity_type: %', p_code
      USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

COMMENT ON FUNCTION data.assert_entity_type_registered(text) IS
  'ES-4 soft check. Call from new polymorphic writers; do not retrofit all RPCs yet.';

REVOKE ALL ON FUNCTION data.assert_entity_type_registered(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_entity_type_registered(text) TO service_role;

-- ─── Seed (idempotent) ──────────────────────────────────────────────────────

INSERT INTO data.entity_types (
  code, label_key,
  supports_timeline, supports_documents, supports_signing, supports_subscriptions
)
SELECT v.code, v.label_key, v.tl, v.doc, v.sig, v.sub
FROM (
  VALUES
    -- Timeline / subscriptions quartet
    ('employee',                  'entity_types.employee',                  true,  true,  true,  true),
    ('contact',                   'entity_types.contact',                   true,  true,  true,  true),
    ('project',                   'entity_types.project',                   true,  true,  false, true),
    ('document',                  'entity_types.document',                  true,  true,  false, true),
    -- Signing role defaults (+ catalog_item)
    ('user',                      'entity_types.user',                      false, true,  true,  false),
    ('person',                    'entity_types.person',                    false, true,  true,  false),
    ('site',                      'entity_types.site',                      false, true,  true,  false),
    ('asset',                     'entity_types.asset',                     false, true,  true,  false),
    ('tenant',                    'entity_types.tenant',                    false, true,  true,  false),
    ('catalog_item',              'entity_types.catalog_item',              false, true,  true,  false),
    -- HR soft strings already in production documents
    ('employee_certification',    'entity_types.employee_certification',    false, true,  true,  false),
    ('employee_asset_assignment', 'entity_types.employee_asset_assignment', false, true,  false, false),
    ('employment_contract',       'entity_types.employment_contract',       false, true,  true,  false)
) AS v(code, label_key, tl, doc, sig, sub)
WHERE NOT EXISTS (
  SELECT 1 FROM data.entity_types et WHERE et.code = v.code
);

-- ─── API view ────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW api.entity_types
  WITH (security_invoker = true) AS
  SELECT
    code,
    label_key,
    supports_timeline,
    supports_documents,
    supports_signing,
    supports_subscriptions,
    created_at
  FROM data.entity_types;

GRANT SELECT ON api.entity_types TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
