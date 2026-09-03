-- =============================================================================
-- Migration: 20260610000001_fix_pdf_rpc_service_role_auth.sql
-- Purpose : Corregir detecció de service_role a RPCs PDF/firma
--
-- Bug: create_pdf_job usava current_user != 'service_role', però dins
--      SECURITY DEFINER current_user és el propietari de la funció, no el rol JWT.
--      Les Edge Functions criden amb service_role → auth.uid() IS NULL → Unauthorized.
-- Fix: usar auth.role() = 'service_role' (patró del projecte).
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_pdf_job(
  p_tenant_id       uuid,
  p_source_type     text,
  p_source_ref_id   uuid,
  p_template_type   text,
  p_document_title  text,
  p_output_profile  text DEFAULT 'pdf',
  p_folder_id       uuid DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_priority        int  DEFAULT 0,
  p_metadata        jsonb DEFAULT '{}'::jsonb,
  p_intermediate_path text DEFAULT NULL,
  p_intermediate_size_bytes bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id     uuid;
  v_job_id      uuid;
  v_idem_key    text;
  v_max_retries int;
  v_existing    uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL AND COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.tenant_members
       WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_active = true
         AND role IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Forbidden: requires owner or manager role';
    END IF;
  END IF;

  v_idem_key := COALESCE(p_idempotency_key, 'pdf-' || gen_random_uuid()::text);

  SELECT id INTO v_existing
    FROM data.document_pdf_jobs
   WHERE tenant_id = p_tenant_id AND idempotency_key = v_idem_key
     AND status NOT IN ('failed', 'dead_letter')
   LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('job_id', v_existing, 'idempotent_replay', true);
  END IF;

  SELECT COALESCE(
    (settings -> 'retry' ->> 'max_attempts')::int, 5
  ) INTO v_max_retries
  FROM data.system_settings WHERE module = 'pdf_converter';

  INSERT INTO data.document_pdf_jobs (
    tenant_id, status, source_type, source_ref_id, template_type, document_title,
    output_profile, priority, max_retries, created_by, folder_id, metadata,
    idempotency_key, intermediate_path, intermediate_size_bytes
  ) VALUES (
    p_tenant_id, 'queued', p_source_type, p_source_ref_id, p_template_type, p_document_title,
    p_output_profile, p_priority, v_max_retries, v_user_id, p_folder_id, p_metadata,
    v_idem_key, p_intermediate_path, p_intermediate_size_bytes
  )
  RETURNING id INTO v_job_id;

  INSERT INTO data.document_pdf_events (job_id, event_type, payload)
  VALUES (v_job_id, 'queued', jsonb_build_object('tenant_id', p_tenant_id));

  PERFORM pgmq.send(
    'document_pdf_queue',
    jsonb_build_object(
      'task',             'convert_to_pdf',
      'tenant_id',        p_tenant_id::text,
      'idempotency_key',  v_idem_key,
      'payload',          jsonb_build_object('job_id', v_job_id)
    )
  );

  RETURN jsonb_build_object('job_id', v_job_id, 'idempotent_replay', false);
END;
$$;

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

GRANT EXECUTE ON FUNCTION api.create_signing_session(uuid,uuid,text,text,text,text,uuid,int) TO service_role;
