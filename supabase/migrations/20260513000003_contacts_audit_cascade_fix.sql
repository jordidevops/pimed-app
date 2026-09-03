-- =============================================================================
-- Migration: 20260513000003_contacts_audit_cascade_fix.sql
-- Propòsit : Evitar warnings d'auditoria en cascada DELETE de tenants quan els
--            triggers de contacts/contact_sites intenten escriure tenant_id a
--            data.audit_logs després que el tenant ja no existeixi.
--
-- Solució:
--   · CONTACT_DELETED i CONTACT_SITE_DELETED passen a usar:
--       CASE WHEN EXISTS(SELECT 1 FROM data.tenants WHERE id = OLD.tenant_id)
--            THEN OLD.tenant_id
--            ELSE NULL
--       END
--   · Manté payload i semàntica d'auditoria intactes.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Fix: data.trg_audit_contacts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_contacts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by),
      NEW.site_id,
      'CONTACT_CREATED',
      'contact',
      NEW.id,
      jsonb_build_object(
        'display_name', NEW.display_name,
        'kind',         NEW.kind,
        'email',        NEW.email
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.is_archived IS DISTINCT FROM NEW.is_archived THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        CASE WHEN NEW.is_archived THEN 'CONTACT_ARCHIVED' ELSE 'CONTACT_UNARCHIVED' END,
        'contact', NEW.id,
        jsonb_build_object(
          'display_name', NEW.display_name,
          'kind',         NEW.kind,
          'email',        NEW.email
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'CONTACT_UPDATED',
        'contact', NEW.id,
        jsonb_build_object(
          'old', jsonb_build_object(
            'display_name', OLD.display_name,
            'kind',         OLD.kind,
            'email',        OLD.email
          ),
          'new', jsonb_build_object(
            'display_name', NEW.display_name,
            'kind',         NEW.kind,
            'email',        NEW.email
          )
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      CASE
        WHEN EXISTS (SELECT 1 FROM data.tenants t WHERE t.id = OLD.tenant_id) THEN OLD.tenant_id
        ELSE NULL
      END,
      auth.uid(),
      OLD.site_id,
      'CONTACT_DELETED',
      'contact',
      OLD.id,
      jsonb_build_object(
        'display_name', OLD.display_name,
        'kind',         OLD.kind,
        'email',        OLD.email
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;


-- ---------------------------------------------------------------------------
-- Fix: data.trg_audit_contact_sites
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_contact_sites()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NULL,
      'CONTACT_SITE_CREATED',
      'contact_site', NEW.id,
      jsonb_build_object(
        'contact_id', NEW.contact_id,
        'name',       NEW.name
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NULL,
      'CONTACT_SITE_UPDATED',
      'contact_site', NEW.id,
      jsonb_build_object(
        'contact_id', NEW.contact_id,
        'name',       NEW.name
      )
    );

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      CASE
        WHEN EXISTS (SELECT 1 FROM data.tenants t WHERE t.id = OLD.tenant_id) THEN OLD.tenant_id
        ELSE NULL
      END,
      auth.uid(),
      NULL,
      'CONTACT_SITE_DELETED',
      'contact_site', OLD.id,
      jsonb_build_object(
        'contact_id', OLD.contact_id,
        'name',       OLD.name
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;
