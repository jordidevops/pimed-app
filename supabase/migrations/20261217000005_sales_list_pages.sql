-- CF-27 / Sales 4: keyset list RPCs for delivery notes and invoices.
-- Never call delivery_balances(tenant, NULL) — scope by candidate project_ids.

-- ---------------------------------------------------------------------------
-- 1. Indexes for sales list keyset (issued_at, id)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_cd_sales_dn_issued_id
  ON data.commercial_documents (tenant_id, doc_type, issued_at DESC, id DESC)
  WHERE doc_type = 'delivery_note';

CREATE INDEX IF NOT EXISTS idx_cd_sales_invoice_issued_id
  ON data.commercial_documents (tenant_id, doc_type, issued_at DESC, id DESC)
  WHERE doc_type = 'invoice';

CREATE INDEX IF NOT EXISTS idx_cd_sales_client_issued
  ON data.commercial_documents (tenant_id, client_id, issued_at DESC)
  WHERE doc_type IN ('delivery_note', 'invoice');

CREATE INDEX IF NOT EXISTS idx_cd_sales_doc_number_trgm
  ON data.commercial_documents USING gin (doc_number gin_trgm_ops)
  WHERE doc_number IS NOT NULL
    AND doc_type IN ('delivery_note', 'invoice');

CREATE INDEX IF NOT EXISTS idx_idn_active_dn_tenant
  ON data.invoice_delivery_notes (tenant_id, delivery_note_id)
  WHERE released_at IS NULL;

-- ---------------------------------------------------------------------------
-- 2. list_sales_delivery_notes_page
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_sales_delivery_notes_page(
  p_client_id uuid DEFAULT NULL,
  p_project_id uuid DEFAULT NULL,
  p_q text DEFAULT NULL,
  p_billing_status text[] DEFAULT NULL,
  p_collection_status text[] DEFAULT NULL,
  p_year int DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL,
  p_sort text DEFAULT 'issued_at',
  p_dir text DEFAULT 'desc',
  p_cursor_value text DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_limit int DEFAULT 50
)
RETURNS TABLE (
  items jsonb,
  total_count bigint,
  next_cursor_value text,
  next_cursor_id uuid,
  has_more boolean
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(btrim(COALESCE(p_q, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_sort text := lower(COALESCE(NULLIF(btrim(p_sort), ''), 'issued_at'));
  v_dir text := CASE
    WHEN lower(COALESCE(NULLIF(btrim(p_dir), ''), 'desc')) = 'asc' THEN 'asc'
    ELSE 'desc'
  END;
  v_billing text[] := COALESCE(p_billing_status, ARRAY[]::text[]);
  v_collection text[] := COALESCE(p_collection_status, ARRAY[]::text[]);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  IF v_sort NOT IN ('issued_at', 'doc_number', 'total') THEN
    RAISE EXCEPTION 'invalid_sort' USING ERRCODE = 'P0001';
  END IF;
  IF (p_cursor_value IS NULL) IS DISTINCT FROM (p_cursor_id IS NULL) THEN
    RAISE EXCEPTION 'invalid_cursor' USING ERRCODE = 'P0001';
  END IF;
  IF v_q IS NOT NULL AND char_length(v_q) < 2 THEN
    RAISE EXCEPTION 'q_too_short' USING ERRCODE = 'P0001';
  END IF;
  IF cardinality(v_billing) > 0
     AND EXISTS (
       SELECT 1 FROM unnest(v_billing) s(x)
       WHERE lower(x) NOT IN ('to_invoice', 'draft_invoice', 'invoiced', 'rectified')
     ) THEN
    RAISE EXCEPTION 'invalid_billing_status' USING ERRCODE = 'P0001';
  END IF;
  IF cardinality(v_collection) > 0
     AND EXISTS (
       SELECT 1 FROM unnest(v_collection) s(x)
       WHERE lower(x) NOT IN ('pending', 'partial', 'paid')
     ) THEN
    RAISE EXCEPTION 'invalid_collection_status' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  WITH notes AS (
    SELECT d.*
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant_id
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted', 'cancelled')
      AND (p_client_id IS NULL OR d.client_id = p_client_id)
      AND (p_project_id IS NULL OR d.project_id = p_project_id)
      AND (
        p_year IS NULL
        OR EXTRACT(YEAR FROM COALESCE(d.issued_on, (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date))
           = p_year
      )
      AND (p_date_from IS NULL OR COALESCE(d.issued_at, d.created_at) >= p_date_from)
      AND (p_date_to IS NULL OR COALESCE(d.issued_at, d.created_at) <= p_date_to)
  ),
  candidate_projects AS (
    SELECT COALESCE(
      ARRAY_AGG(DISTINCT n.project_id) FILTER (WHERE n.project_id IS NOT NULL),
      ARRAY[]::uuid[]
    ) AS project_ids
    FROM notes n
  ),
  enriched AS (
    SELECT
      n.id,
      n.doc_number,
      n.client_id,
      n.project_id,
      n.status AS document_status,
      n.total,
      n.issued_at,
      n.issued_on,
      n.created_at,
      COALESCE(n.issued_at, n.created_at) AS sort_issued_at,
      COALESCE(n.doc_number, '') AS sort_doc_number,
      COALESCE(n.total, 0) AS sort_total,
      COALESCE(
        NULLIF(btrim(c.display_name), ''),
        NULLIF(btrim(n.buyer_snapshot ->> 'display_name'), ''),
        ''
      ) AS client_display_name,
      pr.name AS project_name,
      data.commercial_document_total_cents(n.total)::bigint AS total_cents,
      COALESCE(b.direct_paid_cents, 0)::bigint AS direct_paid_cents,
      COALESCE(b.inherited_paid_cents, 0)::bigint AS inherited_paid_cents,
      COALESCE(b.advance_applied_cents, 0)::bigint AS advance_applied_cents,
      CASE
        WHEN n.status = 'cancelled' THEN 0::bigint
        ELSE COALESCE(b.remaining_cents, data.commercial_document_total_cents(n.total))::bigint
      END AS remaining_cents,
      inv.id AS invoice_id,
      inv.doc_number AS invoice_doc_number,
      inv.status AS invoice_status,
      CASE
        WHEN n.status = 'cancelled' THEN 'rectified'
        WHEN inv.id IS NOT NULL AND inv.status = 'draft' THEN 'draft_invoice'
        WHEN inv.id IS NOT NULL THEN 'invoiced'
        ELSE 'to_invoice'
      END AS billing_status
    FROM notes n
    CROSS JOIN candidate_projects cp
    LEFT JOIN LATERAL data.delivery_balances(v_tenant_id, cp.project_ids) b
      ON b.delivery_note_id = n.id
    LEFT JOIN data.contacts c ON c.id = n.client_id AND c.tenant_id = n.tenant_id
    LEFT JOIN data.projects pr ON pr.id = n.project_id AND pr.tenant_id = n.tenant_id
    LEFT JOIN data.invoice_delivery_notes ilink
      ON ilink.delivery_note_id = n.id AND ilink.released_at IS NULL
    LEFT JOIN data.commercial_documents inv
      ON inv.id = ilink.invoice_id AND inv.doc_type = 'invoice'
  ),
  balanced AS (
    SELECT
      e.*,
      (e.direct_paid_cents + e.inherited_paid_cents + e.advance_applied_cents)::bigint AS paid_cents,
      CASE
        WHEN e.document_status = 'cancelled' THEN 'paid'
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
      cardinality(v_billing) = 0
      OR b.billing_status = ANY (
        SELECT lower(x) FROM unnest(v_billing) AS t(x)
      )
    )
    AND (
      cardinality(v_collection) = 0
      OR b.collection_status = ANY (
        SELECT lower(x) FROM unnest(v_collection) AS t(x)
      )
    )
    AND (
      v_q IS NULL
      OR COALESCE(b.doc_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.client_display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.project_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.invoice_doc_number, '') ILIKE '%' || v_q || '%'
    )
    AND (
      p_cursor_id IS NULL
      OR (
        v_sort = 'issued_at' AND v_dir = 'desc'
        AND (b.sort_issued_at, b.id) < (p_cursor_value::timestamptz, p_cursor_id)
      )
      OR (
        v_sort = 'issued_at' AND v_dir = 'asc'
        AND (b.sort_issued_at, b.id) > (p_cursor_value::timestamptz, p_cursor_id)
      )
      OR (
        v_sort = 'doc_number' AND v_dir = 'desc'
        AND (b.sort_doc_number, b.id) < (p_cursor_value, p_cursor_id)
      )
      OR (
        v_sort = 'doc_number' AND v_dir = 'asc'
        AND (b.sort_doc_number, b.id) > (p_cursor_value, p_cursor_id)
      )
      OR (
        v_sort = 'total' AND v_dir = 'desc'
        AND (b.sort_total, b.id) < (p_cursor_value::numeric, p_cursor_id)
      )
      OR (
        v_sort = 'total' AND v_dir = 'asc'
        AND (b.sort_total, b.id) > (p_cursor_value::numeric, p_cursor_id)
      )
    )
  ),
  totals AS (
    SELECT COUNT(*)::bigint AS total_count
    FROM balanced b
    WHERE (
      cardinality(v_billing) = 0
      OR b.billing_status = ANY (SELECT lower(x) FROM unnest(v_billing) AS t(x))
    )
    AND (
      cardinality(v_collection) = 0
      OR b.collection_status = ANY (SELECT lower(x) FROM unnest(v_collection) AS t(x))
    )
    AND (
      v_q IS NULL
      OR COALESCE(b.doc_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.client_display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.project_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.invoice_doc_number, '') ILIKE '%' || v_q || '%'
    )
  ),
  ranked AS (
    SELECT
      f.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN v_sort = 'issued_at' AND v_dir = 'asc' THEN f.sort_issued_at END ASC NULLS LAST,
          CASE WHEN v_sort = 'issued_at' AND v_dir = 'desc' THEN f.sort_issued_at END DESC NULLS LAST,
          CASE WHEN v_sort = 'doc_number' AND v_dir = 'asc' THEN f.sort_doc_number END ASC,
          CASE WHEN v_sort = 'doc_number' AND v_dir = 'desc' THEN f.sort_doc_number END DESC,
          CASE WHEN v_sort = 'total' AND v_dir = 'asc' THEN f.sort_total END ASC,
          CASE WHEN v_sort = 'total' AND v_dir = 'desc' THEN f.sort_total END DESC,
          CASE WHEN v_dir = 'asc' THEN f.id END ASC,
          CASE WHEN v_dir = 'desc' THEN f.id END DESC
      ) AS rn
    FROM filtered f
  ),
  page AS (
    SELECT * FROM ranked WHERE rn <= v_limit + 1
  ),
  page_trim AS (
    SELECT * FROM page WHERE rn <= v_limit
  ),
  last_row AS (
    SELECT * FROM page_trim WHERE rn = (SELECT MAX(rn) FROM page_trim)
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
          'billing_status', p.billing_status,
          'collection_status', p.collection_status,
          'total', p.total,
          'total_cents', p.total_cents,
          'paid_cents', p.paid_cents,
          'remaining_cents', p.remaining_cents,
          'issued_at', p.issued_at,
          'issued_on', p.issued_on,
          'created_at', p.created_at,
          'invoice_id', p.invoice_id,
          'invoice_doc_number', p.invoice_doc_number
        )
        ORDER BY p.rn
      )
      FROM page_trim p
    ), '[]'::jsonb),
    totals.total_count,
    CASE
      WHEN EXISTS (SELECT 1 FROM page WHERE rn = v_limit + 1) THEN
        CASE v_sort
          WHEN 'issued_at' THEN (SELECT sort_issued_at::text FROM last_row)
          WHEN 'doc_number' THEN (SELECT sort_doc_number FROM last_row)
          WHEN 'total' THEN (SELECT sort_total::text FROM last_row)
        END
      ELSE NULL
    END,
    CASE
      WHEN EXISTS (SELECT 1 FROM page WHERE rn = v_limit + 1) THEN (SELECT id FROM last_row)
      ELSE NULL
    END,
    EXISTS (SELECT 1 FROM page WHERE rn = v_limit + 1)
  FROM totals;
END;
$$;

REVOKE ALL ON FUNCTION api.list_sales_delivery_notes_page(
  uuid, uuid, text, text[], text[], int, timestamptz, timestamptz,
  text, text, text, uuid, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_sales_delivery_notes_page(
  uuid, uuid, text, text[], text[], int, timestamptz, timestamptz,
  text, text, text, uuid, int
) TO authenticated, service_role;

COMMENT ON FUNCTION api.list_sales_delivery_notes_page(
  uuid, uuid, text, text[], text[], int, timestamptz, timestamptz,
  text, text, text, uuid, int
) IS
  'CF-27 Sales 4: keyset DN hub. Balances scoped to candidate project_ids; billing from active invoice_delivery_notes.';

-- ---------------------------------------------------------------------------
-- 3. list_sales_invoices_page
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_sales_invoices_page(
  p_client_id uuid DEFAULT NULL,
  p_project_id uuid DEFAULT NULL,
  p_q text DEFAULT NULL,
  p_document_status text[] DEFAULT NULL,
  p_collection_status text[] DEFAULT NULL,
  p_year int DEFAULT NULL,
  p_date_from date DEFAULT NULL,
  p_date_to date DEFAULT NULL,
  p_sort text DEFAULT 'issued_at',
  p_dir text DEFAULT 'desc',
  p_cursor_value text DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_limit int DEFAULT 50
)
RETURNS TABLE (
  items jsonb,
  total_count bigint,
  next_cursor_value text,
  next_cursor_id uuid,
  has_more boolean
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(btrim(COALESCE(p_q, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_sort text := lower(COALESCE(NULLIF(btrim(p_sort), ''), 'issued_at'));
  v_dir text := CASE
    WHEN lower(COALESCE(NULLIF(btrim(p_dir), ''), 'desc')) = 'asc' THEN 'asc'
    ELSE 'desc'
  END;
  v_doc_status text[] := COALESCE(p_document_status, ARRAY[]::text[]);
  v_collection text[] := COALESCE(p_collection_status, ARRAY[]::text[]);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  IF v_sort NOT IN ('issued_at', 'doc_number', 'total') THEN
    RAISE EXCEPTION 'invalid_sort' USING ERRCODE = 'P0001';
  END IF;
  IF (p_cursor_value IS NULL) IS DISTINCT FROM (p_cursor_id IS NULL) THEN
    RAISE EXCEPTION 'invalid_cursor' USING ERRCODE = 'P0001';
  END IF;
  IF v_q IS NOT NULL AND char_length(v_q) < 2 THEN
    RAISE EXCEPTION 'q_too_short' USING ERRCODE = 'P0001';
  END IF;
  IF cardinality(v_doc_status) > 0
     AND EXISTS (
       SELECT 1 FROM unnest(v_doc_status) s(x)
       WHERE lower(x) NOT IN ('draft', 'issued', 'cancelled')
     ) THEN
    RAISE EXCEPTION 'invalid_document_status' USING ERRCODE = 'P0001';
  END IF;
  IF cardinality(v_collection) > 0
     AND EXISTS (
       SELECT 1 FROM unnest(v_collection) s(x)
       WHERE lower(x) NOT IN ('pending', 'partial', 'paid')
     ) THEN
    RAISE EXCEPTION 'invalid_collection_status' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  WITH invoices AS (
    SELECT d.*
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant_id
      AND d.doc_type = 'invoice'
      AND (p_client_id IS NULL OR d.client_id = p_client_id)
      AND (
        p_project_id IS NULL
        OR EXISTS (
          SELECT 1
          FROM data.invoice_delivery_notes link
          JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
          WHERE link.invoice_id = d.id
            AND link.released_at IS NULL
            AND dn.project_id = p_project_id
        )
      )
      AND (
        p_year IS NULL
        OR EXTRACT(YEAR FROM COALESCE(d.issued_on, (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date))
           = p_year
      )
      AND (
        p_date_from IS NULL
        OR COALESCE(d.issued_on, (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date) >= p_date_from
      )
      AND (
        p_date_to IS NULL
        OR COALESCE(d.issued_on, (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date) <= p_date_to
      )
      AND (
        cardinality(v_doc_status) = 0
        OR d.status = ANY (SELECT lower(x) FROM unnest(v_doc_status) AS t(x))
      )
  ),
  candidate_projects AS (
    SELECT COALESCE(
      ARRAY_AGG(DISTINCT dn.project_id) FILTER (WHERE dn.project_id IS NOT NULL),
      ARRAY[]::uuid[]
    ) AS project_ids
    FROM invoices i
    JOIN data.invoice_delivery_notes link
      ON link.invoice_id = i.id AND link.released_at IS NULL
    JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
  ),
  dn_meta AS (
    SELECT
      link.invoice_id,
      COUNT(*)::int AS delivery_count,
      COALESCE(
        jsonb_agg(dn.doc_number ORDER BY COALESCE(dn.issued_at, dn.created_at), dn.id)
          FILTER (WHERE dn.doc_number IS NOT NULL),
        '[]'::jsonb
      ) AS delivery_numbers
    FROM data.invoice_delivery_notes link
    JOIN invoices i ON i.id = link.invoice_id
    JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
    WHERE link.released_at IS NULL
    GROUP BY link.invoice_id
  ),
  open_balance AS (
    SELECT
      link.invoice_id,
      COALESCE(SUM(b.remaining_cents), 0)::bigint AS remaining_cents,
      COALESCE(SUM(b.own_paid_cents + b.advance_applied_cents), 0)::bigint AS paid_cents
    FROM data.invoice_delivery_notes link
    JOIN invoices i ON i.id = link.invoice_id
    CROSS JOIN candidate_projects cp
    LEFT JOIN LATERAL data.delivery_balances(v_tenant_id, cp.project_ids) b
      ON b.delivery_note_id = link.delivery_note_id
    WHERE link.released_at IS NULL
    GROUP BY link.invoice_id
  ),
  external_ref AS (
    SELECT DISTINCT ON (r.document_id)
      r.document_id,
      r.external_number,
      r.provider
    FROM data.commercial_document_external_refs r
    JOIN invoices i ON i.id = r.document_id
    ORDER BY r.document_id, r.updated_at DESC NULLS LAST, r.created_at DESC
  ),
  enriched AS (
    SELECT
      i.id,
      i.doc_number,
      i.client_id,
      i.status AS document_status,
      i.total,
      i.issued_at,
      i.issued_on,
      i.created_at,
      COALESCE(i.issued_at, i.created_at) AS sort_issued_at,
      COALESCE(i.doc_number, '') AS sort_doc_number,
      COALESCE(i.total, 0) AS sort_total,
      COALESCE(
        NULLIF(btrim(c.display_name), ''),
        NULLIF(btrim(i.buyer_snapshot ->> 'display_name'), ''),
        ''
      ) AS client_display_name,
      data.commercial_document_total_cents(i.total)::bigint AS total_cents,
      COALESCE(m.delivery_count, 0) AS delivery_count,
      COALESCE(m.delivery_numbers, '[]'::jsonb) AS delivery_numbers,
      COALESCE(o.paid_cents, 0)::bigint AS paid_cents,
      CASE
        WHEN i.status = 'cancelled' THEN 0::bigint
        WHEN i.status = 'draft' THEN data.commercial_document_total_cents(i.total)::bigint
        ELSE COALESCE(o.remaining_cents, data.commercial_document_total_cents(i.total))::bigint
      END AS remaining_cents,
      xref.external_number AS external_ref,
      xref.provider AS external_provider,
      'pending'::text AS review_status,
      'none'::text AS export_status
    FROM invoices i
    LEFT JOIN data.contacts c ON c.id = i.client_id AND c.tenant_id = i.tenant_id
    LEFT JOIN dn_meta m ON m.invoice_id = i.id
    LEFT JOIN open_balance o ON o.invoice_id = i.id
    LEFT JOIN external_ref xref ON xref.document_id = i.id
  ),
  balanced AS (
    SELECT
      e.*,
      CASE
        WHEN e.document_status = 'cancelled' THEN 'paid'
        WHEN e.document_status = 'draft' THEN 'pending'
        WHEN e.remaining_cents = 0 THEN 'paid'
        WHEN e.paid_cents <= 0 THEN 'pending'
        ELSE 'partial'
      END AS collection_status
    FROM enriched e
  ),
  filtered AS (
    SELECT b.*
    FROM balanced b
    WHERE (
      cardinality(v_collection) = 0
      OR b.collection_status = ANY (
        SELECT lower(x) FROM unnest(v_collection) AS t(x)
      )
    )
    AND (
      v_q IS NULL
      OR COALESCE(b.doc_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.client_display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.external_ref, '') ILIKE '%' || v_q || '%'
    )
    AND (
      p_cursor_id IS NULL
      OR (
        v_sort = 'issued_at' AND v_dir = 'desc'
        AND (b.sort_issued_at, b.id) < (p_cursor_value::timestamptz, p_cursor_id)
      )
      OR (
        v_sort = 'issued_at' AND v_dir = 'asc'
        AND (b.sort_issued_at, b.id) > (p_cursor_value::timestamptz, p_cursor_id)
      )
      OR (
        v_sort = 'doc_number' AND v_dir = 'desc'
        AND (b.sort_doc_number, b.id) < (p_cursor_value, p_cursor_id)
      )
      OR (
        v_sort = 'doc_number' AND v_dir = 'asc'
        AND (b.sort_doc_number, b.id) > (p_cursor_value, p_cursor_id)
      )
      OR (
        v_sort = 'total' AND v_dir = 'desc'
        AND (b.sort_total, b.id) < (p_cursor_value::numeric, p_cursor_id)
      )
      OR (
        v_sort = 'total' AND v_dir = 'asc'
        AND (b.sort_total, b.id) > (p_cursor_value::numeric, p_cursor_id)
      )
    )
  ),
  totals AS (
    SELECT COUNT(*)::bigint AS total_count
    FROM balanced b
    WHERE (
      cardinality(v_collection) = 0
      OR b.collection_status = ANY (SELECT lower(x) FROM unnest(v_collection) AS t(x))
    )
    AND (
      v_q IS NULL
      OR COALESCE(b.doc_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.client_display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.external_ref, '') ILIKE '%' || v_q || '%'
    )
  ),
  ranked AS (
    SELECT
      f.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN v_sort = 'issued_at' AND v_dir = 'asc' THEN f.sort_issued_at END ASC NULLS LAST,
          CASE WHEN v_sort = 'issued_at' AND v_dir = 'desc' THEN f.sort_issued_at END DESC NULLS LAST,
          CASE WHEN v_sort = 'doc_number' AND v_dir = 'asc' THEN f.sort_doc_number END ASC,
          CASE WHEN v_sort = 'doc_number' AND v_dir = 'desc' THEN f.sort_doc_number END DESC,
          CASE WHEN v_sort = 'total' AND v_dir = 'asc' THEN f.sort_total END ASC,
          CASE WHEN v_sort = 'total' AND v_dir = 'desc' THEN f.sort_total END DESC,
          CASE WHEN v_dir = 'asc' THEN f.id END ASC,
          CASE WHEN v_dir = 'desc' THEN f.id END DESC
      ) AS rn
    FROM filtered f
  ),
  page AS (
    SELECT * FROM ranked WHERE rn <= v_limit + 1
  ),
  page_trim AS (
    SELECT * FROM page WHERE rn <= v_limit
  ),
  last_row AS (
    SELECT * FROM page_trim WHERE rn = (SELECT MAX(rn) FROM page_trim)
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'doc_number', p.doc_number,
          'client_id', p.client_id,
          'client_display_name', p.client_display_name,
          'document_status', p.document_status,
          'collection_status', p.collection_status,
          'delivery_count', p.delivery_count,
          'delivery_numbers', p.delivery_numbers,
          'total', p.total,
          'total_cents', p.total_cents,
          'paid_cents', p.paid_cents,
          'remaining_cents', p.remaining_cents,
          'issued_at', p.issued_at,
          'issued_on', p.issued_on,
          'created_at', p.created_at,
          'external_ref', p.external_ref,
          'external_provider', p.external_provider,
          'review_status', p.review_status,
          'export_status', p.export_status
        )
        ORDER BY p.rn
      )
      FROM page_trim p
    ), '[]'::jsonb),
    totals.total_count,
    CASE
      WHEN EXISTS (SELECT 1 FROM page WHERE rn = v_limit + 1) THEN
        CASE v_sort
          WHEN 'issued_at' THEN (SELECT sort_issued_at::text FROM last_row)
          WHEN 'doc_number' THEN (SELECT sort_doc_number FROM last_row)
          WHEN 'total' THEN (SELECT sort_total::text FROM last_row)
        END
      ELSE NULL
    END,
    CASE
      WHEN EXISTS (SELECT 1 FROM page WHERE rn = v_limit + 1) THEN (SELECT id FROM last_row)
      ELSE NULL
    END,
    EXISTS (SELECT 1 FROM page WHERE rn = v_limit + 1)
  FROM totals;
END;
$$;

REVOKE ALL ON FUNCTION api.list_sales_invoices_page(
  uuid, uuid, text, text[], text[], int, date, date,
  text, text, text, uuid, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_sales_invoices_page(
  uuid, uuid, text, text[], text[], int, date, date,
  text, text, text, uuid, int
) TO authenticated, service_role;

COMMENT ON FUNCTION api.list_sales_invoices_page(
  uuid, uuid, text, text[], text[], int, date, date,
  text, text, text, uuid, int
) IS
  'CF-27 Sales 4: keyset invoice hub. DN balances scoped to candidate projects; review/export stubbed until Sales 5.';

NOTIFY pgrst, 'reload schema';
