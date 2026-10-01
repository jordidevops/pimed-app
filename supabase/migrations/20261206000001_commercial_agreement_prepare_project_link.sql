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
