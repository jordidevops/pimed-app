-- Fix PL/pgSQL: do not read unassigned record fields in on_native_signer_completed.

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
