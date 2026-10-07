-- CF-28 / F6 tall 2: customer portal delivery notes + invoices list RPCs.

CREATE OR REPLACE FUNCTION data.list_customer_portal_delivery_notes(
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
      d.id,
      d.doc_number AS label,
      -- Portal copy: rejected → disputed (UI maps status key).
      CASE WHEN d.status = 'rejected' THEN 'disputed' ELSE d.status END AS status,
      COALESCE(d.issued_at, d.created_at) AS sort_date,
      CASE WHEN d.show_prices THEN d.total ELSE NULL END AS total,
      CASE WHEN d.show_prices THEN d.currency::text ELSE NULL END AS currency,
      NULLIF(btrim(p.name), '') AS project_label
    FROM data.commercial_documents d
    LEFT JOIN data.projects p
      ON p.id = d.project_id
     AND p.tenant_id = d.tenant_id
    WHERE d.tenant_id = p_tenant_id
      AND d.client_id = p_client_account_contact_id
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'rejected', 'cancelled')
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
        'item_kind', 'document',
        'id', id,
        'doc_type', 'delivery_note',
        'label', label,
        'status', status,
        'sort_date', sort_date,
        'total', total,
        'currency', currency,
        'project_label', project_label,
        'paid_total', NULL,
        'outstanding_total', NULL,
        'collection_status', NULL
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

REVOKE ALL ON FUNCTION data.list_customer_portal_delivery_notes(uuid, uuid, timestamptz, uuid, integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.list_customer_portal_delivery_notes(uuid, uuid, timestamptz, uuid, integer)
  TO service_role;

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
      d.currency::text AS currency,
      data.commercial_document_total_cents(d.total)::bigint AS total_cents
    FROM data.commercial_documents d
    WHERE d.tenant_id = p_tenant_id
      AND d.client_id = p_client_account_contact_id
      AND d.doc_type = 'invoice'
      AND d.status IN ('issued', 'cancelled')
  ),
  allocated AS (
    SELECT
      link.invoice_id,
      COALESCE(SUM(pa.amount_cents), 0)::bigint AS cents
    FROM data.invoice_delivery_notes link
    JOIN invoices i ON i.id = link.invoice_id
    LEFT JOIN data.payment_allocations pa
      ON pa.delivery_note_id = link.delivery_note_id
     AND pa.tenant_id = p_tenant_id
    WHERE link.released_at IS NULL
    GROUP BY link.invoice_id
  ),
  direct_paid AS (
    -- Direct DN payments (invoice-document payments are not counted here).
    SELECT
      link.invoice_id,
      COALESCE(SUM(p.amount_cents), 0)::bigint AS cents
    FROM data.invoice_delivery_notes link
    JOIN invoices i ON i.id = link.invoice_id
    JOIN data.payments p
      ON p.document_id = link.delivery_note_id
     AND p.tenant_id = p_tenant_id
    WHERE link.released_at IS NULL
    GROUP BY link.invoice_id
  ),
  enriched AS (
    SELECT
      i.*,
      CASE
        WHEN i.status = 'cancelled' THEN i.total_cents
        ELSE LEAST(
          i.total_cents,
          COALESCE(a.cents, 0) + COALESCE(dp.cents, 0)
        )
      END AS paid_cents,
      CASE
        WHEN i.status = 'cancelled' THEN 0::bigint
        ELSE GREATEST(
          i.total_cents - (COALESCE(a.cents, 0) + COALESCE(dp.cents, 0)),
          0
        )
      END AS outstanding_cents
    FROM invoices i
    LEFT JOIN allocated a ON a.invoice_id = i.id
    LEFT JOIN direct_paid dp ON dp.invoice_id = i.id
  ),
  page AS (
    SELECT
      e.*,
      CASE
        WHEN e.status = 'cancelled' THEN 'cancelled'
        WHEN e.outstanding_cents = 0 THEN 'paid'
        WHEN e.paid_cents <= 0 THEN 'pending'
        ELSE 'partial'
      END AS collection_status
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
        'paid_total', ROUND(paid_cents / 100.0, 2),
        'outstanding_total', ROUND(outstanding_cents / 100.0, 2),
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

REVOKE ALL ON FUNCTION data.list_customer_portal_invoices(uuid, uuid, timestamptz, uuid, integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.list_customer_portal_invoices(uuid, uuid, timestamptz, uuid, integer)
  TO service_role;

-- Wire kinds into session resolver (replace stub empty arrays).
CREATE OR REPLACE FUNCTION api.resolve_customer_portal_commercial(
  p_session_token_hash bytea,
  p_action text DEFAULT 'list_documents',
  p_kind text DEFAULT 'quotes_agreements',
  p_cursor_sort timestamptz DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_request_id text DEFAULT NULL
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
  v_enabled boolean := false;
BEGIN
  IF v_action NOT IN ('list_documents', 'list_summary') THEN
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
      v_sess.tenant_id,
      v_grant.client_account_contact_id,
      p_cursor_sort,
      p_cursor_id,
      p_limit
    );
  ELSIF v_kind = 'delivery_notes' THEN
    v_items := data.list_customer_portal_delivery_notes(
      v_sess.tenant_id,
      v_grant.client_account_contact_id,
      p_cursor_sort,
      p_cursor_id,
      p_limit
    );
  ELSIF v_kind = 'invoices' THEN
    v_items := data.list_customer_portal_invoices(
      v_sess.tenant_id,
      v_grant.client_account_contact_id,
      p_cursor_sort,
      p_cursor_id,
      p_limit
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
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_customer_portal_commercial(
  bytea, text, text, timestamptz, uuid, integer, inet, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_customer_portal_commercial(
  bytea, text, text, timestamptz, uuid, integer, inet, text, text
) TO service_role;
