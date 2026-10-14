-- CS-D6 (acords): no apply commercial decision / finalize until ALL native
-- sessions in the signing group are signed (or declined for decline path).

CREATE OR REPLACE FUNCTION data.apply_commercial_signing_intent_for_session(p_session_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = data
AS $$
DECLARE
  v_intent data.commercial_signing_intents%ROWTYPE;
  v_intent_id uuid;
  v_session data.document_signing_sessions%ROWTYPE;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_signature jsonb;
  v_outcome text;
  v_via text;
  v_apply jsonb;
  v_group_id uuid;
  v_pending int;
BEGIN
  -- Prefer intent bound to this session; else same submission / signing group
  -- (multi-signer: intent is registered on primary session only).
  SELECT id INTO v_intent_id
  FROM data.commercial_signing_intents
  WHERE session_id = p_session_id
  LIMIT 1;

  IF v_intent_id IS NULL THEN
    SELECT i.id INTO v_intent_id
    FROM data.commercial_signing_intents i
    JOIN data.document_signing_sessions s ON s.id = p_session_id
    JOIN data.signing_submissions ss
      ON ss.id = i.submission_id
     AND ss.signing_provider = 'native'
     AND (
       (s.signing_group_id IS NOT NULL AND ss.native_group_id = s.signing_group_id)
       OR (ss.metadata->'session_ids') ? p_session_id::text
     )
    WHERE i.applied_at IS NULL
    ORDER BY i.created_at DESC
    LIMIT 1;
  END IF;

  IF v_intent_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_intent
  FROM data.commercial_signing_intents
  WHERE id = v_intent_id
  FOR UPDATE;

  IF NOT FOUND OR v_intent.applied_at IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_session
  FROM data.document_signing_sessions
  WHERE id = p_session_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_via := CASE
    WHEN COALESCE(v_session.timestamps->>'decision_via', '') = 'portal' THEN 'portal'
    WHEN COALESCE(v_session.signing_type, '') = 'presential' THEN 'presential'
    ELSE 'link'
  END;

  v_group_id := v_session.signing_group_id;

  -- Multi-signer gate: wait until every session in the group is terminal.
  IF v_group_id IS NOT NULL AND COALESCE(v_session.total_signers, 1) > 1 THEN
    SELECT count(*)::int INTO v_pending
    FROM data.document_signing_sessions s
    WHERE s.signing_group_id = v_group_id
      AND s.status NOT IN ('signed', 'declined', 'cancelled');
    IF v_pending > 0 THEN
      RETURN;
    END IF;
  ELSIF COALESCE(v_session.total_signers, 1) > 1 THEN
    -- Legacy: no group link — do not apply from a non-final signer alone.
    IF v_session.signer_order IS NOT NULL
       AND v_session.signer_order < GREATEST(v_session.total_signers - 1, 0) THEN
      RETURN;
    END IF;
  END IF;

  IF v_session.status = 'declined'
     AND v_intent.decision_request_id IS NOT NULL
     AND data.commercial_decision_requests_enabled(v_intent.tenant_id)
  THEN
    v_signature := jsonb_strip_nulls(jsonb_build_object(
      'method', 'native',
      'provider', 'native',
      'provider_session_id', v_intent.session_id,
      'provider_submission_id', v_intent.submission_id,
      'signer_role', v_session.signer_role,
      'signer_name', v_session.signer_name,
      'reason', v_session.timestamps ->> 'decline_reason'
    ));
    v_apply := data.apply_commercial_decision_request(
      v_intent.decision_request_id,
      'declined',
      v_via,
      v_signature,
      v_intent.client_op_id,
      COALESCE(v_intent.created_by, v_session.operator_user_id)
    );
    IF NOT (
      coalesce((v_apply->>'applied')::boolean, false)
      OR (
        coalesce((v_apply->>'already_decided')::boolean, false)
        AND coalesce(v_apply->>'status', '') IN ('accepted', 'declined')
      )
    ) THEN
      RAISE EXCEPTION 'commercial_decision_strangler_apply_failed:%',
        coalesce(v_apply->>'status', 'unknown')
        USING ERRCODE = 'P0001';
    END IF;
    UPDATE data.commercial_signing_intents
    SET applied_at = now()
    WHERE id = v_intent.id;
    RETURN;
  END IF;

  IF v_session.status <> 'signed' THEN
    RETURN;
  END IF;

  -- If any peer declined, do not accept from a remaining signed session.
  IF v_group_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM data.document_signing_sessions s
      WHERE s.signing_group_id = v_group_id AND s.status = 'declined'
    ) THEN
      RETURN;
    END IF;
  END IF;

  IF v_intent.decision_request_id IS NOT NULL
     AND data.commercial_decision_requests_enabled(v_intent.tenant_id)
  THEN
    IF v_intent.action = 'accept' THEN
      PERFORM data.commercial_accept_office_gate_for_actor(
        v_intent.document_id,
        COALESCE(v_intent.created_by, v_session.operator_user_id)
      );
      v_outcome := 'accepted';
    ELSIF v_intent.action = 'reject' THEN
      v_outcome := 'declined';
    ELSIF v_intent.action = 'delivery' THEN
      v_outcome := 'accepted';
    ELSE
      RETURN;
    END IF;

    SELECT * INTO v_req
    FROM data.commercial_decision_requests
    WHERE id = v_intent.decision_request_id;

    v_signature := jsonb_strip_nulls(jsonb_build_object(
      'method', 'native',
      'provider', 'native',
      'provider_session_id', v_intent.session_id,
      'provider_submission_id', v_intent.submission_id,
      'signer_role', v_session.signer_role,
      'signer_name', v_session.signer_name,
      'principal_kind', v_session.timestamps->>'principal_kind',
      'grant_id', v_session.timestamps->>'grant_id',
      'all_signers_required',
        CASE
          WHEN v_req.agreement_version_id IS NOT NULL THEN true
          ELSE null
        END
    ));

    v_apply := data.apply_commercial_decision_request(
      v_intent.decision_request_id,
      v_outcome,
      v_via,
      v_signature,
      v_intent.client_op_id,
      COALESCE(v_intent.created_by, v_session.operator_user_id)
    );
    IF NOT (
      coalesce((v_apply->>'applied')::boolean, false)
      OR (
        coalesce((v_apply->>'already_decided')::boolean, false)
        AND coalesce(v_apply->>'status', '') IN ('accepted', 'declined')
      )
    ) THEN
      RAISE EXCEPTION 'commercial_decision_strangler_apply_failed:%',
        coalesce(v_apply->>'status', 'unknown')
        USING ERRCODE = 'P0001';
    END IF;

    UPDATE data.commercial_signing_intents
    SET applied_at = now()
    WHERE id = v_intent.id;
    RETURN;
  END IF;

  IF v_intent.action = 'accept' THEN
    PERFORM data.commercial_accept_office_gate_for_actor(
      v_intent.document_id,
      COALESCE(v_intent.created_by, v_session.operator_user_id)
    );
  END IF;

  v_signature := jsonb_strip_nulls(jsonb_build_object(
    'method', 'native',
    'signing_submission_id', v_intent.submission_id,
    'signing_session_id', v_intent.session_id,
    'signer_role', v_session.signer_role,
    'signer_name', v_session.signer_name
  ));

  PERFORM data.apply_commercial_decision(
    v_intent.document_id,
    v_intent.action,
    v_signature,
    v_intent.client_op_id,
    COALESCE(v_intent.created_by, v_session.operator_user_id)
  );

  UPDATE data.commercial_signing_intents
  SET applied_at = now()
  WHERE id = v_intent.id;
END;
$$;

COMMENT ON FUNCTION data.apply_commercial_signing_intent_for_session(uuid) IS
  'Applies commercial signing intent after native session terminal state. Multi-signer groups wait until all sessions are signed (CS-D6 acords).';

-- DocuSeal evidence: include full signers array (not only signers->0).
CREATE OR REPLACE FUNCTION data.apply_commercial_decision_from_docuseal_submission(
  p_submission_id uuid,
  p_outcome text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sub data.signing_submissions%ROWTYPE;
  v_request_id uuid;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_evidence jsonb;
  v_op uuid;
  v_result jsonb;
  v_client jsonb;
BEGIN
  IF p_outcome NOT IN ('accepted', 'declined') THEN
    RAISE EXCEPTION 'invalid_decision_outcome' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_sub
  FROM data.signing_submissions
  WHERE id = p_submission_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'submission_not_found');
  END IF;

  IF NOT COALESCE((v_sub.metadata->>'commercial_bridge')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_commercial_bridge');
  END IF;

  IF COALESCE((v_sub.metadata->>'superseded_by_switch')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'submission_superseded');
  END IF;

  -- CS-D6: only when the whole submission is complete (DocuSeal multi-signer).
  IF p_outcome = 'accepted' AND v_sub.status IS DISTINCT FROM 'completed' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'submission_not_completed');
  END IF;

  BEGIN
    v_request_id := NULLIF(btrim(COALESCE(v_sub.metadata->>'decision_request_id', '')), '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_decision_request_id');
  END;

  IF v_request_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'missing_decision_request_id');
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = v_request_id;
  IF NOT FOUND OR v_req.tenant_id IS DISTINCT FROM v_sub.tenant_id THEN
    RETURN jsonb_build_object('ok', false, 'code', 'decision_request_not_found');
  END IF;

  v_op := (
    SELECT uuid_in(
      overlay(
        overlay(md5('commercial-docuseal:' || p_submission_id::text || ':' || p_outcome)
          placing '4' from 13)
        placing '8' from 17)::cstring
    )
  );

  SELECT elem INTO v_client
  FROM jsonb_array_elements(COALESCE(v_sub.signers, '[]'::jsonb)) AS elem
  WHERE elem->>'role' IN ('client', 'client_accept')
  ORDER BY COALESCE((elem->>'order')::int, 0) DESC
  LIMIT 1;
  IF v_client IS NULL THEN
    v_client := COALESCE(v_sub.signers->0, '{}'::jsonb);
  END IF;

  v_evidence := jsonb_strip_nulls(jsonb_build_object(
    'method', 'docuseal',
    'provider', 'docuseal',
    'provider_submission_id', v_sub.id,
    'docuseal_submission_id', v_sub.docuseal_submission_id,
    'signer_name', v_client->>'name',
    'signer_email', v_client->>'email',
    'signers', v_sub.signers,
    'result_document_version_id', v_sub.result_document_version_id,
    'artifact_status', v_sub.metadata->>'artifact_status'
  ));

  v_result := data.apply_commercial_decision_request(
    v_request_id,
    p_outcome,
    'provider',
    v_evidence,
    v_op,
    NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_request_id,
    'result', v_result
  );
END;
$$;
