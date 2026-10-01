-- CF-21-h1: idempotency hardening + one active agreement per source quote.
--
-- 1. data.commercial_agreement_replay_event: typed client_op replay helper.
--    A client_op_id may only be replayed by the same kind of operation (event type),
--    on the same agreement (and same billing period when applicable). Anything else
--    raises client_op_conflict instead of silently returning an unrelated id.
-- 2. Unique partial index: at most one non-cancelled agreement per (tenant, source quote).
-- 3. Replace the soft/untyped replay in prepare, create_framework, mark_sent,
--    mark_billing_period_invoiced and skip_billing_period.
--
-- Old migrations are never edited; bodies are replaced via CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Typed replay helper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.commercial_agreement_replay_event(
  p_tenant_id uuid,
  p_client_op_id uuid,
  p_expected_event_type text,
  p_expected_agreement_id uuid DEFAULT NULL,
  p_expected_period_id uuid DEFAULT NULL
)
RETURNS data.commercial_agreement_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_event data.commercial_agreement_events;
BEGIN
  IF p_tenant_id IS NULL OR p_client_op_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_event
  FROM data.commercial_agreement_events e
  WHERE e.tenant_id = p_tenant_id
    AND e.client_op_id = p_client_op_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_event.event_type IS DISTINCT FROM p_expected_event_type
     OR (
       p_expected_agreement_id IS NOT NULL
       AND v_event.agreement_id IS DISTINCT FROM p_expected_agreement_id
     )
     OR (
       p_expected_period_id IS NOT NULL
       AND (v_event.payload->>'period_id') IS DISTINCT FROM p_expected_period_id::text
     )
  THEN
    RAISE EXCEPTION 'client_op_conflict' USING ERRCODE = 'P0001';
  END IF;

  RETURN v_event;
END;
$$;

COMMENT ON FUNCTION data.commercial_agreement_replay_event(uuid, uuid, text, uuid, uuid) IS
  'CF-21-h1: replay tipat de client_op_id. NULL si no existeix; client_op_conflict si tipus/acord/període no coincideixen.';

REVOKE ALL ON FUNCTION data.commercial_agreement_replay_event(uuid, uuid, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Preflight + unique index (one active agreement per source quote)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_dups int;
  v_sample text;
BEGIN
  SELECT count(*), string_agg(d.tenant_id::text || '/' || d.source_quote_id::text, ', ')
  INTO v_dups, v_sample
  FROM (
    SELECT a.tenant_id, a.source_quote_id
    FROM data.commercial_agreements a
    WHERE a.source_quote_id IS NOT NULL
      AND a.status <> 'cancelled'
    GROUP BY a.tenant_id, a.source_quote_id
    HAVING count(*) > 1
    ORDER BY a.tenant_id, a.source_quote_id
    LIMIT 20
  ) d;

  IF COALESCE(v_dups, 0) > 0 THEN
    RAISE EXCEPTION
      'CF-21-h1 preflight failed: % (tenant/source_quote) pair(s) have more than one non-cancelled agreement. Reconcile manually (cancel the extras) before re-running this migration. Sample: %',
      v_dups, v_sample;
  END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_commercial_agreements_tenant_source_quote_active
  ON data.commercial_agreements (tenant_id, source_quote_id)
  WHERE source_quote_id IS NOT NULL AND status <> 'cancelled';

COMMENT ON INDEX data.uq_commercial_agreements_tenant_source_quote_active IS
  'CF-21-h1: màxim un acord no cancel·lat per pressupost origen.';

-- ---------------------------------------------------------------------------
-- 3a. prepare_agreement_from_quote — typed replay + race-safe insert
-- ---------------------------------------------------------------------------
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
  IF v_doc.status <> 'accepted' THEN
    RAISE EXCEPTION 'quote_not_accepted' USING ERRCODE = 'P0001';
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

  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text, text, int, text, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text, text, int, text, int
) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3b. create_framework_agreement — typed replay (prepared)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_framework_agreement(
  p_tenant_id uuid,
  p_client_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid,
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL,
  p_notice_days int DEFAULT NULL,
  p_locale text DEFAULT NULL,
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
  v_contact data.contacts%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_event data.commercial_agreement_events;
  v_html text;
  v_missing text[];
  v_hash text;
  v_locale text;
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
  IF p_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'tenant_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF p_work_gate IS NULL OR p_work_gate NOT IN ('none', 'require_signed_agreement') THEN
    RAISE EXCEPTION 'invalid_work_gate' USING ERRCODE = 'P0001';
  END IF;
  IF p_ends_on IS NULL THEN
    RAISE EXCEPTION 'recurring_ends_on_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_starts_on IS NOT NULL AND p_ends_on < p_starts_on THEN
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

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  -- Typed replay: same op must be a 'prepared' event for the same client.
  v_event := data.commercial_agreement_replay_event(
    p_tenant_id, p_client_op_id, 'prepared'
  );
  IF v_event.id IS NOT NULL THEN
    IF (v_event.payload->>'client_id') IS DISTINCT FROM p_client_id::text THEN
      RAISE EXCEPTION 'client_op_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_event.agreement_id;
  END IF;

  SELECT * INTO v_contact FROM data.contacts WHERE id = p_client_id;
  IF NOT FOUND OR v_contact.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'client_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'agreement_template_required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = p_template_id AND t.is_active AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (t.tenant_id = p_tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
  ) THEN
    RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
  END IF;

  v_locale := COALESCE(
    NULLIF(btrim(p_locale), ''),
    NULLIF(btrim(v_contact.preferred_locale), ''),
    'ca'
  );

  SELECT l.html_content INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id AND l.locale = v_locale
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
        'framework|' || p_client_id::text || '|' || p_template_id::text
        || '|' || COALESCE(p_starts_on::text, '') || '|' || p_ends_on::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  INSERT INTO data.commercial_agreements (
    tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by
  ) VALUES (
    p_tenant_id, p_client_id, 'framework', 'pending_start',
    NULL, p_work_gate, v_uid
  ) RETURNING * INTO v_agreement;

  INSERT INTO data.commercial_agreement_versions (
    tenant_id, agreement_id, version_no, status,
    source_quote_id, source_quote_content_hash, source_quote_document_id,
    full_body_template_id, content_hash, starts_on, ends_on, notice_days, auto_renew,
    sla_response_hours, sla_resolution_hours, sla_coverage_notes,
    billing_cadence, billing_amount_cents, billing_currency, billing_anchor_day, next_billing_on,
    terms_snapshot
  ) VALUES (
    p_tenant_id, v_agreement.id, 1, 'draft',
    NULL, NULL, NULL,
    p_template_id, v_hash, p_starts_on, p_ends_on, p_notice_days, v_auto_renew,
    p_sla_response_hours, p_sla_resolution_hours, v_sla_notes,
    v_billing_cadence,
    CASE WHEN v_billing_cadence = 'none' THEN NULL ELSE p_billing_amount_cents END,
    v_billing_currency, p_billing_anchor_day, v_next_billing,
    jsonb_build_object('locale', v_locale, 'kind', 'framework')
  ) RETURNING * INTO v_version;

  UPDATE data.commercial_agreements
  SET active_version_id = v_version.id
  WHERE id = v_agreement.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    p_tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
    jsonb_build_object(
      'kind', 'framework',
      'full_body_template_id', p_template_id,
      'client_id', p_client_id,
      'auto_renew', v_auto_renew,
      'sla_response_hours', p_sla_response_hours,
      'sla_resolution_hours', p_sla_resolution_hours,
      'billing_cadence', v_billing_cadence,
      'billing_amount_cents', p_billing_amount_cents
    )
  );

  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_framework_agreement(
  uuid, uuid, uuid, text, uuid, date, date, int, text, boolean, int, int, text, text, int, text, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_framework_agreement(
  uuid, uuid, uuid, text, uuid, date, date, int, text, boolean, int, int, text, text, int, text, int
) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3c. mark_agreement_sent_for_signature — typed replay (sent)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.mark_agreement_sent_for_signature(
  p_version_id uuid,
  p_submission_id uuid,
  p_signer_role text,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_event data.commercial_agreement_events;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_signer_role IS DISTINCT FROM 'client' THEN
    RAISE EXCEPTION 'agreement_signer_role_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_version FROM data.commercial_agreement_versions WHERE id = p_version_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_version.tenant_id::text) THEN
    RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE((
    SELECT tm.role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_version.tenant_id
      AND tm.user_id = v_uid
      AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  -- Typed replay: same op must be a 'sent' event on this agreement.
  v_event := data.commercial_agreement_replay_event(
    v_version.tenant_id, p_client_op_id, 'sent', v_version.agreement_id
  );
  IF v_event.id IS NOT NULL THEN
    RETURN v_version.agreement_id;
  END IF;

  IF v_version.status = 'pending_signature' THEN
    RETURN v_version.agreement_id;
  END IF;
  IF v_version.status <> 'draft' THEN
    RAISE EXCEPTION 'agreement_version_immutable' USING ERRCODE = 'P0001';
  END IF;
  IF v_version.rendered_document_id IS NULL THEN
    RAISE EXCEPTION 'agreement_pdf_required' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_agreement_versions
  SET status = 'pending_signature'
  WHERE id = v_version.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_version.tenant_id, v_version.agreement_id, 'sent', v_uid, p_client_op_id,
    jsonb_build_object(
      'submission_id', p_submission_id,
      'signer_role', 'client',
      'rendered_document_id', v_version.rendered_document_id
    )
  );

  RETURN v_version.agreement_id;
END;
$$;

REVOKE ALL ON FUNCTION api.mark_agreement_sent_for_signature(uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.mark_agreement_sent_for_signature(uuid, uuid, text, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3d. billing period invoiced / skipped — typed replay incl. period_id
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.mark_agreement_billing_period_invoiced(
  p_period_id uuid,
  p_external_invoice_ref text,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_period data.commercial_agreement_billing_periods%ROWTYPE;
  v_event data.commercial_agreement_events;
  v_ref text := NULLIF(btrim(p_external_invoice_ref), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_ref IS NULL THEN
    RAISE EXCEPTION 'external_invoice_ref_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_period
  FROM data.commercial_agreement_billing_periods
  WHERE id = p_period_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_period.tenant_id::text) THEN
    RAISE EXCEPTION 'billing_period_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_period.tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:billing_invoice' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NOT NULL THEN
    v_event := data.commercial_agreement_replay_event(
      v_period.tenant_id, p_client_op_id,
      'billing_period_invoiced', v_period.agreement_id, v_period.id
    );
    IF v_event.id IS NOT NULL THEN
      RETURN v_period.id;
    END IF;
  END IF;

  IF v_period.status = 'invoiced'
     AND v_period.external_invoice_ref IS NOT DISTINCT FROM v_ref THEN
    RETURN v_period.id;
  END IF;
  IF v_period.status NOT IN ('due', 'invoiced') THEN
    RAISE EXCEPTION 'billing_period_not_due' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_agreement_billing_periods
  SET status = 'invoiced',
      external_invoice_ref = v_ref,
      invoiced_at = now(),
      invoiced_by = v_uid,
      updated_at = now()
  WHERE id = v_period.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_period.tenant_id, v_period.agreement_id, 'billing_period_invoiced', v_uid, p_client_op_id,
    jsonb_build_object(
      'period_id', v_period.id,
      'external_invoice_ref', v_ref,
      'amount_cents', v_period.amount_cents
    )
  );

  RETURN v_period.id;
END;
$$;

REVOKE ALL ON FUNCTION api.mark_agreement_billing_period_invoiced(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.mark_agreement_billing_period_invoiced(uuid, text, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.skip_agreement_billing_period(
  p_period_id uuid,
  p_client_op_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_period data.commercial_agreement_billing_periods%ROWTYPE;
  v_event data.commercial_agreement_events;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_period
  FROM data.commercial_agreement_billing_periods
  WHERE id = p_period_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_period.tenant_id::text) THEN
    RAISE EXCEPTION 'billing_period_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_period.tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:billing_skip' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NOT NULL THEN
    v_event := data.commercial_agreement_replay_event(
      v_period.tenant_id, p_client_op_id,
      'billing_period_skipped', v_period.agreement_id, v_period.id
    );
    IF v_event.id IS NOT NULL THEN
      RETURN v_period.id;
    END IF;
  END IF;

  IF v_period.status = 'skipped' THEN
    RETURN v_period.id;
  END IF;
  IF v_period.status IS DISTINCT FROM 'due' THEN
    RAISE EXCEPTION 'billing_period_not_due' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_agreement_billing_periods
  SET status = 'skipped',
      notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
      updated_at = now()
  WHERE id = v_period.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_period.tenant_id, v_period.agreement_id, 'billing_period_skipped', v_uid, p_client_op_id,
    jsonb_build_object('period_id', v_period.id, 'notes', NULLIF(btrim(COALESCE(p_notes, '')), ''))
  );

  RETURN v_period.id;
END;
$$;

REVOKE ALL ON FUNCTION api.skip_agreement_billing_period(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.skip_agreement_billing_period(uuid, uuid, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
