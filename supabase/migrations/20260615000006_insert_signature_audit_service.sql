-- Inserció d'auditoria de signatura amb camps sensibles (no exposats a api.*)

CREATE OR REPLACE FUNCTION api.insert_signature_audit_service(
  p_tenant_id            uuid,
  p_document_id          uuid,
  p_session_id           uuid,
  p_signer_name          text,
  p_signer_email         text,
  p_signer_role          text,
  p_timestamp_signed     timestamptz,
  p_ip_address           text DEFAULT NULL,
  p_user_agent           text DEFAULT NULL,
  p_geolocation          jsonb DEFAULT NULL,
  p_signature_image_path text DEFAULT NULL,
  p_document_hash_before text DEFAULT NULL,
  p_document_hash_after  text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE v_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  INSERT INTO data.document_signatures_audit (
    tenant_id, document_id, session_id,
    signer_name, signer_email, signer_role,
    timestamp_signed, ip_address, user_agent, geolocation,
    signature_image_path, document_hash_before, document_hash_after
  ) VALUES (
    p_tenant_id, p_document_id, p_session_id,
    p_signer_name, p_signer_email, p_signer_role,
    p_timestamp_signed,
    CASE WHEN p_ip_address IS NOT NULL THEN p_ip_address::inet ELSE NULL END,
    p_user_agent, p_geolocation,
    p_signature_image_path, p_document_hash_before, p_document_hash_after
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.insert_signature_audit_service(uuid, uuid, uuid, text, text, text, timestamptz, text, text, jsonb, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.insert_signature_audit_service(uuid, uuid, uuid, text, text, text, timestamptz, text, text, jsonb, text, text, text) TO service_role;
