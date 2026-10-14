-- Fix CS-D6 multi-signer terminal handling + CS-D8 strangler (no quote accept on agreement sign).
-- Peer declined/cancelled → apply decline (never silent RETURN / never accept).
-- Without decision-requests: finalize agreement version; never apply_commercial_decision on quote.

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
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_sub data.signing_submissions%ROWTYPE;
  v_signature jsonb;
  v_outcome text;
  v_via text;
  v_apply jsonb;
  v_group_id uuid;
  v_pending int;
  v_group_failed boolean := false;
  v_signed_doc uuid;
  v_actor uuid;
BEGIN
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
  v_actor := COALESCE(v_intent.created_by, v_session.operator_user_id);
  v_group_id := v_session.signing_group_id;

  -- Wait until every session in the multi-signer group is terminal.
  IF v_group_id IS NOT NULL AND COALESCE(v_session.total_signers, 1) > 1 THEN
    SELECT count(*)::int INTO v_pending
    FROM data.document_signing_sessions s
    WHERE s.signing_group_id = v_group_id
      AND s.status NOT IN ('signed', 'declined', 'cancelled');
    IF v_pending > 0 THEN
      RETURN;
    END IF;
    SELECT EXISTS (
      SELECT 1 FROM data.document_signing_sessions s
      WHERE s.signing_group_id = v_group_id
        AND s.status IN ('declined', 'cancelled')
    ) INTO v_group_failed;
  ELSIF COALESCE(v_session.total_signers, 1) > 1 THEN
    IF v_session.signer_order IS NOT NULL
       AND v_session.signer_order < GREATEST(v_session.total_signers - 1, 0)
       AND v_session.status = 'signed' THEN
      RETURN;
    END IF;
    v_group_failed := v_session.status IN ('declined', 'cancelled');
  ELSE
    v_group_failed := v_session.status IN ('declined', 'cancelled');
  END IF;

  -- Decline / cancel path (current session or peer in group).
  IF v_group_failed
     OR v_session.status = 'declined'
     OR v_session.status = 'cancelled' THEN
    IF v_intent.decision_request_id IS NOT NULL
       AND data.commercial_decision_requests_enabled(v_intent.tenant_id) THEN
      v_signature := jsonb_strip_nulls(jsonb_build_object(
        'method', 'native',
        'provider', 'native',
        'provider_session_id', v_intent.session_id,
        'provider_submission_id', v_intent.submission_id,
        'signer_role', v_session.signer_role,
        'signer_name', v_session.signer_name,
        'reason', COALESCE(
          v_session.timestamps ->> 'decline_reason',
          CASE WHEN v_session.status = 'cancelled' THEN 'signer_cancelled' ELSE null END
        )
      ));
      v_apply := data.apply_commercial_decision_request(
        v_intent.decision_request_id,
        'declined',
        v_via,
        v_signature,
        v_intent.client_op_id,
        v_actor
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

    -- Strangler: decline pending agreement linked to quote, do not touch quote status.
    SELECT * INTO v_version
    FROM data.commercial_agreement_versions
    WHERE source_quote_id = v_intent.document_id
      AND tenant_id = v_intent.tenant_id
      AND status = 'pending_signature'
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;
    IF FOUND THEN
      PERFORM set_config('app.commercial_agreement_signing_unlocked', 'on', true);
      UPDATE data.commercial_agreement_versions
      SET status = 'declined', updated_at = now()
      WHERE id = v_version.id;
      PERFORM set_config('app.commercial_agreement_signing_unlocked', 'off', true);
      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, payload
      ) VALUES (
        v_version.tenant_id, v_version.agreement_id, 'declined', v_actor,
        jsonb_build_object(
          'version_id', v_version.id,
          'via', v_via,
          'reason', COALESCE(v_session.timestamps ->> 'decline_reason', 'signer_cancelled')
        )
      );
    END IF;
    UPDATE data.commercial_signing_intents
    SET applied_at = now()
    WHERE id = v_intent.id;
    RETURN;
  END IF;

  IF v_session.status <> 'signed' THEN
    RETURN;
  END IF;

  -- Accept path with decision request.
  IF v_intent.decision_request_id IS NOT NULL
     AND data.commercial_decision_requests_enabled(v_intent.tenant_id)
  THEN
    IF v_intent.action = 'accept' THEN
      PERFORM data.commercial_accept_office_gate_for_actor(
        v_intent.document_id,
        v_actor
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
        CASE WHEN v_req.agreement_version_id IS NOT NULL THEN true ELSE null END
    ));

    v_apply := data.apply_commercial_decision_request(
      v_intent.decision_request_id,
      v_outcome,
      v_via,
      v_signature,
      v_intent.client_op_id,
      v_actor
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

  -- Strangler without decision-requests.
  -- CS-D8: if this intent is for an agreement (pending version on quote), finalize
  -- the agreement — never apply_commercial_decision(accept) on the quote.
  SELECT * INTO v_version
  FROM data.commercial_agreement_versions
  WHERE source_quote_id = v_intent.document_id
    AND tenant_id = v_intent.tenant_id
    AND status = 'pending_signature'
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND AND v_intent.action = 'accept' THEN
    v_signed_doc := NULL;
    IF v_intent.submission_id IS NOT NULL THEN
      SELECT * INTO v_sub
      FROM data.signing_submissions
      WHERE id = v_intent.submission_id;
      IF FOUND AND v_sub.result_document_version_id IS NOT NULL THEN
        SELECT document_id INTO v_signed_doc
        FROM data.document_versions
        WHERE id = v_sub.result_document_version_id;
      END IF;
    END IF;
    v_signed_doc := COALESCE(
      v_signed_doc,
      v_version.signed_document_id,
      v_version.rendered_document_id
    );
    IF v_signed_doc IS NULL THEN
      RAISE EXCEPTION 'signed_document_required' USING ERRCODE = 'P0001';
    END IF;
    PERFORM data.finalize_commercial_agreement_version(
      v_version.id,
      v_signed_doc,
      v_actor,
      CURRENT_DATE
    );
    UPDATE data.commercial_signing_intents
    SET applied_at = now()
    WHERE id = v_intent.id;
    RETURN;
  END IF;

  -- Legacy quote / delivery_note path (signed_quote formalization).
  IF v_intent.action = 'accept' THEN
    PERFORM data.commercial_accept_office_gate_for_actor(
      v_intent.document_id,
      v_actor
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
    v_actor
  );

  UPDATE data.commercial_signing_intents
  SET applied_at = now()
  WHERE id = v_intent.id;
END;
$$;

COMMENT ON FUNCTION data.apply_commercial_signing_intent_for_session(uuid) IS
  'Applies commercial signing intent after native terminal state. Multi-signer: wait for all; peer decline/cancel → decline. Agreement strangler finalizes version without accepting quote (CS-D6/D8).';
