-- Submission Hub: firma pròpia visible al Centre de signatures (paritat DocuSeal)

-- ── Columnes noves ───────────────────────────────────────────────────────────
ALTER TABLE data.signing_submissions
  ADD COLUMN IF NOT EXISTS signing_provider text NOT NULL DEFAULT 'docuseal',
  ADD COLUMN IF NOT EXISTS native_group_id   uuid;

ALTER TABLE data.signing_submissions
  DROP CONSTRAINT IF EXISTS signing_submissions_signing_provider_check;

ALTER TABLE data.signing_submissions
  ADD CONSTRAINT signing_submissions_signing_provider_check
  CHECK (signing_provider IN ('docuseal', 'native'));

CREATE INDEX IF NOT EXISTS idx_signing_submissions_native_group
  ON data.signing_submissions (native_group_id)
  WHERE native_group_id IS NOT NULL;

COMMENT ON COLUMN data.signing_submissions.signing_provider IS
  'docuseal | native — proveïdor de firma per al Centre de signatures';
COMMENT ON COLUMN data.signing_submissions.native_group_id IS
  'Enllaç amb document_signing_sessions.signing_group_id per a firma pròpia';

-- ── create_signing_submission ampliat ─────────────────────────────────────────
DROP FUNCTION IF EXISTS api.create_signing_submission(uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb);

CREATE OR REPLACE FUNCTION api.create_signing_submission(
  p_tenant_id                   uuid,
  p_source_type                 text,
  p_source_document_id          uuid,
  p_source_document_version_id  uuid,
  p_source_template_locale_id   uuid,
  p_document_title              text,
  p_external_id                 text,
  p_signers                     jsonb,
  p_initiated_by                uuid,
  p_submitted_at                timestamptz DEFAULT NULL,
  p_metadata                    jsonb       DEFAULT NULL,
  p_signing_provider            text        DEFAULT 'docuseal',
  p_native_group_id             uuid        DEFAULT NULL,
  p_notification_mode           text        DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO data.signing_submissions (
    tenant_id,
    source_type,
    source_document_id,
    source_document_version_id,
    source_template_locale_id,
    document_title,
    status,
    external_id,
    signers,
    initiated_by,
    submitted_at,
    metadata,
    signing_provider,
    native_group_id,
    notification_mode
  )
  VALUES (
    p_tenant_id,
    p_source_type::data.signing_source_type,
    p_source_document_id,
    p_source_document_version_id,
    p_source_template_locale_id,
    p_document_title,
    'pending'::data.signing_submission_status,
    p_external_id,
    p_signers,
    p_initiated_by,
    COALESCE(p_submitted_at, now()),
    p_metadata,
    COALESCE(NULLIF(p_signing_provider, ''), 'docuseal'),
    p_native_group_id,
    p_notification_mode::data.signing_notification_mode
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_signing_submission(uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.create_signing_submission(uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb, text, uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.create_signing_submission(uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb, text, uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.create_signing_submission(uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb, text, uuid, text) TO service_role;

-- ── Sempre persistir signing_group_id quan es passa explícitament ─────────────
CREATE OR REPLACE FUNCTION api.create_signing_session(
  p_tenant_id           uuid,
  p_document_version_id uuid,
  p_signing_type        text,
  p_signer_name         text DEFAULT NULL,
  p_signer_email        text DEFAULT NULL,
  p_signer_role         text DEFAULT NULL,
  p_pdf_job_id          uuid DEFAULT NULL,
  p_expires_days        int  DEFAULT NULL,
  p_signing_group_id    uuid DEFAULT NULL,
  p_signer_order        int  DEFAULT 0,
  p_total_signers       int  DEFAULT 1
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
  v_group_id   uuid;
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
    RAISE EXCEPTION 'native_signing_disabled';
  END IF;

  SELECT COALESCE(
    p_expires_days,
    (settings ->> 'remote_signing_token_days')::int,
    7
  ) INTO v_token_days
  FROM data.system_settings WHERE module = 'pdf_converter';

  v_expires_at := now() + (v_token_days || ' days')::interval;
  v_token := replace(gen_random_uuid()::text, '-', '') || encode(extensions.gen_random_bytes(16), 'hex');
  v_group_id := COALESCE(p_signing_group_id, gen_random_uuid());

  INSERT INTO data.document_signing_sessions (
    tenant_id, document_version_id, signing_token, signing_type,
    signer_name, signer_email, signer_role,
    operator_user_id, expires_at, pdf_job_id,
    signing_group_id, signer_order, total_signers
  ) VALUES (
    p_tenant_id, p_document_version_id, v_token, p_signing_type,
    p_signer_name, p_signer_email, p_signer_role,
    v_user_id, v_expires_at, p_pdf_job_id,
    COALESCE(
      p_signing_group_id,
      CASE WHEN GREATEST(COALESCE(p_total_signers, 1), 1) > 1 THEN v_group_id ELSE NULL END
    ),
    COALESCE(p_signer_order, 0),
    GREATEST(COALESCE(p_total_signers, 1), 1)
  )
  RETURNING id INTO v_session_id;

  IF p_signing_type = 'remote' THEN
    INSERT INTO data.document_signature_evidences (session_id, event_type)
    VALUES (v_session_id, 'link_sent');
  END IF;

  RETURN jsonb_build_object(
    'session_id',        v_session_id,
    'token',             v_token,
    'expires_at',        v_expires_at,
    'signing_type',      p_signing_type,
    'signing_group_id',  COALESCE(
      p_signing_group_id,
      CASE WHEN GREATEST(COALESCE(p_total_signers, 1), 1) > 1 THEN v_group_id ELSE NULL END
    ),
    'signer_order',      COALESCE(p_signer_order, 0),
    'total_signers',     GREATEST(COALESCE(p_total_signers, 1), 1)
  );
END;
$$;

-- ── Completar signant native → actualitza submission ─────────────────────────
CREATE OR REPLACE FUNCTION api.on_native_signer_completed(
  p_session_id          uuid,
  p_result_version_id   uuid,
  p_signed_at           timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_sess         record;
  v_submission   record;
  v_all_signed   boolean;
  v_signers      jsonb;
  v_status_after text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT id, tenant_id, signing_group_id, signer_email, signer_name,
         signer_order, total_signers, signing_type
    INTO v_sess
    FROM data.document_signing_sessions
   WHERE id = p_session_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'session_not_found';
  END IF;

  IF v_sess.signing_group_id IS NULL THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'no_signing_group');
  END IF;

  SELECT id, status, signers, tenant_id
    INTO v_submission
    FROM data.signing_submissions
   WHERE native_group_id = v_sess.signing_group_id
     AND signing_provider = 'native'
   ORDER BY created_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'submission_not_found');
  END IF;

  -- Actualitzar snapshot del signant
  SELECT COALESCE(
    jsonb_agg(
      CASE
        WHEN (elem->>'order')::int = v_sess.signer_order
          OR (v_sess.signer_email IS NOT NULL AND elem->>'email' = v_sess.signer_email)
        THEN elem || jsonb_build_object(
          'status',       'completed',
          'completed_at', to_char(p_signed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        )
        ELSE elem
      END
      ORDER BY COALESCE((elem->>'order')::int, 0)
    ),
    '[]'::jsonb
  )
  INTO v_signers
  FROM jsonb_array_elements(COALESCE(v_submission.signers, '[]'::jsonb)) AS elem;

  UPDATE data.signing_submissions
     SET signers    = v_signers,
         updated_at = now()
   WHERE id = v_submission.id;

  -- Totes les sessions del grup signades?
  SELECT NOT EXISTS (
    SELECT 1
      FROM data.document_signing_sessions
     WHERE signing_group_id = v_sess.signing_group_id
       AND status NOT IN ('signed', 'cancelled')
  ) INTO v_all_signed;

  IF v_all_signed THEN
    v_status_after := 'completed';
    UPDATE data.signing_submissions
       SET status                     = 'completed'::data.signing_submission_status,
           result_document_version_id = p_result_version_id,
           completed_at               = COALESCE(completed_at, p_signed_at),
           last_event_at              = now(),
           updated_at                 = now()
     WHERE id = v_submission.id;
  ELSE
    v_status_after := 'in_progress';
    UPDATE data.signing_submissions
       SET status        = 'in_progress'::data.signing_submission_status,
           last_event_at = now(),
           updated_at    = now()
     WHERE id = v_submission.id
       AND status NOT IN ('completed', 'cancelled', 'error');
  END IF;

  RETURN jsonb_build_object(
    'submission_id', v_submission.id,
    'all_signed',    v_all_signed,
    'status',        v_status_after,
    'signer_email',  v_sess.signer_email,
    'signer_name',   v_sess.signer_name
  );
END;
$$;

REVOKE ALL ON FUNCTION api.on_native_signer_completed(uuid, uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.on_native_signer_completed(uuid, uuid, timestamptz) TO service_role;

-- ── Auditoria de hashes per submission native ────────────────────────────────
CREATE OR REPLACE FUNCTION api.get_signature_audit_for_submission(p_submission_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_group_id uuid;
  v_tenant   uuid;
BEGIN
  SELECT native_group_id, tenant_id
    INTO v_group_id, v_tenant
    FROM data.signing_submissions
   WHERE id = p_submission_id
     AND signing_provider = 'native';

  IF NOT FOUND OR v_group_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  IF auth.role() <> 'service_role'
     AND NOT (data.jwt_user_tenants() ? v_tenant::text)
  THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'session_id',           a.session_id,
        'signer_name',          a.signer_name,
        'signer_email',         a.signer_email,
        'signer_role',          a.signer_role,
        'timestamp_signed',     a.timestamp_signed,
        'document_hash_before', a.document_hash_before,
        'document_hash_after',  a.document_hash_after,
        'audit_pdf_path',       a.audit_pdf_path,
        'signer_order',         s.signer_order
      )
      ORDER BY s.signer_order
    )
    FROM data.document_signatures_audit a
    JOIN data.document_signing_sessions s ON s.id = a.session_id
   WHERE s.signing_group_id = v_group_id
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.get_signature_audit_for_submission(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_signature_audit_for_submission(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_signature_audit_for_submission(uuid) TO service_role;

-- ── Vista api.signing_submissions ─────────────────────────────────────────────
DROP VIEW IF EXISTS api.signing_submissions;

CREATE VIEW api.signing_submissions WITH (security_invoker = true) AS
  SELECT
    ss.id,
    ss.tenant_id,
    ss.source_type,
    ss.source_document_id,
    ss.source_document_version_id,
    ss.source_template_locale_id,
    ss.result_document_version_id,
    rv.file_path_or_url       AS result_file_path_or_url,
    rv.storage_type           AS result_storage_type,
    ss.docuseal_submission_id,
    ss.external_id,
    ss.status,
    ss.status_reason,
    ss.error_message,
    ss.last_event_at,
    ss.signers,
    ss.docuseal_signing_url,
    ss.notification_mode,
    ss.notification_enabled,
    ss.next_signer_index,
    ss.first_email_sent_at,
    ss.last_notification_at,
    ss.submitted_at,
    ss.completed_at,
    ss.reviewed_at,
    ss.reviewed_by,
    ss.document_title,
    ss.audit_trail_storage_path,
    ss.audit_log_url,
    ss.initiated_by,
    ss.metadata,
    ss.signing_provider,
    ss.native_group_id,
    ss.created_at,
    ss.updated_at
  FROM data.signing_submissions ss
  LEFT JOIN data.document_versions rv ON rv.id = ss.result_document_version_id;

GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO service_role;

-- ── Trigger UPDATE vista ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION data.trg_api_signing_submissions_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.signing_submissions
  SET
    status                     = NEW.status,
    status_reason              = NEW.status_reason,
    error_message              = NEW.error_message,
    last_event_at              = NEW.last_event_at,
    updated_at                 = NEW.updated_at,
    docuseal_submission_id     = NEW.docuseal_submission_id,
    docuseal_signing_url       = NEW.docuseal_signing_url,
    signers                    = NEW.signers,
    result_document_version_id = NEW.result_document_version_id,
    audit_trail_storage_path   = NEW.audit_trail_storage_path,
    audit_log_url              = NEW.audit_log_url,
    notification_mode          = NEW.notification_mode,
    notification_enabled       = NEW.notification_enabled,
    next_signer_index          = NEW.next_signer_index,
    first_email_sent_at        = NEW.first_email_sent_at,
    last_notification_at       = NEW.last_notification_at,
    submitted_at               = NEW.submitted_at,
    completed_at               = NEW.completed_at,
    reviewed_at                = NEW.reviewed_at,
    reviewed_by                = NEW.reviewed_by,
    document_title             = NEW.document_title,
    initiated_by               = NEW.initiated_by,
    metadata                   = NEW.metadata,
    signing_provider           = NEW.signing_provider,
    native_group_id            = NEW.native_group_id
  WHERE id = NEW.id;

  RETURN NEW;
END;
$$;
