-- sign_native des de plantilla: la sessió es crea abans que el PDF estigui llest.
-- document_version_id s'omple quan el job PDF completa (via worker o stamp-pdf-signatures).

ALTER TABLE data.document_signing_sessions
  ALTER COLUMN document_version_id DROP NOT NULL;

ALTER TABLE data.document_signing_sessions
  ADD CONSTRAINT signing_sessions_version_or_job_chk
  CHECK (document_version_id IS NOT NULL OR pdf_job_id IS NOT NULL);

CREATE OR REPLACE FUNCTION api.create_signing_session(
  p_tenant_id           uuid,
  p_document_version_id uuid,
  p_signing_type        text,
  p_signer_name         text DEFAULT NULL,
  p_signer_email        text DEFAULT NULL,
  p_signer_role         text DEFAULT NULL,
  p_pdf_job_id          uuid DEFAULT NULL,
  p_expires_days        int  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_token      text;
  v_session_id uuid;
  v_expires_at timestamptz;
  v_token_days int;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.tenant_members
       WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_active = true
         AND role IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Forbidden: requires owner or manager role';
    END IF;
  END IF;

  IF p_document_version_id IS NULL AND p_pdf_job_id IS NULL THEN
    RAISE EXCEPTION 'missing_document_version: document_version_id o pdf_job_id és obligatori';
  END IF;

  IF NOT COALESCE(
    (SELECT (settings ->> 'native_signing_enabled')::boolean
       FROM data.system_settings WHERE module = 'pdf_converter'),
    false
  ) THEN
    RAISE EXCEPTION 'native_signing_disabled: La firma nativa no està activada per a aquesta plataforma';
  END IF;

  SELECT COALESCE(
    p_expires_days,
    (settings ->> 'remote_signing_token_days')::int,
    7
  ) INTO v_token_days
  FROM data.system_settings WHERE module = 'pdf_converter';

  v_expires_at := now() + (v_token_days || ' days')::interval;
  v_token := replace(gen_random_uuid()::text, '-', '') || encode(extensions.gen_random_bytes(16), 'hex');

  INSERT INTO data.document_signing_sessions (
    tenant_id, document_version_id, signing_token, signing_type,
    signer_name, signer_email, signer_role,
    operator_user_id, expires_at, pdf_job_id
  ) VALUES (
    p_tenant_id, p_document_version_id, v_token, p_signing_type,
    p_signer_name, p_signer_email, p_signer_role,
    v_user_id, v_expires_at, p_pdf_job_id
  )
  RETURNING id INTO v_session_id;

  IF p_signing_type = 'remote' THEN
    INSERT INTO data.document_signature_evidences (session_id, event_type)
    VALUES (v_session_id, 'link_sent');
  END IF;

  RETURN jsonb_build_object(
    'session_id',  v_session_id,
    'token',       v_token,
    'expires_at',  v_expires_at,
    'signing_type',p_signing_type
  );
END;
$$;
