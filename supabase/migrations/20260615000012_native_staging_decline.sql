-- Staging PDF temporal, rebuig públic, integritat només al completar grup

ALTER TABLE data.signing_submissions
  ADD COLUMN IF NOT EXISTS staging_storage_path text;

COMMENT ON COLUMN data.signing_submissions.staging_storage_path IS
  'PDF de treball amb firmes parcials (no és document_version). Esborrat al completar o rebutjar.';

-- ── Evidència: rebutjar signatura ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION api.log_signing_evidence(
  p_session_id uuid,
  p_event_type text,
  p_ip_address text DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_geolocation jsonb DEFAULT NULL,
  p_metadata    jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_event_type NOT IN (
    'link_opened', 'document_viewed', 'signature_drawn', 'signed', 'link_sent', 'declined'
  ) THEN
    RAISE EXCEPTION 'invalid_event_type';
  END IF;

  IF p_event_type <> 'declined' AND NOT EXISTS (
    SELECT 1 FROM data.document_signing_sessions
     WHERE id = p_session_id AND status NOT IN ('signed', 'cancelled', 'expired')
  ) THEN
    RAISE EXCEPTION 'session_not_active';
  END IF;

  INSERT INTO data.document_signature_evidences (
    session_id, event_type, ip_address, user_agent, geolocation, metadata
  ) VALUES (
    p_session_id, p_event_type,
    CASE WHEN p_ip_address IS NOT NULL THEN p_ip_address::inet ELSE NULL END,
    p_user_agent, p_geolocation, p_metadata
  );
END;
$$;

-- ── Completar signant: staging durant in_progress, versió final només al completar ──
CREATE OR REPLACE FUNCTION api.on_native_signer_completed(
  p_session_id             uuid,
  p_result_version_id      uuid,
  p_staging_storage_path   text DEFAULT NULL,
  p_signed_at              timestamptz DEFAULT now()
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

  SELECT NOT EXISTS (
    SELECT 1
      FROM data.document_signing_sessions
     WHERE signing_group_id = v_sess.signing_group_id
       AND status NOT IN ('signed', 'cancelled')
  ) INTO v_all_signed;

  IF v_all_signed THEN
    v_status_after := 'completed';
    UPDATE data.signing_submissions
       SET signers                    = v_signers,
           status                     = 'completed'::data.signing_submission_status,
           result_document_version_id = p_result_version_id,
           staging_storage_path       = NULL,
           completed_at               = COALESCE(completed_at, p_signed_at),
           last_event_at              = now(),
           updated_at                 = now()
     WHERE id = v_submission.id;
  ELSE
    v_status_after := 'in_progress';
    UPDATE data.signing_submissions
       SET signers                    = v_signers,
           status                     = 'in_progress'::data.signing_submission_status,
           staging_storage_path       = COALESCE(p_staging_storage_path, staging_storage_path),
           last_event_at              = now(),
           updated_at                 = now()
     WHERE id = v_submission.id
       AND status NOT IN ('completed', 'cancelled', 'declined', 'error');
  END IF;

  RETURN jsonb_build_object(
    'submission_id', v_submission.id,
    'all_signed',    v_all_signed,
    'status',        v_status_after,
    'signer_email',  v_sess.signer_email,
    'signer_name',   v_sess.signer_name,
    'signer_order',  v_sess.signer_order
  );
END;
$$;

-- ── Avançar grup: ja no canvia document_version_id (preview via staging) ────
CREATE OR REPLACE FUNCTION api.advance_native_signing_group(
  p_completed_session_id    uuid,
  p_new_document_version_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_done   record;
  v_next   record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT signing_group_id, signer_order, total_signers, tenant_id
    INTO v_done
    FROM data.document_signing_sessions
   WHERE id = p_completed_session_id;

  IF NOT FOUND OR v_done.signing_group_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_done.signer_order >= v_done.total_signers - 1 THEN
    RETURN NULL;
  END IF;

  SELECT *
    INTO v_next
    FROM data.document_signing_sessions
   WHERE signing_group_id = v_done.signing_group_id
     AND signer_order     = v_done.signer_order + 1
     AND status NOT IN ('signed', 'cancelled', 'expired')
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'session_id',   v_next.id,
    'token',        v_next.signing_token,
    'signer_email', v_next.signer_email,
    'signer_name',  v_next.signer_name,
    'signer_role',  v_next.signer_role,
    'signer_order', v_next.signer_order,
    'total_signers', v_next.total_signers,
    'tenant_id',    v_next.tenant_id,
    'expires_at',   v_next.expires_at
  );
END;
$$;

-- ── Rebuig públic des de /sign/:token ───────────────────────────────────────
CREATE OR REPLACE FUNCTION api.decline_signing_session_public(
  p_token  text,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_sess            record;
  v_submission      record;
  v_signers         jsonb;
  v_staging         text;
  v_submission_id   uuid;
BEGIN
  SELECT * INTO v_sess
    FROM data.document_signing_sessions
   WHERE signing_token = p_token
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'token_not_found');
  END IF;

  IF v_sess.status = 'signed' THEN
    RETURN jsonb_build_object('error', 'already_signed');
  END IF;

  IF v_sess.status = 'cancelled' THEN
    RETURN jsonb_build_object('success', true, 'already_declined', true);
  END IF;

  IF v_sess.expires_at < now() THEN
    RETURN jsonb_build_object('error', 'token_expired');
  END IF;

  UPDATE data.document_signing_sessions
     SET status = 'cancelled', updated_at = now()
   WHERE id = v_sess.id;

  IF v_sess.signing_group_id IS NOT NULL THEN
    UPDATE data.document_signing_sessions
       SET status = 'cancelled', updated_at = now()
     WHERE signing_group_id = v_sess.signing_group_id
       AND status NOT IN ('signed', 'cancelled');

    SELECT id, signers, staging_storage_path
      INTO v_submission
      FROM data.signing_submissions
     WHERE native_group_id = v_sess.signing_group_id
       AND signing_provider = 'native'
     ORDER BY created_at DESC
     LIMIT 1;

    IF FOUND THEN
      v_submission_id := v_submission.id;
      v_staging := v_submission.staging_storage_path;

      SELECT COALESCE(
        jsonb_agg(
          CASE
            WHEN (elem->>'order')::int = v_sess.signer_order
              OR (v_sess.signer_email IS NOT NULL AND elem->>'email' = v_sess.signer_email)
            THEN elem || jsonb_build_object('status', 'declined')
            WHEN (elem->>'status') = 'pending'
            THEN elem || jsonb_build_object('status', 'cancelled')
            ELSE elem
          END
          ORDER BY COALESCE((elem->>'order')::int, 0)
        ),
        '[]'::jsonb
      )
      INTO v_signers
      FROM jsonb_array_elements(COALESCE(v_submission.signers, '[]'::jsonb)) AS elem;

      UPDATE data.signing_submissions
         SET status                 = 'declined'::data.signing_submission_status,
             status_reason          = COALESCE(p_reason, status_reason),
             signers                = v_signers,
             staging_storage_path   = NULL,
             last_event_at          = now(),
             updated_at             = now()
       WHERE id = v_submission.id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success',              true,
    'session_id',           v_sess.id,
    'staging_storage_path', v_staging,
    'submission_id',        v_submission_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.decline_signing_session_public(text, text) TO anon, authenticated, service_role;

-- ── Sempre persistir signing_group_id quan el router l'envia (multi-signant) ──
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
    CASE WHEN p_signing_group_id IS NOT NULL AND p_total_signers > 1 THEN p_signing_group_id ELSE NULL END,
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
    'signing_group_id',  CASE WHEN p_signing_group_id IS NOT NULL AND p_total_signers > 1 THEN p_signing_group_id ELSE NULL END,
    'signer_order',      COALESCE(p_signer_order, 0),
    'total_signers',     GREATEST(COALESCE(p_total_signers, 1), 1)
  );
END;
$$;

-- ── Vista: preview via staging mentre in_progress ───────────────────────────
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
    COALESCE(rv.file_path_or_url, ss.staging_storage_path) AS result_file_path_or_url,
    CASE
      WHEN rv.id IS NOT NULL THEN rv.storage_type
      WHEN ss.staging_storage_path IS NOT NULL THEN 'native'
      ELSE NULL
    END AS result_storage_type,
    ss.staging_storage_path,
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

-- ── Sessió pública: estat declined ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION api.get_signing_session_public(p_token text)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_session record;
  v_staging text;
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
    RETURN jsonb_build_object('error', 'session_declined');
  END IF;

  IF v_session.status = 'pending' THEN
    UPDATE data.document_signing_sessions
       SET status     = 'opened',
           timestamps = COALESCE(v_session.timestamps, '{}') || jsonb_build_object('opened_at', now()),
           updated_at = now()
     WHERE id = v_session.id;
    v_session.status := 'opened';
  END IF;

  v_staging := NULL;
  IF v_session.signing_group_id IS NOT NULL THEN
    SELECT staging_storage_path INTO v_staging
      FROM data.signing_submissions
     WHERE native_group_id = v_session.signing_group_id
       AND signing_provider = 'native'
     ORDER BY created_at DESC
     LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'session_id',           v_session.id,
    'tenant_id',            v_session.tenant_id,
    'document_version_id',  v_session.document_version_id,
    'staging_storage_path', v_staging,
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
