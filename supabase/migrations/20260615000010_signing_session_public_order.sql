-- Ampliar get_signing_session_public amb ordre del signant (UI pública)
CREATE OR REPLACE FUNCTION api.get_signing_session_public(
  p_token text
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_session record;
BEGIN
  SELECT * INTO v_session
    FROM data.document_signing_sessions
   WHERE signing_token = p_token
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'token_not_found');
  END IF;

  IF v_session.status = 'signed' THEN
    RETURN jsonb_build_object(
      'error',            'already_signed',
      'timestamp_signed', v_session.timestamps ->> 'signed_at'
    );
  END IF;

  IF v_session.expires_at < now() THEN
    UPDATE data.document_signing_sessions
       SET status = 'expired', updated_at = now()
     WHERE id = v_session.id AND status NOT IN ('signed', 'cancelled');

    RETURN jsonb_build_object('error', 'token_expired');
  END IF;

  IF v_session.status = 'cancelled' THEN
    RETURN jsonb_build_object('error', 'session_cancelled');
  END IF;

  IF v_session.status = 'pending' THEN
    UPDATE data.document_signing_sessions
       SET status     = 'opened',
           timestamps = COALESCE(v_session.timestamps, '{}') || jsonb_build_object('opened_at', now()),
           updated_at = now()
     WHERE id = v_session.id;
    v_session.status := 'opened';
  END IF;

  RETURN jsonb_build_object(
    'session_id',           v_session.id,
    'tenant_id',            v_session.tenant_id,
    'document_version_id',  v_session.document_version_id,
    'signing_type',         v_session.signing_type,
    'status',               v_session.status,
    'signer_name',          v_session.signer_name,
    'signer_role',          v_session.signer_role,
    'signer_order',         v_session.signer_order,
    'total_signers',        v_session.total_signers,
    'expires_at',           v_session.expires_at
  );
END;
$$;
