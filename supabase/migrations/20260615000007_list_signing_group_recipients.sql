-- Destinataris del correu de confirmació quan tot el grup ha signat

CREATE OR REPLACE FUNCTION api.list_signing_group_recipients(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_session record;
  v_result  jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT id, signing_group_id, signer_email, signer_name
    INTO v_session
    FROM data.document_signing_sessions
   WHERE id = p_session_id;

  IF NOT FOUND THEN
    RETURN '[]'::jsonb;
  END IF;

  IF v_session.signing_group_id IS NULL THEN
    IF v_session.signer_email IS NULL THEN
      RETURN '[]'::jsonb;
    END IF;
    RETURN jsonb_build_array(jsonb_build_object(
      'session_id',   v_session.id,
      'signer_email', v_session.signer_email,
      'signer_name',  v_session.signer_name
    ));
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'session_id',   s.id,
      'signer_email', s.signer_email,
      'signer_name',  s.signer_name
    )
    ORDER BY s.signer_order
  ), '[]'::jsonb)
  INTO v_result
  FROM data.document_signing_sessions s
  WHERE s.signing_group_id = v_session.signing_group_id
    AND s.signer_email IS NOT NULL;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION api.list_signing_group_recipients(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_signing_group_recipients(uuid) TO service_role;
