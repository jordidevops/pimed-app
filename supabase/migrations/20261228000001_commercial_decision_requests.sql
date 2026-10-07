-- CF-28 / F2: commercial_decision_requests domain (strangler behind tenant flag).
-- Flag: tenants.settings.commercial.decision_requests_enabled (default false).

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.commercial_decision_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  client_account_contact_id uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  commercial_document_id uuid REFERENCES data.commercial_documents(id) ON DELETE RESTRICT,
  agreement_version_id uuid REFERENCES data.commercial_agreement_versions(id) ON DELETE RESTRICT,
  purpose text NOT NULL CHECK (purpose IN ('acceptance', 'delivery_confirmation')),
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'accepted', 'declined', 'expired', 'revoked', 'superseded')),
  active_provider text CHECK (active_provider IS NULL OR active_provider IN ('native', 'docuseal')),
  snapshot_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  content_hash text NOT NULL,
  rendered_document_id uuid NOT NULL REFERENCES data.documents(id) ON DELETE RESTRICT,
  document_version_id uuid NOT NULL REFERENCES data.document_versions(id) ON DELETE RESTRICT,
  expires_at timestamptz NOT NULL,
  client_op_id uuid NOT NULL,
  created_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  decided_at timestamptz,
  decided_via text CHECK (
    decided_via IS NULL OR decided_via IN ('link', 'portal', 'office', 'presential', 'provider')
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commercial_decision_requests_xor_target CHECK (
    (commercial_document_id IS NOT NULL AND agreement_version_id IS NULL)
    OR (commercial_document_id IS NULL AND agreement_version_id IS NOT NULL)
  ),
  CONSTRAINT commercial_decision_requests_decided_pair CHECK (
    (status IN ('accepted', 'declined') AND decided_at IS NOT NULL)
    OR (status NOT IN ('accepted', 'declined'))
  ),
  CONSTRAINT commercial_decision_requests_tenant_client_op UNIQUE (tenant_id, client_op_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cdr_open_document
  ON data.commercial_decision_requests (commercial_document_id)
  WHERE status = 'open' AND commercial_document_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_cdr_open_agreement_version
  ON data.commercial_decision_requests (agreement_version_id)
  WHERE status = 'open' AND agreement_version_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cdr_tenant_client_status
  ON data.commercial_decision_requests (
    tenant_id, client_account_contact_id, status, created_at DESC, id DESC
  );

CREATE INDEX IF NOT EXISTS idx_cdr_open_expires
  ON data.commercial_decision_requests (tenant_id, status, expires_at)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_cdr_rendered_document
  ON data.commercial_decision_requests (rendered_document_id);

CREATE INDEX IF NOT EXISTS idx_cdr_document_version
  ON data.commercial_decision_requests (document_version_id);

COMMENT ON TABLE data.commercial_decision_requests IS
  'CF-28: unitat de negoci per acceptar/refusar quote, agreement version o albarà.';

CREATE TABLE IF NOT EXISTS data.commercial_decision_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  request_id uuid NOT NULL REFERENCES data.commercial_decision_requests(id) ON DELETE CASCADE,
  channel text NOT NULL CHECK (channel IN ('email', 'whatsapp', 'copy_link', 'portal', 'presential')),
  recipient_contact_point_id uuid,
  recipient_hash text,
  recipient_masked text,
  locale text NOT NULL DEFAULT 'ca',
  status text NOT NULL DEFAULT 'prepared'
    CHECK (status IN ('prepared', 'queued', 'sent', 'failed', 'revoked')),
  idempotency_key text NOT NULL,
  email_log_id uuid,
  error_code text,
  queued_at timestamptz,
  sent_at timestamptz,
  failed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commercial_decision_deliveries_tenant_idem UNIQUE (tenant_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_cdd_request_created
  ON data.commercial_decision_deliveries (request_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_cdd_tenant_status_created
  ON data.commercial_decision_deliveries (tenant_id, status, created_at);

CREATE TABLE IF NOT EXISTS data.commercial_decision_access_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  request_id uuid NOT NULL REFERENCES data.commercial_decision_requests(id) ON DELETE CASCADE,
  delivery_id uuid REFERENCES data.commercial_decision_deliveries(id) ON DELETE SET NULL,
  token_hash text NOT NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'revoked', 'expired', 'consumed')),
  expires_at timestamptz NOT NULL,
  opened_at timestamptz,
  last_opened_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CONSTRAINT commercial_decision_access_tokens_hash_unique UNIQUE (token_hash)
);

CREATE INDEX IF NOT EXISTS idx_cdat_active_hash
  ON data.commercial_decision_access_tokens (token_hash)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_cdat_request_status
  ON data.commercial_decision_access_tokens (request_id, status);

CREATE TABLE IF NOT EXISTS data.commercial_decision_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  request_id uuid NOT NULL REFERENCES data.commercial_decision_requests(id) ON DELETE CASCADE,
  event_type text NOT NULL,
  outcome text,
  via text,
  actor_id uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  portal_principal_id uuid,
  signer_name text,
  signer_email text,
  signer_role text,
  ip_address inet,
  user_agent text,
  content_hash text NOT NULL,
  provider text,
  provider_submission_id uuid,
  provider_session_id uuid,
  reason text,
  client_op_id uuid,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cde_request_client_op
  ON data.commercial_decision_events (request_id, client_op_id)
  WHERE client_op_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cde_request_created
  ON data.commercial_decision_events (request_id, created_at);

CREATE OR REPLACE FUNCTION data.trg_commercial_decision_events_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'commercial_decision_events_immutable' USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_decision_events_append_only
  ON data.commercial_decision_events;
CREATE TRIGGER trg_commercial_decision_events_append_only
  BEFORE UPDATE OR DELETE ON data.commercial_decision_events
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_decision_events_append_only();

DROP TRIGGER IF EXISTS trg_commercial_decision_requests_updated_at
  ON data.commercial_decision_requests;
CREATE TRIGGER trg_commercial_decision_requests_updated_at
  BEFORE UPDATE ON data.commercial_decision_requests
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- Strangler column on intents
ALTER TABLE data.commercial_signing_intents
  ADD COLUMN IF NOT EXISTS decision_request_id uuid
    REFERENCES data.commercial_decision_requests(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_csi_decision_request
  ON data.commercial_signing_intents (decision_request_id)
  WHERE decision_request_id IS NOT NULL;

-- Session declined (CS-D24)
ALTER TABLE data.document_signing_sessions
  DROP CONSTRAINT IF EXISTS document_signing_sessions_status_check;
ALTER TABLE data.document_signing_sessions
  ADD CONSTRAINT document_signing_sessions_status_check
  CHECK (status IN (
    'pending', 'opened', 'viewed', 'signed', 'declined', 'expired', 'cancelled'
  ));

-- Agreement version declined
ALTER TABLE data.commercial_agreement_versions
  DROP CONSTRAINT IF EXISTS commercial_agreement_versions_status_check;
ALTER TABLE data.commercial_agreement_versions
  ADD CONSTRAINT commercial_agreement_versions_status_check
  CHECK (status IN ('draft', 'pending_signature', 'signed', 'declined'));

ALTER TABLE data.commercial_agreement_events
  DROP CONSTRAINT IF EXISTS commercial_agreement_events_event_type_check;
ALTER TABLE data.commercial_agreement_events
  ADD CONSTRAINT commercial_agreement_events_event_type_check
  CHECK (event_type IN (
    'created', 'prepared', 'sent', 'signed', 'declined', 'activated',
    'cancelled', 'project_linked', 'project_unlinked',
    'suspended', 'finished', 'renewed',
    'coverage_linked', 'coverage_unlinked',
    'maintenance_plan_linked', 'maintenance_plan_unlinked',
    'expiry_notice_sent',
    'billing_period_generated', 'billing_period_invoiced', 'billing_period_skipped',
    'signing_failed'
  ));

-- ---------------------------------------------------------------------------
-- 2. RLS
-- ---------------------------------------------------------------------------

ALTER TABLE data.commercial_decision_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_decision_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_decision_access_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_decision_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cdr_select ON data.commercial_decision_requests;
CREATE POLICY cdr_select ON data.commercial_decision_requests
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

DROP POLICY IF EXISTS cdd_select ON data.commercial_decision_deliveries;
CREATE POLICY cdd_select ON data.commercial_decision_deliveries
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

-- Tokens: no SELECT for authenticated (hash-only; resolve via service RPC)
DROP POLICY IF EXISTS cdat_select ON data.commercial_decision_access_tokens;

DROP POLICY IF EXISTS cde_select ON data.commercial_decision_events;
CREATE POLICY cde_select ON data.commercial_decision_events
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

REVOKE ALL ON data.commercial_decision_requests FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_decision_deliveries FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_decision_access_tokens FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_decision_events FROM PUBLIC, anon, authenticated;

GRANT SELECT ON data.commercial_decision_requests TO authenticated;
GRANT SELECT ON data.commercial_decision_deliveries TO authenticated;
GRANT SELECT ON data.commercial_decision_events TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_decision_requests TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_decision_deliveries TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_decision_access_tokens TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_decision_events TO service_role;

CREATE OR REPLACE VIEW api.commercial_decision_requests
AS SELECT * FROM data.commercial_decision_requests
WHERE data.jwt_user_tenants() ? tenant_id::text;

CREATE OR REPLACE VIEW api.commercial_decision_deliveries
AS SELECT * FROM data.commercial_decision_deliveries
WHERE data.jwt_user_tenants() ? tenant_id::text;

CREATE OR REPLACE VIEW api.commercial_decision_events
AS SELECT * FROM data.commercial_decision_events
WHERE data.jwt_user_tenants() ? tenant_id::text;

GRANT SELECT ON api.commercial_decision_requests TO authenticated;
GRANT SELECT ON api.commercial_decision_deliveries TO authenticated;
GRANT SELECT ON api.commercial_decision_events TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.commercial_decision_requests_enabled(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    (t.settings #>> '{commercial,decision_requests_enabled}')::boolean,
    false
  )
  FROM data.tenants t
  WHERE t.id = p_tenant_id;
$$;

REVOKE ALL ON FUNCTION data.commercial_decision_requests_enabled(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.commercial_decision_requests_enabled(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.commercial_decision_latest_version_id(p_document_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT v.id
  FROM data.document_versions v
  WHERE v.document_id = p_document_id
  ORDER BY v.version_number DESC
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION data.commercial_decision_latest_version_id(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.commercial_decision_latest_version_id(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.commercial_decision_build_document_snapshot(
  p_doc data.commercial_documents
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'kind', 'commercial_document',
    'id', p_doc.id,
    'doc_type', p_doc.doc_type,
    'doc_number', p_doc.doc_number,
    'status', p_doc.status,
    'client_id', p_doc.client_id,
    'project_id', p_doc.project_id,
    'formalization_mode', p_doc.formalization_mode,
    'content_hash', p_doc.content_hash,
    'total', p_doc.total,
    'currency', p_doc.currency,
    'locale', p_doc.locale,
    'rendered_document_id', p_doc.rendered_document_id,
    'valid_until', p_doc.valid_until
  );
$$;

-- ---------------------------------------------------------------------------
-- 4. Create request
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_commercial_decision_request(
  p_target_kind text,
  p_target_id uuid,
  p_expires_at timestamptz,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_existing uuid;
  v_open uuid;
  v_purpose text;
  v_client uuid;
  v_tenant uuid;
  v_hash text;
  v_rendered uuid;
  v_doc_version uuid;
  v_snapshot jsonb;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_expires_at IS NULL OR p_expires_at <= now() THEN
    RAISE EXCEPTION 'expires_at_invalid' USING ERRCODE = 'P0001';
  END IF;
  IF p_target_kind NOT IN ('commercial_document', 'agreement_version') THEN
    RAISE EXCEPTION 'invalid_target_kind' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_existing
  FROM data.commercial_decision_requests
  WHERE client_op_id = p_client_op_id
    AND tenant_id IN (
      SELECT t.id FROM data.tenants t
      WHERE data.jwt_user_tenants() ? t.id::text
    )
  LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  IF p_target_kind = 'commercial_document' THEN
    SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
      RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF NOT data.commercial_decision_requests_enabled(v_doc.tenant_id) THEN
      RAISE EXCEPTION 'decision_requests_disabled' USING ERRCODE = 'P0001';
    END IF;
    IF v_doc.status <> 'issued' THEN
      RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
    END IF;
    IF v_doc.doc_type IN ('quote', 'quote_amendment') THEN
      v_purpose := 'acceptance';
    ELSIF v_doc.doc_type = 'delivery_note' THEN
      v_purpose := 'delivery_confirmation';
    ELSE
      RAISE EXCEPTION 'document_not_decisionable_type:%', v_doc.doc_type USING ERRCODE = 'P0001';
    END IF;
    IF v_doc.rendered_document_id IS NULL THEN
      RAISE EXCEPTION 'rendered_document_required' USING ERRCODE = 'P0001';
    END IF;
    IF v_doc.content_hash IS NULL OR btrim(v_doc.content_hash) = '' THEN
      RAISE EXCEPTION 'content_hash_missing' USING ERRCODE = 'P0001';
    END IF;
    v_doc_version := data.commercial_decision_latest_version_id(v_doc.rendered_document_id);
    IF v_doc_version IS NULL THEN
      RAISE EXCEPTION 'document_version_missing' USING ERRCODE = 'P0001';
    END IF;
    v_tenant := v_doc.tenant_id;
    v_client := v_doc.client_id;
    v_hash := v_doc.content_hash;
    v_rendered := v_doc.rendered_document_id;
    v_snapshot := data.commercial_decision_build_document_snapshot(v_doc);

    UPDATE data.commercial_decision_access_tokens t
    SET status = 'revoked', revoked_at = now()
    FROM data.commercial_decision_requests r
    WHERE r.commercial_document_id = v_doc.id
      AND r.status = 'open'
      AND t.request_id = r.id
      AND t.status = 'active';

    UPDATE data.commercial_decision_requests
    SET status = 'superseded', updated_at = now()
    WHERE commercial_document_id = v_doc.id
      AND status = 'open';

    INSERT INTO data.commercial_decision_requests (
      tenant_id, client_account_contact_id, commercial_document_id, purpose,
      snapshot_json, content_hash, rendered_document_id, document_version_id,
      expires_at, client_op_id, created_by
    ) VALUES (
      v_tenant, v_client, v_doc.id, v_purpose,
      v_snapshot, v_hash, v_rendered, v_doc_version,
      p_expires_at, p_client_op_id, v_uid
    ) RETURNING id INTO v_id;
  ELSE
    SELECT * INTO v_version
    FROM data.commercial_agreement_versions WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_version.tenant_id::text) THEN
      RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF NOT data.commercial_decision_requests_enabled(v_version.tenant_id) THEN
      RAISE EXCEPTION 'decision_requests_disabled' USING ERRCODE = 'P0001';
    END IF;
    IF v_version.status <> 'pending_signature' THEN
      RAISE EXCEPTION 'agreement_version_not_pending' USING ERRCODE = 'P0001';
    END IF;
    IF v_version.rendered_document_id IS NULL OR v_version.content_hash IS NULL THEN
      RAISE EXCEPTION 'agreement_version_not_rendered' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_version.agreement_id;
    v_doc_version := data.commercial_decision_latest_version_id(v_version.rendered_document_id);
    IF v_doc_version IS NULL THEN
      RAISE EXCEPTION 'document_version_missing' USING ERRCODE = 'P0001';
    END IF;
    v_tenant := v_version.tenant_id;
    v_client := v_agreement.client_id;
    v_hash := v_version.content_hash;
    v_rendered := v_version.rendered_document_id;
    v_snapshot := jsonb_build_object(
      'kind', 'agreement_version',
      'id', v_version.id,
      'agreement_id', v_version.agreement_id,
      'version_no', v_version.version_no,
      'source_quote_id', v_version.source_quote_id,
      'content_hash', v_version.content_hash,
      'rendered_document_id', v_version.rendered_document_id
    );

    UPDATE data.commercial_decision_access_tokens t
    SET status = 'revoked', revoked_at = now()
    FROM data.commercial_decision_requests r
    WHERE r.agreement_version_id = v_version.id
      AND r.status = 'open'
      AND t.request_id = r.id
      AND t.status = 'active';

    UPDATE data.commercial_decision_requests
    SET status = 'superseded', updated_at = now()
    WHERE agreement_version_id = v_version.id
      AND status = 'open';

    INSERT INTO data.commercial_decision_requests (
      tenant_id, client_account_contact_id, agreement_version_id, purpose,
      snapshot_json, content_hash, rendered_document_id, document_version_id,
      expires_at, client_op_id, created_by
    ) VALUES (
      v_tenant, v_client, v_version.id, 'acceptance',
      v_snapshot, v_hash, v_rendered, v_doc_version,
      p_expires_at, p_client_op_id, v_uid
    ) RETURNING id INTO v_id;
  END IF;

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, via, actor_id, content_hash, client_op_id, evidence
  ) VALUES (
    v_tenant, v_id, 'created', 'office', v_uid, v_hash, p_client_op_id,
    jsonb_build_object('target_kind', p_target_kind, 'target_id', p_target_id)
  );

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_commercial_decision_request(text, uuid, timestamptz, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_commercial_decision_request(text, uuid, timestamptz, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Delivery + token (raw token once)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_commercial_decision_delivery(
  p_request_id uuid,
  p_channel text,
  p_contact_point_id uuid,
  p_locale text,
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
  v_delivery_id uuid;
  v_token text;
  v_hash text;
  v_locale text := COALESCE(NULLIF(btrim(p_locale), ''), 'ca');
  v_idem text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_channel NOT IN ('email', 'whatsapp', 'copy_link', 'portal', 'presential') THEN
    RAISE EXCEPTION 'invalid_delivery_channel' USING ERRCODE = 'P0001';
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
  IF v_req.expires_at <= now() THEN
    RAISE EXCEPTION 'decision_request_expired' USING ERRCODE = 'P0001';
  END IF;

  v_idem := 'commercial-decision:' || v_req.id::text || ':op:' || p_client_op_id::text;

  SELECT id INTO v_delivery_id
  FROM data.commercial_decision_deliveries
  WHERE tenant_id = v_req.tenant_id AND idempotency_key = v_idem;
  IF v_delivery_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'delivery_id', v_delivery_id,
      'raw_token', NULL,
      'already_created', true
    );
  END IF;

  INSERT INTO data.commercial_decision_deliveries (
    tenant_id, request_id, channel, recipient_contact_point_id, locale, status, idempotency_key
  ) VALUES (
    v_req.tenant_id, v_req.id, p_channel, p_contact_point_id, v_locale, 'prepared', v_idem
  ) RETURNING id INTO v_delivery_id;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_hash := encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex');

  INSERT INTO data.commercial_decision_access_tokens (
    tenant_id, request_id, delivery_id, token_hash, status, expires_at
  ) VALUES (
    v_req.tenant_id, v_req.id, v_delivery_id, v_hash, 'active',
    LEAST(v_req.expires_at, now() + interval '30 days')
  );

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, via, actor_id, content_hash, client_op_id, evidence
  ) VALUES (
    v_req.tenant_id, v_req.id, 'delivery_created', p_channel, v_uid, v_req.content_hash,
    p_client_op_id,
    jsonb_build_object('delivery_id', v_delivery_id, 'channel', p_channel)
  );

  RETURN jsonb_build_object(
    'delivery_id', v_delivery_id,
    'raw_token', v_token,
    'already_created', false
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_commercial_decision_delivery(uuid, text, uuid, text, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_commercial_decision_delivery(uuid, text, uuid, text, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Apply (atomic, first-wins)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.apply_commercial_decision_request(
  p_request_id uuid,
  p_outcome text,
  p_via text,
  p_evidence jsonb,
  p_client_op_id uuid,
  p_actor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_req data.commercial_decision_requests%ROWTYPE;
  v_doc data.commercial_documents%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_quote data.commercial_documents%ROWTYPE;
  v_event_id uuid;
  v_status text;
  v_evidence jsonb := COALESCE(p_evidence, '{}'::jsonb);
  v_updated int;
BEGIN
  IF p_outcome NOT IN ('accepted', 'declined') THEN
    RAISE EXCEPTION 'invalid_decision_outcome' USING ERRCODE = 'P0001';
  END IF;
  IF p_via NOT IN ('link', 'portal', 'office', 'presential', 'provider') THEN
    RAISE EXCEPTION 'invalid_decision_via' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = p_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_client_op_id IS NOT NULL THEN
    SELECT id INTO v_event_id
    FROM data.commercial_decision_events
    WHERE request_id = v_req.id AND client_op_id = p_client_op_id
    LIMIT 1;
    IF v_event_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'request_id', v_req.id,
        'status', v_req.status,
        'applied', false,
        'already_decided', v_req.status IN ('accepted', 'declined')
      );
    END IF;
  END IF;

  IF v_req.status <> 'open' THEN
    RETURN jsonb_build_object(
      'request_id', v_req.id,
      'status', v_req.status,
      'applied', false,
      'already_decided', true
    );
  END IF;

  IF v_req.expires_at <= now() THEN
    UPDATE data.commercial_decision_requests
    SET status = 'expired', updated_at = now()
    WHERE id = v_req.id AND status = 'open';
    RETURN jsonb_build_object(
      'request_id', v_req.id,
      'status', 'expired',
      'applied', false,
      'already_decided', false
    );
  END IF;

  v_status := p_outcome;

  IF v_req.commercial_document_id IS NOT NULL THEN
    SELECT * INTO v_doc
    FROM data.commercial_documents
    WHERE id = v_req.commercial_document_id
    FOR UPDATE;
    IF NOT FOUND OR v_doc.tenant_id IS DISTINCT FROM v_req.tenant_id THEN
      RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_doc.status <> 'issued' THEN
      RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
    END IF;
    IF v_doc.content_hash IS DISTINCT FROM v_req.content_hash THEN
      RAISE EXCEPTION 'content_hash_mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF v_doc.valid_until IS NOT NULL AND v_doc.valid_until < now() THEN
      RAISE EXCEPTION 'document_expired' USING ERRCODE = 'P0001';
    END IF;

    UPDATE data.commercial_decision_requests
    SET status = v_status,
        decided_at = now(),
        decided_via = p_via,
        updated_at = now()
    WHERE id = v_req.id AND status = 'open';
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
      SELECT status INTO v_status FROM data.commercial_decision_requests WHERE id = v_req.id;
      RETURN jsonb_build_object(
        'request_id', v_req.id,
        'status', v_status,
        'applied', false,
        'already_decided', true
      );
    END IF;

    IF v_req.purpose = 'delivery_confirmation' THEN
      IF p_outcome = 'accepted' THEN
        UPDATE data.commercial_documents
        SET status = 'signed', updated_at = now()
        WHERE id = v_doc.id;
        INSERT INTO data.commercial_document_events (
          tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
        ) VALUES (
          v_doc.tenant_id, v_doc.id, 'signed', p_actor_id, v_evidence, v_doc.content_hash,
          p_client_op_id,
          data.commercial_event_payload_with_signing(
            jsonb_build_object('signed_content_hash', v_doc.content_hash),
            v_evidence
          )
        );
      ELSE
        UPDATE data.commercial_documents
        SET status = 'rejected', updated_at = now()
        WHERE id = v_doc.id;
        INSERT INTO data.commercial_document_events (
          tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
        ) VALUES (
          v_doc.tenant_id, v_doc.id, 'rejected', p_actor_id, v_evidence, v_doc.content_hash,
          p_client_op_id,
          data.commercial_event_payload_with_signing(
            jsonb_build_object('rejected_content_hash', v_doc.content_hash, 'disputed', true),
            v_evidence
          )
        );
      END IF;
    ELSE
      IF p_outcome = 'accepted' THEN
        IF v_doc.formalization_mode = 'separate_agreement' THEN
          RAISE EXCEPTION 'separate_agreement_requires_agreement_target' USING ERRCODE = 'P0001';
        END IF;
        UPDATE data.commercial_documents
        SET status = 'accepted', updated_at = now()
        WHERE id = v_doc.id;
        INSERT INTO data.commercial_document_events (
          tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
        ) VALUES (
          v_doc.tenant_id, v_doc.id, 'accepted', p_actor_id, v_evidence, v_doc.content_hash,
          p_client_op_id,
          data.commercial_event_payload_with_signing(
            jsonb_build_object('accepted_content_hash', v_doc.content_hash),
            v_evidence
          )
        );
        IF v_doc.project_id IS NOT NULL THEN
          PERFORM api.recompute_project_authorized_total(v_doc.project_id);
        END IF;
      ELSE
        UPDATE data.commercial_documents
        SET status = 'rejected', updated_at = now()
        WHERE id = v_doc.id;
        INSERT INTO data.commercial_document_events (
          tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
        ) VALUES (
          v_doc.tenant_id, v_doc.id, 'rejected', p_actor_id, v_evidence, v_doc.content_hash,
          p_client_op_id,
          data.commercial_event_payload_with_signing(
            jsonb_build_object('rejected_content_hash', v_doc.content_hash),
            v_evidence
          )
        );
        IF v_doc.project_id IS NOT NULL THEN
          PERFORM api.recompute_project_authorized_total(v_doc.project_id);
        END IF;
      END IF;
    END IF;
  ELSE
    SELECT * INTO v_version
    FROM data.commercial_agreement_versions
    WHERE id = v_req.agreement_version_id
    FOR UPDATE;
    IF NOT FOUND OR v_version.tenant_id IS DISTINCT FROM v_req.tenant_id THEN
      RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_version.status <> 'pending_signature' THEN
      RAISE EXCEPTION 'agreement_version_not_pending' USING ERRCODE = 'P0001';
    END IF;
    IF v_version.content_hash IS DISTINCT FROM v_req.content_hash THEN
      RAISE EXCEPTION 'content_hash_mismatch' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_agreement
    FROM data.commercial_agreements
    WHERE id = v_version.agreement_id
    FOR UPDATE;

    SELECT * INTO v_quote
    FROM data.commercial_documents
    WHERE id = v_version.source_quote_id
    FOR UPDATE;

    UPDATE data.commercial_decision_requests
    SET status = v_status,
        decided_at = now(),
        decided_via = p_via,
        updated_at = now()
    WHERE id = v_req.id AND status = 'open';
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
      SELECT status INTO v_status FROM data.commercial_decision_requests WHERE id = v_req.id;
      RETURN jsonb_build_object(
        'request_id', v_req.id,
        'status', v_status,
        'applied', false,
        'already_decided', true
      );
    END IF;

    IF p_outcome = 'accepted' THEN
      PERFORM set_config('app.commercial_agreement_signing_unlocked', 'on', true);
      UPDATE data.commercial_agreement_versions
      SET status = 'signed', updated_at = now()
      WHERE id = v_version.id;
      PERFORM set_config('app.commercial_agreement_signing_unlocked', 'off', true);

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
      ) VALUES (
        v_version.tenant_id, v_version.agreement_id, 'signed', p_actor_id, p_client_op_id,
        jsonb_build_object('version_id', v_version.id, 'via', p_via)
      );

      IF v_agreement.status NOT IN ('cancelled', 'finished', 'active') THEN
        UPDATE data.commercial_agreements
        SET status = 'active', updated_at = now()
        WHERE id = v_agreement.id;
        INSERT INTO data.commercial_agreement_events (
          tenant_id, agreement_id, event_type, actor_id, payload
        ) VALUES (
          v_version.tenant_id, v_agreement.id, 'activated', p_actor_id,
          jsonb_build_object('version_id', v_version.id)
        );
      END IF;

      IF v_quote.status = 'issued' THEN
        UPDATE data.commercial_documents
        SET status = 'accepted', updated_at = now()
        WHERE id = v_quote.id;
        INSERT INTO data.commercial_document_events (
          tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
        ) VALUES (
          v_quote.tenant_id, v_quote.id, 'accepted', p_actor_id, v_evidence, v_quote.content_hash,
          COALESCE(p_client_op_id, gen_random_uuid()),
          data.commercial_event_payload_with_signing(
            jsonb_build_object(
              'accepted_content_hash', v_quote.content_hash,
              'via_agreement_version', v_version.id
            ),
            v_evidence
          )
        );
        IF v_quote.project_id IS NOT NULL THEN
          PERFORM api.recompute_project_authorized_total(v_quote.project_id);
        END IF;
      END IF;

      BEGIN
        PERFORM data.commercial_agreement_ensure_cycle(v_agreement.id);
      EXCEPTION WHEN undefined_function THEN
        NULL;
      END;
    ELSE
      PERFORM set_config('app.commercial_agreement_signing_unlocked', 'on', true);
      UPDATE data.commercial_agreement_versions
      SET status = 'declined', updated_at = now()
      WHERE id = v_version.id;
      PERFORM set_config('app.commercial_agreement_signing_unlocked', 'off', true);

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
      ) VALUES (
        v_version.tenant_id, v_version.agreement_id, 'declined', p_actor_id, p_client_op_id,
        jsonb_build_object(
          'version_id', v_version.id,
          'via', p_via,
          'reason', v_evidence->>'reason'
        )
      );
      -- Quote stays issued / not accepted
    END IF;
  END IF;

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, outcome, via, actor_id,
    signer_name, signer_email, signer_role,
    content_hash, provider, provider_submission_id, provider_session_id,
    reason, client_op_id, evidence
  ) VALUES (
    v_req.tenant_id, v_req.id, 'decided', p_outcome, p_via, p_actor_id,
    v_evidence->>'signer_name', v_evidence->>'signer_email', v_evidence->>'signer_role',
    v_req.content_hash,
    v_evidence->>'provider',
    NULLIF(v_evidence->>'provider_submission_id', '')::uuid,
    NULLIF(v_evidence->>'provider_session_id', '')::uuid,
    v_evidence->>'reason',
    p_client_op_id,
    v_evidence - 'signer_name' - 'signer_email' - 'signer_role' - 'provider'
      - 'provider_submission_id' - 'provider_session_id' - 'reason'
  );

  UPDATE data.commercial_decision_access_tokens
  SET status = 'consumed', revoked_at = COALESCE(revoked_at, now())
  WHERE request_id = v_req.id AND status = 'active';

  RETURN jsonb_build_object(
    'request_id', v_req.id,
    'status', p_outcome,
    'applied', true,
    'already_decided', false
  );
END;
$$;

REVOKE ALL ON FUNCTION data.apply_commercial_decision_request(uuid, text, text, jsonb, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.apply_commercial_decision_request(uuid, text, text, jsonb, uuid, uuid)
  TO service_role;

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
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_req FROM data.commercial_decision_requests WHERE id = p_request_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_req.tenant_id::text) THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF p_outcome = 'declined' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
    RAISE EXCEPTION 'office_decline_reason_required' USING ERRCODE = 'P0001';
  END IF;
  v_evidence := jsonb_strip_nulls(jsonb_build_object(
    'method', 'office',
    'role', 'office_reject',
    'reason', NULLIF(btrim(p_reason), '')
  ));
  RETURN data.apply_commercial_decision_request(
    p_request_id, p_outcome, 'office', v_evidence, p_client_op_id, v_uid
  );
END;
$$;

REVOKE ALL ON FUNCTION api.apply_commercial_decision_office(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_commercial_decision_office(uuid, text, text, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.revoke_commercial_decision_request(
  p_request_id uuid,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_req data.commercial_decision_requests%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = p_request_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_req.tenant_id::text) THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_req.status = 'revoked' THEN
    RETURN v_req.id;
  END IF;
  IF v_req.status <> 'open' THEN
    RAISE EXCEPTION 'decision_request_not_open:%', v_req.status USING ERRCODE = 'P0001';
  END IF;

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
    v_req.tenant_id, v_req.id, 'revoked', 'office', v_uid, v_req.content_hash, p_client_op_id
  );

  RETURN v_req.id;
END;
$$;

REVOKE ALL ON FUNCTION api.revoke_commercial_decision_request(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.revoke_commercial_decision_request(uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Legacy DN reject + agreement immutability for declined
-- ---------------------------------------------------------------------------

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
    IF v_doc.doc_type NOT IN ('quote', 'quote_amendment', 'delivery_note') THEN
      RAISE EXCEPTION 'document_not_rejectable_type:%', v_doc.doc_type USING ERRCODE = 'P0001';
    END IF;
    v_status := 'rejected';
    v_event_type := 'rejected';
    v_payload := data.commercial_event_payload_with_signing(
      jsonb_build_object(
        'rejected_content_hash', v_doc.content_hash,
        'disputed', v_doc.doc_type = 'delivery_note'
      ),
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

-- Immutability: allow pending_signature → declined
CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_renew_ok boolean :=
    current_setting('app.commercial_agreement_renew_unlocked', true) = 'on';
  v_billing_ok boolean :=
    current_setting('app.commercial_agreement_billing_unlocked', true) = 'on';
  v_signing_ok boolean :=
    current_setting('app.commercial_agreement_signing_unlocked', true) = 'on';
BEGIN
  IF OLD.status = 'draft' AND NEW.status = 'signed' THEN
    RAISE EXCEPTION 'agreement_version_not_sent'
      USING ERRCODE = 'P0001';
  END IF;

  IF OLD.status IN ('pending_signature', 'signed', 'declined') THEN
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.agreement_id IS DISTINCT FROM OLD.agreement_id
       OR NEW.version_no IS DISTINCT FROM OLD.version_no
       OR NEW.source_quote_id IS DISTINCT FROM OLD.source_quote_id
       OR NEW.source_quote_content_hash IS DISTINCT FROM OLD.source_quote_content_hash
       OR NEW.source_quote_document_id IS DISTINCT FROM OLD.source_quote_document_id
       OR NEW.full_body_template_id IS DISTINCT FROM OLD.full_body_template_id
       OR NEW.rendered_document_id IS DISTINCT FROM OLD.rendered_document_id
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
       OR NEW.notice_days IS DISTINCT FROM OLD.notice_days
       OR NEW.auto_renew IS DISTINCT FROM OLD.auto_renew
       OR NEW.sla_response_hours IS DISTINCT FROM OLD.sla_response_hours
       OR NEW.sla_resolution_hours IS DISTINCT FROM OLD.sla_resolution_hours
       OR NEW.sla_coverage_notes IS DISTINCT FROM OLD.sla_coverage_notes
       OR NEW.billing_cadence IS DISTINCT FROM OLD.billing_cadence
       OR NEW.billing_amount_cents IS DISTINCT FROM OLD.billing_amount_cents
       OR NEW.billing_currency IS DISTINCT FROM OLD.billing_currency
       OR NEW.billing_anchor_day IS DISTINCT FROM OLD.billing_anchor_day
       OR NEW.terms_snapshot IS DISTINCT FROM OLD.terms_snapshot
       OR (
         NOT v_signing_ok
         AND NEW.signed_document_id IS DISTINCT FROM OLD.signed_document_id
       )
       OR (
         NOT v_billing_ok
         AND NEW.next_billing_on IS DISTINCT FROM OLD.next_billing_on
       )
       OR (
         NOT v_renew_ok
         AND (
           NEW.starts_on IS DISTINCT FROM OLD.starts_on
           OR NEW.ends_on IS DISTINCT FROM OLD.ends_on
         )
       )
       OR (
         NEW.status IS DISTINCT FROM OLD.status
         AND NOT (
           OLD.status = 'pending_signature'
           AND NEW.status IN ('signed', 'declined')
         )
       )
    THEN
      RAISE EXCEPTION 'agreement_version_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Strangler: signing intent → decision request when flagged + linked
-- ---------------------------------------------------------------------------

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
  v_outcome text;
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
  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- New path: declined session with linked request
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
    PERFORM data.apply_commercial_decision_request(
      v_intent.decision_request_id,
      'declined',
      'link',
      v_signature,
      v_intent.client_op_id,
      COALESCE(v_intent.created_by, v_session.operator_user_id)
    );
    UPDATE data.commercial_signing_intents
    SET applied_at = now()
    WHERE id = v_intent.id;
    RETURN;
  END IF;

  IF v_session.status <> 'signed' THEN
    RETURN;
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

    v_signature := jsonb_strip_nulls(jsonb_build_object(
      'method', 'native',
      'provider', 'native',
      'provider_session_id', v_intent.session_id,
      'provider_submission_id', v_intent.submission_id,
      'signer_role', v_session.signer_role,
      'signer_name', v_session.signer_name
    ));

    PERFORM data.apply_commercial_decision_request(
      v_intent.decision_request_id,
      v_outcome,
      CASE WHEN COALESCE(v_session.signing_type, '') = 'presential' THEN 'presential' ELSE 'link' END,
      v_signature,
      v_intent.client_op_id,
      COALESCE(v_intent.created_by, v_session.operator_user_id)
    );

    UPDATE data.commercial_signing_intents
    SET applied_at = now()
    WHERE id = v_intent.id;
    RETURN;
  END IF;

  -- Legacy path (flag off or no linked request)
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

CREATE OR REPLACE FUNCTION data.trg_apply_commercial_signing_intent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.status = 'signed' AND OLD.status IS DISTINCT FROM 'signed' THEN
    PERFORM data.apply_commercial_signing_intent_for_session(NEW.id);
  ELSIF NEW.status = 'declined' AND OLD.status IS DISTINCT FROM 'declined' THEN
    PERFORM data.apply_commercial_signing_intent_for_session(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 9. separate_agreement: prepare from issued|accepted
-- ---------------------------------------------------------------------------

-- CF-21-h: restore auto-link of the quote's project on prepare.
-- 20261198 rewrote prepare_agreement_from_quote and dropped the CT-4 behaviour
-- that inserts into commercial_agreement_projects for v_doc.project_id.
CREATE OR REPLACE FUNCTION api.prepare_agreement_from_quote(
  p_document_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid,
  p_kind text DEFAULT 'specific',
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL,
  p_notice_days int DEFAULT NULL,
  p_auto_renew boolean DEFAULT false,
  p_sla_response_hours int DEFAULT NULL,
  p_sla_resolution_hours int DEFAULT NULL,
  p_sla_coverage_notes text DEFAULT NULL,
  p_billing_cadence text DEFAULT 'none',
  p_billing_amount_cents int DEFAULT NULL,
  p_billing_currency text DEFAULT 'EUR',
  p_billing_anchor_day int DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_event data.commercial_agreement_events;
  v_html text;
  v_missing text[];
  v_hash text;
  v_annex uuid;
  v_kind text := COALESCE(NULLIF(btrim(p_kind), ''), 'specific');
  v_auto_renew boolean := COALESCE(p_auto_renew, false);
  v_sla_notes text := NULLIF(btrim(p_sla_coverage_notes), '');
  v_billing_cadence text := COALESCE(NULLIF(btrim(p_billing_cadence), ''), 'none');
  v_billing_currency text := COALESCE(NULLIF(btrim(p_billing_currency), ''), 'EUR');
  v_next_billing date;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_work_gate IS NULL OR p_work_gate NOT IN ('none', 'require_signed_agreement') THEN
    RAISE EXCEPTION 'invalid_work_gate' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind NOT IN ('specific', 'recurring', 'framework') THEN
    RAISE EXCEPTION 'invalid_agreement_kind' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind IN ('recurring', 'framework') AND p_ends_on IS NULL THEN
    RAISE EXCEPTION 'recurring_ends_on_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_starts_on IS NOT NULL AND p_ends_on IS NOT NULL AND p_ends_on < p_starts_on THEN
    RAISE EXCEPTION 'invalid_agreement_dates' USING ERRCODE = 'P0001';
  END IF;
  IF p_notice_days IS NOT NULL AND p_notice_days <= 0 THEN
    RAISE EXCEPTION 'invalid_notice_days' USING ERRCODE = 'P0001';
  END IF;
  IF p_sla_response_hours IS NOT NULL AND p_sla_response_hours <= 0 THEN
    RAISE EXCEPTION 'invalid_sla_response_hours' USING ERRCODE = 'P0001';
  END IF;
  IF p_sla_resolution_hours IS NOT NULL AND p_sla_resolution_hours <= 0 THEN
    RAISE EXCEPTION 'invalid_sla_resolution_hours' USING ERRCODE = 'P0001';
  END IF;

  IF v_billing_cadence NOT IN ('none', 'monthly', 'quarterly', 'yearly') THEN
    RAISE EXCEPTION 'invalid_billing_cadence' USING ERRCODE = 'P0001';
  END IF;
  IF v_billing_cadence = 'none' THEN
    IF p_billing_amount_cents IS NOT NULL THEN
      RAISE EXCEPTION 'billing_amount_requires_cadence' USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_billing_amount_cents IS NULL OR p_billing_amount_cents <= 0 THEN
    RAISE EXCEPTION 'billing_amount_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_billing_anchor_day IS NOT NULL AND (p_billing_anchor_day < 1 OR p_billing_anchor_day > 28) THEN
    RAISE EXCEPTION 'invalid_billing_anchor_day' USING ERRCODE = 'P0001';
  END IF;
  IF v_billing_cadence <> 'none' THEN
    v_next_billing := COALESCE(p_starts_on, CURRENT_DATE);
  ELSE
    v_next_billing := NULL;
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'quote_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status NOT IN ('issued', 'accepted') THEN
    RAISE EXCEPTION 'quote_not_preparable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.formalization_mode IS DISTINCT FROM 'separate_agreement' THEN
    RAISE EXCEPTION 'quote_not_separate_agreement' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.content_hash IS NULL OR btrim(v_doc.content_hash) = '' THEN
    RAISE EXCEPTION 'quote_content_hash_missing' USING ERRCODE = 'P0001';
  END IF;

  -- Typed replay: same op must be a 'prepared' event for this same quote.
  v_event := data.commercial_agreement_replay_event(
    v_doc.tenant_id, p_client_op_id, 'prepared'
  );
  IF v_event.id IS NOT NULL THEN
    IF (v_event.payload->>'source_quote_id') IS DISTINCT FROM v_doc.id::text THEN
      RAISE EXCEPTION 'client_op_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_event.agreement_id;
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'agreement_template_required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = p_template_id
      AND t.is_active AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (t.tenant_id = v_doc.tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
  ) THEN
    RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT l.html_content INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id
    AND l.locale = COALESCE(NULLIF(btrim(v_doc.locale), ''), 'ca')
    AND l.is_active AND l.mime_type = 'text/html';
  IF v_html IS NULL THEN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id AND l.locale = 'ca'
      AND l.is_active AND l.mime_type = 'text/html';
  END IF;
  v_missing := data.validate_commercial_agreement_template_locale(v_html, 'text/html');
  IF v_html IS NULL OR COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_invalid'
      USING ERRCODE = 'P0001', DETAIL = array_to_string(v_missing, ', ');
  END IF;

  v_hash := encode(
    extensions.digest(
      convert_to(
        v_doc.content_hash || '|' || COALESCE(v_doc.doc_number, '') || '|' || p_template_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  v_annex := v_doc.rendered_document_id;

  SELECT a.* INTO v_agreement
  FROM data.commercial_agreements a
  WHERE a.tenant_id = v_doc.tenant_id
    AND a.source_quote_id = v_doc.id
    AND a.status <> 'cancelled'
  ORDER BY a.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    IF v_agreement.client_id IS DISTINCT FROM v_doc.client_id THEN
      RAISE EXCEPTION 'agreement_client_mismatch' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_version
    FROM data.commercial_agreement_versions
    WHERE agreement_id = v_agreement.id
    ORDER BY version_no DESC
    LIMIT 1;
    IF v_version.status IN ('pending_signature', 'signed') THEN
      RETURN v_agreement.id;
    END IF;

    UPDATE data.commercial_agreements
    SET work_gate = p_work_gate, kind = v_kind
    WHERE id = v_agreement.id;

    UPDATE data.commercial_agreement_versions
    SET source_quote_content_hash = v_doc.content_hash,
        source_quote_document_id = v_annex,
        full_body_template_id = p_template_id,
        content_hash = v_hash,
        rendered_document_id = NULL,
        starts_on = p_starts_on,
        ends_on = p_ends_on,
        notice_days = p_notice_days,
        auto_renew = v_auto_renew,
        sla_response_hours = p_sla_response_hours,
        sla_resolution_hours = p_sla_resolution_hours,
        sla_coverage_notes = v_sla_notes,
        billing_cadence = v_billing_cadence,
        billing_amount_cents = CASE WHEN v_billing_cadence = 'none' THEN NULL ELSE p_billing_amount_cents END,
        billing_currency = v_billing_currency,
        billing_anchor_day = p_billing_anchor_day,
        next_billing_on = v_next_billing
    WHERE id = v_version.id;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
      jsonb_build_object(
        'source_quote_id', v_doc.id,
        'full_body_template_id', p_template_id,
        'kind', v_kind,
        'auto_renew', v_auto_renew,
        'sla_response_hours', p_sla_response_hours,
        'sla_resolution_hours', p_sla_resolution_hours,
        'billing_cadence', v_billing_cadence,
        'billing_amount_cents', p_billing_amount_cents
      )
    );
    
    IF v_doc.project_id IS NOT NULL THEN
      INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
      VALUES (v_doc.tenant_id, v_agreement.id, v_doc.project_id)
      ON CONFLICT (agreement_id, project_id) DO NOTHING;
    END IF;
    RETURN v_agreement.id;
  END IF;

  -- Race-safe insert: a concurrent prepare for the same quote may win the unique
  -- index uq_commercial_agreements_tenant_source_quote_active. The loser returns
  -- the winner's agreement (no second agreement, no duplicate prepared event).
  BEGIN
    INSERT INTO data.commercial_agreements (
      tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by
    ) VALUES (
      v_doc.tenant_id, v_doc.client_id, v_kind, 'pending_start',
      v_doc.id, p_work_gate, v_uid
    ) RETURNING * INTO v_agreement;
  EXCEPTION WHEN unique_violation THEN
    SELECT a.* INTO v_agreement
    FROM data.commercial_agreements a
    WHERE a.tenant_id = v_doc.tenant_id
      AND a.source_quote_id = v_doc.id
      AND a.status <> 'cancelled'
    ORDER BY a.created_at DESC
    LIMIT 1;
    IF NOT FOUND THEN
      RAISE;
    END IF;
    IF v_agreement.client_id IS DISTINCT FROM v_doc.client_id THEN
      RAISE EXCEPTION 'agreement_client_mismatch' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_agreement.id;
  END;

  INSERT INTO data.commercial_agreement_versions (
    tenant_id, agreement_id, version_no, status,
    source_quote_id, source_quote_content_hash, source_quote_document_id,
    full_body_template_id, content_hash,
    starts_on, ends_on, notice_days, auto_renew,
    sla_response_hours, sla_resolution_hours, sla_coverage_notes,
    billing_cadence, billing_amount_cents, billing_currency, billing_anchor_day, next_billing_on
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 1, 'draft',
    v_doc.id, v_doc.content_hash, v_annex,
    p_template_id, v_hash,
    p_starts_on, p_ends_on, p_notice_days, v_auto_renew,
    p_sla_response_hours, p_sla_resolution_hours, v_sla_notes,
    v_billing_cadence,
    CASE WHEN v_billing_cadence = 'none' THEN NULL ELSE p_billing_amount_cents END,
    v_billing_currency, p_billing_anchor_day, v_next_billing
  ) RETURNING * INTO v_version;

  UPDATE data.commercial_agreements
  SET active_version_id = v_version.id
  WHERE id = v_agreement.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
    jsonb_build_object(
      'source_quote_id', v_doc.id,
      'full_body_template_id', p_template_id,
      'kind', v_kind,
      'auto_renew', v_auto_renew,
      'sla_response_hours', p_sla_response_hours,
      'sla_resolution_hours', p_sla_resolution_hours,
      'billing_cadence', v_billing_cadence,
      'billing_amount_cents', p_billing_amount_cents
    )
  );

  
  IF v_doc.project_id IS NOT NULL THEN
    INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
    VALUES (v_doc.tenant_id, v_agreement.id, v_doc.project_id)
    ON CONFLICT (agreement_id, project_id) DO NOTHING;
    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'project_linked', v_uid,
      jsonb_build_object('project_id', v_doc.project_id)
    );
  END IF;
  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text, text, int, text, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text, text, int, text, int
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';


-- ---------------------------------------------------------------------------
-- 10. finalize: accept issued separate_agreement quote atomically
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.finalize_commercial_agreement_version(
  p_version_id uuid,
  p_signed_document_id uuid DEFAULT NULL,
  p_actor_id uuid DEFAULT NULL,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_doc_id uuid;
  v_doc_tenant uuid;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_activate boolean;
BEGIN
  SELECT * INTO v_version
  FROM data.commercial_agreement_versions
  WHERE id = p_version_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_agreement
  FROM data.commercial_agreements
  WHERE id = v_version.agreement_id
  FOR UPDATE;

  IF v_version.status = 'signed' THEN
    IF p_signed_document_id IS NOT NULL
       AND v_version.signed_document_id IS DISTINCT FROM p_signed_document_id THEN
      RAISE EXCEPTION 'signed_document_conflict' USING ERRCODE = 'P0001';
    END IF;
    IF v_agreement.status IN ('active', 'finished', 'cancelled') THEN
      IF v_agreement.status = 'active' THEN
        PERFORM data.commercial_agreement_ensure_cycle(v_agreement.id);
      END IF;
      -- still accept issued source quote if needed (CF-28)
    END IF;
  ELSIF v_version.status = 'pending_signature' THEN
    v_doc_id := COALESCE(p_signed_document_id, v_version.signed_document_id);
    IF v_doc_id IS NULL THEN
      RAISE EXCEPTION 'signed_document_required' USING ERRCODE = 'P0001';
    END IF;

    SELECT d.tenant_id INTO v_doc_tenant
    FROM data.documents d
    WHERE d.id = v_doc_id;
    IF NOT FOUND OR v_doc_tenant IS DISTINCT FROM v_version.tenant_id THEN
      RAISE EXCEPTION 'signed_document_invalid' USING ERRCODE = 'P0001';
    END IF;

    PERFORM set_config('app.commercial_agreement_signing_unlocked', 'on', true);
    UPDATE data.commercial_agreement_versions
    SET status = 'signed',
        signed_document_id = v_doc_id,
        updated_at = now()
    WHERE id = v_version.id;
    PERFORM set_config('app.commercial_agreement_signing_unlocked', 'off', true);

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_version.tenant_id, v_version.agreement_id, 'signed', p_actor_id,
      jsonb_build_object(
        'version_id', v_version.id,
        'signed_document_id', v_doc_id
      )
    );
  ELSE
    RAISE EXCEPTION 'agreement_version_not_sent' USING ERRCODE = 'P0001';
  END IF;

  IF v_agreement.status NOT IN ('cancelled', 'finished') THEN
    v_activate := (v_version.starts_on IS NULL OR v_version.starts_on <= v_as_of);

    IF v_activate AND v_agreement.status IS DISTINCT FROM 'active' THEN
      UPDATE data.commercial_agreements
      SET status = 'active'
      WHERE id = v_agreement.id;

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, payload
      ) VALUES (
        v_version.tenant_id, v_version.agreement_id, 'activated', p_actor_id,
        jsonb_build_object(
          'version_id', v_version.id,
          'starts_on', v_version.starts_on,
          'as_of', v_as_of
        )
      );
    ELSIF NOT v_activate AND v_agreement.status = 'active' THEN
      UPDATE data.commercial_agreements
      SET status = 'pending_start'
      WHERE id = v_agreement.id;
    END IF;

    PERFORM data.commercial_agreement_ensure_cycle(v_agreement.id);
  END IF;

  -- CF-28: agreement signed ⇒ accept issued separate_agreement quote (idempotent).
  UPDATE data.commercial_documents d
  SET status = 'accepted', updated_at = now()
  WHERE d.id = v_version.source_quote_id
    AND d.status = 'issued'
    AND d.formalization_mode = 'separate_agreement';
  IF FOUND THEN
    INSERT INTO data.commercial_document_events (
      tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
    )
    SELECT
      d.tenant_id, d.id, 'accepted', p_actor_id, d.content_hash, gen_random_uuid(),
      jsonb_build_object(
        'accepted_content_hash', d.content_hash,
        'via_agreement_version', v_version.id
      )
    FROM data.commercial_documents d
    WHERE d.id = v_version.source_quote_id;
    IF (SELECT project_id FROM data.commercial_documents WHERE id = v_version.source_quote_id) IS NOT NULL THEN
      PERFORM api.recompute_project_authorized_total(
        (SELECT project_id FROM data.commercial_documents WHERE id = v_version.source_quote_id)
      );
    END IF;
  END IF;

  RETURN v_agreement.id;
END;
$$;

COMMENT ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date) IS
  'CF-21-h3: com h2 (pending_signature → signed amb PDF signat, tenant-checked, signed_document_conflict) i a més crea el cicle 1 de l''acord.';

REVOKE ALL ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 11. Public decline: commercial request -> declined (not cancelled)
-- ---------------------------------------------------------------------------
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
  v_intent          data.commercial_signing_intents%ROWTYPE;
  v_new_status      text := 'cancelled';
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

  IF v_sess.status IN ('cancelled', 'declined') THEN
    RETURN jsonb_build_object('success', true, 'already_declined', true);
  END IF;

  IF v_sess.expires_at < now() THEN
    RETURN jsonb_build_object('error', 'token_expired');
  END IF;

  SELECT * INTO v_intent
  FROM data.commercial_signing_intents
  WHERE session_id = v_sess.id
  LIMIT 1;

  IF FOUND
     AND v_intent.decision_request_id IS NOT NULL
     AND data.commercial_decision_requests_enabled(v_intent.tenant_id)
  THEN
    v_new_status := 'declined';
  END IF;

  UPDATE data.document_signing_sessions
     SET status = v_new_status,
         timestamps = COALESCE(timestamps, '{}'::jsonb)
           || jsonb_build_object('decline_reason', NULLIF(btrim(p_reason), ''), 'declined_at', now()),
         updated_at = now()
   WHERE id = v_sess.id;

  IF v_sess.signing_group_id IS NOT NULL THEN
    UPDATE data.document_signing_sessions
       SET status = v_new_status, updated_at = now()
     WHERE signing_group_id = v_sess.signing_group_id
       AND status NOT IN ('signed', 'cancelled', 'declined');

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
    'submission_id',        v_submission_id,
    'status',               v_new_status
  );
END;
$$;

REVOKE ALL ON FUNCTION api.decline_signing_session_public(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.decline_signing_session_public(text, text)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
