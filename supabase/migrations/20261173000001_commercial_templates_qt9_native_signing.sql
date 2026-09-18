-- QT-9: commercial accept/reject/delivery record native signing refs.
-- Additive only. Does not change sign-document-router / stamp-pdf-signatures.
-- SQL still accepts any p_signature jsonb (regression: method=sql_test / staff_closeout).
-- The product path stores method=native plus signing_submission_id / signing_session_id.

CREATE OR REPLACE FUNCTION data.commercial_event_payload_with_signing(
  p_base jsonb,
  p_signature jsonb
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(p_base, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
    'signing_submission_id', NULLIF(p_signature ->> 'signing_submission_id', ''),
    'signing_session_id', NULLIF(p_signature ->> 'signing_session_id', ''),
    'signing_group_id', NULLIF(p_signature ->> 'signing_group_id', '')
  ));
$$;

-- Drop the composite-row overload if a previous apply created it.
DROP FUNCTION IF EXISTS data.commercial_accept_office_gate(data.commercial_documents);

CREATE OR REPLACE FUNCTION data.commercial_accept_office_gate(p_document_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_project data.projects%ROWTYPE;
  v_estimated numeric(14,2) := 0;
  v_overage numeric(14,2) := 0;
  v_threshold numeric := 0;
BEGIN
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF v_doc.doc_type <> 'quote_amendment' OR v_doc.project_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = v_doc.project_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COALESCE(
    SUM(
      ROUND(
        data.line_net(pl.quantity, pl.unit_price, pl.discount_pct)
          * (1 + pl.tax_rate / 100.0),
        2
      )
    ),
    0
  )
  INTO v_estimated
  FROM data.project_lines pl
  WHERE pl.project_id = v_project.id
    AND pl.tenant_id = v_project.tenant_id;

  v_overage := GREATEST(
    0::numeric,
    v_estimated - COALESCE(v_project.authorized_total, 0)
  );
  v_threshold := data.commercial_deviation_approval_threshold_eur(v_doc.tenant_id);

  IF v_overage > v_threshold
     AND NOT data.can_edit_commercial_pricing(v_doc.tenant_id) THEN
    RAISE EXCEPTION 'office_approval_required'
      USING ERRCODE = 'P0001',
            DETAIL = format('overage=%s threshold=%s', v_overage, v_threshold);
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS data.commercial_signing_intents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  document_id uuid NOT NULL REFERENCES data.commercial_documents(id) ON DELETE CASCADE,
  submission_id uuid,
  session_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN ('accept', 'reject', 'delivery')),
  client_op_id uuid NOT NULL,
  created_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  applied_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_commercial_signing_intents_client_op
  ON data.commercial_signing_intents (tenant_id, client_op_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_commercial_signing_intents_session
  ON data.commercial_signing_intents (session_id);

CREATE INDEX IF NOT EXISTS idx_commercial_signing_intents_document
  ON data.commercial_signing_intents (document_id, created_at DESC);

ALTER TABLE data.commercial_signing_intents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS csi_select ON data.commercial_signing_intents;
CREATE POLICY csi_select ON data.commercial_signing_intents
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

REVOKE ALL ON data.commercial_signing_intents FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.commercial_signing_intents TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_signing_intents TO service_role;

CREATE OR REPLACE VIEW api.commercial_signing_intents
AS SELECT * FROM data.commercial_signing_intents
WHERE data.jwt_user_tenants() ? tenant_id::text;

GRANT SELECT ON api.commercial_signing_intents TO authenticated;

CREATE OR REPLACE FUNCTION data.apply_commercial_decision(
  p_document_id uuid,
  p_action text,
  p_signature jsonb,
  p_client_op_id uuid,
  p_actor_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
  v_status text;
  v_event_type text;
  v_payload jsonb;
BEGIN
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_action NOT IN ('accept', 'reject', 'delivery') THEN
    RAISE EXCEPTION 'invalid_commercial_signing_action' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN p_document_id;
  END IF;

  IF v_doc.status <> 'issued' THEN
    IF p_action = 'reject' THEN
      RAISE EXCEPTION 'document_not_rejectable_state:%', v_doc.status USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;

  IF p_action = 'delivery' THEN
    IF v_doc.doc_type <> 'delivery_note' THEN
      RAISE EXCEPTION 'document_not_delivery_note' USING ERRCODE = 'P0001';
    END IF;
    v_status := 'signed';
    v_event_type := 'signed';
    v_payload := data.commercial_event_payload_with_signing(
      jsonb_build_object('signed_content_hash', v_doc.content_hash),
      p_signature
    );
  ELSIF p_action = 'reject' THEN
    IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
      RAISE EXCEPTION 'document_not_rejectable_type:%', v_doc.doc_type USING ERRCODE = 'P0001';
    END IF;
    v_status := 'rejected';
    v_event_type := 'rejected';
    v_payload := data.commercial_event_payload_with_signing(
      jsonb_build_object('rejected_content_hash', v_doc.content_hash),
      p_signature
    );
  ELSE
    IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
      RAISE EXCEPTION 'document_not_acceptable_type:%', v_doc.doc_type USING ERRCODE = 'P0001';
    END IF;
    v_status := 'accepted';
    v_event_type := 'accepted';
    v_payload := data.commercial_event_payload_with_signing(
      jsonb_build_object('accepted_content_hash', v_doc.content_hash),
      p_signature
    );
  END IF;

  UPDATE data.commercial_documents
  SET status = v_status, updated_at = now()
  WHERE id = p_document_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, v_event_type, p_actor_id, p_signature, v_doc.content_hash,
    p_client_op_id, v_payload
  );

  IF v_doc.doc_type IN ('quote', 'quote_amendment') AND v_doc.project_id IS NOT NULL THEN
    PERFORM api.recompute_project_authorized_total(v_doc.project_id);
  END IF;

  RETURN p_document_id;
END;
$$;

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

  PERFORM data.commercial_accept_office_gate(p_document_id);

  RETURN data.apply_commercial_decision(
    p_document_id, 'accept', COALESCE(p_signature, '{}'::jsonb), p_client_op_id, v_uid
  );
END;
$$;

REVOKE ALL ON FUNCTION api.accept_commercial_document(uuid, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.accept_commercial_document(uuid, jsonb, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.reject_commercial_document(
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

  RETURN data.apply_commercial_decision(
    p_document_id, 'reject', COALESCE(p_signature, '{}'::jsonb), p_client_op_id, v_uid
  );
END;
$$;

REVOKE ALL ON FUNCTION api.reject_commercial_document(uuid, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reject_commercial_document(uuid, jsonb, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.sign_commercial_delivery_note(
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

  RETURN data.apply_commercial_decision(
    p_document_id, 'delivery', COALESCE(p_signature, '{}'::jsonb), p_client_op_id, v_uid
  );
END;
$$;

REVOKE ALL ON FUNCTION api.sign_commercial_delivery_note(uuid, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.sign_commercial_delivery_note(uuid, jsonb, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.register_commercial_signing_intent(
  p_document_id uuid,
  p_session_id uuid,
  p_action text,
  p_client_op_id uuid,
  p_submission_id uuid DEFAULT NULL
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
  IF v_doc.status <> 'issued' THEN
    RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;
  IF p_action = 'delivery' AND v_doc.doc_type <> 'delivery_note' THEN
    RAISE EXCEPTION 'document_not_delivery_note' USING ERRCODE = 'P0001';
  END IF;
  IF p_action IN ('accept', 'reject') AND v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'document_not_quote' USING ERRCODE = 'P0001';
  END IF;
  IF p_action = 'accept' THEN
    PERFORM data.commercial_accept_office_gate(p_document_id);
  END IF;

  SELECT id INTO v_id
  FROM data.commercial_signing_intents
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  SELECT id INTO v_id
  FROM data.commercial_signing_intents
  WHERE session_id = p_session_id;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO data.commercial_signing_intents (
    tenant_id, document_id, submission_id, session_id, action, client_op_id, created_by
  ) VALUES (
    v_doc.tenant_id, p_document_id, p_submission_id, p_session_id, p_action, p_client_op_id, v_uid
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.apply_commercial_signing_intent_for_session(p_session_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_intent data.commercial_signing_intents%ROWTYPE;
  v_session data.document_signing_sessions%ROWTYPE;
  v_signature jsonb;
BEGIN
  SELECT * INTO v_intent
  FROM data.commercial_signing_intents
  WHERE session_id = p_session_id
  FOR UPDATE;
  IF NOT FOUND OR v_intent.applied_at IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_session
  FROM data.document_signing_sessions
  WHERE id = p_session_id;
  IF NOT FOUND OR v_session.status <> 'signed' THEN
    RETURN;
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

CREATE OR REPLACE FUNCTION data.trg_apply_commercial_signing_intent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.status = 'signed' AND OLD.status IS DISTINCT FROM 'signed' THEN
    BEGIN
      PERFORM data.apply_commercial_signing_intent_for_session(NEW.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'QT-9 commercial signing intent apply failed: %', SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_apply_commercial_signing_intent ON data.document_signing_sessions;
CREATE TRIGGER trg_apply_commercial_signing_intent
  AFTER UPDATE OF status ON data.document_signing_sessions
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_apply_commercial_signing_intent();

CREATE OR REPLACE FUNCTION data.trg_commercial_document_event_project_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
BEGIN
  IF NEW.event_type NOT IN (
    'issued', 'sent', 'accepted', 'rejected', 'cancelled', 'superseded', 'signed'
  ) THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = NEW.document_id;
  IF NOT FOUND OR v_doc.project_id IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM data.log_audit_event(
    NEW.tenant_id,
    NEW.actor_id,
    NULL,
    'PROJECT_COMMERCIAL_' || upper(NEW.event_type),
    'project',
    v_doc.project_id,
    jsonb_build_object(
      'doc_number', v_doc.doc_number,
      'doc_type', v_doc.doc_type,
      'event', NEW.event_type,
      'commercial_document_id', v_doc.id
    )
  );
  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';
