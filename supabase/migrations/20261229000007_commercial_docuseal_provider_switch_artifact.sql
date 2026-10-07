-- CF-28 F8 tall 4: provider switch on open request + observable signed-artifact status.

-- ---------------------------------------------------------------------------
-- Supersede prior bridge submissions for a request (one active provider attempt)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.supersede_commercial_bridge_submissions(
  p_tenant_id uuid,
  p_request_id uuid,
  p_keep_submission_id uuid DEFAULT NULL
)
RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  WITH upd AS (
    UPDATE data.signing_submissions ss
    SET
      status = CASE
        WHEN ss.status IN ('completed', 'declined', 'expired', 'cancelled', 'error')
          THEN ss.status
        ELSE 'cancelled'
      END,
      metadata = COALESCE(ss.metadata, '{}'::jsonb) || jsonb_build_object(
        'superseded_by_switch', true,
        'superseded_at', to_jsonb(now())
      ),
      updated_at = now()
    WHERE ss.tenant_id = p_tenant_id
      AND ss.metadata->>'decision_request_id' = p_request_id::text
      AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
      AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
      AND (p_keep_submission_id IS NULL OR ss.id IS DISTINCT FROM p_keep_submission_id)
    RETURNING ss.id
  )
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_ids FROM upd;

  RETURN v_ids;
END;
$$;

REVOKE ALL ON FUNCTION data.supersede_commercial_bridge_submissions(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.supersede_commercial_bridge_submissions(uuid, uuid, uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Prepare resend / provider switch (revoke tokens, cancel prior intents)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.prepare_commercial_decision_signing_attempt(
  p_request_id uuid,
  p_provider text,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_req data.commercial_decision_requests%ROWTYPE;
  v_op uuid := COALESCE(p_client_op_id, gen_random_uuid());
  v_from text;
  v_to text;
  v_superseded uuid[];
  v_sessions int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_request_id IS NULL OR p_provider IS NULL OR p_provider NOT IN ('native', 'docuseal') THEN
    RAISE EXCEPTION 'invalid_provider_switch' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = p_request_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_req.tenant_id::text) THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_req.status <> 'open' THEN
    RAISE EXCEPTION 'decision_request_not_open:%', v_req.status USING ERRCODE = 'P0001';
  END IF;

  v_from := COALESCE(v_req.active_provider, 'native');
  v_to := p_provider;

  -- Revoke prior delivery tokens (new delivery creates a fresh /sign link).
  UPDATE data.commercial_decision_access_tokens
  SET status = 'revoked', revoked_at = now()
  WHERE request_id = v_req.id AND status = 'active';

  UPDATE data.commercial_decision_deliveries
  SET status = 'revoked'
  WHERE request_id = v_req.id AND status IN ('prepared', 'queued');

  -- Cancel open native sessions bound to this request.
  UPDATE data.document_signing_sessions s
  SET status = 'cancelled', updated_at = now()
  FROM data.commercial_signing_intents i
  WHERE i.decision_request_id = v_req.id
    AND i.session_id = s.id
    AND s.tenant_id = v_req.tenant_id
    AND s.status NOT IN ('signed', 'cancelled');
  GET DIAGNOSTICS v_sessions = ROW_COUNT;

  v_superseded := data.supersede_commercial_bridge_submissions(
    v_req.tenant_id,
    v_req.id,
    NULL
  );

  UPDATE data.commercial_decision_requests
  SET active_provider = v_to,
      updated_at = now()
  WHERE id = v_req.id;

  IF v_from IS DISTINCT FROM v_to THEN
    INSERT INTO data.commercial_decision_events (
      tenant_id, request_id, event_type, via, actor_id, content_hash, client_op_id, evidence
    ) VALUES (
      v_req.tenant_id, v_req.id, 'provider_changed', 'office', v_uid, v_req.content_hash, v_op,
      jsonb_build_object(
        'from', v_from,
        'to', v_to,
        'superseded_submission_ids', to_jsonb(v_superseded),
        'cancelled_native_sessions', v_sessions
      )
    );
  ELSE
    INSERT INTO data.commercial_decision_events (
      tenant_id, request_id, event_type, via, actor_id, content_hash, client_op_id, evidence
    ) VALUES (
      v_req.tenant_id, v_req.id, 'signing_attempt_rotated', 'office', v_uid, v_req.content_hash, v_op,
      jsonb_build_object(
        'provider', v_to,
        'superseded_submission_ids', to_jsonb(v_superseded),
        'cancelled_native_sessions', v_sessions
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req.id,
    'from_provider', v_from,
    'to_provider', v_to,
    'provider_changed', (v_from IS DISTINCT FROM v_to),
    'superseded_submission_ids', to_jsonb(v_superseded)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_commercial_decision_signing_attempt(uuid, text, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_commercial_decision_signing_attempt(uuid, text, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Bind: keep a single active bridge; force active_provider=docuseal
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.bind_commercial_decision_docuseal_submission(
  p_request_id uuid,
  p_submission_id uuid,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_req data.commercial_decision_requests%ROWTYPE;
  v_sub data.signing_submissions%ROWTYPE;
  v_op uuid := COALESCE(p_client_op_id, gen_random_uuid());
  v_superseded uuid[];
BEGIN
  IF p_request_id IS NULL OR p_submission_id IS NULL THEN
    RAISE EXCEPTION 'invalid_bind_args' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = p_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_uid IS NOT NULL AND NOT (data.jwt_user_tenants() ? v_req.tenant_id::text) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_req.status <> 'open' THEN
    RAISE EXCEPTION 'decision_request_not_open' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_sub
  FROM data.signing_submissions
  WHERE id = p_submission_id
  FOR UPDATE;
  IF NOT FOUND OR v_sub.tenant_id IS DISTINCT FROM v_req.tenant_id THEN
    RAISE EXCEPTION 'submission_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_superseded := data.supersede_commercial_bridge_submissions(
    v_req.tenant_id,
    v_req.id,
    v_sub.id
  );

  UPDATE data.signing_submissions
  SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
        'decision_request_id', v_req.id::text,
        'commercial_bridge', true
      ) - 'superseded_by_switch' - 'superseded_at',
      updated_at = now()
  WHERE id = v_sub.id;

  UPDATE data.commercial_decision_requests
  SET active_provider = 'docuseal',
      updated_at = now()
  WHERE id = v_req.id;

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, via, actor_id, content_hash, client_op_id, evidence
  ) VALUES (
    v_req.tenant_id, v_req.id, 'provider_bound', 'office', v_uid, v_req.content_hash, v_op,
    jsonb_build_object(
      'provider', 'docuseal',
      'submission_id', v_sub.id,
      'external_id', v_sub.external_id,
      'superseded_submission_ids', to_jsonb(v_superseded)
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req.id,
    'submission_id', v_sub.id,
    'active_provider', 'docuseal'
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Apply: ignore superseded bridge submissions
-- ---------------------------------------------------------------------------
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

  v_evidence := jsonb_strip_nulls(jsonb_build_object(
    'method', 'docuseal',
    'provider', 'docuseal',
    'provider_submission_id', v_sub.id,
    'docuseal_submission_id', v_sub.docuseal_submission_id,
    'signer_name', v_sub.signers->0->>'name',
    'signer_email', v_sub.signers->0->>'email',
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

-- Native register: force active_provider=native when linking (provider switch)
CREATE OR REPLACE FUNCTION api.register_commercial_signing_intent(
  p_document_id uuid,
  p_session_id uuid,
  p_action text,
  p_client_op_id uuid,
  p_submission_id uuid DEFAULT NULL,
  p_decision_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_id uuid;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_source_quote uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_action NOT IN ('accept', 'reject', 'delivery') THEN
    RAISE EXCEPTION 'invalid_commercial_signing_action' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF p_action = 'delivery' AND v_doc.doc_type <> 'delivery_note' THEN
    RAISE EXCEPTION 'document_not_delivery_note' USING ERRCODE = 'P0001';
  END IF;
  IF p_action IN ('accept', 'reject') AND v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'document_not_quote' USING ERRCODE = 'P0001';
  END IF;

  IF p_decision_request_id IS NOT NULL THEN
    SELECT * INTO v_req
    FROM data.commercial_decision_requests
    WHERE id = p_decision_request_id;
    IF NOT FOUND
       OR v_req.tenant_id IS DISTINCT FROM v_doc.tenant_id
       OR v_req.status <> 'open'
    THEN
      RAISE EXCEPTION 'decision_request_invalid' USING ERRCODE = 'P0001';
    END IF;
    IF v_req.commercial_document_id IS NOT NULL
       AND v_req.commercial_document_id IS DISTINCT FROM p_document_id THEN
      RAISE EXCEPTION 'decision_request_invalid' USING ERRCODE = 'P0001';
    END IF;
    IF v_req.agreement_version_id IS NOT NULL THEN
      SELECT v.source_quote_id INTO v_source_quote
      FROM data.commercial_agreement_versions v
      WHERE v.id = v_req.agreement_version_id;
      IF v_source_quote IS DISTINCT FROM p_document_id THEN
        RAISE EXCEPTION 'decision_request_invalid' USING ERRCODE = 'P0001';
      END IF;
      IF v_doc.status NOT IN ('issued', 'accepted') THEN
        RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
      END IF;
    ELSIF v_doc.status <> 'issued' THEN
      RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_doc.status <> 'issued' THEN
    RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;

  IF p_action = 'accept' THEN
    PERFORM data.commercial_accept_office_gate(p_document_id);
  END IF;

  SELECT id INTO v_id
  FROM data.commercial_signing_intents
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_id IS NOT NULL THEN
    IF p_decision_request_id IS NOT NULL THEN
      UPDATE data.commercial_signing_intents
      SET decision_request_id = COALESCE(decision_request_id, p_decision_request_id)
      WHERE id = v_id AND decision_request_id IS NULL;
      UPDATE data.commercial_decision_requests
      SET active_provider = 'native', updated_at = now()
      WHERE id = p_decision_request_id;
    END IF;
    RETURN v_id;
  END IF;

  SELECT id INTO v_id
  FROM data.commercial_signing_intents
  WHERE session_id = p_session_id;
  IF v_id IS NOT NULL THEN
    IF p_decision_request_id IS NOT NULL THEN
      UPDATE data.commercial_signing_intents
      SET decision_request_id = COALESCE(decision_request_id, p_decision_request_id)
      WHERE id = v_id AND decision_request_id IS NULL;
      UPDATE data.commercial_decision_requests
      SET active_provider = 'native', updated_at = now()
      WHERE id = p_decision_request_id;
    END IF;
    RETURN v_id;
  END IF;

  INSERT INTO data.commercial_signing_intents (
    tenant_id, document_id, submission_id, session_id, action, client_op_id,
    created_by, decision_request_id
  ) VALUES (
    v_doc.tenant_id, p_document_id, p_submission_id, p_session_id, p_action, p_client_op_id,
    v_uid, p_decision_request_id
  )
  RETURNING id INTO v_id;

  IF p_decision_request_id IS NOT NULL THEN
    UPDATE data.commercial_decision_requests
    SET active_provider = 'native', updated_at = now()
    WHERE id = p_decision_request_id;
  END IF;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Artifact status (metadata + commercial events) for reconciliation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.record_signing_submission_artifact_status(
  p_submission_id uuid,
  p_status text,
  p_error text DEFAULT NULL,
  p_signed_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sub data.signing_submissions%ROWTYPE;
  v_request_id uuid;
  v_meta jsonb;
  v_event text;
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('pending', 'attached', 'failed') THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_status');
  END IF;

  SELECT * INTO v_sub
  FROM data.signing_submissions
  WHERE id = p_submission_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'submission_not_found');
  END IF;

  v_meta := COALESCE(v_sub.metadata, '{}'::jsonb) || jsonb_build_object(
    'artifact_status', p_status,
    'artifact_updated_at', to_jsonb(now())
  );
  IF p_error IS NOT NULL THEN
    v_meta := v_meta || jsonb_build_object('artifact_error', left(p_error, 500));
  ELSIF p_status = 'attached' THEN
    v_meta := v_meta - 'artifact_error';
  END IF;
  IF p_signed_url IS NOT NULL AND NULLIF(btrim(p_signed_url), '') IS NOT NULL THEN
    v_meta := v_meta || jsonb_build_object(
      'artifact_signed_url', left(btrim(p_signed_url), 2000)
    );
  END IF;

  UPDATE data.signing_submissions
  SET metadata = v_meta, updated_at = now()
  WHERE id = v_sub.id;

  IF COALESCE((v_meta->>'commercial_bridge')::boolean, false) THEN
    BEGIN
      v_request_id := NULLIF(btrim(COALESCE(v_meta->>'decision_request_id', '')), '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_request_id := NULL;
    END;

    IF v_request_id IS NOT NULL THEN
      v_event := CASE p_status
        WHEN 'pending' THEN 'artifact_pending'
        WHEN 'attached' THEN 'artifact_attached'
        ELSE 'artifact_failed'
      END;
      INSERT INTO data.commercial_decision_events (
        tenant_id, request_id, event_type, via, content_hash, evidence
      )
      SELECT
        r.tenant_id,
        r.id,
        v_event,
        'provider',
        r.content_hash,
        jsonb_strip_nulls(jsonb_build_object(
          'submission_id', v_sub.id,
          'artifact_status', p_status,
          'error', CASE WHEN p_status = 'failed' THEN left(COALESCE(p_error, ''), 500) ELSE NULL END
        ))
      FROM data.commercial_decision_requests r
      WHERE r.id = v_request_id
        AND r.tenant_id = v_sub.tenant_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'submission_id', v_sub.id,
    'artifact_status', p_status
  );
END;
$$;

REVOKE ALL ON FUNCTION api.record_signing_submission_artifact_status(uuid, text, text, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_signing_submission_artifact_status(uuid, text, text, text)
  TO service_role;

CREATE OR REPLACE FUNCTION api.list_signing_submissions_needing_artifact_reconcile(
  p_limit integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit int := GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.updated_at ASC)
    FROM (
      SELECT
        ss.id AS submission_id,
        ss.tenant_id,
        ss.docuseal_submission_id,
        ss.metadata->>'decision_request_id' AS decision_request_id,
        ss.metadata->>'artifact_status' AS artifact_status,
        ss.metadata->>'artifact_signed_url' AS artifact_signed_url,
        ss.metadata->>'artifact_error' AS artifact_error,
        ss.updated_at
      FROM data.signing_submissions ss
      WHERE ss.status = 'completed'
        AND ss.result_document_version_id IS NULL
        AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
        AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
        AND COALESCE(ss.metadata->>'artifact_status', 'failed') IN ('pending', 'failed')
      ORDER BY ss.updated_at ASC
      LIMIT v_limit
    ) x
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.list_signing_submissions_needing_artifact_reconcile(integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_signing_submissions_needing_artifact_reconcile(integer)
  TO service_role;

-- Tenant-visible artifact status for a commercial document's latest bridge submission
CREATE OR REPLACE FUNCTION api.get_commercial_document_signed_artifact_status(
  p_document_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_sub data.signing_submissions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.commercial_document_id = p_document_id
    AND r.tenant_id = v_doc.tenant_id
    AND r.active_provider = 'docuseal'
  ORDER BY r.created_at DESC
  LIMIT 1;

  IF v_req.id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_sub
  FROM data.signing_submissions ss
  WHERE ss.tenant_id = v_req.tenant_id
    AND ss.metadata->>'decision_request_id' = v_req.id::text
    AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
    AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
  ORDER BY ss.created_at DESC
  LIMIT 1;

  IF v_sub.id IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'request_id', v_req.id,
    'request_status', v_req.status,
    'submission_id', v_sub.id,
    'submission_status', v_sub.status,
    'artifact_status', COALESCE(
      v_sub.metadata->>'artifact_status',
      CASE WHEN v_sub.result_document_version_id IS NOT NULL THEN 'attached' ELSE NULL END
    ),
    'artifact_error', v_sub.metadata->>'artifact_error',
    'has_result_pdf', (v_sub.result_document_version_id IS NOT NULL)
  ));
END;
$$;

REVOKE ALL ON FUNCTION api.get_commercial_document_signed_artifact_status(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_commercial_document_signed_artifact_status(uuid)
  TO authenticated, service_role;

-- Cron dispatcher → Edge reconcile (graceful if pg_cron/pg_net missing)
CREATE OR REPLACE FUNCTION data.invoke_docuseal_artifact_reconcile(p_limit integer DEFAULT 20)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_supabase_url text;
  v_service_key text;
  v_request_id bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets WHERE name = 'app_supabase_url' LIMIT 1;
  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'app_service_role_key' LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RETURN -1;
  END IF;

  BEGIN
    SELECT extensions.http_post(
      url := v_supabase_url || '/functions/v1/reconcile-docuseal-signed-artifacts',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body := jsonb_build_object('limit', COALESCE(p_limit, 20)),
      timeout_milliseconds := 60000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'invoke_docuseal_artifact_reconcile failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_docuseal_artifact_reconcile(integer) FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('reconcile-docuseal-signed-artifacts')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'reconcile-docuseal-signed-artifacts'
    );
    PERFORM cron.schedule(
      'reconcile-docuseal-signed-artifacts',
      '*/10 * * * *',
      'SELECT data.invoke_docuseal_artifact_reconcile(20)'
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
