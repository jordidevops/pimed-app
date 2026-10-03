-- CF-25: set-based AR list for office hub /cobraments.
-- One collectable delivery note per project (latest); orphan DNs without project_id as own rows.

CREATE INDEX IF NOT EXISTS idx_commercial_documents_tenant_dn_created
  ON data.commercial_documents (tenant_id, created_at DESC, id DESC)
  WHERE doc_type = 'delivery_note';

CREATE INDEX IF NOT EXISTS idx_payments_tenant_document
  ON data.payments (tenant_id, document_id);

CREATE OR REPLACE FUNCTION api.list_delivery_collection_page(
  p_client_id uuid DEFAULT NULL,
  p_project_id uuid DEFAULT NULL,
  p_status_group text DEFAULT 'open',
  p_has_external_ref text DEFAULT 'all',
  p_q text DEFAULT NULL,
  p_issued_from timestamptz DEFAULT NULL,
  p_issued_to timestamptz DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
)
RETURNS TABLE (
  items jsonb,
  total_count bigint,
  total_remaining_cents bigint
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(btrim(COALESCE(p_q, '')), '');
  v_status text := lower(NULLIF(btrim(COALESCE(p_status_group, 'open')), ''));
  v_ext text := lower(NULLIF(btrim(COALESCE(p_has_external_ref, 'all')), ''));
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset int := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF v_status IS NULL OR v_status NOT IN ('open', 'pending', 'partial', 'paid', 'all') THEN
    v_status := 'open';
  END IF;

  IF v_ext IS NULL OR v_ext NOT IN ('all', 'yes', 'no') THEN
    v_ext := 'all';
  END IF;

  RETURN QUERY
  WITH collectable AS (
    SELECT d.*
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant_id
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted')
      AND (p_client_id IS NULL OR d.client_id = p_client_id)
      AND (p_project_id IS NULL OR d.project_id = p_project_id)
      AND (p_issued_from IS NULL OR COALESCE(d.issued_at, d.created_at) >= p_issued_from)
      AND (p_issued_to IS NULL OR COALESCE(d.issued_at, d.created_at) <= p_issued_to)
  ),
  latest_with_project AS (
    SELECT DISTINCT ON (c.project_id) c.*
    FROM collectable c
    WHERE c.project_id IS NOT NULL
    ORDER BY c.project_id, c.created_at DESC, c.id DESC
  ),
  orphan_dns AS (
    SELECT c.*
    FROM collectable c
    WHERE c.project_id IS NULL
  ),
  surface AS (
    SELECT * FROM latest_with_project
    UNION ALL
    SELECT * FROM orphan_dns
  ),
  payments_by_doc AS (
    SELECT p.document_id, COALESCE(SUM(p.amount_cents), 0)::bigint AS paid_cents
    FROM data.payments p
    WHERE p.tenant_id = v_tenant_id
    GROUP BY p.document_id
  ),
  advances_by_project AS (
    SELECT
      d.project_id,
      COALESCE(SUM(p.amount_cents), 0)::bigint AS advance_cents
    FROM data.payments p
    JOIN data.commercial_documents d ON d.id = p.document_id
    WHERE p.tenant_id = v_tenant_id
      AND d.tenant_id = v_tenant_id
      AND d.project_id IS NOT NULL
      AND d.doc_type IN ('quote', 'quote_amendment')
      AND d.status IN ('accepted', 'signed')
    GROUP BY d.project_id
  ),
  enriched AS (
    SELECT
      s.id,
      s.tenant_id,
      s.doc_number,
      s.client_id,
      s.project_id,
      s.status AS document_status,
      s.total,
      s.issued_at,
      s.created_at,
      s.external_invoice_ref,
      COALESCE(
        NULLIF(btrim(c.display_name), ''),
        NULLIF(btrim(s.buyer_snapshot ->> 'display_name'), ''),
        NULLIF(btrim(s.buyer_snapshot ->> 'legal_name'), ''),
        ''
      ) AS client_display_name,
      pr.name AS project_name,
      data.commercial_document_total_cents(s.total)::bigint AS total_cents,
      COALESCE(pd.paid_cents, 0)::bigint AS own_paid_cents,
      CASE
        WHEN s.project_id IS NULL THEN 0::bigint
        ELSE COALESCE(ap.advance_cents, 0)::bigint
      END AS advance_cents
    FROM surface s
    LEFT JOIN data.contacts c
      ON c.id = s.client_id AND c.tenant_id = s.tenant_id
    LEFT JOIN data.projects pr
      ON pr.id = s.project_id AND pr.tenant_id = s.tenant_id
    LEFT JOIN payments_by_doc pd ON pd.document_id = s.id
    LEFT JOIN advances_by_project ap ON ap.project_id = s.project_id
  ),
  balanced AS (
    SELECT
      e.*,
      GREATEST(0, e.total_cents - e.own_paid_cents - e.advance_cents)::bigint AS remaining_cents,
      GREATEST(
        0,
        e.total_cents
          - GREATEST(0, e.total_cents - e.own_paid_cents - e.advance_cents)
      )::bigint AS paid_cents,
      CASE
        WHEN GREATEST(0, e.total_cents - e.own_paid_cents - e.advance_cents) = 0 THEN 'paid'
        WHEN (e.own_paid_cents + e.advance_cents) <= 0 THEN 'pending'
        ELSE 'partial'
      END AS collection_status
    FROM enriched e
  ),
  filtered AS (
    SELECT b.*
    FROM balanced b
    WHERE (
      v_status = 'all'
      OR (v_status = 'open' AND b.collection_status IN ('pending', 'partial'))
      OR b.collection_status = v_status
    )
    AND (
      v_ext = 'all'
      OR (v_ext = 'yes' AND NULLIF(btrim(COALESCE(b.external_invoice_ref, '')), '') IS NOT NULL)
      OR (v_ext = 'no' AND NULLIF(btrim(COALESCE(b.external_invoice_ref, '')), '') IS NULL)
    )
    AND (
      v_q IS NULL
      OR COALESCE(b.doc_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.client_display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.project_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.external_invoice_ref, '') ILIKE '%' || v_q || '%'
    )
  ),
  totals AS (
    SELECT
      COUNT(*)::bigint AS total_count,
      COALESCE(SUM(f.remaining_cents), 0)::bigint AS total_remaining_cents
    FROM filtered f
  ),
  page AS (
    SELECT f.*
    FROM filtered f
    ORDER BY COALESCE(f.issued_at, f.created_at) DESC, f.id DESC
    OFFSET v_offset
    LIMIT v_limit
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'tenant_id', p.tenant_id,
          'doc_number', p.doc_number,
          'client_id', p.client_id,
          'client_display_name', p.client_display_name,
          'project_id', p.project_id,
          'project_name', p.project_name,
          'document_status', p.document_status,
          'collection_status', p.collection_status,
          'total', p.total,
          'total_cents', p.total_cents,
          'paid_cents', p.paid_cents,
          'remaining_cents', p.remaining_cents,
          'own_paid_cents', p.own_paid_cents,
          'advance_cents', p.advance_cents,
          'issued_at', p.issued_at,
          'created_at', p.created_at,
          'external_invoice_ref', p.external_invoice_ref
        )
        ORDER BY COALESCE(p.issued_at, p.created_at) DESC, p.id DESC
      )
      FROM page p
    ), '[]'::jsonb) AS items,
    totals.total_count,
    totals.total_remaining_cents
  FROM totals;
END;
$$;

REVOKE ALL ON FUNCTION api.list_delivery_collection_page(
  uuid, uuid, text, text, text, timestamptz, timestamptz, int, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_delivery_collection_page(
  uuid, uuid, text, text, text, timestamptz, timestamptz, int, int
) TO authenticated, service_role;

COMMENT ON FUNCTION api.list_delivery_collection_page(
  uuid, uuid, text, text, text, timestamptz, timestamptz, int, int
) IS
  'CF-25 office AR hub: latest collectable delivery note per project with allocated paid/remaining (set-based).';

NOTIFY pgrst, 'reload schema';
