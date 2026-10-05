-- Sales dashboard overview: cash KPIs + agreement attention queues + monthly series.
-- Agreements are NOT year-scoped. Cash/series use p_year.
-- Auth: tenant membership (same as list_commercial_agreements_page), not invoices.view only.

CREATE OR REPLACE FUNCTION api.get_sales_dashboard_overview(
  p_year int DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_year int := COALESCE(p_year, EXTRACT(YEAR FROM CURRENT_DATE)::int);
  v_to_invoice_count bigint := 0;
  v_to_invoice_cents bigint := 0;
  v_pending_collection_cents bigint := 0;
  v_pending_quotes_count bigint := 0;
  v_project_ids uuid[] := ARRAY[]::uuid[];
  v_sig_draft bigint := 0;
  v_sig_pending bigint := 0;
  v_sig_signed bigint := 0;
  v_life_active bigint := 0;
  v_life_expiring bigint := 0;
  v_life_suspended bigint := 0;
  v_life_finished bigint := 0;
  v_needs_prepare bigint := 0;
  v_attention jsonb := '[]'::jsonb;
  v_series jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL OR NOT COALESCE(data.jwt_user_tenants() ? v_tenant::text, false) THEN
    RAISE EXCEPTION 'tenant_access_denied' USING ERRCODE = 'P0001';
  END IF;

  -- ── cash (year-scoped; same definitions as get_sales_dashboard_kpis) ──────
  SELECT
    COUNT(*)::bigint,
    COALESCE(SUM(data.commercial_document_total_cents(d.total)), 0)::bigint
  INTO v_to_invoice_count, v_to_invoice_cents
  FROM data.commercial_documents d
  WHERE d.tenant_id = v_tenant
    AND d.doc_type = 'delivery_note'
    AND d.status IN ('issued', 'signed', 'accepted')
    AND EXTRACT(
      YEAR FROM COALESCE(
        d.issued_on,
        (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date
      )
    ) = v_year
    AND NOT EXISTS (
      SELECT 1
      FROM data.invoice_delivery_notes link
      WHERE link.delivery_note_id = d.id
        AND link.released_at IS NULL
    );

  SELECT COUNT(*)::bigint
  INTO v_pending_quotes_count
  FROM data.commercial_documents d
  WHERE d.tenant_id = v_tenant
    AND d.doc_type = 'quote'
    AND d.status = 'issued'
    AND EXTRACT(
      YEAR FROM COALESCE(
        d.issued_on,
        (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date
      )
    ) = v_year;

  WITH open_dns AS (
    SELECT d.id, d.project_id
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted')
      AND EXTRACT(
        YEAR FROM COALESCE(
          d.issued_on,
          (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date
        )
      ) = v_year
  ),
  open_invoices AS (
    SELECT d.id
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant
      AND d.doc_type = 'invoice'
      AND d.status = 'issued'
      AND EXTRACT(
        YEAR FROM COALESCE(
          d.issued_on,
          (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date
        )
      ) = v_year
  ),
  scoped_dns AS (
    SELECT od.id, od.project_id FROM open_dns od
    UNION
    SELECT dn.id, dn.project_id
    FROM open_invoices oi
    JOIN data.invoice_delivery_notes link
      ON link.invoice_id = oi.id
     AND link.released_at IS NULL
    JOIN data.commercial_documents dn
      ON dn.id = link.delivery_note_id
     AND dn.tenant_id = v_tenant
    WHERE dn.doc_type = 'delivery_note'
      AND dn.status IN ('issued', 'signed', 'accepted')
  ),
  candidate_projects AS (
    SELECT COALESCE(
      ARRAY_AGG(DISTINCT s.project_id) FILTER (WHERE s.project_id IS NOT NULL),
      ARRAY[]::uuid[]
    ) AS project_ids
    FROM scoped_dns s
  )
  SELECT
    cp.project_ids,
    CASE
      WHEN cardinality(cp.project_ids) = 0 THEN 0::bigint
      ELSE COALESCE((
        SELECT SUM(b.remaining_cents)::bigint
        FROM data.delivery_balances(v_tenant, cp.project_ids) b
        WHERE b.delivery_note_id IN (SELECT s.id FROM scoped_dns s)
      ), 0)::bigint
    END
  INTO v_project_ids, v_pending_collection_cents
  FROM candidate_projects cp;

  -- ── agreements (NOT year-scoped) ─────────────────────────────────────────
  SELECT
    COUNT(*) FILTER (WHERE COALESCE(v.status, 'draft') = 'draft')::bigint,
    COUNT(*) FILTER (WHERE v.status = 'pending_signature')::bigint,
    COUNT(*) FILTER (WHERE v.status = 'signed')::bigint,
    COUNT(*) FILTER (WHERE a.status = 'active')::bigint,
    COUNT(*) FILTER (
      WHERE a.status IN ('active', 'suspended')
        AND (CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END) IS NOT NULL
        AND (CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END)
            <= CURRENT_DATE + COALESCE(v.notice_days, 30)
    )::bigint,
    COUNT(*) FILTER (WHERE a.status = 'suspended')::bigint,
    COUNT(*) FILTER (WHERE a.status IN ('finished', 'cancelled'))::bigint
  INTO
    v_sig_draft,
    v_sig_pending,
    v_sig_signed,
    v_life_active,
    v_life_expiring,
    v_life_suspended,
    v_life_finished
  FROM data.commercial_agreements a
  LEFT JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
  LEFT JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
  WHERE a.tenant_id = v_tenant;

  SELECT COUNT(*)::bigint
  INTO v_needs_prepare
  FROM data.commercial_documents d
  WHERE d.tenant_id = v_tenant
    AND d.doc_type = 'quote'
    AND d.status = 'accepted'
    AND d.formalization_mode = 'separate_agreement'
    AND NOT EXISTS (
      SELECT 1
      FROM data.commercial_agreements a
      WHERE a.tenant_id = v_tenant
        AND a.source_quote_id = d.id
        AND a.kind = 'specific'
        AND a.status IS DISTINCT FROM 'cancelled'
    );

  -- attention: needs_prepare → pending_signature → draft → expiring → suspended
  WITH prepare_rows AS (
    SELECT
      'quote_prepare'::text AS kind,
      d.id,
      d.client_id,
      COALESCE(NULLIF(btrim(ct.display_name), ''), d.client_id::text) AS client_name,
      COALESCE(NULLIF(btrim(d.doc_number), ''), left(d.id::text, 8)) AS label,
      'needs_prepare'::text AS reason,
      1 AS prio,
      d.created_at
    FROM data.commercial_documents d
    LEFT JOIN data.contacts ct ON ct.id = d.client_id
    WHERE d.tenant_id = v_tenant
      AND d.doc_type = 'quote'
      AND d.status = 'accepted'
      AND d.formalization_mode = 'separate_agreement'
      AND NOT EXISTS (
        SELECT 1
        FROM data.commercial_agreements a
        WHERE a.tenant_id = v_tenant
          AND a.source_quote_id = d.id
          AND a.kind = 'specific'
          AND a.status IS DISTINCT FROM 'cancelled'
      )
  ),
  agreement_base AS (
    SELECT
      a.id,
      a.client_id,
      a.status AS agreement_status,
      a.created_at,
      COALESCE(v.status, 'draft') AS version_status,
      COALESCE(NULLIF(btrim(ct.display_name), ''), a.client_id::text) AS client_name,
      COALESCE(
        NULLIF(btrim(q.doc_number), ''),
        NULLIF(btrim(a.kind), ''),
        left(a.id::text, 8)
      ) AS label,
      (CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END) AS ends_on,
      COALESCE(v.notice_days, 30) AS notice_days
    FROM data.commercial_agreements a
    LEFT JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    LEFT JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
    LEFT JOIN data.contacts ct ON ct.id = a.client_id
    LEFT JOIN data.commercial_documents q ON q.id = a.source_quote_id
    WHERE a.tenant_id = v_tenant
      AND a.status IS DISTINCT FROM 'cancelled'
  ),
  agreement_attention AS (
    SELECT
      'agreement'::text AS kind,
      b.id,
      b.client_id,
      b.client_name,
      b.label,
      CASE
        WHEN b.version_status = 'pending_signature' THEN 'pending_signature'
        WHEN b.version_status = 'draft' THEN 'draft'
        WHEN b.agreement_status IN ('active', 'suspended')
          AND b.ends_on IS NOT NULL
          AND b.ends_on <= CURRENT_DATE + b.notice_days
          THEN 'expiring'
        WHEN b.agreement_status = 'suspended' THEN 'suspended'
        ELSE NULL
      END AS reason,
      CASE
        WHEN b.version_status = 'pending_signature' THEN 2
        WHEN b.version_status = 'draft' THEN 3
        WHEN b.agreement_status IN ('active', 'suspended')
          AND b.ends_on IS NOT NULL
          AND b.ends_on <= CURRENT_DATE + b.notice_days
          THEN 4
        WHEN b.agreement_status = 'suspended' THEN 5
        ELSE 99
      END AS prio,
      b.created_at
    FROM agreement_base b
  ),
  ranked AS (
    SELECT *
    FROM (
      SELECT * FROM prepare_rows
      UNION ALL
      SELECT * FROM agreement_attention WHERE reason IS NOT NULL
    ) u
    ORDER BY prio ASC, created_at DESC
    LIMIT 8
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'kind', r.kind,
        'id', r.id,
        'client_id', r.client_id,
        'client_name', r.client_name,
        'label', r.label,
        'reason', r.reason
      )
      ORDER BY r.prio ASC, r.created_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_attention
  FROM ranked r;

  -- ── monthly series (year-scoped) ─────────────────────────────────────────
  WITH months AS (
    SELECT generate_series(1, 12) AS month
  ),
  doc_months AS (
    SELECT
      EXTRACT(
        MONTH FROM COALESCE(
          d.issued_on,
          (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date
        )
      )::int AS month,
      COUNT(*) FILTER (WHERE d.doc_type = 'quote' AND d.status IN ('issued', 'accepted', 'signed', 'rejected', 'expired'))::bigint
        AS quotes_issued,
      COUNT(*) FILTER (
        WHERE d.doc_type = 'delivery_note' AND d.status IN ('issued', 'signed', 'accepted')
      )::bigint AS delivery_notes_issued,
      COALESCE(
        SUM(data.commercial_document_total_cents(d.total)) FILTER (
          WHERE d.doc_type = 'invoice' AND d.status = 'issued'
        ),
        0
      )::bigint AS invoiced_cents
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant
      AND EXTRACT(
        YEAR FROM COALESCE(
          d.issued_on,
          (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date
        )
      ) = v_year
      AND d.doc_type IN ('quote', 'delivery_note', 'invoice')
    GROUP BY 1
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'month', m.month,
        'quotes_issued', COALESCE(dm.quotes_issued, 0),
        'delivery_notes_issued', COALESCE(dm.delivery_notes_issued, 0),
        'invoiced_cents', COALESCE(dm.invoiced_cents, 0)
      )
      ORDER BY m.month
    ),
    '[]'::jsonb
  )
  INTO v_series
  FROM months m
  LEFT JOIN doc_months dm ON dm.month = m.month;

  RETURN jsonb_build_object(
    'year', v_year,
    'cash', jsonb_build_object(
      'to_invoice_count', v_to_invoice_count,
      'to_invoice_cents', v_to_invoice_cents,
      'pending_collection_cents', v_pending_collection_cents,
      'pending_quotes_count', v_pending_quotes_count
    ),
    'agreements', jsonb_build_object(
      'signature', jsonb_build_object(
        'draft', v_sig_draft,
        'pending', v_sig_pending,
        'signed', v_sig_signed
      ),
      'lifecycle', jsonb_build_object(
        'active', v_life_active,
        'expiring', v_life_expiring,
        'suspended', v_life_suspended,
        'finished', v_life_finished
      ),
      'needs_prepare_count', v_needs_prepare,
      'attention', v_attention
    ),
    'series', jsonb_build_object('months', v_series)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_sales_dashboard_overview(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_sales_dashboard_overview(int)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.get_sales_dashboard_overview(int) IS
  'Sales hub overview: year-scoped cash+series; live agreement queues (not year-scoped); needs_prepare quotes.';

-- Keep legacy KPI in sync (thin wrapper) to avoid drift.
CREATE OR REPLACE FUNCTION api.get_sales_dashboard_kpis(
  p_year int DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_overview jsonb;
  v_cash jsonb;
BEGIN
  -- Legacy callers may only have invoices.view; overview uses membership.
  -- Preserve old gate when assert exists, else membership via overview.
  IF to_regprocedure('data.assert_invoice_permission(uuid, text)') IS NOT NULL THEN
    PERFORM data.assert_invoice_permission(data.active_tenant_id(), 'invoices.view');
  END IF;
  v_overview := api.get_sales_dashboard_overview(p_year);
  v_cash := v_overview->'cash';
  RETURN jsonb_build_object(
    'to_invoice_count', v_cash->'to_invoice_count',
    'to_invoice_cents', v_cash->'to_invoice_cents',
    'pending_collection_cents', v_cash->'pending_collection_cents',
    'pending_quotes_count', v_cash->'pending_quotes_count',
    'year', v_overview->'year'
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
