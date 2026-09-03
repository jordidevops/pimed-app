-- Fase 4: mode evidències (detached per defecte) + mapa de camps de signatura

ALTER TABLE data.document_signing_sessions
  ADD COLUMN IF NOT EXISTS signing_field_map jsonb;

COMMENT ON COLUMN data.document_signing_sessions.signing_field_map IS
  'Coordenades normalitzades (0-1) dels camps signature-field / tags DocuSeal per overlay pdf-lib';

-- Default detached per a instal·lacions existents i noves
UPDATE data.system_settings
   SET settings = settings || '{"native_evidence_mode": "detached"}'::jsonb
 WHERE module = 'pdf_converter'
   AND (settings ->> 'native_evidence_mode') IS NULL;

-- Vista sessions (service_role / stamp)
DROP VIEW IF EXISTS api.document_signing_sessions;
CREATE OR REPLACE VIEW api.document_signing_sessions
WITH (security_invoker = true)
AS
SELECT
  id, tenant_id, document_version_id, signing_type, status,
  signer_name, signer_email, signer_role, operator_user_id,
  expires_at, timestamps, result_version_id, audit_version_id,
  pdf_job_id, signing_group_id, signer_order, total_signers,
  signing_field_map,
  created_at, updated_at
FROM data.document_signing_sessions;

GRANT SELECT ON api.document_signing_sessions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.document_signing_sessions TO service_role;

-- Actualitzar mapa de camps per grup o per job PDF
CREATE OR REPLACE FUNCTION api.update_signing_sessions_field_map(
  p_field_map         jsonb,
  p_signing_group_id  uuid DEFAULT NULL,
  p_pdf_job_id        uuid DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_count int;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_signing_group_id IS NULL AND p_pdf_job_id IS NULL THEN
    RAISE EXCEPTION 'group_or_job_required';
  END IF;

  UPDATE data.document_signing_sessions
     SET signing_field_map = p_field_map,
         updated_at        = now()
   WHERE (
     (p_signing_group_id IS NOT NULL AND signing_group_id = p_signing_group_id)
     OR (p_pdf_job_id IS NOT NULL AND pdf_job_id = p_pdf_job_id)
   );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION api.update_signing_sessions_field_map(jsonb, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_signing_sessions_field_map(jsonb, uuid, uuid) TO service_role;
