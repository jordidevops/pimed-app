-- CF-26: invoice view of the delivery-note hub.

CREATE OR REPLACE FUNCTION api.list_external_invoices_page(
  p_client_id uuid DEFAULT NULL,
  p_project_id uuid DEFAULT NULL,
  p_q text DEFAULT NULL,
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
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset int := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  WITH invoices AS (
    SELECT i.*
    FROM data.external_invoices i
    WHERE i.tenant_id = v_tenant_id
      AND (p_client_id IS NULL OR i.client_id = p_client_id)
      AND (
        p_project_id IS NULL
        OR EXISTS (
          SELECT 1
          FROM data.external_invoice_delivery_notes link
          JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
          WHERE link.invoice_id = i.id
            AND dn.project_id = p_project_id
        )
      )
  ),
  note_totals AS (
    SELECT
      link.invoice_id,
      COALESCE(SUM(data.commercial_document_total_cents(dn.total)), 0)::bigint AS notes_total_cents,
      COUNT(*)::integer AS delivery_count,
      COALESCE(
        jsonb_agg(dn.doc_number ORDER BY COALESCE(dn.issued_at, dn.created_at), dn.id)
          FILTER (WHERE dn.doc_number IS NOT NULL),
        '[]'::jsonb
      ) AS delivery_numbers
    FROM data.external_invoice_delivery_notes link
    JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
    JOIN invoices i ON i.id = link.invoice_id
    GROUP BY link.invoice_id
  ),
  paid AS (
    SELECT p.external_invoice_id AS invoice_id, COALESCE(SUM(p.amount_cents), 0)::bigint AS paid_cents
    FROM data.payments p
    JOIN invoices i ON i.id = p.external_invoice_id
    WHERE p.tenant_id = v_tenant_id
    GROUP BY p.external_invoice_id
  ),
  open_balance AS (
    SELECT link.invoice_id, COALESCE(SUM(b.remaining_cents), 0)::bigint AS remaining_cents
    FROM data.external_invoice_delivery_notes link
    JOIN invoices i ON i.id = link.invoice_id
    JOIN data.delivery_balances(v_tenant_id, NULL) b ON b.delivery_note_id = link.delivery_note_id
    GROUP BY link.invoice_id
  ),
  enriched AS (
    SELECT
      i.id,
      i.invoice_number,
      i.client_id,
      i.issued_on,
      i.total_cents,
      COALESCE(
        NULLIF(btrim(c.display_name), ''),
        ''
      ) AS client_display_name,
      COALESCE(n.notes_total_cents, 0)::bigint AS notes_total_cents,
      (i.total_cents - COALESCE(n.notes_total_cents, 0))::bigint AS difference_cents,
      COALESCE(n.delivery_count, 0) AS delivery_count,
      COALESCE(n.delivery_numbers, '[]'::jsonb) AS delivery_numbers,
      COALESCE(p.paid_cents, 0)::bigint AS paid_cents,
      COALESCE(o.remaining_cents, 0)::bigint AS remaining_cents
    FROM invoices i
    LEFT JOIN data.contacts c ON c.id = i.client_id AND c.tenant_id = i.tenant_id
    LEFT JOIN note_totals n ON n.invoice_id = i.id
    LEFT JOIN paid p ON p.invoice_id = i.id
    LEFT JOIN open_balance o ON o.invoice_id = i.id
  ),
  filtered AS (
    SELECT e.*
    FROM enriched e
    WHERE v_q IS NULL
       OR e.invoice_number ILIKE '%' || v_q || '%'
       OR e.client_display_name ILIKE '%' || v_q || '%'
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
    ORDER BY f.issued_on DESC, f.invoice_number
    OFFSET v_offset
    LIMIT v_limit
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'invoice_number', p.invoice_number,
          'client_id', p.client_id,
          'client_display_name', p.client_display_name,
          'issued_on', p.issued_on,
          'total_cents', p.total_cents,
          'notes_total_cents', p.notes_total_cents,
          'difference_cents', p.difference_cents,
          'delivery_count', p.delivery_count,
          'delivery_numbers', p.delivery_numbers,
          'paid_cents', p.paid_cents,
          'remaining_cents', p.remaining_cents
        )
        ORDER BY p.issued_on DESC, p.invoice_number
      )
      FROM page p
    ), '[]'::jsonb),
    totals.total_count,
    totals.total_remaining_cents
  FROM totals;
END;
$$;

REVOKE ALL ON FUNCTION api.list_external_invoices_page(uuid, uuid, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_external_invoices_page(uuid, uuid, text, int, int)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
