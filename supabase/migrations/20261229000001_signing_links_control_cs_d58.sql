-- CS-D58 / CS-D13: platform-controlled signing links
-- - raw_token never returned to authenticated clients
-- - ephemeral token store for email enqueue (server-side only)
-- - api.signing_submissions strips signing URLs
-- - allow channel whatsapp_portal_nudge

-- ---------------------------------------------------------------------------
-- 0. Widen delivery channel check
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_decision_deliveries
  DROP CONSTRAINT IF EXISTS commercial_decision_deliveries_channel_check;

ALTER TABLE data.commercial_decision_deliveries
  ADD CONSTRAINT commercial_decision_deliveries_channel_check
  CHECK (channel IN (
    'email',
    'whatsapp',
    'whatsapp_portal_nudge',
    'copy_link',
    'portal',
    'presential'
  ));

-- ---------------------------------------------------------------------------
-- 1. Ephemeral plaintext token (service_role / SECURITY DEFINER only)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_decision_token_once (
  delivery_id uuid PRIMARY KEY
    REFERENCES data.commercial_decision_deliveries(id) ON DELETE CASCADE,
  raw_token   text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON data.commercial_decision_token_once FROM PUBLIC;
REVOKE ALL ON data.commercial_decision_token_once FROM authenticated;
GRANT ALL ON data.commercial_decision_token_once TO service_role;

COMMENT ON TABLE data.commercial_decision_token_once IS
  'CS-D58: plaintext delivery token readable only by SECURITY DEFINER enqueue; never exposed via api.*';

-- ---------------------------------------------------------------------------
-- 2. create_commercial_decision_delivery — no raw_token to client
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
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  -- CS-D13: copy_link removed from product; keep accepting legacy for old clients → map away
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
    v_req.tenant_id, v_req.id, v_channel, p_contact_point_id, v_locale, 'prepared', v_idem
  ) RETURNING id INTO v_delivery_id;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_hash := encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex');

  INSERT INTO data.commercial_decision_access_tokens (
    tenant_id, request_id, delivery_id, token_hash, status, expires_at
  ) VALUES (
    v_req.tenant_id, v_req.id, v_delivery_id, v_hash, 'active',
    LEAST(v_req.expires_at, now() + interval '30 days')
  );

  INSERT INTO data.commercial_decision_token_once (delivery_id, raw_token)
  VALUES (v_delivery_id, v_token);

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, via, actor_id, content_hash, client_op_id, evidence
  ) VALUES (
    v_req.tenant_id, v_req.id, 'delivery_created', v_channel, v_uid, v_req.content_hash,
    p_client_op_id,
    jsonb_build_object('delivery_id', v_delivery_id, 'channel', v_channel)
  );

  -- CS-D58: never return plaintext token to authenticated JWT
  RETURN jsonb_build_object(
    'delivery_id', v_delivery_id,
    'raw_token', NULL,
    'already_created', false
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. enqueue email — resolve token server-side; ignore client decision URL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.enqueue_commercial_decision_delivery_email(
  p_delivery_id uuid,
  p_to_email text,
  p_decision_url text,
  p_recipient_name text DEFAULT NULL,
  p_locale text DEFAULT NULL,
  p_portal_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_delivery data.commercial_decision_deliveries%ROWTYPE;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_tenant_name text;
  v_locale text;
  v_email text := lower(btrim(COALESCE(p_to_email, '')));
  v_url text;
  v_token text;
  v_origin text;
  v_log_id uuid;
  v_snap jsonb;
  v_doc_type text;
  v_kind text;
  v_number text;
  v_client text;
  v_total text;
  v_valid_until text;
  v_expires text;
  v_show_prices boolean;
  v_currency text;
  v_total_num numeric;
  v_idem text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_email = '' OR position('@' IN v_email) = 0 THEN
    RAISE EXCEPTION 'recipient_email_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_delivery
  FROM data.commercial_decision_deliveries
  WHERE id = p_delivery_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_delivery.tenant_id::text) THEN
    RAISE EXCEPTION 'decision_delivery_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_delivery.channel <> 'email' THEN
    RAISE EXCEPTION 'decision_delivery_not_email' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = v_delivery.request_id
  FOR UPDATE;
  IF NOT FOUND OR v_req.status <> 'open' THEN
    RAISE EXCEPTION 'decision_request_not_open' USING ERRCODE = 'P0001';
  END IF;

  IF v_delivery.status = 'queued' AND v_delivery.email_log_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'delivery_id', v_delivery.id,
      'email_log_id', v_delivery.email_log_id,
      'status', v_delivery.status,
      'already_queued', true
    );
  END IF;
  IF v_delivery.status NOT IN ('prepared', 'failed') THEN
    RAISE EXCEPTION 'decision_delivery_not_queueable:%', v_delivery.status USING ERRCODE = 'P0001';
  END IF;

  -- CS-D58: build decision URL from server-held token; never trust client URL as secret source
  SELECT raw_token INTO v_token
  FROM data.commercial_decision_token_once
  WHERE delivery_id = v_delivery.id
  FOR UPDATE;
  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RAISE EXCEPTION 'decision_token_unavailable' USING ERRCODE = 'P0001';
  END IF;

  -- p_decision_url may carry only the public origin (https://host) or a full URL (legacy).
  -- Strip to origin; append /sign/{token} ourselves.
  v_origin := NULLIF(btrim(COALESCE(p_decision_url, '')), '');
  IF v_origin IS NULL OR v_origin !~* '^https?://' THEN
    RAISE EXCEPTION 'decision_url_invalid' USING ERRCODE = 'P0001';
  END IF;
  -- If client still passes full /sign/... URL, use its origin only
  IF v_origin ~* '/sign/' THEN
    v_origin := regexp_replace(v_origin, '/sign/.*$', '');
  END IF;
  v_origin := rtrim(v_origin, '/');
  v_url := v_origin || '/sign/' || v_token;

  SELECT COALESCE(NULLIF(btrim(t.name), ''), 'PiMed')
  INTO v_tenant_name
  FROM data.tenants t
  WHERE t.id = v_req.tenant_id;

  v_locale := COALESCE(
    NULLIF(btrim(p_locale), ''),
    NULLIF(btrim(v_delivery.locale), ''),
    'ca'
  );
  v_snap := COALESCE(v_req.snapshot_json, '{}'::jsonb);
  v_doc_type := COALESCE(v_snap->>'doc_type', v_snap->>'kind', 'document');
  v_number := COALESCE(NULLIF(btrim(v_snap->>'doc_number'), ''), '—');
  v_show_prices := COALESCE((v_snap->>'show_prices')::boolean, true);
  v_currency := COALESCE(NULLIF(btrim(v_snap->>'currency'), ''), 'EUR');
  BEGIN
    v_total_num := NULLIF(v_snap->>'total', '')::numeric;
  EXCEPTION WHEN others THEN
    v_total_num := NULL;
  END;
  v_valid_until := NULLIF(btrim(v_snap->>'valid_until'), '');

  IF v_req.commercial_document_id IS NOT NULL THEN
    SELECT
      d.doc_type,
      COALESCE(NULLIF(btrim(d.doc_number), ''), v_number),
      COALESCE(d.show_prices, v_show_prices),
      COALESCE(NULLIF(btrim(d.currency), ''), v_currency),
      d.total,
      NULLIF(btrim(COALESCE(
        d.buyer_snapshot->>'display_name',
        d.buyer_snapshot->>'legal_name',
        d.buyer_snapshot->>'name',
        ''
      )), ''),
      CASE WHEN d.valid_until IS NULL THEN v_valid_until
           ELSE to_char(d.valid_until AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
      END
    INTO v_doc_type, v_number, v_show_prices, v_currency, v_total_num, v_client, v_valid_until
    FROM data.commercial_documents d
    WHERE d.id = v_req.commercial_document_id;
  END IF;

  v_kind := CASE v_doc_type
    WHEN 'quote' THEN CASE v_locale
      WHEN 'es' THEN 'Presupuesto'
      WHEN 'en' THEN 'Quote'
      ELSE 'Pressupost'
    END
    WHEN 'quote_amendment' THEN CASE v_locale
      WHEN 'es' THEN 'Ampliación'
      WHEN 'en' THEN 'Amendment'
      ELSE 'Ampliació'
    END
    WHEN 'delivery_note' THEN CASE v_locale
      WHEN 'es' THEN 'Albarán'
      WHEN 'en' THEN 'Delivery note'
      ELSE 'Albarà'
    END
    WHEN 'agreement_version' THEN CASE v_locale
      WHEN 'es' THEN 'Contrato'
      WHEN 'en' THEN 'Agreement'
      ELSE 'Acord'
    END
    ELSE CASE v_locale
      WHEN 'es' THEN 'Documento'
      WHEN 'en' THEN 'Document'
      ELSE 'Document'
    END
  END;
  IF v_show_prices AND v_total_num IS NOT NULL THEN
    v_total := trim(to_char(v_total_num, 'FM999999990.00')) || ' ' || v_currency;
  ELSE
    v_total := NULL;
  END IF;
  v_expires := to_char(v_req.expires_at AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD HH24:MI');

  v_idem := 'commercial-decision:' || v_req.id::text || ':delivery:' || v_delivery.id::text;

  v_log_id := api.enqueue_email(jsonb_build_object(
    'tenant_id', v_req.tenant_id,
    'idempotency_key', v_idem,
    'to', jsonb_build_array(v_email),
    'event_type', 'commercial.decision_request',
    'locale', v_locale,
    'email_type', 'transactional',
    'template_variables', jsonb_strip_nulls(jsonb_build_object(
      'recipient_name', NULLIF(btrim(COALESCE(p_recipient_name, '')), ''),
      'tenant_name', v_tenant_name,
      'document_kind', v_kind,
      'document_number', v_number,
      'client_name', v_client,
      'total_summary', v_total,
      'valid_until', v_valid_until,
      'request_expires_at', v_expires,
      'decision_url', v_url,
      'portal_url', NULLIF(btrim(COALESCE(p_portal_url, '')), ''),
      'purpose', v_req.purpose
    )),
    'metadata', jsonb_build_object(
      'source', 'commercial_decision',
      'request_id', v_req.id,
      'delivery_id', v_delivery.id,
      'commercial_document_id', v_req.commercial_document_id,
      'agreement_version_id', v_req.agreement_version_id
    ),
    'tags', jsonb_build_array('commercial', 'decision_request')
  ));

  UPDATE data.commercial_decision_deliveries
  SET status = 'queued',
      queued_at = COALESCE(queued_at, now()),
      email_log_id = v_log_id,
      recipient_masked = data.mask_email_for_audit(v_email),
      error_code = NULL,
      failed_at = NULL
  WHERE id = v_delivery.id;

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, via, actor_id, content_hash, evidence
  ) VALUES (
    v_req.tenant_id, v_req.id, 'delivery_queued', 'email', v_uid, v_req.content_hash,
    jsonb_build_object(
      'delivery_id', v_delivery.id,
      'email_log_id', v_log_id,
      'recipient_masked', data.mask_email_for_audit(v_email)
    )
  );

  -- Consume plaintext only after enqueue succeeded (retry can reuse token_once)
  DELETE FROM data.commercial_decision_token_once WHERE delivery_id = v_delivery.id;

  RETURN jsonb_build_object(
    'delivery_id', v_delivery.id,
    'email_log_id', v_log_id,
    'status', 'queued',
    'already_queued', false
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. api.signing_submissions — strip counterparty signing URLs (CS-D58)
-- ---------------------------------------------------------------------------
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
    ss.metadata,
    ss.signing_provider,
    ss.native_group_id,
    ss.created_at,
    ss.updated_at
  FROM data.signing_submissions ss
  LEFT JOIN data.document_versions rv ON rv.id = ss.result_document_version_id;

GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO service_role;

-- Preserve data.docuseal_signing_url / signers[].signing_url on updates through the
-- stripped api view (NEW would otherwise carry NULLs from the view projection).
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
                                   -- If client only has stripped signers, keep server URLs
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
    metadata                   = NEW.metadata,
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

-- Full URLs for service_role / Edge workers only (email resend, router internals)
CREATE OR REPLACE VIEW api.signing_submissions_internal WITH (security_invoker = true) AS
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
    ss.created_at,
    ss.updated_at
  FROM data.signing_submissions ss;

REVOKE ALL ON api.signing_submissions_internal FROM PUBLIC;
REVOKE ALL ON api.signing_submissions_internal FROM authenticated;
GRANT SELECT ON api.signing_submissions_internal TO service_role;

NOTIFY pgrst, 'reload schema';
