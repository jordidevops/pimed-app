-- CF-27 / Sales 4 follow-up: dashboard KPIs for calendar year.
-- Never call delivery_balances(tenant, NULL) — scope by candidate project_ids.

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
  v_tenant uuid := data.active_tenant_id();
  v_year int := COALESCE(p_year, EXTRACT(YEAR FROM CURRENT_DATE)::int);
  v_to_invoice_count bigint := 0;
  v_to_invoice_cents bigint := 0;
  v_pending_collection_cents bigint := 0;
  v_pending_quotes_count bigint := 0;
  v_project_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF to_regprocedure('data.assert_invoice_permission(uuid, text)') IS NOT NULL THEN
    PERFORM data.assert_invoice_permission(v_tenant, 'invoices.view');
  ELSE
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
    END IF;
    IF NOT COALESCE(data.jwt_user_tenants() ? v_tenant::text, false) THEN
      RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  -- to_invoice: active DNs in year without an active invoice link
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

  -- pending_quotes: issued quotes awaiting response in year
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

  -- pending_collection: remaining on scoped DNs for open DNs/invoices in year
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

  RETURN jsonb_build_object(
    'to_invoice_count', v_to_invoice_count,
    'to_invoice_cents', v_to_invoice_cents,
    'pending_collection_cents', v_pending_collection_cents,
    'pending_quotes_count', v_pending_quotes_count,
    'year', v_year
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_sales_dashboard_kpis(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_sales_dashboard_kpis(int)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.get_sales_dashboard_kpis(int) IS
  'CF-27 Sales dashboard KPIs for a calendar year. Balances scoped to candidate project_ids; never delivery_balances(tenant, NULL).';

NOTIFY pgrst, 'reload schema';
