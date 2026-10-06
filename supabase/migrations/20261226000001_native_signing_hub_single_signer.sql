-- Fix: native single-signer presential left signing_submissions stuck on pending.
--
-- Root cause (20260615000012): create_signing_session only persisted
-- signing_group_id when total_signers > 1. The router still stored
-- native_group_id on signing_submissions. on_native_signer_completed then
-- skipped with reason no_signing_group, so the hub never completed even
-- though document_signing_sessions was signed and commercial accept ran.

-- ── 1. Always persist explicit signing_group_id (incl. 1 signant) ────────────
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
  v_token := replace(gen_random_uuid()::text, '-', '')
    || encode(extensions.gen_random_bytes(16), 'hex');

  INSERT INTO data.document_signing_sessions (
    tenant_id, document_version_id, signing_token, signing_type,
    signer_name, signer_email, signer_role,
    operator_user_id, expires_at, pdf_job_id,
    signing_group_id, signer_order, total_signers
  ) VALUES (
    p_tenant_id, p_document_version_id, v_token, p_signing_type,
    p_signer_name, p_signer_email, p_signer_role,
    v_user_id, v_expires_at, p_pdf_job_id,
    p_signing_group_id,
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
    'signing_group_id',  p_signing_group_id,
    'signer_order',      COALESCE(p_signer_order, 0),
    'total_signers',     GREATEST(COALESCE(p_total_signers, 1), 1)
  );
END;
$$;

-- ── 2. Hub completion: group lookup + legacy metadata fallback ───────────────
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
  v_group_id     uuid;
  v_all_signed   boolean;
  v_signers      jsonb;
  v_status_after text;
  v_found        boolean := false;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT id, tenant_id, signing_group_id, signer_email, signer_name,
         signer_order, total_signers, signing_type, status
    INTO v_sess
    FROM data.document_signing_sessions
   WHERE id = p_session_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'session_not_found';
  END IF;

  -- Preferred: session.signing_group_id ↔ submission.native_group_id
  IF v_sess.signing_group_id IS NOT NULL THEN
    SELECT id, status, signers, tenant_id, native_group_id, metadata
      INTO v_submission
      FROM data.signing_submissions
     WHERE native_group_id = v_sess.signing_group_id
       AND signing_provider = 'native'
     ORDER BY created_at DESC
     LIMIT 1;
    v_found := FOUND;
  END IF;

  -- Legacy single-signer: group was dropped on the session but hub kept
  -- native_group_id + session ids in metadata.
  IF NOT v_found THEN
    SELECT id, status, signers, tenant_id, native_group_id, metadata
      INTO v_submission
      FROM data.signing_submissions
     WHERE signing_provider = 'native'
       AND (
         metadata->>'primary_session_id' = p_session_id::text
         OR (metadata->'session_ids') ? p_session_id::text
       )
     ORDER BY created_at DESC
     LIMIT 1;
    v_found := FOUND;
  END IF;

  IF NOT v_found THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'submission_not_found');
  END IF;

  v_group_id := COALESCE(v_sess.signing_group_id, v_submission.native_group_id);

  -- Heal orphan sessions so future multi-signer / audit lookups work.
  IF v_sess.signing_group_id IS NULL AND v_group_id IS NOT NULL THEN
    UPDATE data.document_signing_sessions
       SET signing_group_id = v_group_id,
           updated_at = now()
     WHERE id = p_session_id
       AND signing_group_id IS NULL;
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

  IF v_group_id IS NOT NULL THEN
    SELECT NOT EXISTS (
      SELECT 1
        FROM data.document_signing_sessions s
       WHERE (
           s.signing_group_id = v_group_id
           OR s.id IN (
             SELECT (jsonb_array_elements_text(
               COALESCE(v_submission.metadata->'session_ids', '[]'::jsonb)
             ))::uuid
           )
         )
         AND s.status NOT IN ('signed', 'cancelled')
    ) INTO v_all_signed;
  ELSE
    v_all_signed := COALESCE(v_sess.total_signers, 1) <= 1;
  END IF;

  IF v_all_signed THEN
    v_status_after := 'completed';
    UPDATE data.signing_submissions
       SET signers                    = v_signers,
           status                     = 'completed'::data.signing_submission_status,
           result_document_version_id = COALESCE(p_result_version_id, result_document_version_id),
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

REVOKE ALL ON FUNCTION api.on_native_signer_completed(uuid, uuid, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.on_native_signer_completed(uuid, uuid, text, timestamptz) TO service_role;

-- ── 3. Backfill: restore group link on legacy single-signer sessions ─────────
UPDATE data.document_signing_sessions s
   SET signing_group_id = ss.native_group_id,
       updated_at = now()
  FROM data.signing_submissions ss
 WHERE ss.signing_provider = 'native'
   AND ss.native_group_id IS NOT NULL
   AND s.signing_group_id IS NULL
   AND (
     ss.metadata->>'primary_session_id' = s.id::text
     OR (ss.metadata->'session_ids') ? s.id::text
   );

-- ── 4. Repair hub rows already signed but still pending/in_progress ──────────
WITH candidates AS (
  SELECT ss.id AS submission_id
  FROM data.signing_submissions ss
  WHERE ss.signing_provider = 'native'
    AND ss.status IN ('pending', 'in_progress')
    AND EXISTS (
      SELECT 1
        FROM data.document_signing_sessions s
       WHERE s.status = 'signed'
         AND (
           s.id::text = ss.metadata->>'primary_session_id'
           OR (ss.metadata->'session_ids') ? s.id::text
           OR (ss.native_group_id IS NOT NULL AND s.signing_group_id = ss.native_group_id)
         )
    )
    AND NOT EXISTS (
      SELECT 1
        FROM data.document_signing_sessions open_s
       WHERE open_s.status NOT IN ('signed', 'cancelled')
         AND (
           (ss.native_group_id IS NOT NULL AND open_s.signing_group_id = ss.native_group_id)
           OR open_s.id::text = ss.metadata->>'primary_session_id'
           OR (ss.metadata->'session_ids') ? open_s.id::text
         )
    )
),
linked AS (
  SELECT
    ss.id AS submission_id,
    (
      SELECT s.result_version_id
        FROM data.document_signing_sessions s
       WHERE s.status = 'signed'
         AND (
           s.id::text = ss.metadata->>'primary_session_id'
           OR (ss.metadata->'session_ids') ? s.id::text
           OR (ss.native_group_id IS NOT NULL AND s.signing_group_id = ss.native_group_id)
         )
       ORDER BY CASE WHEN s.id::text = ss.metadata->>'primary_session_id' THEN 0 ELSE 1 END,
                s.updated_at DESC NULLS LAST
       LIMIT 1
    ) AS result_version_id,
    COALESCE(
      (
        SELECT MAX((ts.timestamps->>'signed_at')::timestamptz)
          FROM data.document_signing_sessions ts
         WHERE ts.status = 'signed'
           AND (
             ts.signing_group_id = ss.native_group_id
             OR ts.id::text = ss.metadata->>'primary_session_id'
             OR (ss.metadata->'session_ids') ? ts.id::text
           )
      ),
      now()
    ) AS signed_at,
    (
      SELECT COALESCE(
        jsonb_agg(
          CASE
            WHEN EXISTS (
              SELECT 1
                FROM data.document_signing_sessions xs
               WHERE xs.status = 'signed'
                 AND (
                   (elem->>'email' IS NOT NULL AND xs.signer_email = elem->>'email')
                   OR (elem->>'order')::int IS NOT DISTINCT FROM xs.signer_order
                 )
                 AND (
                   xs.signing_group_id = ss.native_group_id
                   OR xs.id::text = ss.metadata->>'primary_session_id'
                   OR (ss.metadata->'session_ids') ? xs.id::text
                 )
            )
            THEN elem || jsonb_build_object(
              'status', 'completed',
              'completed_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            )
            ELSE elem
          END
          ORDER BY COALESCE((elem->>'order')::int, 0)
        ),
        ss.signers
      )
      FROM jsonb_array_elements(COALESCE(ss.signers, '[]'::jsonb)) AS elem
    ) AS healed_signers
  FROM data.signing_submissions ss
  JOIN candidates c ON c.submission_id = ss.id
)
UPDATE data.signing_submissions ss
   SET signers                    = linked.healed_signers,
       status                     = 'completed'::data.signing_submission_status,
       result_document_version_id = COALESCE(ss.result_document_version_id, linked.result_version_id),
       staging_storage_path       = NULL,
       completed_at               = COALESCE(ss.completed_at, linked.signed_at),
       last_event_at              = now(),
       updated_at                 = now()
  FROM linked
 WHERE ss.id = linked.submission_id;
