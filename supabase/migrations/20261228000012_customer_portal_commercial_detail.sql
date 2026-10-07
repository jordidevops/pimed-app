-- CF-28 / F6 tall 3: customer portal commercial detail + PDF version handles.

ALTER TABLE data.customer_report_share_access_logs
  DROP CONSTRAINT IF EXISTS customer_report_share_access_logs_action_check;

ALTER TABLE data.customer_report_share_access_logs
  ADD CONSTRAINT customer_report_share_access_logs_action_check
  CHECK (action = ANY (ARRAY[
    'session_create'::text,
    'report_view'::text,
    'media_download'::text,
    'resolve_denied'::text,
    'session_denied'::text,
    'rate_limited'::text,
    'list_bulletins'::text,
    'invitation_accepted'::text,
    'login_token_requested'::text,
    'login_token_exchanged'::text,
    'handoff_consumed'::text,
    'commercial_list'::text,
    'commercial_denied'::text,
    'commercial_detail'::text,
    'commercial_pdf'::text
  ]));

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.customer_portal_mask_payment_ref(p_ref text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_ref IS NULL OR btrim(p_ref) = '' THEN NULL
    WHEN char_length(btrim(p_ref)) <= 4 THEN '••••'
    ELSE '••••' || right(btrim(p_ref), 4)
  END;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_mask_payment_ref(text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.customer_portal_commercial_lines_json(
  p_document_id uuid,
  p_show_prices boolean
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_strip_nulls(jsonb_build_object(
        'position', l.position,
        'name', l.name,
        'description', l.description,
        'unit', l.unit,
        'quantity', l.quantity,
        'unit_price', CASE WHEN p_show_prices THEN l.unit_price ELSE NULL END,
        'discount_pct', CASE WHEN p_show_prices THEN l.discount_pct ELSE NULL END,
        'tax_rate', CASE WHEN p_show_prices THEN l.tax_rate ELSE NULL END,
        'line_subtotal', CASE WHEN p_show_prices THEN l.line_subtotal ELSE NULL END,
        'line_tax', CASE WHEN p_show_prices THEN l.line_tax ELSE NULL END,
        'line_total', CASE WHEN p_show_prices THEN l.line_total ELSE NULL END
      ))
      ORDER BY l.position, l.id
    ),
    '[]'::jsonb
  )
  FROM data.commercial_document_lines l
  WHERE l.document_id = p_document_id;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_commercial_lines_json(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_commercial_lines_json(uuid, boolean)
  TO service_role;

CREATE OR REPLACE FUNCTION data.customer_portal_latest_pdf_version(p_document_id uuid)
RETURNS TABLE (
  document_version_id uuid,
  document_id uuid,
  storage_type text,
  file_path_or_url text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT dv.id, dv.document_id, dv.storage_type, dv.file_path_or_url
  FROM data.document_versions dv
  WHERE dv.document_id = p_document_id
  ORDER BY dv.version_number DESC, dv.created_at DESC
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_latest_pdf_version(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_latest_pdf_version(uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Detail getters
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.get_customer_portal_quote_agreement(
  p_tenant_id uuid,
  p_client_account_contact_id uuid,
  p_target_id uuid,
  p_item_kind text DEFAULT 'document'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_kind text := COALESCE(NULLIF(btrim(p_item_kind), ''), 'document');
  v_doc data.commercial_documents%ROWTYPE;
  v_agr data.commercial_agreements%ROWTYPE;
  v_ver data.commercial_agreement_versions%ROWTYPE;
  v_pdf record;
  v_decision jsonb;
  v_show boolean;
  v_dms uuid;
BEGIN
  IF p_tenant_id IS NULL OR p_client_account_contact_id IS NULL OR p_target_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_kind = 'agreement' THEN
    SELECT * INTO v_agr
    FROM data.commercial_agreements a
    WHERE a.id = p_target_id
      AND a.tenant_id = p_tenant_id
      AND a.client_id = p_client_account_contact_id
      AND a.status IS DISTINCT FROM 'cancelled';

    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    SELECT * INTO v_ver
    FROM data.commercial_agreement_versions v
    WHERE v.id = v_agr.active_version_id
      AND v.status IN ('pending_signature', 'signed', 'declined');

    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    v_dms := COALESCE(v_ver.signed_document_id, v_ver.rendered_document_id);
    SELECT * INTO v_pdf FROM data.customer_portal_latest_pdf_version(v_dms);

    SELECT jsonb_build_object(
      'status', r.status,
      'decided_at', r.decided_at,
      'decided_via', r.decided_via
    )
    INTO v_decision
    FROM data.commercial_decision_requests r
    WHERE r.tenant_id = p_tenant_id
      AND r.agreement_version_id = v_ver.id
    ORDER BY r.created_at DESC
    LIMIT 1;

    RETURN jsonb_strip_nulls(jsonb_build_object(
      'item_kind', 'agreement',
      'id', v_agr.id,
      'doc_type', 'agreement',
      'label', v_agr.kind,
      'agreement_kind', v_agr.kind,
      'status', v_ver.status,
      'agreement_status', v_agr.status,
      'sort_date', v_ver.updated_at,
      'starts_on', v_ver.starts_on,
      'ends_on', v_ver.ends_on,
      'version_no', v_ver.version_no,
      'source_quote_id', v_agr.source_quote_id,
      'decision', v_decision,
      'pdf_document_id', v_dms,
      'pdf_version_id', v_pdf.document_version_id,
      'pdf_storage_type', v_pdf.storage_type,
      'pdf_file_path', v_pdf.file_path_or_url,
      'lines', '[]'::jsonb
    ));
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents d
  WHERE d.id = p_target_id
    AND d.tenant_id = p_tenant_id
    AND d.client_id = p_client_account_contact_id
    AND d.doc_type IN ('quote', 'quote_amendment')
    AND d.status IN ('issued', 'accepted', 'rejected', 'expired', 'cancelled');

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_show := v_doc.show_prices;
  SELECT * INTO v_pdf FROM data.customer_portal_latest_pdf_version(v_doc.rendered_document_id);

  SELECT jsonb_build_object(
    'status', r.status,
    'decided_at', r.decided_at,
    'decided_via', r.decided_via
  )
  INTO v_decision
  FROM data.commercial_decision_requests r
  WHERE r.tenant_id = p_tenant_id
    AND r.commercial_document_id = v_doc.id
  ORDER BY r.created_at DESC
  LIMIT 1;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'item_kind', 'document',
    'id', v_doc.id,
    'doc_type', v_doc.doc_type,
    'label', v_doc.doc_number,
    'status', v_doc.status,
    'sort_date', COALESCE(v_doc.issued_at, v_doc.created_at),
    'valid_until', v_doc.valid_until,
    'currency', v_doc.currency,
    'show_prices', v_show,
    'subtotal', CASE WHEN v_show THEN v_doc.subtotal ELSE NULL END,
    'total', CASE WHEN v_show THEN v_doc.total ELSE NULL END,
    'decision', v_decision,
    'pdf_document_id', v_doc.rendered_document_id,
    'pdf_version_id', v_pdf.document_version_id,
    'pdf_storage_type', v_pdf.storage_type,
    'pdf_file_path', v_pdf.file_path_or_url,
    'lines', data.customer_portal_commercial_lines_json(v_doc.id, v_show)
  ));
END;
$$;

REVOKE ALL ON FUNCTION data.get_customer_portal_quote_agreement(uuid, uuid, uuid, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.get_customer_portal_quote_agreement(uuid, uuid, uuid, text)
  TO service_role;

CREATE OR REPLACE FUNCTION data.get_customer_portal_delivery_note(
  p_tenant_id uuid,
  p_client_account_contact_id uuid,
  p_target_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_pdf record;
  v_project text;
  v_invoice_label text;
  v_decision jsonb;
  v_show boolean;
  v_status text;
BEGIN
  IF p_tenant_id IS NULL OR p_client_account_contact_id IS NULL OR p_target_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents d
  WHERE d.id = p_target_id
    AND d.tenant_id = p_tenant_id
    AND d.client_id = p_client_account_contact_id
    AND d.doc_type = 'delivery_note'
    AND d.status IN ('issued', 'signed', 'rejected', 'cancelled');

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_show := v_doc.show_prices;
  v_status := CASE WHEN v_doc.status = 'rejected' THEN 'disputed' ELSE v_doc.status END;
  SELECT * INTO v_pdf FROM data.customer_portal_latest_pdf_version(v_doc.rendered_document_id);

  SELECT NULLIF(btrim(p.name), '') INTO v_project
  FROM data.projects p
  WHERE p.id = v_doc.project_id AND p.tenant_id = p_tenant_id;

  SELECT inv.doc_number INTO v_invoice_label
  FROM data.invoice_delivery_notes link
  JOIN data.commercial_documents inv ON inv.id = link.invoice_id
  WHERE link.delivery_note_id = v_doc.id
    AND link.released_at IS NULL
    AND inv.status IN ('issued', 'cancelled')
  ORDER BY link.created_at DESC
  LIMIT 1;

  SELECT jsonb_build_object(
    'status', r.status,
    'decided_at', r.decided_at,
    'decided_via', r.decided_via
  )
  INTO v_decision
  FROM data.commercial_decision_requests r
  WHERE r.tenant_id = p_tenant_id
    AND r.commercial_document_id = v_doc.id
  ORDER BY r.created_at DESC
  LIMIT 1;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'item_kind', 'document',
    'id', v_doc.id,
    'doc_type', 'delivery_note',
    'label', v_doc.doc_number,
    'status', v_status,
    'sort_date', COALESCE(v_doc.issued_at, v_doc.created_at),
    'currency', CASE WHEN v_show THEN v_doc.currency ELSE NULL END,
    'show_prices', v_show,
    'subtotal', CASE WHEN v_show THEN v_doc.subtotal ELSE NULL END,
    'total', CASE WHEN v_show THEN v_doc.total ELSE NULL END,
    'project_label', v_project,
    'linked_invoice_label', v_invoice_label,
    'decision', v_decision,
    'pdf_document_id', v_doc.rendered_document_id,
    'pdf_version_id', v_pdf.document_version_id,
    'pdf_storage_type', v_pdf.storage_type,
    'pdf_file_path', v_pdf.file_path_or_url,
    'lines', data.customer_portal_commercial_lines_json(v_doc.id, v_show)
  ));
END;
$$;

REVOKE ALL ON FUNCTION data.get_customer_portal_delivery_note(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.get_customer_portal_delivery_note(uuid, uuid, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION data.get_customer_portal_invoice(
  p_tenant_id uuid,
  p_client_account_contact_id uuid,
  p_target_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_pdf record;
  v_paid bigint := 0;
  v_out bigint := 0;
  v_collection text;
  v_dns jsonb;
  v_payments jsonb;
BEGIN
  IF p_tenant_id IS NULL OR p_client_account_contact_id IS NULL OR p_target_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents d
  WHERE d.id = p_target_id
    AND d.tenant_id = p_tenant_id
    AND d.client_id = p_client_account_contact_id
    AND d.doc_type = 'invoice'
    AND d.status IN ('issued', 'cancelled');

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_pdf FROM data.customer_portal_latest_pdf_version(v_doc.rendered_document_id);

  SELECT COALESCE(SUM(pa.amount_cents), 0)::bigint INTO v_paid
  FROM data.invoice_delivery_notes link
  LEFT JOIN data.payment_allocations pa
    ON pa.delivery_note_id = link.delivery_note_id
   AND pa.tenant_id = p_tenant_id
  WHERE link.invoice_id = v_doc.id
    AND link.released_at IS NULL;

  v_paid := v_paid + COALESCE((
    SELECT SUM(p.amount_cents)::bigint
    FROM data.invoice_delivery_notes link
    JOIN data.payments p
      ON p.document_id = link.delivery_note_id
     AND p.tenant_id = p_tenant_id
    WHERE link.invoice_id = v_doc.id
      AND link.released_at IS NULL
  ), 0);

  IF v_doc.status = 'cancelled' THEN
    v_paid := data.commercial_document_total_cents(v_doc.total);
    v_out := 0;
    v_collection := 'cancelled';
  ELSE
    v_paid := LEAST(data.commercial_document_total_cents(v_doc.total), v_paid);
    v_out := GREATEST(data.commercial_document_total_cents(v_doc.total) - v_paid, 0);
    v_collection := CASE
      WHEN v_out = 0 THEN 'paid'
      WHEN v_paid <= 0 THEN 'pending'
      ELSE 'partial'
    END;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', dn.id,
        'label', dn.doc_number,
        'status', CASE WHEN dn.status = 'rejected' THEN 'disputed' ELSE dn.status END
      )
      ORDER BY COALESCE(dn.issued_at, dn.created_at), dn.id
    ),
    '[]'::jsonb
  )
  INTO v_dns
  FROM data.invoice_delivery_notes link
  JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
  WHERE link.invoice_id = v_doc.id
    AND link.released_at IS NULL;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'occurred_at', p.occurred_at,
        'amount', ROUND(p.amount_cents / 100.0, 2),
        'reference_masked', data.customer_portal_mask_payment_ref(p.reference)
      )
      ORDER BY p.occurred_at DESC, p.id
    ),
    '[]'::jsonb
  )
  INTO v_payments
  FROM data.payments p
  WHERE p.tenant_id = p_tenant_id
    AND (
      p.document_id = v_doc.id
      OR p.document_id IN (
        SELECT link.delivery_note_id
        FROM data.invoice_delivery_notes link
        WHERE link.invoice_id = v_doc.id
          AND link.released_at IS NULL
      )
      OR p.id IN (
        SELECT pa.payment_id
        FROM data.invoice_delivery_notes link
        JOIN data.payment_allocations pa ON pa.delivery_note_id = link.delivery_note_id
        WHERE link.invoice_id = v_doc.id
          AND link.released_at IS NULL
      )
    );

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'item_kind', 'document',
    'id', v_doc.id,
    'doc_type', 'invoice',
    'label', v_doc.doc_number,
    'status', v_doc.status,
    'sort_date', COALESCE(v_doc.issued_at, v_doc.created_at),
    'currency', v_doc.currency,
    'show_prices', true,
    'subtotal', v_doc.subtotal,
    'total', v_doc.total,
    'paid_total', ROUND(v_paid / 100.0, 2),
    'outstanding_total', ROUND(v_out / 100.0, 2),
    'collection_status', v_collection,
    'source_delivery_notes', v_dns,
    'payments', v_payments,
    'pdf_document_id', v_doc.rendered_document_id,
    'pdf_version_id', v_pdf.document_version_id,
    'pdf_storage_type', v_pdf.storage_type,
    'pdf_file_path', v_pdf.file_path_or_url,
    'lines', data.customer_portal_commercial_lines_json(v_doc.id, true)
  ));
END;
$$;

REVOKE ALL ON FUNCTION data.get_customer_portal_invoice(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.get_customer_portal_invoice(uuid, uuid, uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Resolve: add target_id + detail actions (replace overload)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.resolve_customer_portal_commercial(
  bytea, text, text, timestamptz, uuid, integer, inet, text, text
);

CREATE OR REPLACE FUNCTION api.resolve_customer_portal_commercial(
  p_session_token_hash bytea,
  p_action text DEFAULT 'list_documents',
  p_kind text DEFAULT 'quotes_agreements',
  p_cursor_sort timestamptz DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_request_id text DEFAULT NULL,
  p_target_id uuid DEFAULT NULL,
  p_item_kind text DEFAULT NULL
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
  v_action text := COALESCE(NULLIF(btrim(p_action), ''), 'list_documents');
  v_kind text := COALESCE(NULLIF(btrim(p_kind), ''), 'quotes_agreements');
  v_items jsonb := '[]'::jsonb;
  v_detail jsonb;
  v_enabled boolean := false;
  v_log_action text := 'commercial_list';
BEGIN
  IF v_action NOT IN (
    'list_documents', 'list_summary',
    'get_quote_or_agreement', 'get_delivery_note', 'get_invoice'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_action');
  END IF;

  IF p_session_token_hash IS NULL OR length(p_session_token_hash) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_sess
  FROM data.customer_portal_grant_sessions
  WHERE session_token_hash = p_session_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_grant FROM data.customer_access_grants WHERE id = v_sess.grant_id;
  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
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
      'session_invalid', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  UPDATE data.customer_portal_grant_sessions
  SET last_seen_at = now()
  WHERE id = v_sess.id;

  UPDATE data.customer_access_grants
  SET last_seen_at = now()
  WHERE id = v_grant.id;

  IF v_action = 'list_summary' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'tenant_id', v_sess.tenant_id,
      'grant_id', v_grant.id,
      'client_account_contact_id', v_grant.client_account_contact_id,
      'modules', jsonb_build_object(
        'quotes_agreements', v_tstate.commercial_quotes_agreements_enabled,
        'delivery_notes', v_tstate.commercial_delivery_notes_enabled,
        'invoices', v_tstate.commercial_invoices_enabled
      )
    );
  END IF;

  IF v_action = 'list_documents' THEN
    IF v_kind = 'quotes_agreements' THEN
      v_enabled := v_tstate.commercial_quotes_agreements_enabled;
    ELSIF v_kind = 'delivery_notes' THEN
      v_enabled := v_tstate.commercial_delivery_notes_enabled;
    ELSIF v_kind = 'invoices' THEN
      v_enabled := v_tstate.commercial_invoices_enabled;
    ELSE
      RETURN jsonb_build_object('ok', false, 'code', 'invalid_kind');
    END IF;

    IF NOT v_enabled THEN
      INSERT INTO data.customer_report_share_access_logs (
        tenant_id, grant_id, session_id, action, http_status,
        failure_reason, ip_address, user_agent, request_id
      ) VALUES (
        v_sess.tenant_id, v_grant.id, v_sess.id, 'commercial_denied', 403,
        'module_disabled', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
      );
      RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
    END IF;

    IF v_kind = 'quotes_agreements' THEN
      v_items := data.list_customer_portal_quotes_agreements(
        v_sess.tenant_id, v_grant.client_account_contact_id,
        p_cursor_sort, p_cursor_id, p_limit
      );
    ELSIF v_kind = 'delivery_notes' THEN
      v_items := data.list_customer_portal_delivery_notes(
        v_sess.tenant_id, v_grant.client_account_contact_id,
        p_cursor_sort, p_cursor_id, p_limit
      );
    ELSE
      v_items := data.list_customer_portal_invoices(
        v_sess.tenant_id, v_grant.client_account_contact_id,
        p_cursor_sort, p_cursor_id, p_limit
      );
    END IF;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_grant.id, v_sess.id, 'commercial_list', 200,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'kind', v_kind,
      'tenant_id', v_sess.tenant_id,
      'grant_id', v_grant.id,
      'client_account_contact_id', v_grant.client_account_contact_id,
      'items', v_items
    );
  END IF;

  -- Detail actions
  IF p_target_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_target');
  END IF;

  IF v_action = 'get_quote_or_agreement' THEN
    v_enabled := v_tstate.commercial_quotes_agreements_enabled;
    v_kind := 'quotes_agreements';
  ELSIF v_action = 'get_delivery_note' THEN
    v_enabled := v_tstate.commercial_delivery_notes_enabled;
    v_kind := 'delivery_notes';
  ELSE
    v_enabled := v_tstate.commercial_invoices_enabled;
    v_kind := 'invoices';
  END IF;

  IF NOT v_enabled THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_grant.id, v_sess.id, 'commercial_denied', 403,
      'module_disabled', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  IF v_action = 'get_quote_or_agreement' THEN
    v_detail := data.get_customer_portal_quote_agreement(
      v_sess.tenant_id,
      v_grant.client_account_contact_id,
      p_target_id,
      COALESCE(NULLIF(btrim(p_item_kind), ''), 'document')
    );
  ELSIF v_action = 'get_delivery_note' THEN
    v_detail := data.get_customer_portal_delivery_note(
      v_sess.tenant_id,
      v_grant.client_account_contact_id,
      p_target_id
    );
  ELSE
    v_detail := data.get_customer_portal_invoice(
      v_sess.tenant_id,
      v_grant.client_account_contact_id,
      p_target_id
    );
  END IF;

  IF v_detail IS NULL THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_grant.id, v_sess.id, 'commercial_denied', 404,
      'not_found', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  v_log_action := CASE
    WHEN v_detail ? 'pdf_version_id' AND v_detail->>'pdf_version_id' IS NOT NULL
      THEN 'commercial_detail'
    ELSE 'commercial_detail'
  END;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, grant_id, session_id, action, http_status,
    ip_address, user_agent, request_id
  ) VALUES (
    v_sess.tenant_id, v_grant.id, v_sess.id, v_log_action, 200,
    p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
  );

  RETURN jsonb_build_object(
    'ok', true,
    'action', v_action,
    'kind', v_kind,
    'tenant_id', v_sess.tenant_id,
    'grant_id', v_grant.id,
    'client_account_contact_id', v_grant.client_account_contact_id,
    'detail', v_detail
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_customer_portal_commercial(
  bytea, text, text, timestamptz, uuid, integer, inet, text, text, uuid, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_customer_portal_commercial(
  bytea, text, text, timestamptz, uuid, integer, inet, text, text, uuid, text
) TO service_role;
