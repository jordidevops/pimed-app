-- CF-15: tenant-scoped search for commercial documents (quotes section).

CREATE INDEX IF NOT EXISTS idx_commercial_document_lines_tenant_name
  ON data.commercial_document_lines (tenant_id, name);

CREATE OR REPLACE FUNCTION api.search_commercial_documents(
  p_q text DEFAULT NULL,
  p_doc_types text[] DEFAULT NULL,
  p_statuses text[] DEFAULT NULL,
  p_issued_from timestamptz DEFAULT NULL,
  p_issued_to timestamptz DEFAULT NULL,
  p_expired_only boolean DEFAULT false,
  p_total_min numeric DEFAULT NULL,
  p_total_max numeric DEFAULT NULL,
  p_limit int DEFAULT 100
)
RETURNS TABLE (
  id uuid,
  tenant_id uuid,
  doc_type text,
  doc_number text,
  client_id uuid,
  project_id uuid,
  status text,
  subtotal numeric,
  total numeric,
  show_prices boolean,
  issued_at timestamptz,
  valid_until timestamptz,
  parent_document_id uuid,
  supersedes_id uuid,
  created_at timestamptz,
  client_display_name text,
  project_name text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(trim(COALESCE(p_q, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    d.id,
    d.tenant_id,
    d.doc_type,
    d.doc_number,
    d.client_id,
    d.project_id,
    d.status,
    d.subtotal,
    d.total,
    d.show_prices,
    d.issued_at,
    d.valid_until,
    d.parent_document_id,
    d.supersedes_id,
    d.created_at,
    COALESCE(
      NULLIF(trim(c.display_name), ''),
      NULLIF(trim(d.buyer_snapshot ->> 'display_name'), ''),
      NULLIF(trim(d.buyer_snapshot ->> 'legal_name'), ''),
      ''
    ) AS client_display_name,
    p.name AS project_name
  FROM data.commercial_documents d
  LEFT JOIN data.contacts c
    ON c.id = d.client_id AND c.tenant_id = d.tenant_id
  LEFT JOIN data.projects p
    ON p.id = d.project_id AND p.tenant_id = d.tenant_id
  WHERE d.tenant_id = v_tenant_id
    AND (p_doc_types IS NULL OR cardinality(p_doc_types) = 0 OR d.doc_type = ANY (p_doc_types))
    AND (p_statuses IS NULL OR cardinality(p_statuses) = 0 OR d.status = ANY (p_statuses))
    AND (p_issued_from IS NULL OR COALESCE(d.issued_at, d.created_at) >= p_issued_from)
    AND (p_issued_to IS NULL OR COALESCE(d.issued_at, d.created_at) <= p_issued_to)
    AND (
      NOT COALESCE(p_expired_only, false)
      OR (
        d.status = 'issued'
        AND d.valid_until IS NOT NULL
        AND d.valid_until < now()
        AND d.doc_type IN ('quote', 'quote_amendment')
      )
      OR d.status = 'expired'
    )
    AND (p_total_min IS NULL OR d.total >= p_total_min)
    AND (p_total_max IS NULL OR d.total <= p_total_max)
    AND (
      v_q IS NULL
      OR d.doc_number ILIKE '%' || v_q || '%'
      OR COALESCE(c.display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(c.legal_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(d.buyer_snapshot ->> 'display_name', '') ILIKE '%' || v_q || '%'
      OR COALESCE(d.buyer_snapshot ->> 'legal_name', '') ILIKE '%' || v_q || '%'
      OR COALESCE(p.name, '') ILIKE '%' || v_q || '%'
      OR EXISTS (
        SELECT 1
        FROM data.commercial_document_lines l
        WHERE l.document_id = d.id
          AND l.tenant_id = d.tenant_id
          AND (
            COALESCE(l.name, '') ILIKE '%' || v_q || '%'
            OR COALESCE(l.description, '') ILIKE '%' || v_q || '%'
          )
      )
    )
  ORDER BY COALESCE(d.issued_at, d.created_at) DESC, d.created_at DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION api.search_commercial_documents(
  text, text[], text[], timestamptz, timestamptz, boolean, numeric, numeric, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_commercial_documents(
  text, text[], text[], timestamptz, timestamptz, boolean, numeric, numeric, int
) TO authenticated, service_role;

COMMENT ON FUNCTION api.search_commercial_documents(
  text, text[], text[], timestamptz, timestamptz, boolean, numeric, numeric, int
) IS
  'CF-15: search commercial documents by number, client, project name or line text.';
