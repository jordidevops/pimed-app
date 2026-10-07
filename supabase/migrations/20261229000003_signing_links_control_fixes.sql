-- CS-D58–D60 fixes from review:
-- - strip api.signing_submitters.signing_url
-- - create_signing_session: token only for service_role
-- - whatsapp_portal_nudge / portal / presential: no access token
-- - grant required for whatsapp_portal_nudge
-- - token_once TTL + purge
-- - get_my_pending_signing_url scoped to monthly attendance submissions
-- - email_logs: persist event_type for durable redaction

-- ---------------------------------------------------------------------------
-- 0. token_once TTL
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_decision_token_once
  ADD COLUMN IF NOT EXISTS expires_at timestamptz;

UPDATE data.commercial_decision_token_once
SET expires_at = created_at + interval '24 hours'
WHERE expires_at IS NULL;

ALTER TABLE data.commercial_decision_token_once
  ALTER COLUMN expires_at SET DEFAULT (now() + interval '24 hours');

ALTER TABLE data.commercial_decision_token_once
  ALTER COLUMN expires_at SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_commercial_decision_token_once_expires
  ON data.commercial_decision_token_once (expires_at);

CREATE OR REPLACE FUNCTION data.purge_expired_commercial_decision_token_once()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_n integer;
BEGIN
  DELETE FROM data.commercial_decision_token_once
  WHERE expires_at < now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

REVOKE ALL ON FUNCTION data.purge_expired_commercial_decision_token_once() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.purge_expired_commercial_decision_token_once() TO service_role;

-- ---------------------------------------------------------------------------
-- 1. api.signing_submitters — strip signing_url for authenticated
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.signing_submitters CASCADE;

CREATE VIEW api.signing_submitters WITH (security_invoker = true) AS
  SELECT
    st.id,
    st.submission_id,
    st.tenant_id,
    st.signer_order,
    st.role,
    st.email,
    st.name,
    st.external_submitter_id,
    NULL::text AS signing_url,
    st.status,
    st.notified_at,
    st.email_log_id,
    st.opened_at,
    st.completed_at,
    st.created_at,
    st.updated_at
  FROM data.signing_submitters st;

GRANT SELECT, INSERT, UPDATE ON api.signing_submitters TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.signing_submitters TO service_role;

CREATE OR REPLACE VIEW api.signing_submitters_internal WITH (security_invoker = true) AS
  SELECT
    st.id,
    st.submission_id,
    st.tenant_id,
    st.signer_order,
    st.role,
    st.email,
    st.name,
    st.external_submitter_id,
    st.signing_url,
    st.status,
    st.notified_at,
    st.email_log_id,
    st.opened_at,
    st.completed_at,
    st.created_at,
    st.updated_at
  FROM data.signing_submitters st;

REVOKE ALL ON api.signing_submitters_internal FROM PUBLIC;
REVOKE ALL ON api.signing_submitters_internal FROM authenticated;
GRANT SELECT ON api.signing_submitters_internal TO service_role;

CREATE OR REPLACE FUNCTION data.trg_api_signing_submitters_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_keep data.signing_submitters%ROWTYPE;
BEGIN
  SELECT * INTO v_keep FROM data.signing_submitters WHERE id = OLD.id;

  UPDATE data.signing_submitters
  SET
    status                 = NEW.status,
    notified_at            = NEW.notified_at,
    email_log_id           = NEW.email_log_id,
    opened_at              = NEW.opened_at,
    completed_at           = NEW.completed_at,
    updated_at             = NEW.updated_at,
    external_submitter_id  = NEW.external_submitter_id,
    signing_url            = COALESCE(NULLIF(NEW.signing_url, ''), v_keep.signing_url),
    role                   = NEW.role,
    email                  = NEW.email,
    name                   = NEW.name,
    signer_order           = NEW.signer_order
  WHERE id = NEW.id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_api_signing_submitters_update ON api.signing_submitters;
CREATE TRIGGER trg_api_signing_submitters_update
  INSTEAD OF UPDATE ON api.signing_submitters
  FOR EACH ROW EXECUTE FUNCTION data.trg_api_signing_submitters_update();

-- ---------------------------------------------------------------------------
-- 2. create_signing_session — token only for service_role
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.create_signing_session(
  uuid, uuid, text, text, text, text, uuid, int, uuid, int, int
);

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
  p_total_signers       int  DEFAULT 1,
  p_operator_user_id    uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_operator   uuid;
  v_token      text;
  v_session_id uuid;
  v_expires_at timestamptz;
  v_token_days int;
  v_is_service boolean := COALESCE(auth.role(), '') = 'service_role';
BEGIN
  IF NOT v_is_service THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.tenant_members
       WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_active = true
         AND role IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Forbidden: requires owner or manager role';
    END IF;
  END IF;

  v_operator := COALESCE(p_operator_user_id, v_user_id);

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
    v_operator, v_expires_at, p_pdf_job_id,
    p_signing_group_id,
    COALESCE(p_signer_order, 0),
    GREATEST(COALESCE(p_total_signers, 1), 1)
  )
  RETURNING id INTO v_session_id;

  IF p_signing_type = 'remote' THEN
    INSERT INTO data.document_signature_evidences (session_id, event_type)
    VALUES (v_session_id, 'link_sent');
  END IF;

  -- CS-D58: plaintext token only for service_role (Edge workers)
  RETURN jsonb_build_object(
    'session_id',        v_session_id,
    'token',             CASE WHEN v_is_service THEN v_token ELSE NULL END,
    'expires_at',        v_expires_at,
    'signing_type',      p_signing_type,
    'signing_group_id',  p_signing_group_id,
    'signer_order',      COALESCE(p_signer_order, 0),
    'total_signers',     GREATEST(COALESCE(p_total_signers, 1), 1)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_signing_session(
  uuid, uuid, text, text, text, text, uuid, int, uuid, int, int, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_signing_session(
  uuid, uuid, text, text, text, text, uuid, int, uuid, int, int, uuid
) TO authenticated, service_role;

-- Legacy 8-arg overload: also redact token for authenticated
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api'
      AND p.proname = 'create_signing_session'
      AND pg_get_function_identity_arguments(p.oid) =
        'p_tenant_id uuid, p_document_version_id uuid, p_signing_type text, p_signer_name text, p_signer_email text, p_signer_role text, p_pdf_job_id uuid, p_expires_days integer'
  ) THEN
    EXECUTE $fn$
      CREATE OR REPLACE FUNCTION api.create_signing_session(
        p_tenant_id uuid,
        p_document_version_id uuid,
        p_signing_type text,
        p_signer_name text DEFAULT NULL,
        p_signer_email text DEFAULT NULL,
        p_signer_role text DEFAULT NULL,
        p_pdf_job_id uuid DEFAULT NULL,
        p_expires_days int DEFAULT NULL
      )
      RETURNS jsonb
      LANGUAGE plpgsql SECURITY DEFINER
      SET search_path = data, extensions, public
      AS $body$
      BEGIN
        RETURN api.create_signing_session(
          p_tenant_id, p_document_version_id, p_signing_type,
          p_signer_name, p_signer_email, p_signer_role,
          p_pdf_job_id, p_expires_days,
          NULL::uuid, 0, 1
        );
      END;
      $body$;
    $fn$;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. create_commercial_decision_delivery — no token for non-email; grant for WA
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
  v_channel text := NULLIF(btrim(p_channel), '');
  v_needs_token boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF v_channel = 'copy_link' THEN
    RAISE EXCEPTION 'invalid_delivery_channel' USING ERRCODE = 'P0001';
  END IF;
  IF v_channel = 'whatsapp' THEN
    v_channel := 'whatsapp_portal_nudge';
  END IF;
  IF v_channel NOT IN ('email', 'whatsapp_portal_nudge', 'portal', 'presential') THEN
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
    RAISE EXCEPTION 'decision_request_not_open' USING ERRCODE = 'P0001';
  END IF;

  -- CS-D13: WhatsApp portal nudge requires an active customer portal grant
  IF v_channel = 'whatsapp_portal_nudge' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM data.customer_access_grants g
      WHERE g.tenant_id = v_req.tenant_id
        AND g.client_account_contact_id = v_req.client_account_contact_id
        AND g.revoked_at IS NULL
    ) THEN
      RAISE EXCEPTION 'portal_grant_required' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_idem := 'cdr_delivery:' || p_request_id::text || ':' || v_channel || ':' || p_client_op_id::text;

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
    v_req.tenant_id, v_req.id, v_channel, p_contact_point_id, v_locale, 'prepared', v_idem
  ) RETURNING id INTO v_delivery_id;

  -- Only email deliveries mint a bearer usable on /sign/:token
  v_needs_token := v_channel = 'email';
  IF v_needs_token THEN
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_hash := encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex');

    INSERT INTO data.commercial_decision_access_tokens (
      tenant_id, request_id, delivery_id, token_hash, status, expires_at
    ) VALUES (
      v_req.tenant_id, v_req.id, v_delivery_id, v_hash, 'active',
      LEAST(v_req.expires_at, now() + interval '30 days')
    );

    INSERT INTO data.commercial_decision_token_once (delivery_id, raw_token, expires_at)
    VALUES (v_delivery_id, v_token, now() + interval '24 hours');
  END IF;

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, via, actor_id, content_hash, client_op_id, evidence
  ) VALUES (
    v_req.tenant_id, v_req.id, 'delivery_created', v_channel, v_uid, v_req.content_hash,
    p_client_op_id,
    jsonb_build_object('delivery_id', v_delivery_id, 'channel', v_channel, 'has_token', v_needs_token)
  );

  RETURN jsonb_build_object(
    'delivery_id', v_delivery_id,
    'raw_token', NULL,
    'already_created', false
  );
END;
$$;

-- Helper for tenant UI preflight (no secrets)
CREATE OR REPLACE FUNCTION api.has_active_customer_portal_grant_for_request(p_request_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_req data.commercial_decision_requests%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;
  SELECT * INTO v_req FROM data.commercial_decision_requests WHERE id = p_request_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_req.tenant_id::text) THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT 1
    FROM data.customer_access_grants g
    WHERE g.tenant_id = v_req.tenant_id
      AND g.client_account_contact_id = v_req.client_account_contact_id
      AND g.revoked_at IS NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.has_active_customer_portal_grant_for_document(p_document_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid;
  v_client uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;
  SELECT d.tenant_id, d.client_id
  INTO v_tenant, v_client
  FROM data.commercial_documents d
  WHERE d.id = p_document_id;
  IF v_tenant IS NULL OR v_client IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant::text) THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT 1
    FROM data.customer_access_grants g
    WHERE g.tenant_id = v_tenant
      AND g.client_account_contact_id = v_client
      AND g.revoked_at IS NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION api.has_active_customer_portal_grant_for_request(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.has_active_customer_portal_grant_for_document(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.has_active_customer_portal_grant_for_request(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.has_active_customer_portal_grant_for_document(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. email_logs: durable event_type column for redaction
-- ---------------------------------------------------------------------------
ALTER TABLE data.email_logs
  ADD COLUMN IF NOT EXISTS event_type text;

COMMENT ON COLUMN data.email_logs.event_type IS
  'Immutable event_type snapshot at enqueue (CS-D58 email body redaction).';

DROP VIEW IF EXISTS api.email_logs;

CREATE VIEW api.email_logs
  WITH (security_invoker = true) AS
  SELECT
    el.id,
    el.tenant_id,
    el.site_id,
    el.idempotency_key,
    el.status,
    el.email_type,
    el.from_email,
    el.from_name,
    el.to_emails,
    el.cc_emails,
    el.bcc_emails,
    el.reply_to,
    el.subject,
    CASE
      WHEN COALESCE(el.event_type, et.event_type, '') LIKE 'signing.%'
        OR COALESCE(el.event_type, et.event_type, '') LIKE 'commercial.decision%'
        OR COALESCE(el.html_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.text_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.html_body, '') ILIKE '%docuseal%'
        OR COALESCE(el.text_body, '') ILIKE '%docuseal%'
      THEN NULL
      ELSE el.html_body
    END AS html_body,
    CASE
      WHEN COALESCE(el.event_type, et.event_type, '') LIKE 'signing.%'
        OR COALESCE(el.event_type, et.event_type, '') LIKE 'commercial.decision%'
        OR COALESCE(el.html_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.text_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.html_body, '') ILIKE '%docuseal%'
        OR COALESCE(el.text_body, '') ILIKE '%docuseal%'
      THEN NULL
      ELSE el.text_body
    END AS text_body,
    el.provider,
    el.provider_message_id,
    el.attempt_count,
    el.is_dead_letter,
    el.last_error,
    el.error_history,
    el.tags,
    el.scheduled_at,
    el.created_at,
    el.sent_at,
    el.delivered_at,
    el.template_id,
    COALESCE(el.event_type, et.event_type) AS event_type,
    CASE
      WHEN COALESCE(el.event_type, et.event_type, '') LIKE 'signing.%'
        OR COALESCE(el.event_type, et.event_type, '') LIKE 'commercial.decision%'
        OR COALESCE(el.html_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.text_body, '') ILIKE '%/sign/%'
        OR COALESCE(el.html_body, '') ILIKE '%docuseal%'
        OR COALESCE(el.text_body, '') ILIKE '%docuseal%'
      THEN true
      ELSE false
    END AS body_redacted
  FROM data.email_logs el
  LEFT JOIN data.email_templates et ON et.id = el.template_id;

GRANT SELECT ON api.email_logs TO authenticated;
GRANT SELECT ON api.email_logs TO service_role;

-- Backfill event_type from template where possible
UPDATE data.email_logs el
SET event_type = et.event_type
FROM data.email_templates et
WHERE el.template_id = et.id
  AND el.event_type IS NULL
  AND et.event_type IS NOT NULL;

CREATE OR REPLACE FUNCTION data.trg_email_logs_stamp_event_type()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NEW.event_type IS NULL AND NEW.template_id IS NOT NULL THEN
    SELECT et.event_type INTO NEW.event_type
    FROM data.email_templates et
    WHERE et.id = NEW.template_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_email_logs_stamp_event_type ON data.email_logs;
CREATE TRIGGER trg_email_logs_stamp_event_type
  BEFORE INSERT OR UPDATE OF template_id ON data.email_logs
  FOR EACH ROW EXECUTE FUNCTION data.trg_email_logs_stamp_event_type();

-- ---------------------------------------------------------------------------
-- 5. get_my_pending_signing_url — monthly attendance only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_my_pending_signing_url(p_submission_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_tenant uuid;
  v_signers jsonb;
  v_url text;
  v_status text;
  v_linked boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_submission_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT lower(btrim(u.email)) INTO v_email
  FROM auth.users u
  WHERE u.id = v_uid;

  IF v_email IS NULL OR v_email = '' THEN
    RETURN NULL;
  END IF;

  SELECT ss.tenant_id, ss.signers, ss.status
  INTO v_tenant, v_signers, v_status
  FROM data.signing_submissions ss
  WHERE ss.id = p_submission_id;

  IF v_tenant IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_tenant
      AND tm.user_id = v_uid
      AND tm.is_active = true
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
  END IF;

  -- CS-D58 §4: only attendance monthly report submissions
  SELECT EXISTS (
    SELECT 1
    FROM data.attendance_monthly_reports amr
    WHERE amr.signing_submission_id = p_submission_id
      AND amr.tenant_id = v_tenant
  ) INTO v_linked;

  IF NOT v_linked THEN
    RETURN NULL;
  END IF;

  IF v_status IN ('completed', 'declined', 'expired', 'cancelled', 'error') THEN
    RETURN NULL;
  END IF;

  SELECT x.url
  INTO v_url
  FROM (
    SELECT
      NULLIF(e->>'signing_url', '') AS url,
      COALESCE((e->>'order')::int, 0) AS ord
    FROM jsonb_array_elements(COALESCE(v_signers, '[]'::jsonb)) e
    WHERE lower(btrim(COALESCE(e->>'email', ''))) = v_email
      AND lower(COALESCE(e->>'status', 'pending')) NOT IN ('completed', 'signed')
  ) x
  WHERE x.url IS NOT NULL
  ORDER BY x.ord
  LIMIT 1;

  RETURN v_url;
END;
$$;

NOTIFY pgrst, 'reload schema';
