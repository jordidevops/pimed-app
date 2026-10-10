-- Office accept without client signature (tenant opt-in).
-- Setting: tenants.settings.commercial.allow_office_accept (default false).

CREATE OR REPLACE FUNCTION data.commercial_allow_office_accept(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(
    (SELECT (settings #>> '{commercial,allow_office_accept}')::boolean
     FROM data.tenants
     WHERE id = p_tenant_id),
    false
  );
$$;

REVOKE ALL ON FUNCTION data.commercial_allow_office_accept(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.commercial_allow_office_accept(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.revoke_open_commercial_decision_requests_for_document(
  p_document_id uuid,
  p_actor_id uuid,
  p_client_op_id uuid
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_req data.commercial_decision_requests%ROWTYPE;
  v_count int := 0;
  v_op uuid;
BEGIN
  FOR v_req IN
    SELECT *
    FROM data.commercial_decision_requests
    WHERE commercial_document_id = p_document_id
      AND status = 'open'
    FOR UPDATE
  LOOP
    v_count := v_count + 1;
    v_op := COALESCE(p_client_op_id, gen_random_uuid());

    UPDATE data.commercial_decision_requests
    SET status = 'revoked', updated_at = now()
    WHERE id = v_req.id;

    UPDATE data.commercial_decision_access_tokens
    SET status = 'revoked', revoked_at = now()
    WHERE request_id = v_req.id AND status = 'active';

    UPDATE data.commercial_decision_deliveries
    SET status = 'revoked'
    WHERE request_id = v_req.id AND status IN ('prepared', 'queued');

    INSERT INTO data.commercial_decision_events (
      tenant_id, request_id, event_type, via, actor_id, content_hash, client_op_id
    ) VALUES (
      v_req.tenant_id, v_req.id, 'revoked', 'office', p_actor_id, v_req.content_hash, v_op
    );
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION data.revoke_open_commercial_decision_requests_for_document(uuid, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.revoke_open_commercial_decision_requests_for_document(uuid, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.assert_office_accept_allowed(
  p_tenant_id uuid,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF NOT data.commercial_allow_office_accept(p_tenant_id) THEN
    RAISE EXCEPTION 'office_accept_disabled' USING ERRCODE = 'P0001';
  END IF;
  v_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_role IS DISTINCT FROM 'owner' AND v_role IS DISTINCT FROM 'manager' THEN
    RAISE EXCEPTION 'office_accept_forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT data.can_edit_commercial_pricing(p_tenant_id) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'office_accept_reason_required' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_office_accept_allowed(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_office_accept_allowed(uuid, text)
  TO authenticated, service_role;

-- Dedicated office-accept RPC (preferred UI path).
CREATE OR REPLACE FUNCTION api.accept_commercial_document_office(
  p_document_id uuid,
  p_reason text,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_evidence jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'document_not_acceptable_type:%', v_doc.doc_type USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.assert_office_accept_allowed(v_doc.tenant_id, v_reason);

  PERFORM data.commercial_accept_office_gate(p_document_id);

  PERFORM data.revoke_open_commercial_decision_requests_for_document(
    p_document_id, v_uid, p_client_op_id
  );

  v_evidence := jsonb_build_object(
    'method', 'office',
    'role', 'office_accept',
    'reason', v_reason,
    'attested_at', now(),
    'attested_by', v_uid
  );

  RETURN data.apply_commercial_decision(
    p_document_id, 'accept', v_evidence, p_client_op_id, v_uid
  );
END;
$$;

REVOKE ALL ON FUNCTION api.accept_commercial_document_office(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.accept_commercial_document_office(uuid, text, uuid)
  TO authenticated, service_role;

-- Harden legacy accept when signature claims office accept.
CREATE OR REPLACE FUNCTION api.accept_commercial_document(
  p_document_id uuid,
  p_signature jsonb,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_sig jsonb := COALESCE(p_signature, '{}'::jsonb);
  v_role text;
  v_reason text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_role := COALESCE(v_sig->>'role', '');
  IF v_role = 'office_accept'
     OR (COALESCE(v_sig->>'method', '') = 'office' AND v_role <> 'office_reject')
  THEN
    v_reason := NULLIF(btrim(COALESCE(v_sig->>'reason', '')), '');
    PERFORM data.assert_office_accept_allowed(v_doc.tenant_id, v_reason);
    PERFORM data.revoke_open_commercial_decision_requests_for_document(
      p_document_id, v_uid, p_client_op_id
    );
    v_sig := v_sig || jsonb_build_object(
      'method', 'office',
      'role', 'office_accept',
      'reason', v_reason,
      'attested_at', COALESCE(v_sig->>'attested_at', now()::text),
      'attested_by', COALESCE(v_sig->>'attested_by', v_uid::text)
    );
  END IF;

  PERFORM data.commercial_accept_office_gate(p_document_id);

  RETURN data.apply_commercial_decision(
    p_document_id, 'accept', v_sig, p_client_op_id, v_uid
  );
END;
$$;

REVOKE ALL ON FUNCTION api.accept_commercial_document(uuid, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.accept_commercial_document(uuid, jsonb, uuid)
  TO authenticated, service_role;

-- Fix office decision-request apply: role + reason required for accept too.
CREATE OR REPLACE FUNCTION api.apply_commercial_decision_office(
  p_request_id uuid,
  p_outcome text,
  p_reason text,
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
  v_evidence jsonb;
  v_role text;
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_req FROM data.commercial_decision_requests WHERE id = p_request_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_req.tenant_id::text) THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_outcome NOT IN ('accepted', 'declined') THEN
    RAISE EXCEPTION 'invalid_decision_outcome' USING ERRCODE = 'P0001';
  END IF;

  IF p_outcome = 'declined' AND v_reason IS NULL THEN
    RAISE EXCEPTION 'office_decline_reason_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_outcome = 'accepted' THEN
    PERFORM data.assert_office_accept_allowed(v_req.tenant_id, v_reason);
    v_role := 'office_accept';
  ELSE
    v_role := 'office_reject';
  END IF;

  v_evidence := jsonb_strip_nulls(jsonb_build_object(
    'method', 'office',
    'role', v_role,
    'reason', v_reason,
    'attested_at', now(),
    'attested_by', v_uid
  ));

  RETURN data.apply_commercial_decision_request(
    p_request_id, p_outcome, 'office', v_evidence, p_client_op_id, v_uid
  );
END;
$$;

REVOKE ALL ON FUNCTION api.apply_commercial_decision_office(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_commercial_decision_office(uuid, text, text, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
