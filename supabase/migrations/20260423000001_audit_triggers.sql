-- =============================================================================
-- Migration: 20260423000001_audit_triggers.sql
-- Propòsit : Triggers d'auditoria automàtica + api.ping() per health check
--
-- Conté:
--   1. api.ping()                  — RPC de health check (SELECT TRUE)
--   2. data.log_audit_event()      — funció helper cridada pels triggers
--   3. data.trg_audit_tenants()    — trigger AFTER UPDATE sobre data.tenants
--   4. data.trg_audit_sites()      — trigger AFTER INSERT OR UPDATE sobre data.sites
--   5. data.trg_audit_tenant_members() — trigger AFTER INSERT OR UPDATE OR DELETE
--                                       sobre data.tenant_members
--
-- Accions registrades:
--   TENANT_ACTIVATED, TENANT_DEACTIVATED, TENANT_PLAN_CHANGED,
--   TENANT_STORAGE_BLOCKED, TENANT_STORAGE_UNBLOCKED,
--   SITE_CREATED, SITE_ACTIVATED, SITE_DEACTIVATED, SITE_RENAMED,
--   MEMBER_INVITED, MEMBER_ROLE_CHANGED, MEMBER_ACTIVATED,
--   MEMBER_DEACTIVATED, MEMBER_REMOVED
--
-- Nota: MEMBER_INVITE_EMAIL_SENT es registra manualment des de l'Edge Function
--       invite-member (captura si l'email de convit s'ha enviat realment).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. api.ping() — health check per a UptimeRobot i l'Edge Function health
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.ping()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = api, data, public
AS $$
  SELECT TRUE;
$$;

-- La funció és pública per permetre crides sense autenticació des del health check.
GRANT EXECUTE ON FUNCTION api.ping() TO anon;
GRANT EXECUTE ON FUNCTION api.ping() TO authenticated;
GRANT EXECUTE ON FUNCTION api.ping() TO service_role;

-- ---------------------------------------------------------------------------
-- 2. data.log_audit_event() — helper cridat pels triggers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.log_audit_event(
  p_tenant_id   uuid,
  p_user_id     uuid,
  p_site_id     uuid,
  p_action      text,
  p_entity_type text,
  p_entity_id   uuid,
  p_payload     jsonb DEFAULT '{}'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  INSERT INTO data.audit_logs (
    tenant_id, user_id, site_id, action, entity_type, entity_id, payload
  ) VALUES (
    p_tenant_id, p_user_id, p_site_id, p_action, p_entity_type, p_entity_id, p_payload
  );
EXCEPTION
  -- Si l'insert falla (ex: FK trencada per row suprimida) no trenquem la transacció
  -- principal. El trigger ha de ser transparent.
  WHEN OTHERS THEN
    RAISE WARNING '[audit] log_audit_event error: % — action=%, entity_id=%',
      SQLERRM, p_action, p_entity_id;
END;
$$;

-- Privat: el criden els triggers amb SECURITY DEFINER; cap rol extern ho ha de cridar.
REVOKE ALL ON FUNCTION data.log_audit_event(uuid, uuid, uuid, text, text, uuid, jsonb) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 3. Trigger: data.tenants — cicle de vida del tenant
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_tenants()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_actor uuid := auth.uid();  -- NULL en operacions via admin/Prisma (acceptable)
BEGIN
  -- Canvi d'estat actiu/arxivat
  IF OLD.is_active IS DISTINCT FROM NEW.is_active THEN
    PERFORM data.log_audit_event(
      NEW.id, v_actor, NULL,
      CASE WHEN NEW.is_active THEN 'TENANT_ACTIVATED' ELSE 'TENANT_DEACTIVATED' END,
      'tenant', NEW.id,
      jsonb_build_object('is_active', NEW.is_active)
    );
  END IF;

  -- Canvi de pla
  IF OLD.plan_id IS DISTINCT FROM NEW.plan_id THEN
    PERFORM data.log_audit_event(
      NEW.id, v_actor, NULL,
      'TENANT_PLAN_CHANGED',
      'tenant', NEW.id,
      jsonb_build_object('old_plan_id', OLD.plan_id, 'new_plan_id', NEW.plan_id)
    );
  END IF;

  -- Bloqueig / desbloqueig d'emmagatzematge
  IF OLD.storage_blocked IS DISTINCT FROM NEW.storage_blocked THEN
    PERFORM data.log_audit_event(
      NEW.id, v_actor, NULL,
      CASE WHEN NEW.storage_blocked THEN 'TENANT_STORAGE_BLOCKED' ELSE 'TENANT_STORAGE_UNBLOCKED' END,
      'tenant', NEW.id,
      jsonb_build_object(
        'storage_blocked',        NEW.storage_blocked,
        'storage_blocked_reason', NEW.storage_blocked_reason
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS audit_tenants ON data.tenants;
CREATE TRIGGER audit_tenants
  AFTER UPDATE ON data.tenants
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_audit_tenants();

-- ---------------------------------------------------------------------------
-- 4. Trigger: data.sites — cicle de vida del site
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_sites()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, v_actor, NEW.id,
      'SITE_CREATED',
      'site', NEW.id,
      jsonb_build_object('name', NEW.name)
    );

  ELSIF TG_OP = 'UPDATE' THEN
    -- Activació / desactivació
    IF OLD.is_active IS DISTINCT FROM NEW.is_active THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, v_actor, NEW.id,
        CASE WHEN NEW.is_active THEN 'SITE_ACTIVATED' ELSE 'SITE_DEACTIVATED' END,
        'site', NEW.id,
        jsonb_build_object('name', NEW.name, 'is_active', NEW.is_active)
      );
    END IF;

    -- Reanomenament
    IF OLD.name IS DISTINCT FROM NEW.name THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, v_actor, NEW.id,
        'SITE_RENAMED',
        'site', NEW.id,
        jsonb_build_object('old_name', OLD.name, 'new_name', NEW.name)
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS audit_sites ON data.sites;
CREATE TRIGGER audit_sites
  AFTER INSERT OR UPDATE ON data.sites
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_audit_sites();

-- ---------------------------------------------------------------------------
-- 5. Trigger: data.tenant_members — cicle de vida de la membresia
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_tenant_members()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Per convits des de l'EF invite-member, invited_by és l'actor real.
    -- auth.uid() pot ser NULL (service_role). Usem invited_by com a fallback.
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(v_actor, NEW.invited_by),
      NEW.site_id,
      'MEMBER_INVITED',
      'tenant_member', NEW.id,
      jsonb_build_object(
        'user_id',    NEW.user_id,
        'role',       NEW.role,
        'site_id',    NEW.site_id,
        'invited_by', NEW.invited_by
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    -- Canvi de rol
    IF OLD.role IS DISTINCT FROM NEW.role THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, v_actor, NEW.site_id,
        'MEMBER_ROLE_CHANGED',
        'tenant_member', NEW.id,
        jsonb_build_object(
          'user_id',  NEW.user_id,
          'old_role', OLD.role,
          'new_role', NEW.role,
          'site_id',  NEW.site_id
        )
      );
    END IF;

    -- Activació / desactivació de la membresia
    IF OLD.is_active IS DISTINCT FROM NEW.is_active THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, v_actor, NEW.site_id,
        CASE WHEN NEW.is_active THEN 'MEMBER_ACTIVATED' ELSE 'MEMBER_DEACTIVATED' END,
        'tenant_member', NEW.id,
        jsonb_build_object(
          'user_id', NEW.user_id,
          'role',    NEW.role,
          'site_id', NEW.site_id
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, v_actor, OLD.site_id,
      'MEMBER_REMOVED',
      'tenant_member', OLD.id,
      jsonb_build_object(
        'user_id', OLD.user_id,
        'role',    OLD.role,
        'site_id', OLD.site_id
      )
    );
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS audit_tenant_members ON data.tenant_members;
CREATE TRIGGER audit_tenant_members
  AFTER INSERT OR UPDATE OR DELETE ON data.tenant_members
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_audit_tenant_members();
