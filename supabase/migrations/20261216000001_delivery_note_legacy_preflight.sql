-- CF-26 preflight: list delivery-note data that cannot be interpreted as
-- progressive deliveries. Detection only; it does not rewrite documents.

CREATE OR REPLACE FUNCTION api.list_delivery_note_legacy_conflicts(p_tenant_id uuid DEFAULT NULL)
RETURNS TABLE (
  conflict_kind text,
  tenant_id uuid,
  project_id uuid,
  client_id uuid,
  document_id uuid,
  detail text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid := p_tenant_id;
BEGIN
  IF v_tenant IS NULL THEN
    v_tenant := data.active_tenant_id();
  END IF;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF auth.uid() IS NOT NULL
     AND NOT (data.jwt_user_tenants() ? v_tenant::text) THEN
    RAISE EXCEPTION 'tenant_access_denied' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  WITH active_dn AS (
    SELECT d.*
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted')
  ),
  multi AS (
    SELECT
      d.tenant_id,
      d.project_id,
      d.client_id,
      count(*)::int AS dn_count
    FROM active_dn d
    WHERE d.project_id IS NOT NULL
    GROUP BY d.tenant_id, d.project_id, d.client_id
    HAVING count(*) > 1
  ),
  delivered AS (
    SELECT
      pl.tenant_id,
      pl.project_id,
      pl.name,
      pl.quantity AS planned_qty,
      COALESCE(SUM(cdl.quantity), 0) AS delivered_qty
    FROM data.project_lines pl
    JOIN data.commercial_document_lines cdl
      ON cdl.source_project_line_id = pl.id
     AND cdl.tenant_id = pl.tenant_id
    JOIN active_dn d ON d.id = cdl.document_id
    WHERE pl.tenant_id = v_tenant
    GROUP BY pl.tenant_id, pl.project_id, pl.id, pl.name, pl.quantity
    HAVING COALESCE(SUM(cdl.quantity), 0) > pl.quantity
  )
  SELECT
    'multiple_active_delivery_notes'::text,
    m.tenant_id,
    m.project_id,
    m.client_id,
    NULL::uuid,
    format('%s active delivery notes', m.dn_count)
  FROM multi m

  UNION ALL

  SELECT
    'delivered_qty_exceeds_project_line'::text,
    d.tenant_id,
    d.project_id,
    NULL::uuid,
    NULL::uuid,
    format('%s delivered %s of planned %s', d.name, d.delivered_qty, d.planned_qty)
  FROM delivered d

  UNION ALL

  SELECT
    'null_source_project_line'::text,
    dn.tenant_id,
    dn.project_id,
    dn.client_id,
    dn.id,
    format('%s has a line without source_project_line_id', COALESCE(dn.doc_number, dn.id::text))
  FROM active_dn dn
  JOIN data.commercial_document_lines cdl ON cdl.document_id = dn.id
  WHERE cdl.source_project_line_id IS NULL

  UNION ALL

  SELECT
    'invoice_ref_cross_client'::text,
    r.tenant_id,
    NULL::uuid,
    NULL::uuid,
    NULL::uuid,
    format('%s is used by %s clients', r.invoice_ref, r.client_count)
  FROM (
    SELECT
      dn.tenant_id,
      lower(btrim(dn.external_invoice_ref)) AS invoice_ref,
      count(DISTINCT dn.client_id)::int AS client_count
    FROM active_dn dn
    WHERE NULLIF(btrim(COALESCE(dn.external_invoice_ref, '')), '') IS NOT NULL
    GROUP BY dn.tenant_id, lower(btrim(dn.external_invoice_ref))
    HAVING count(DISTINCT dn.client_id) > 1
  ) r;
END;
$$;

REVOKE ALL ON FUNCTION api.list_delivery_note_legacy_conflicts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_delivery_note_legacy_conflicts(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.list_delivery_note_legacy_conflicts(uuid) IS
  'CF-26: reports delivery notes that cannot be treated as progressive deliveries. Does not modify data.';
