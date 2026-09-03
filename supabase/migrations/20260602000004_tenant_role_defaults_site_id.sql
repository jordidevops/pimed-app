-- ============================================================================
-- Migration: 20260602000004_tenant_role_defaults_site_id
-- Purpose:   Add site_id to data.tenant_role_defaults to support site-specific
--            role default overrides. Priority: site-specific > tenant-global.
--
-- Changes:
--   1) ADD COLUMN site_id (nullable FK → data.sites)
--   2) DROP old UNIQUE (tenant_id, role_key, entity_type)
--   3) CREATE functional UNIQUE INDEX with COALESCE sentinel for ON CONFLICT
--   4) Rebuild api.tenant_role_defaults view to expose site_id
--   5) Update api.upsert_tenant_role_default RPC to accept p_site_id
--   6) Update audit trigger to include site_id in payloads
-- ============================================================================

-- ── 1) ADD COLUMN site_id ──────────────────────────────────────────────────

ALTER TABLE data.tenant_role_defaults
  ADD COLUMN site_id uuid REFERENCES data.sites(id) ON DELETE CASCADE;

COMMENT ON COLUMN data.tenant_role_defaults.site_id
  IS 'NULL = default global del tenant; NOT NULL = override específic per site.';

-- ── 2) DROP old UNIQUE constraint ─────────────────────────────────────────

ALTER TABLE data.tenant_role_defaults
  DROP CONSTRAINT tenant_role_defaults_tenant_id_role_key_entity_type_key;

-- ── 3) Functional UNIQUE INDEX (sentinel '00000000...' per NULLs) ──────────

CREATE UNIQUE INDEX uq_tenant_role_defaults_site
  ON data.tenant_role_defaults (
    tenant_id,
    role_key,
    entity_type,
    COALESCE(site_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

-- ── 4) Rebuild api.tenant_role_defaults view ──────────────────────────────

CREATE OR REPLACE VIEW api.tenant_role_defaults
WITH (security_invoker = true)
AS
SELECT
  id,
  tenant_id,
  role_key,
  entity_type,
  entity_id,
  entity_label,
  entity_email,
  source,
  created_at,
  updated_at,
  site_id
FROM data.tenant_role_defaults;

COMMENT ON VIEW api.tenant_role_defaults
  IS 'Defaults de rols de document per tenant/site. security_invoker = RLS del caller aplicada.';

GRANT SELECT ON api.tenant_role_defaults TO authenticated;

-- ── 5) Update api.upsert_tenant_role_default RPC ─────────────────────────

DROP FUNCTION IF EXISTS api.upsert_tenant_role_default(uuid, text, text, uuid, text, text);

CREATE OR REPLACE FUNCTION api.upsert_tenant_role_default(
  p_tenant_id    uuid,
  p_role_key     text,
  p_entity_type  text,
  p_entity_id    uuid    DEFAULT NULL,
  p_entity_label text    DEFAULT NULL,
  p_entity_email text    DEFAULT NULL,
  p_site_id      uuid    DEFAULT NULL
)
RETURNS api.tenant_role_defaults
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_result data.tenant_role_defaults;
BEGIN
  INSERT INTO data.tenant_role_defaults (
    tenant_id, role_key, entity_type,
    entity_id, entity_label, entity_email, site_id
  )
  VALUES (
    p_tenant_id, p_role_key, p_entity_type,
    p_entity_id, p_entity_label, p_entity_email, p_site_id
  )
  ON CONFLICT (tenant_id, role_key, entity_type,
    COALESCE(site_id, '00000000-0000-0000-0000-000000000000'))
  DO UPDATE SET
    entity_id    = EXCLUDED.entity_id,
    entity_label = EXCLUDED.entity_label,
    entity_email = EXCLUDED.entity_email,
    site_id      = EXCLUDED.site_id,
    updated_at   = now()
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION api.upsert_tenant_role_default IS
  'Crea o actualitza un default de rol per tenant/site. RLS verifica owner/manager.';

GRANT EXECUTE ON FUNCTION api.upsert_tenant_role_default TO authenticated;

-- ── 6) Update audit trigger to include site_id ────────────────────────────

CREATE OR REPLACE FUNCTION data.audit_tenant_role_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      'ROLE_DEFAULT_CREATED',
      'tenant_role_default',
      NEW.id,
      jsonb_build_object(
        'tenant_id',   NEW.tenant_id,
        'site_id',     NEW.site_id,
        'role_key',    NEW.role_key,
        'entity_type', NEW.entity_type,
        'entity_id',   NEW.entity_id,
        'entity_label',NEW.entity_label
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      'ROLE_DEFAULT_UPDATED',
      'tenant_role_default',
      NEW.id,
      jsonb_build_object(
        'tenant_id',       NEW.tenant_id,
        'site_id',         NEW.site_id,
        'role_key',        NEW.role_key,
        'entity_type',     NEW.entity_type,
        'old_entity_id',   OLD.entity_id,
        'new_entity_id',   NEW.entity_id,
        'old_entity_label',OLD.entity_label,
        'new_entity_label',NEW.entity_label
      )
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      'ROLE_DEFAULT_DELETED',
      'tenant_role_default',
      OLD.id,
      jsonb_build_object(
        'tenant_id',   OLD.tenant_id,
        'site_id',     OLD.site_id,
        'role_key',    OLD.role_key,
        'entity_type', OLD.entity_type,
        'entity_id',   OLD.entity_id
      )
    );
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;
