-- Actualitzar result_document_version_id a cada signatura (no només al completar el grup)
-- Permet veure el PDF parcialment signat des del Centre mentre in_progress.

CREATE OR REPLACE FUNCTION api.on_native_signer_completed(
  p_session_id        uuid,
  p_result_version_id uuid,
  p_signed_at         timestamptz DEFAULT now()
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
           completed_at               = COALESCE(completed_at, p_signed_at),
           last_event_at              = now(),
           updated_at                 = now()
     WHERE id = v_submission.id;
  ELSE
    v_status_after := 'in_progress';
    UPDATE data.signing_submissions
       SET signers                    = v_signers,
           status                     = 'in_progress'::data.signing_submission_status,
           result_document_version_id = p_result_version_id,
           last_event_at              = now(),
           updated_at                 = now()
     WHERE id = v_submission.id
       AND status NOT IN ('completed', 'cancelled', 'error');
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
