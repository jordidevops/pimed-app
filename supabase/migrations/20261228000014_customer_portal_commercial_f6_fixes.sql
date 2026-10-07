-- CF-28 / F6 review fixes: mode_effective gate, show_prices, invoice ledger parity,
-- agreement sent-only, public field hygiene helpers.

-- ---------------------------------------------------------------------------
-- Invoice paid/remaining via same delivery_balances basis as sales hub
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.customer_portal_invoice_collection(
  p_tenant_id uuid,
  p_invoice_id uuid,
  p_invoice_total numeric,
  p_invoice_status text
)
RETURNS TABLE (
  paid_cents bigint,
  outstanding_cents bigint,
  collection_status text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_project_ids uuid[];
  v_paid bigint := 0;
  v_remaining bigint := 0;
  v_total bigint;
BEGIN
  v_total := data.commercial_document_total_cents(p_invoice_total);

  IF p_invoice_status = 'cancelled' THEN
    paid_cents := 0;
    outstanding_cents := 0;
    collection_status := 'cancelled';
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT COALESCE(
    ARRAY_AGG(DISTINCT dn.project_id) FILTER (WHERE dn.project_id IS NOT NULL),
    ARRAY[]::uuid[]
  )
  INTO v_project_ids
  FROM data.invoice_delivery_notes link
  JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
  WHERE link.invoice_id = p_invoice_id
    AND link.released_at IS NULL;

  SELECT
    COALESCE(SUM(b.own_paid_cents + b.advance_applied_cents), 0)::bigint,
    COALESCE(SUM(b.remaining_cents), 0)::bigint
  INTO v_paid, v_remaining
  FROM data.invoice_delivery_notes link
  LEFT JOIN LATERAL data.delivery_balances(p_tenant_id, v_project_ids) b
    ON b.delivery_note_id = link.delivery_note_id
  WHERE link.invoice_id = p_invoice_id
    AND link.released_at IS NULL;

  -- Invoices without DN links: treat as unpaid full total.
  IF NOT EXISTS (
    SELECT 1 FROM data.invoice_delivery_notes link
    WHERE link.invoice_id = p_invoice_id AND link.released_at IS NULL
  ) THEN
    v_paid := 0;
    v_remaining := v_total;
  END IF;

  paid_cents := LEAST(v_total, GREATEST(v_paid, 0));
  outstanding_cents := GREATEST(v_remaining, 0);
  collection_status := CASE
    WHEN outstanding_cents = 0 THEN 'paid'
    WHEN paid_cents <= 0 THEN 'pending'
    ELSE 'partial'
  END;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_invoice_collection(uuid, uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_invoice_collection(uuid, uuid, numeric, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Quotes/agreements list
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.list_customer_portal_quotes_agreements(
  p_tenant_id uuid,
  p_client_account_contact_id uuid,
  p_cursor_sort timestamptz DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit integer := GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
  v_items jsonb;
BEGIN
  IF p_tenant_id IS NULL OR p_client_account_contact_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  WITH docs AS (
    SELECT
      'document'::text AS item_kind,
      d.id,
      d.doc_type,
      d.doc_number AS label,
      d.status,
      COALESCE(d.issued_at, d.created_at) AS sort_date,
      CASE WHEN d.show_prices THEN d.total ELSE NULL END AS total,
      CASE WHEN d.show_prices THEN d.currency::text ELSE NULL END AS currency,
      d.valid_until,
      NULL::text AS agreement_kind
    FROM data.commercial_documents d
    WHERE d.tenant_id = p_tenant_id
      AND d.client_id = p_client_account_contact_id
      AND d.doc_type IN ('quote', 'quote_amendment')
      AND d.status IN ('issued', 'accepted', 'rejected', 'expired', 'cancelled')

    UNION ALL

    SELECT
      'agreement'::text AS item_kind,
      a.id,
      'agreement'::text AS doc_type,
      COALESCE(NULLIF(btrim(sq.doc_number), ''), a.kind, 'agreement') AS label,
      COALESCE(v.status, a.status) AS status,
      COALESCE(v.updated_at, a.created_at) AS sort_date,
      NULL::numeric AS total,
      NULL::text AS currency,
      v.ends_on::timestamptz AS valid_until,
      a.kind AS agreement_kind
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v
      ON v.id = a.active_version_id
    LEFT JOIN data.commercial_documents sq
      ON sq.id = a.source_quote_id
    WHERE a.tenant_id = p_tenant_id
      AND a.client_id = p_client_account_contact_id
      AND a.status IS DISTINCT FROM 'cancelled'
      AND (
        v.status IN ('signed', 'declined')
        OR (
          v.status = 'pending_signature'
          AND EXISTS (
            SELECT 1
            FROM data.commercial_decision_requests r
            WHERE r.agreement_version_id = v.id
              AND r.tenant_id = p_tenant_id
              AND r.status IN ('open', 'accepted', 'declined', 'expired', 'superseded')
          )
        )
      )
  ),
  page AS (
    SELECT *
    FROM docs
    WHERE (
      p_cursor_sort IS NULL
      OR (sort_date, id) < (p_cursor_sort, p_cursor_id)
    )
    ORDER BY sort_date DESC NULLS LAST, id DESC
    LIMIT v_limit
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'item_kind', item_kind,
        'id', id,
        'doc_type', doc_type,
        'label', label,
        'status', status,
        'sort_date', sort_date,
        'total', total,
        'currency', currency,
        'valid_until', valid_until,
        'agreement_kind', agreement_kind
      )
      ORDER BY sort_date DESC NULLS LAST, id DESC
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM page;

  RETURN v_items;
END;
$$;

-- ---------------------------------------------------------------------------
-- Invoices list (ledger parity)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.list_customer_portal_invoices(
  p_tenant_id uuid,
  p_client_account_contact_id uuid,
  p_cursor_sort timestamptz DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit integer := GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
  v_items jsonb;
BEGIN
  IF p_tenant_id IS NULL OR p_client_account_contact_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  WITH invoices AS (
    SELECT
      d.id,
      d.doc_number AS label,
      d.status,
      COALESCE(d.issued_at, d.created_at) AS sort_date,
      d.total,
      d.currency::text AS currency
    FROM data.commercial_documents d
    WHERE d.tenant_id = p_tenant_id
      AND d.client_id = p_client_account_contact_id
      AND d.doc_type = 'invoice'
      AND d.status IN ('issued', 'cancelled')
  ),
  enriched AS (
    SELECT
      i.*,
      c.paid_cents,
      c.outstanding_cents,
      c.collection_status
    FROM invoices i
    CROSS JOIN LATERAL data.customer_portal_invoice_collection(
      p_tenant_id, i.id, i.total, i.status
    ) c
  ),
  page AS (
    SELECT *
    FROM enriched e
    WHERE (
      p_cursor_sort IS NULL
      OR (e.sort_date, e.id) < (p_cursor_sort, p_cursor_id)
    )
    ORDER BY e.sort_date DESC NULLS LAST, e.id DESC
    LIMIT v_limit
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'item_kind', 'document',
        'id', id,
        'doc_type', 'invoice',
        'label', label,
        'status', status,
        'sort_date', sort_date,
        'total', total,
        'currency', currency,
        'project_label', NULL,
        'paid_total', CASE
          WHEN collection_status = 'cancelled' THEN NULL
          ELSE ROUND(paid_cents / 100.0, 2)
        END,
        'outstanding_total', CASE
          WHEN collection_status = 'cancelled' THEN NULL
          ELSE ROUND(outstanding_cents / 100.0, 2)
        END,
        'collection_status', collection_status
      )
      ORDER BY sort_date DESC NULLS LAST, id DESC
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM page;

  RETURN v_items;
END;
$$;

-- ---------------------------------------------------------------------------
-- Detail getters (no internal UUID leaks in public fields; path kept for edge)
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
  v_label text;
  v_source_label text;
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
      AND (
        v.status IN ('signed', 'declined')
        OR (
          v.status = 'pending_signature'
          AND EXISTS (
            SELECT 1 FROM data.commercial_decision_requests r
            WHERE r.agreement_version_id = v.id
              AND r.tenant_id = p_tenant_id
              AND r.status IN ('open', 'accepted', 'declined', 'expired', 'superseded')
          )
        )
      );

    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    SELECT NULLIF(btrim(sq.doc_number), '') INTO v_source_label
    FROM data.commercial_documents sq
    WHERE sq.id = v_agr.source_quote_id;

    v_label := COALESCE(v_source_label, v_agr.kind, 'agreement');
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
      'label', v_label,
      'agreement_kind', v_agr.kind,
      'status', v_ver.status,
      'agreement_status', v_agr.status,
      'sort_date', v_ver.updated_at,
      'starts_on', v_ver.starts_on,
      'ends_on', v_ver.ends_on,
      'version_no', v_ver.version_no,
      'source_quote_label', v_source_label,
      'decision', v_decision,
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
    'currency', CASE WHEN v_show THEN v_doc.currency ELSE NULL END,
    'show_prices', v_show,
    'subtotal', CASE WHEN v_show THEN v_doc.subtotal ELSE NULL END,
    'total', CASE WHEN v_show THEN v_doc.total ELSE NULL END,
    'decision', v_decision,
    'pdf_version_id', v_pdf.document_version_id,
    'pdf_storage_type', v_pdf.storage_type,
    'pdf_file_path', v_pdf.file_path_or_url,
    'lines', data.customer_portal_commercial_lines_json(v_doc.id, v_show)
  ));
END;
$$;

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
    'pdf_version_id', v_pdf.document_version_id,
    'pdf_storage_type', v_pdf.storage_type,
    'pdf_file_path', v_pdf.file_path_or_url,
    'lines', data.customer_portal_commercial_lines_json(v_doc.id, v_show)
  ));
END;
$$;

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
  v_coll record;
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
  SELECT * INTO v_coll
  FROM data.customer_portal_invoice_collection(
    p_tenant_id, v_doc.id, v_doc.total, v_doc.status
  );

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

  -- Deduped payments (never list the same payment twice).
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'occurred_at', x.occurred_at,
        'amount', ROUND(x.amount_cents / 100.0, 2),
        'reference_masked', data.customer_portal_mask_payment_ref(x.reference)
      )
      ORDER BY x.occurred_at DESC, x.id
    ),
    '[]'::jsonb
  )
  INTO v_payments
  FROM (
    SELECT DISTINCT ON (p.id)
      p.id,
      p.occurred_at,
      p.amount_cents,
      p.reference
    FROM data.payments p
    WHERE p.tenant_id = p_tenant_id
      AND (
        p.id IN (
          SELECT pa.payment_id
          FROM data.invoice_delivery_notes link
          JOIN data.payment_allocations pa
            ON pa.delivery_note_id = link.delivery_note_id
           AND pa.tenant_id = p_tenant_id
          WHERE link.invoice_id = v_doc.id
            AND link.released_at IS NULL
        )
        OR (
          p.document_id IN (
            SELECT link.delivery_note_id
            FROM data.invoice_delivery_notes link
            WHERE link.invoice_id = v_doc.id
              AND link.released_at IS NULL
          )
          AND NOT EXISTS (
            SELECT 1 FROM data.payment_allocations pa
            WHERE pa.payment_id = p.id
          )
        )
      )
    ORDER BY p.id, p.occurred_at DESC
  ) x;

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
    'paid_total', CASE
      WHEN v_coll.collection_status = 'cancelled' THEN NULL
      ELSE ROUND(v_coll.paid_cents / 100.0, 2)
    END,
    'outstanding_total', CASE
      WHEN v_coll.collection_status = 'cancelled' THEN NULL
      ELSE ROUND(v_coll.outstanding_cents / 100.0, 2)
    END,
    'collection_status', v_coll.collection_status,
    'source_delivery_notes', v_dns,
    'payments', v_payments,
    'pdf_version_id', v_pdf.document_version_id,
    'pdf_storage_type', v_pdf.storage_type,
    'pdf_file_path', v_pdf.file_path_or_url,
    'lines', data.customer_portal_commercial_lines_json(v_doc.id, true)
  ));
END;
$$;

-- ---------------------------------------------------------------------------
-- Resolve: mode_effective=portal gate; modules on every list; staff in request_id
-- ---------------------------------------------------------------------------
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
  v_staff data.customer_portal_staff_sessions%ROWTYPE;
  v_grant data.customer_access_grants%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_ent jsonb;
  v_mode text;
  v_action text := COALESCE(NULLIF(btrim(p_action), ''), 'list_documents');
  v_kind text := COALESCE(NULLIF(btrim(p_kind), ''), 'quotes_agreements');
  v_items jsonb := '[]'::jsonb;
  v_detail jsonb;
  v_enabled boolean := false;
  v_actor text := 'grant';
  v_tenant_id uuid;
  v_client_id uuid;
  v_session_id uuid;
  v_grant_id uuid;
  v_staff_user_id uuid;
  v_audit_rid text;
  v_modules jsonb;
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

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;

  SELECT * INTO v_sess
  FROM data.customer_portal_grant_sessions
  WHERE session_token_hash = p_session_token_hash
  FOR UPDATE;

  IF FOUND THEN
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
        'session_invalid', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
      );
      RETURN jsonb_build_object('ok', false, 'code', 'invalid');
    END IF;

    UPDATE data.customer_portal_grant_sessions
    SET last_seen_at = now() WHERE id = v_sess.id;
    UPDATE data.customer_access_grants
    SET last_seen_at = now() WHERE id = v_grant.id;

    v_actor := 'grant';
    v_tenant_id := v_sess.tenant_id;
    v_client_id := v_grant.client_account_contact_id;
    v_session_id := v_sess.id;
    v_grant_id := v_grant.id;
  ELSE
    SELECT * INTO v_staff
    FROM data.customer_portal_staff_sessions
    WHERE session_token_hash = p_session_token_hash
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'code', 'invalid');
    END IF;

    v_tstate := data.ensure_customer_portal_tenant_state(v_staff.tenant_id);

    IF v_staff.revoked_at IS NOT NULL
       OR v_staff.expires_at <= now()
       OR v_staff.exchanged_at IS NULL
       OR v_staff.client_account_contact_id IS NULL
       OR NOT v_platform.enabled
       OR NOT v_tstate.enabled
       OR v_platform.max_mode <> 'portal'
       OR v_tstate.existing_access_policy <> 'allow'
       OR v_staff.security_version_tenant IS DISTINCT FROM v_tstate.security_version
       OR v_staff.security_version_platform IS DISTINCT FROM v_platform.security_version
    THEN
      INSERT INTO data.customer_report_share_access_logs (
        tenant_id, grant_id, session_id, action, http_status,
        failure_reason, ip_address, user_agent, request_id
      ) VALUES (
        v_staff.tenant_id, NULL, v_staff.id, 'commercial_denied', 401,
        'session_invalid', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
      );
      RETURN jsonb_build_object('ok', false, 'code', 'invalid');
    END IF;

    UPDATE data.customer_portal_staff_sessions
    SET last_seen_at = now() WHERE id = v_staff.id;

    v_actor := 'staff';
    v_tenant_id := v_staff.tenant_id;
    v_client_id := v_staff.client_account_contact_id;
    v_session_id := v_staff.id;
    v_grant_id := NULL;
    v_staff_user_id := v_staff.staff_user_id;
  END IF;

  v_ent := data.resolve_portal_entitlements(v_tenant_id);
  v_mode := COALESCE(v_ent ->> 'mode_effective', '');
  v_audit_rid := left(
    COALESCE(p_request_id, '')
      || CASE WHEN v_staff_user_id IS NOT NULL THEN ' staff=' || v_staff_user_id::text ELSE '' END,
    128
  );

  -- share_only (or any non-portal mode): catalogue denied; summary reports modules false.
  IF v_mode IS DISTINCT FROM 'portal' THEN
    IF v_action = 'list_summary' THEN
      RETURN jsonb_build_object(
        'ok', true,
        'action', v_action,
        'actor_type', v_actor,
        'tenant_id', v_tenant_id,
        'grant_id', v_grant_id,
        'client_account_contact_id', v_client_id,
        'modules', jsonb_build_object(
          'quotes_agreements', false,
          'delivery_notes', false,
          'invoices', false
        ),
        'mode_effective', v_mode
      );
    END IF;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_tenant_id, v_grant_id, v_session_id, 'commercial_denied', 403,
      'mode_not_portal', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  v_modules := jsonb_build_object(
    'quotes_agreements', v_tstate.commercial_quotes_agreements_enabled,
    'delivery_notes', v_tstate.commercial_delivery_notes_enabled,
    'invoices', v_tstate.commercial_invoices_enabled
  );

  IF v_action = 'list_summary' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'actor_type', v_actor,
      'tenant_id', v_tenant_id,
      'grant_id', v_grant_id,
      'client_account_contact_id', v_client_id,
      'modules', v_modules,
      'mode_effective', v_mode
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
        v_tenant_id, v_grant_id, v_session_id, 'commercial_denied', 403,
        'module_disabled', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
      );
      RETURN jsonb_build_object('ok', false, 'code', 'module_disabled', 'modules', v_modules);
    END IF;

    IF v_kind = 'quotes_agreements' THEN
      v_items := data.list_customer_portal_quotes_agreements(
        v_tenant_id, v_client_id, p_cursor_sort, p_cursor_id, p_limit
      );
    ELSIF v_kind = 'delivery_notes' THEN
      v_items := data.list_customer_portal_delivery_notes(
        v_tenant_id, v_client_id, p_cursor_sort, p_cursor_id, p_limit
      );
    ELSE
      v_items := data.list_customer_portal_invoices(
        v_tenant_id, v_client_id, p_cursor_sort, p_cursor_id, p_limit
      );
    END IF;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      ip_address, user_agent, request_id
    ) VALUES (
      v_tenant_id, v_grant_id, v_session_id, 'commercial_list', 200,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'actor_type', v_actor,
      'kind', v_kind,
      'tenant_id', v_tenant_id,
      'grant_id', v_grant_id,
      'client_account_contact_id', v_client_id,
      'modules', v_modules,
      'items', v_items
    );
  END IF;

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
      v_tenant_id, v_grant_id, v_session_id, 'commercial_denied', 403,
      'module_disabled', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled', 'modules', v_modules);
  END IF;

  IF v_action = 'get_quote_or_agreement' THEN
    v_detail := data.get_customer_portal_quote_agreement(
      v_tenant_id, v_client_id, p_target_id,
      COALESCE(NULLIF(btrim(p_item_kind), ''), 'document')
    );
  ELSIF v_action = 'get_delivery_note' THEN
    v_detail := data.get_customer_portal_delivery_note(
      v_tenant_id, v_client_id, p_target_id
    );
  ELSE
    v_detail := data.get_customer_portal_invoice(
      v_tenant_id, v_client_id, p_target_id
    );
  END IF;

  IF v_detail IS NULL THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_tenant_id, v_grant_id, v_session_id, 'commercial_denied', 404,
      'not_found', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, grant_id, session_id, action, http_status,
    ip_address, user_agent, request_id
  ) VALUES (
    v_tenant_id, v_grant_id, v_session_id, 'commercial_detail', 200,
    p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
  );

  RETURN jsonb_build_object(
    'ok', true,
    'action', v_action,
    'actor_type', v_actor,
    'kind', v_kind,
    'tenant_id', v_tenant_id,
    'grant_id', v_grant_id,
    'client_account_contact_id', v_client_id,
    'modules', v_modules,
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
