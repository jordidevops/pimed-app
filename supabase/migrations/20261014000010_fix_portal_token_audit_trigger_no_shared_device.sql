-- Fix audit trigger after shared_device column removal (20261014000008)

CREATE OR REPLACE FUNCTION data.trg_audit_employee_portal_tokens()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_site_id uuid;
BEGIN
  SELECT e.site_id INTO v_site_id
  FROM data.employees e
  WHERE e.id = COALESCE(NEW.employee_id, OLD.employee_id);

  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by_user_id),
      v_site_id,
      'EMPLOYEE_PORTAL_TOKEN_CREATED',
      'employee',
      NEW.employee_id,
      jsonb_build_object(
        'token_id', NEW.id,
        'employee_id', NEW.employee_id,
        'label', NEW.label,
        'expires_at', NEW.expires_at,
        'pin_required', (NEW.pin_hash IS NOT NULL OR NEW.pin_must_set)
      )
    );
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.revoked_at IS NULL
     AND NEW.revoked_at IS NOT NULL THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      v_site_id,
      'EMPLOYEE_PORTAL_TOKEN_REVOKED',
      'employee',
      NEW.employee_id,
      jsonb_build_object(
        'token_id', NEW.id,
        'employee_id', NEW.employee_id,
        'label', NEW.label,
        'revoke_reason', NEW.revoke_reason,
        'compromised', NEW.compromised,
        'session_version', NEW.session_version
      )
    );
  END IF;

  RETURN NEW;
END;
$$;
