-- CS-D8 revision (2026-10): separate_agreement contract after quote accepted.
-- - prepare_agreement_from_quote: quote must be accepted
-- - finalize / apply_core: signing agreement must NOT accept the source quote
-- - register_commercial_signing_intent: agreement target requires accepted quote

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
  IF v_doc.status IS DISTINCT FROM 'accepted' THEN
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
  v_quote_id uuid;
  v_quote_project uuid;
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

  -- CS-D8 (2026-10): signing the agreement must NOT accept the source quote.
  -- Quote must already be accepted (office or quote decision) before prepare.
  IF v_version.source_quote_id IS NOT NULL THEN
    SELECT project_id INTO v_quote_project
    FROM data.commercial_documents WHERE id = v_version.source_quote_id;
    IF v_quote_project IS NOT NULL THEN
      BEGIN
        PERFORM api.link_agreement_project_from_quote(v_version.source_quote_id);
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;
  END IF;

  RETURN v_agreement.id;
END;
$$;

CREATE OR REPLACE FUNCTION data.apply_commercial_decision_request_core(p_request_id uuid, p_outcome text, p_via text, p_evidence jsonb, p_client_op_id uuid, p_actor_id uuid)
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
    -- Only decided events: 'created' reuses the same client_op_id from send UX.
    SELECT id INTO v_event_id
    FROM data.commercial_decision_events
    WHERE request_id = v_req.id
      AND client_op_id = p_client_op_id
      AND event_type = 'decided'
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

      -- CS-D8 (2026-10): do not accept source quote when agreement is signed.
      IF v_quote.project_id IS NOT NULL THEN
        BEGIN
          PERFORM api.link_agreement_project_from_quote(v_quote.id);
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
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
      -- CS-D8: agreement send requires quote already accepted
      IF v_doc.status IS DISTINCT FROM 'accepted' THEN
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

REVOKE ALL ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text, text, int, text, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text, text, int, text, int
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date)
  TO service_role;

REVOKE ALL ON FUNCTION data.apply_commercial_decision_request_core(uuid, text, text, jsonb, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.apply_commercial_decision_request_core(uuid, text, text, jsonb, uuid, uuid)
  TO service_role;

REVOKE ALL ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid, uuid)
  TO authenticated, service_role;