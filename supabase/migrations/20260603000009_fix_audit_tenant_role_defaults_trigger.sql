-- =============================================================================
-- Migration: 20260603000009_fix_audit_tenant_role_defaults_trigger.sql
--
-- Propòsit: Correcció del trigger data.audit_tenant_role_defaults()
--
-- El trigger cridava data.log_audit_event amb 4 arguments (acció, tipus,
-- entity_id, payload) però la signatura canònica del projecte té 7 paràmetres:
-- (tenant_id, user_id, site_id, action, entity_type, entity_id, payload).
-- Això causava:
--   "function data.log_audit_event(unknown, unknown, uuid, jsonb) does not exist"
-- cada vegada que es creava, modificava o eliminava un tenant_role_default.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.audit_tenant_role_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      NULL,
      'ROLE_DEFAULT_CREATED',
      'tenant_role_default',
      NEW.id,
      jsonb_build_object(
        'site_id',     NEW.site_id,
        'role_key',    NEW.role_key,
        'entity_type', NEW.entity_type,
        'entity_id',   NEW.entity_id,
        'entity_label',NEW.entity_label
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      NULL,
      'ROLE_DEFAULT_UPDATED',
      'tenant_role_default',
      NEW.id,
      jsonb_build_object(
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
      OLD.tenant_id,
      auth.uid(),
      NULL,
      'ROLE_DEFAULT_DELETED',
      'tenant_role_default',
      OLD.id,
      jsonb_build_object(
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
