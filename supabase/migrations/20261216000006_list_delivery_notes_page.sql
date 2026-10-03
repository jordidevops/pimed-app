-- CF-26: every delivery note, not only the latest per order.

CREATE INDEX IF NOT EXISTS idx_commercial_documents_tenant_dn_issued
  ON data.commercial_documents (tenant_id, status, (COALESCE(issued_at, created_at)) DESC)
  WHERE doc_type = 'delivery_note';

CREATE OR REPLACE FUNCTION api.list_delivery_notes_page(
  p_client_id uuid DEFAULT NULL,
  p_project_id uuid DEFAULT NULL,
  p_status_group text DEFAULT 'open',
  p_has_external_ref text DEFAULT 'all',
  p_q text DEFAULT NULL,
  p_issued_from timestamptz DEFAULT NULL,
  p_issued_to timestamptz DEFAULT NULL,
  p_include_rectified boolean DEFAULT false,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
)
RETURNS TABLE (
  items jsonb,
  total_count bigint,
  total_cents bigint,
  total_paid_cents bigint,
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
  WITH notes AS (
    SELECT d.*
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant_id
      AND d.doc_type = 'delivery_note'
      AND (
        d.status IN ('issued', 'signed', 'accepted')
        OR (COALESCE(p_include_rectified, false) AND d.status = 'cancelled')
      )
      AND (p_client_id IS NULL OR d.client_id = p_client_id)
      AND (p_project_id IS NULL OR d.project_id = p_project_id)
      AND (p_issued_from IS NULL OR COALESCE(d.issued_at, d.created_at) >= p_issued_from)
      AND (p_issued_to IS NULL OR COALESCE(d.issued_at, d.created_at) <= p_issued_to)
  ),
  successor AS (
    SELECT newer.supersedes_id AS original_id, newer.id, newer.doc_number
    FROM data.commercial_documents newer
    WHERE newer.tenant_id = v_tenant_id
      AND newer.doc_type = 'delivery_note'
      AND newer.supersedes_id IS NOT NULL
  ),
  enriched AS (
    SELECT
      n.id,
      n.tenant_id,
      n.doc_number,
      n.client_id,
      n.project_id,
      n.status AS document_status,
      n.total,
      n.issued_at,
      n.created_at,
      n.external_invoice_ref,
      n.supersedes_id,
      COALESCE(
        NULLIF(btrim(c.display_name), ''),
        NULLIF(btrim(n.buyer_snapshot ->> 'display_name'), ''),
        ''
      ) AS client_display_name,
      pr.name AS project_name,
      data.commercial_document_total_cents(n.total)::bigint AS note_total_cents,
      COALESCE(b.direct_paid_cents, 0)::bigint AS direct_paid_cents,
      COALESCE(b.inherited_paid_cents, 0)::bigint AS inherited_paid_cents,
      COALESCE(b.advance_applied_cents, 0)::bigint AS advance_applied_cents,
      CASE
        WHEN n.status = 'cancelled' THEN 0::bigint
        ELSE COALESCE(b.remaining_cents, data.commercial_document_total_cents(n.total))::bigint
      END AS remaining_cents,
      invoice.id AS external_invoice_id,
      COALESCE(invoice.invoice_number, NULLIF(btrim(n.external_invoice_ref), '')) AS external_invoice_number,
      successor.id AS superseded_by_id,
      successor.doc_number AS superseded_by_number
    FROM notes n
    LEFT JOIN data.delivery_balances(v_tenant_id, NULL) b ON b.delivery_note_id = n.id
    LEFT JOIN data.contacts c ON c.id = n.client_id AND c.tenant_id = n.tenant_id
    LEFT JOIN data.projects pr ON pr.id = n.project_id AND pr.tenant_id = n.tenant_id
    LEFT JOIN data.external_invoice_delivery_notes link ON link.delivery_note_id = n.id
    LEFT JOIN data.external_invoices invoice ON invoice.id = link.invoice_id
    LEFT JOIN successor ON successor.original_id = n.id
  ),
  balanced AS (
    SELECT
      e.*,
      (e.direct_paid_cents + e.inherited_paid_cents + e.advance_applied_cents)::bigint AS paid_cents,
      CASE
        WHEN e.document_status = 'cancelled' THEN 'rectified'
        WHEN e.remaining_cents = 0 THEN 'paid'
        WHEN (e.direct_paid_cents + e.inherited_paid_cents + e.advance_applied_cents) <= 0 THEN 'pending'
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
      OR (v_ext = 'yes' AND b.external_invoice_number IS NOT NULL)
      OR (v_ext = 'no' AND b.external_invoice_number IS NULL)
    )
    AND (
      v_q IS NULL
      OR COALESCE(b.doc_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.client_display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.project_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.external_invoice_number, '') ILIKE '%' || v_q || '%'
    )
  ),
  totals AS (
    SELECT
      COUNT(*)::bigint AS total_count,
      COALESCE(SUM(f.note_total_cents), 0)::bigint AS total_cents,
      COALESCE(SUM(f.paid_cents), 0)::bigint AS total_paid_cents,
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
          'doc_number', p.doc_number,
          'client_id', p.client_id,
          'client_display_name', p.client_display_name,
          'project_id', p.project_id,
          'project_name', p.project_name,
          'document_status', p.document_status,
          'collection_status', p.collection_status,
          'total', p.total,
          'total_cents', p.note_total_cents,
          'direct_paid_cents', p.direct_paid_cents,
          'inherited_paid_cents', p.inherited_paid_cents,
          'advance_applied_cents', p.advance_applied_cents,
          'paid_cents', p.paid_cents,
          'remaining_cents', p.remaining_cents,
          'issued_at', p.issued_at,
          'created_at', p.created_at,
          'external_invoice_id', p.external_invoice_id,
          'external_invoice_ref', p.external_invoice_number,
          'supersedes_id', p.supersedes_id,
          'superseded_by_id', p.superseded_by_id,
          'superseded_by_number', p.superseded_by_number
        )
        ORDER BY COALESCE(p.issued_at, p.created_at) DESC, p.id DESC
      )
      FROM page p
    ), '[]'::jsonb),
    totals.total_count,
    totals.total_cents,
    totals.total_paid_cents,
    totals.total_remaining_cents
  FROM totals;
END;
$$;

CREATE OR REPLACE FUNCTION api.get_project_delivery_summary(p_project_ids uuid[])
RETURNS TABLE (
  project_id uuid,
  authorized_cents bigint,
  billed_cents bigint,
  advance_pool_cents bigint,
  unapplied_advance_cents bigint,
  collected_cents bigint,
  remaining_cents bigint,
  has_open_delivery boolean
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
  WITH requested AS (
    SELECT DISTINCT project_id
    FROM unnest(COALESCE(p_project_ids, ARRAY[]::uuid[])) AS project_id
    WHERE project_id IS NOT NULL
  ),
  balances AS (
    SELECT *
    FROM data.delivery_balances(data.active_tenant_id(), p_project_ids)
  )
  SELECT
    r.project_id,
    data.commercial_document_total_cents(pr.authorized_total)::bigint,
    COALESCE(SUM(b.total_cents), 0)::bigint,
    COALESCE(MAX(b.advance_pool_cents), 0)::bigint,
    COALESCE(MAX(b.unapplied_advance_cents), 0)::bigint,
    COALESCE(SUM(b.own_paid_cents + b.advance_applied_cents), 0)::bigint,
    COALESCE(SUM(b.remaining_cents), 0)::bigint,
    COALESCE(BOOL_OR(b.remaining_cents > 0), false)
  FROM requested r
  JOIN data.projects pr
    ON pr.id = r.project_id
   AND pr.tenant_id = data.active_tenant_id()
  LEFT JOIN balances b ON b.project_id = r.project_id
  GROUP BY r.project_id, pr.authorized_total;
$$;

REVOKE ALL ON FUNCTION api.list_delivery_notes_page(
  uuid, uuid, text, text, text, timestamptz, timestamptz, boolean, int, int
) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_project_delivery_summary(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_delivery_notes_page(
  uuid, uuid, text, text, text, timestamptz, timestamptz, boolean, int, int
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.get_project_delivery_summary(uuid[])
  TO authenticated, service_role;

COMMENT ON FUNCTION api.list_delivery_notes_page(
  uuid, uuid, text, text, text, timestamptz, timestamptz, boolean, int, int
) IS
  'All delivery notes for the hub. Rectified notes stay hidden unless p_include_rectified.';

NOTIFY pgrst, 'reload schema';
