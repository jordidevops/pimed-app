-- Fix 42725: log_audit_event amb 7 i 8 paràmetres coexisteixen → ambiguïtat en triggers.
-- CREATE OR REPLACE no elimina la signatura antiga quan s'afegeix un paràmetre.

DROP FUNCTION IF EXISTS data.log_audit_event(uuid, uuid, uuid, text, text, uuid, jsonb);

CREATE OR REPLACE FUNCTION data.log_audit_event(
  p_tenant_id     uuid,
  p_user_id       uuid,
  p_site_id       uuid,
  p_action        text,
  p_entity_type   text,
  p_entity_id     uuid,
  p_payload       jsonb DEFAULT '{}',
  p_is_background boolean DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  INSERT INTO data.audit_logs (
    tenant_id, user_id, site_id, action, entity_type, entity_id, payload, is_background
  ) VALUES (
    p_tenant_id,
    p_user_id,
    p_site_id,
    p_action,
    p_entity_type,
    p_entity_id,
    p_payload,
    coalesce(
      p_is_background,
      data.is_background_audit_action(p_action),
      coalesce((p_payload ->> 'is_background')::boolean, false)
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING '[audit] log_audit_event error: % — action=%, entity_id=%',
      SQLERRM, p_action, p_entity_id;
END;
$$;

REVOKE ALL ON FUNCTION data.log_audit_event(uuid, uuid, uuid, text, text, uuid, jsonb, boolean) FROM PUBLIC;
