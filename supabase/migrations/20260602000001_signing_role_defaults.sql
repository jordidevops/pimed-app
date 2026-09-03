-- =============================================================================
-- Migration: 20260602000001_signing_role_defaults.sql
-- Propòsit:  Defaults de rols de document per tenant
--            Permet que cada tenant defineixi quina entitat ocupa cada rol
--            per defecte al generar documents sense context explícit.
--
-- Crea:
--   data.tenant_role_defaults     — assignació rol_key → entitat per tenant
--
-- Vistes api.*:
--   api.tenant_role_defaults      — SELECT + write via RPC
--
-- RPCs SECURITY INVOKER:
--   api.upsert_tenant_role_default  — crea o actualitza un default
--   api.delete_tenant_role_default  — elimina un default
--
-- Seguretat:
--   · SELECT: qualsevol membre del tenant
--   · INSERT/UPDATE/DELETE: owner o manager global del tenant
--   · entity_type validat contra domini fixat
--
-- Auditoria:
--   · ROLE_DEFAULT_CREATED / ROLE_DEFAULT_UPDATED / ROLE_DEFAULT_DELETED
-- =============================================================================


-- ============================================================================
-- 1. data.tenant_role_defaults
-- ============================================================================

CREATE TABLE data.tenant_role_defaults (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL
                  REFERENCES data.tenants(id) ON DELETE CASCADE,
  role_key      text        NOT NULL CHECK (role_key ~ '^\w+$'),
  entity_type   text        NOT NULL CHECK (
    entity_type IN ('employee', 'contact', 'user', 'person', 'site', 'asset', 'tenant')
  ),
  -- Entitat concreta assignada (nullable: intencions sense assignació final)
  entity_id     uuid,
  entity_label  text,
  entity_email  text,
  -- 'tenant' = definit per l'admin del tenant (únic valor per ara)
  source        text        NOT NULL DEFAULT 'tenant'
                  CHECK (source IN ('tenant', 'system')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  UNIQUE (tenant_id, role_key, entity_type)
);

CREATE INDEX idx_tenant_role_defaults_tenant
  ON data.tenant_role_defaults (tenant_id);

COMMENT ON TABLE data.tenant_role_defaults
  IS 'Assignació per defecte rol_key → entitat per tenant. Usat per pre-omplir rols a DocumentOrchestrator.';

COMMENT ON COLUMN data.tenant_role_defaults.role_key
  IS 'Clau tècnica del rol en snake_case (ex: worker, hr_manager). Ha de coincidir amb signingRolesSchema de les plantilles.';

COMMENT ON COLUMN data.tenant_role_defaults.entity_id
  IS 'UUID de l''entitat assignada per defecte. NULL = intenció definida però sense entitat concreta.';


-- ============================================================================
-- 2. Trigger updated_at
-- ============================================================================

CREATE TRIGGER trg_tenant_role_defaults_updated_at
  BEFORE UPDATE ON data.tenant_role_defaults
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();


-- ============================================================================
-- 3. RLS
-- ============================================================================

ALTER TABLE data.tenant_role_defaults ENABLE ROW LEVEL SECURITY;

-- SELECT: qualsevol membre del tenant
CREATE POLICY "tenant_role_defaults_select"
  ON data.tenant_role_defaults
  FOR SELECT
  USING (data.jwt_user_tenants() ? tenant_id::text);

-- INSERT: owner o manager global
CREATE POLICY "tenant_role_defaults_insert"
  ON data.tenant_role_defaults
  FOR INSERT
  WITH CHECK (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- UPDATE: owner o manager global
CREATE POLICY "tenant_role_defaults_update"
  ON data.tenant_role_defaults
  FOR UPDATE
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- DELETE: owner o manager global
CREATE POLICY "tenant_role_defaults_delete"
  ON data.tenant_role_defaults
  FOR DELETE
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );


-- ============================================================================
-- 4. Trigger d'auditoria
-- ============================================================================

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

CREATE TRIGGER trg_audit_tenant_role_defaults
  AFTER INSERT OR UPDATE OR DELETE ON data.tenant_role_defaults
  FOR EACH ROW EXECUTE FUNCTION data.audit_tenant_role_defaults();


-- ============================================================================
-- 5. Vista api.tenant_role_defaults
-- ============================================================================

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
  updated_at
FROM data.tenant_role_defaults;

COMMENT ON VIEW api.tenant_role_defaults
  IS 'Defaults de rols de document per tenant. security_invoker = RLS del caller aplicada.';

GRANT SELECT ON api.tenant_role_defaults TO authenticated;


-- ============================================================================
-- 6. RPCs
-- ============================================================================

-- ——————————————————————————————————————————————————————————————————
-- api.upsert_tenant_role_default
-- SECURITY INVOKER: RLS verifica owner/manager via policy
-- ——————————————————————————————————————————————————————————————————
CREATE OR REPLACE FUNCTION api.upsert_tenant_role_default(
  p_tenant_id    uuid,
  p_role_key     text,
  p_entity_type  text,
  p_entity_id    uuid    DEFAULT NULL,
  p_entity_label text    DEFAULT NULL,
  p_entity_email text    DEFAULT NULL
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
    entity_id, entity_label, entity_email
  )
  VALUES (
    p_tenant_id, p_role_key, p_entity_type,
    p_entity_id, p_entity_label, p_entity_email
  )
  ON CONFLICT (tenant_id, role_key, entity_type)
  DO UPDATE SET
    entity_id    = EXCLUDED.entity_id,
    entity_label = EXCLUDED.entity_label,
    entity_email = EXCLUDED.entity_email,
    updated_at   = now()
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION api.upsert_tenant_role_default IS
  'Crea o actualitza un default de rol per tenant. RLS verifica owner/manager.';

GRANT EXECUTE ON FUNCTION api.upsert_tenant_role_default TO authenticated;


-- ——————————————————————————————————————————————————————————————————
-- api.delete_tenant_role_default
-- SECURITY INVOKER: RLS verifica owner/manager via policy
-- ——————————————————————————————————————————————————————————————————
CREATE OR REPLACE FUNCTION api.delete_tenant_role_default(
  p_id        uuid,
  p_tenant_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  DELETE FROM data.tenant_role_defaults
  WHERE id = p_id
    AND tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'role_default_not_found'
      USING HINT = 'El default no existeix o no tens permisos per eliminar-lo.';
  END IF;
END;
$$;

COMMENT ON FUNCTION api.delete_tenant_role_default IS
  'Elimina un default de rol per tenant. RLS verifica owner/manager.';

GRANT EXECUTE ON FUNCTION api.delete_tenant_role_default TO authenticated;
