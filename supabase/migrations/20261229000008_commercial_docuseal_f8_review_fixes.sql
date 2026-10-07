-- CF-28 F8 review fixes: P0 CS-D58 artifact URL, reconcile health, P1/P2 SQL.

-- ---------------------------------------------------------------------------
-- A2: internal retry URL column (never on tenant-readable metadata)
-- ---------------------------------------------------------------------------
ALTER TABLE data.signing_submissions
  ADD COLUMN IF NOT EXISTS artifact_retry_url text;

COMMENT ON COLUMN data.signing_submissions.artifact_retry_url IS
  'DocuSeal signed PDF URL for reconcile only (service_role). CS-D58: not exposed on api.signing_submissions.';

-- Migrate any leaked metadata URLs then strip them
UPDATE data.signing_submissions
SET
  artifact_retry_url = COALESCE(
    artifact_retry_url,
    NULLIF(btrim(metadata->>'artifact_signed_url'), '')
  ),
  metadata = (COALESCE(metadata, '{}'::jsonb) - 'artifact_signed_url'),
  updated_at = now()
WHERE metadata ? 'artifact_signed_url';

-- Redact artifact_signed_url from tenant-facing view metadata
DROP VIEW IF EXISTS api.signing_submissions CASCADE;

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
    (
      SELECT COALESCE(
        jsonb_agg(
          CASE
            WHEN jsonb_typeof(elem) = 'object' THEN (elem - 'signing_url')
            ELSE elem
          END
        ),
        '[]'::jsonb
      )
      FROM jsonb_array_elements(COALESCE(ss.signers, '[]'::jsonb)) AS elem
    ) AS signers,
    NULL::text AS docuseal_signing_url,
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
    (COALESCE(ss.metadata, '{}'::jsonb) - 'artifact_signed_url') AS metadata,
    ss.signing_provider,
    ss.native_group_id,
    ss.created_at,
    ss.updated_at
  FROM data.signing_submissions ss
  LEFT JOIN data.document_versions rv ON rv.id = ss.result_document_version_id;

GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO service_role;

CREATE OR REPLACE FUNCTION data.trg_api_signing_submissions_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_keep data.signing_submissions%ROWTYPE;
BEGIN
  SELECT * INTO v_keep FROM data.signing_submissions WHERE id = OLD.id;

  UPDATE data.signing_submissions
  SET
    status                     = NEW.status,
    status_reason              = NEW.status_reason,
    error_message              = NEW.error_message,
    last_event_at              = NEW.last_event_at,
    updated_at                 = NEW.updated_at,
    docuseal_submission_id     = NEW.docuseal_submission_id,
    docuseal_signing_url       = COALESCE(NEW.docuseal_signing_url, v_keep.docuseal_signing_url),
    signers                    = CASE
                                   WHEN NEW.signers IS NULL THEN v_keep.signers
                                   WHEN NEW.signers = '[]'::jsonb THEN NEW.signers
                                   WHEN NOT EXISTS (
                                     SELECT 1
                                     FROM jsonb_array_elements(NEW.signers) e
                                     WHERE e ? 'signing_url' AND NULLIF(e->>'signing_url', '') IS NOT NULL
                                   ) AND EXISTS (
                                     SELECT 1
                                     FROM jsonb_array_elements(COALESCE(v_keep.signers, '[]'::jsonb)) e
                                     WHERE e ? 'signing_url' AND NULLIF(e->>'signing_url', '') IS NOT NULL
                                   ) THEN v_keep.signers
                                   ELSE NEW.signers
                                 END,
    result_document_version_id = NEW.result_document_version_id,
    staging_storage_path       = NEW.staging_storage_path,
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
    metadata                   = (COALESCE(NEW.metadata, '{}'::jsonb) - 'artifact_signed_url'),
    signing_provider           = NEW.signing_provider,
    native_group_id            = NEW.native_group_id
  WHERE id = NEW.id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_api_signing_submissions_update ON api.signing_submissions;
CREATE TRIGGER trg_api_signing_submissions_update
  INSTEAD OF UPDATE ON api.signing_submissions
  FOR EACH ROW EXECUTE FUNCTION data.trg_api_signing_submissions_update();

DROP VIEW IF EXISTS api.signing_submissions_internal CASCADE;
CREATE VIEW api.signing_submissions_internal WITH (security_invoker = true) AS
  SELECT
    ss.id,
    ss.tenant_id,
    ss.status,
    ss.signers,
    ss.docuseal_signing_url,
    ss.docuseal_submission_id,
    ss.external_id,
    ss.notification_mode,
    ss.signing_provider,
    ss.metadata,
    ss.artifact_retry_url,
    ss.result_document_version_id,
    ss.created_at,
    ss.updated_at
  FROM data.signing_submissions ss;

REVOKE ALL ON api.signing_submissions_internal FROM PUBLIC;
REVOKE ALL ON api.signing_submissions_internal FROM authenticated;
GRANT SELECT ON api.signing_submissions_internal TO service_role;

-- ---------------------------------------------------------------------------
-- A1: job run health for reconcile
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.signing_ops_job_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_name text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  ok boolean,
  listed integer,
  attempted integer,
  attached integer,
  skipped integer,
  error_text text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_signing_ops_job_runs_job_started
  ON data.signing_ops_job_runs (job_name, started_at DESC);

ALTER TABLE data.signing_ops_job_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON data.signing_ops_job_runs FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON data.signing_ops_job_runs TO service_role;

CREATE OR REPLACE FUNCTION api.record_signing_ops_job_run(
  p_job_name text,
  p_ok boolean,
  p_listed integer DEFAULT NULL,
  p_attempted integer DEFAULT NULL,
  p_attached integer DEFAULT NULL,
  p_skipped integer DEFAULT NULL,
  p_error text DEFAULT NULL,
  p_started_at timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NULLIF(btrim(COALESCE(p_job_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'invalid_job_name' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.signing_ops_job_runs (
    job_name, started_at, finished_at, ok, listed, attempted, attached, skipped, error_text
  ) VALUES (
    left(btrim(p_job_name), 128),
    COALESCE(p_started_at, now()),
    now(),
    p_ok,
    p_listed,
    p_attempted,
    p_attached,
    p_skipped,
    left(NULLIF(btrim(COALESCE(p_error, '')), ''), 1000)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.record_signing_ops_job_run(text, boolean, integer, integer, integer, integer, text, timestamptz)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_signing_ops_job_run(text, boolean, integer, integer, integer, integer, text, timestamptz)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Artifact status RPC: column + no spam events + no metadata URL
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
  v_prev text;
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

  v_prev := v_sub.metadata->>'artifact_status';
  v_meta := (COALESCE(v_sub.metadata, '{}'::jsonb) - 'artifact_signed_url')
    || jsonb_build_object(
      'artifact_status', p_status,
      'artifact_updated_at', to_jsonb(now())
    );
  IF p_error IS NOT NULL THEN
    v_meta := v_meta || jsonb_build_object('artifact_error', left(p_error, 500));
  ELSIF p_status = 'attached' THEN
    v_meta := v_meta - 'artifact_error';
  END IF;

  UPDATE data.signing_submissions
  SET
    metadata = v_meta,
    artifact_retry_url = CASE
      WHEN p_signed_url IS NOT NULL AND NULLIF(btrim(p_signed_url), '') IS NOT NULL
        THEN btrim(p_signed_url)
      ELSE artifact_retry_url
    END,
    updated_at = now()
  WHERE id = v_sub.id;

  IF COALESCE((v_meta->>'commercial_bridge')::boolean, false)
     AND v_prev IS DISTINCT FROM p_status
  THEN
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
        ss.artifact_retry_url AS artifact_signed_url,
        ss.metadata->>'artifact_error' AS artifact_error,
        ss.updated_at
      FROM data.signing_submissions ss
      WHERE ss.status = 'completed'
        AND ss.result_document_version_id IS NULL
        AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
        AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
        AND COALESCE(ss.metadata->>'artifact_status', 'failed') IN ('pending', 'failed')
        AND NULLIF(btrim(COALESCE(ss.artifact_retry_url, '')), '') IS NOT NULL
      ORDER BY ss.updated_at ASC
      LIMIT v_limit
    ) x
  ), '[]'::jsonb);
END;
$$;

-- B10: artifact status after provider switch
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

  -- Latest request that still has a non-superseded commercial bridge submission
  SELECT r.* INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.commercial_document_id = p_document_id
    AND r.tenant_id = v_doc.tenant_id
    AND EXISTS (
      SELECT 1
      FROM data.signing_submissions ss
      WHERE ss.tenant_id = r.tenant_id
        AND ss.metadata->>'decision_request_id' = r.id::text
        AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
        AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
    )
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

-- ---------------------------------------------------------------------------
-- B3: abort prepare (compensate after failed router)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.abort_commercial_decision_signing_prepare(
  p_request_id uuid,
  p_client_op_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_req data.commercial_decision_requests%ROWTYPE;
  v_ev data.commercial_decision_events%ROWTYPE;
  v_from text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_request_id IS NULL OR p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'invalid_abort_args' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = p_request_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_req.tenant_id::text) THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_req.status <> 'open' THEN
    RETURN jsonb_build_object('ok', true, 'aborted', false, 'reason', 'not_open');
  END IF;

  SELECT * INTO v_ev
  FROM data.commercial_decision_events e
  WHERE e.request_id = v_req.id
    AND e.client_op_id = p_client_op_id
    AND e.event_type IN ('provider_changed', 'signing_attempt_rotated')
  ORDER BY e.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'aborted', false, 'reason', 'no_prepare_event');
  END IF;

  v_from := COALESCE(NULLIF(btrim(v_ev.evidence->>'from'), ''), 'native');

  UPDATE data.commercial_decision_requests
  SET active_provider = v_from,
      updated_at = now()
  WHERE id = v_req.id;

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, via, actor_id, content_hash, client_op_id, evidence
  ) VALUES (
    v_req.tenant_id, v_req.id, 'signing_prepare_aborted', 'office', v_uid, v_req.content_hash, p_client_op_id,
    jsonb_build_object(
      'restored_provider', v_from,
      'from_event', v_ev.event_type
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'aborted', true,
    'restored_provider', v_from
  );
END;
$$;

REVOKE ALL ON FUNCTION api.abort_commercial_decision_signing_prepare(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.abort_commercial_decision_signing_prepare(uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- B4: register native only sets active_provider when not already docuseal
--     (unless prepare already set native)
-- ---------------------------------------------------------------------------
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
      -- Only set native if prepare already chose native (or unset)
      UPDATE data.commercial_decision_requests
      SET active_provider = 'native', updated_at = now()
      WHERE id = p_decision_request_id
        AND COALESCE(active_provider, 'native') = 'native';
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
      WHERE id = p_decision_request_id
        AND COALESCE(active_provider, 'native') = 'native';
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
    WHERE id = p_decision_request_id
      AND COALESCE(active_provider, 'native') = 'native';
  END IF;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- B11: decline portal — no SQLERRM to client
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.apply_customer_portal_pending_decision(
  p_session_token_hash bytea,
  p_request_id uuid,
  p_outcome text,
  p_evidence jsonb DEFAULT '{}'::jsonb,
  p_client_op_id uuid DEFAULT NULL,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_audit_request_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sess data.customer_portal_grant_sessions%ROWTYPE;
  v_grant data.customer_access_grants%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_ent jsonb;
  v_mode text;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_evidence jsonb := COALESCE(p_evidence, '{}'::jsonb);
  v_op uuid := COALESCE(p_client_op_id, gen_random_uuid());
  v_principal_name text;
  v_actor_name text;
  v_actor_role text;
  v_result jsonb;
  v_audit_rid text;
BEGIN
  IF p_session_token_hash IS NULL OR length(p_session_token_hash) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;
  IF p_request_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_target');
  END IF;
  IF p_outcome IS DISTINCT FROM 'declined' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'outcome_not_supported');
  END IF;

  v_audit_rid := left(COALESCE(p_audit_request_id, gen_random_uuid()::text), 128);

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;

  SELECT * INTO v_sess
  FROM data.customer_portal_grant_sessions
  WHERE session_token_hash = p_session_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
  END IF;

  SELECT * INTO v_grant FROM data.customer_access_grants WHERE id = v_sess.grant_id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_sess.tenant_id);

  IF v_sess.revoked_at IS NOT NULL
     OR v_sess.expires_at <= now()
     OR v_grant.id IS NULL
     OR v_grant.revoked_at IS NOT NULL
     OR NOT v_platform.enabled
     OR NOT v_tstate.enabled
     OR v_platform.max_mode <> 'portal'
     OR v_tstate.existing_access_policy <> 'allow'
     OR v_sess.session_version IS DISTINCT FROM v_grant.session_version
     OR v_sess.security_version_tenant IS DISTINCT FROM v_tstate.security_version
     OR v_sess.security_version_platform IS DISTINCT FROM v_platform.security_version
  THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_sess.grant_id, v_sess.id, 'commercial_denied', 401,
      'session_invalid', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  v_ent := data.resolve_portal_entitlements(v_sess.tenant_id);
  v_mode := COALESCE(
    NULLIF(btrim(v_ent->'customer_portal'->>'mode_effective'), ''),
    NULLIF(btrim(v_ent->>'mode_effective'), ''),
    ''
  );
  IF v_mode IS DISTINCT FROM 'portal' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  IF NOT data.commercial_decision_requests_enabled(v_sess.tenant_id) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  UPDATE data.customer_portal_grant_sessions
  SET last_seen_at = now() WHERE id = v_sess.id;
  UPDATE data.customer_access_grants
  SET last_seen_at = now() WHERE id = v_grant.id;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.id = p_request_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_req.tenant_id IS DISTINCT FROM v_sess.tenant_id
     OR v_req.client_account_contact_id IS DISTINCT FROM v_grant.client_account_contact_id
  THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  IF v_req.status IS DISTINCT FROM 'open' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'applied', false,
      'already_decided', true,
      'status', v_req.status,
      'request_id', v_req.id,
      'decided_via', v_req.decided_via,
      'decided_at', v_req.decided_at
    );
  END IF;

  IF NOT data.customer_portal_pending_decision_visible(
    v_sess.tenant_id,
    v_grant.client_account_contact_id,
    v_req,
    v_tstate.commercial_quotes_agreements_enabled,
    v_tstate.commercial_delivery_notes_enabled
  ) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  IF COALESCE(v_req.active_provider, 'native') NOT IN ('native', 'docuseal') THEN
    RETURN jsonb_build_object('ok', false, 'code', 'provider_not_supported');
  END IF;

  SELECT NULLIF(btrim(COALESCE(c.display_name, c.legal_name,
    NULLIF(btrim(CONCAT_WS(' ', c.given_name, c.family_name)), ''),
    c.email)), '')
    INTO v_principal_name
  FROM data.contacts c
  WHERE c.id = v_grant.principal_contact_id
    AND c.tenant_id = v_sess.tenant_id;

  v_actor_name := NULLIF(btrim(COALESCE(v_evidence->>'actor_name', '')), '');
  v_actor_role := NULLIF(btrim(COALESCE(v_evidence->>'actor_role', '')), '');

  IF v_grant.principal_kind = 'shared_mailbox' THEN
    IF v_actor_name IS NULL OR char_length(v_actor_name) < 2 THEN
      RETURN jsonb_build_object('ok', false, 'code', 'actor_name_required');
    END IF;
    IF v_actor_role IS NULL OR char_length(v_actor_role) < 2 THEN
      RETURN jsonb_build_object('ok', false, 'code', 'actor_role_required');
    END IF;
    v_evidence := v_evidence || jsonb_build_object(
      'signer_name', v_actor_name,
      'signer_role', v_actor_role,
      'principal_kind', 'shared_mailbox',
      'principal_contact_id', v_grant.principal_contact_id,
      'acting_for_account_contact_id', v_grant.client_account_contact_id
    );
  ELSE
    v_evidence := v_evidence || jsonb_build_object(
      'signer_name', COALESCE(v_principal_name, 'client'),
      'signer_role', COALESCE(v_actor_role, v_evidence->>'signer_role'),
      'principal_kind', 'named_person',
      'principal_contact_id', v_grant.principal_contact_id
    );
  END IF;

  v_evidence := v_evidence || jsonb_build_object(
    'grant_id', v_grant.id,
    'session_id', v_sess.id,
    'ip_address', p_ip_address,
    'user_agent', left(COALESCE(p_user_agent, ''), 512),
    'via', 'portal'
  );

  BEGIN
    v_result := data.apply_commercial_decision_request(
      v_req.id,
      'declined',
      'portal',
      v_evidence,
      v_op,
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'apply_customer_portal_pending_decision failed: %', SQLERRM;
    RETURN jsonb_build_object('ok', false, 'code', 'apply_failed');
  END;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, grant_id, session_id, action, http_status,
    ip_address, user_agent, request_id
  ) VALUES (
    v_sess.tenant_id, v_grant.id, v_sess.id, 'commercial_pending', 200,
    p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
  );

  RETURN jsonb_build_object(
    'ok', true,
    'applied', true,
    'already_decided', false,
    'status', 'declined',
    'request_id', v_req.id,
    'result', v_result
  );
END;
$$;

-- List superseded bridge submissions needing DocuSeal cancel (service)
CREATE OR REPLACE FUNCTION api.list_superseded_commercial_bridge_submissions(
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_request_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'submission_id', ss.id,
      'tenant_id', ss.tenant_id,
      'docuseal_submission_id', ss.docuseal_submission_id
    ))
    FROM data.signing_submissions ss
    WHERE ss.metadata->>'decision_request_id' = p_request_id::text
      AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
      AND COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
      AND ss.docuseal_submission_id IS NOT NULL
      AND NOT COALESCE((ss.metadata->>'docuseal_cancel_attempted')::boolean, false)
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.list_superseded_commercial_bridge_submissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_superseded_commercial_bridge_submissions(uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION api.mark_commercial_bridge_docuseal_cancel_attempted(
  p_submission_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE data.signing_submissions
  SET metadata = COALESCE(metadata, '{}'::jsonb)
    || jsonb_build_object('docuseal_cancel_attempted', true),
      updated_at = now()
  WHERE id = p_submission_id;
END;
$$;

REVOKE ALL ON FUNCTION api.mark_commercial_bridge_docuseal_cancel_attempted(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.mark_commercial_bridge_docuseal_cancel_attempted(uuid)
  TO service_role;

-- Supersede all bridges for a request (portal/office decline → cancel DocuSeal)
CREATE OR REPLACE FUNCTION api.supersede_commercial_bridge_submissions_for_request(
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_req data.commercial_decision_requests%ROWTYPE;
  v_ids uuid[];
BEGIN
  IF p_request_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = p_request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  v_ids := data.supersede_commercial_bridge_submissions(
    v_req.tenant_id,
    v_req.id,
    NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'superseded_submission_ids', to_jsonb(v_ids)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.supersede_commercial_bridge_submissions_for_request(uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.supersede_commercial_bridge_submissions_for_request(uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- C3: at most one active (non-superseded, non-terminal) commercial bridge
-- ---------------------------------------------------------------------------
-- Collapse duplicates before unique index (keep newest updated_at).
WITH ranked AS (
  SELECT
    ss.id,
    row_number() OVER (
      PARTITION BY ss.tenant_id, ss.metadata->>'decision_request_id'
      ORDER BY ss.updated_at DESC NULLS LAST, ss.created_at DESC NULLS LAST
    ) AS rn
  FROM data.signing_submissions ss
  WHERE COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
    AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
    AND ss.status NOT IN ('completed', 'declined', 'expired', 'cancelled', 'error')
    AND NULLIF(btrim(COALESCE(ss.metadata->>'decision_request_id', '')), '') IS NOT NULL
)
UPDATE data.signing_submissions ss
SET
  status = CASE
    WHEN ss.status IN ('completed', 'declined', 'expired', 'cancelled', 'error')
      THEN ss.status
    ELSE 'cancelled'
  END,
  metadata = COALESCE(ss.metadata, '{}'::jsonb) || jsonb_build_object(
    'superseded_by_switch', true,
    'superseded_at', to_jsonb(now()),
    'supersede_reason', 'unique_active_bridge_cleanup'
  ),
  updated_at = now()
FROM ranked r
WHERE ss.id = r.id
  AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uq_signing_submissions_one_active_commercial_bridge
  ON data.signing_submissions (
    tenant_id,
    (metadata->>'decision_request_id')
  )
  WHERE COALESCE((metadata->>'commercial_bridge')::boolean, false)
    AND NOT COALESCE((metadata->>'superseded_by_switch')::boolean, false)
    AND status NOT IN ('completed', 'declined', 'expired', 'cancelled', 'error')
    AND NULLIF(btrim(COALESCE(metadata->>'decision_request_id', '')), '') IS NOT NULL;

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
  v_active_count int;
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

  SELECT count(*)::int INTO v_active_count
  FROM data.signing_submissions ss
  WHERE ss.tenant_id = v_req.tenant_id
    AND ss.metadata->>'decision_request_id' = v_req.id::text
    AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
    AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
    AND ss.status NOT IN ('completed', 'declined', 'expired', 'cancelled', 'error');

  IF v_active_count > 1 THEN
    RAISE EXCEPTION 'multiple_active_bridges' USING ERRCODE = 'P0001';
  END IF;

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

-- Admin Signing Ops (prisma_admin read + resolve)
GRANT SELECT ON data.signing_ops_job_runs TO prisma_admin;
GRANT SELECT ON data.tenant_operation_logs TO prisma_admin;
GRANT UPDATE (resolved_at, resolved_by, resolution_note, updated_at)
  ON data.tenant_operation_logs TO prisma_admin;
GRANT SELECT ON data.signing_submissions TO prisma_admin;
GRANT SELECT ON data.commercial_decision_requests TO prisma_admin;
GRANT SELECT ON data.tenant_signing_config TO prisma_admin;
GRANT SELECT ON data.document_pdf_jobs TO prisma_admin;

GRANT SELECT ON TABLE pgmq.q_document_pdf_queue TO prisma_admin;
GRANT SELECT ON TABLE pgmq.a_document_pdf_queue TO prisma_admin;
GRANT SELECT ON TABLE pgmq.q_notification_dispatch_queue TO prisma_admin;
GRANT SELECT ON TABLE pgmq.a_notification_dispatch_queue TO prisma_admin;
GRANT SELECT ON TABLE pgmq.q_reminders_queue TO prisma_admin;
GRANT SELECT ON TABLE pgmq.a_reminders_queue TO prisma_admin;

NOTIFY pgrst, 'reload schema';
