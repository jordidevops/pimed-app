-- Rank same-client jobs first; do not hide other clients from search.

CREATE OR REPLACE FUNCTION api.search_jobs_for_pricing(
  p_query text DEFAULT NULL,
  p_client_id uuid DEFAULT NULL,
  p_exclude_project_id uuid DEFAULT NULL,
  p_completed_only boolean DEFAULT false,
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_limit int DEFAULT 30
)
RETURNS TABLE (
  id uuid,
  name text,
  status text,
  client_id uuid,
  client_display_name text,
  site_id uuid,
  updated_at timestamptz,
  created_at timestamptz,
  line_count int,
  subtotal numeric,
  same_client boolean
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(trim(COALESCE(p_query, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 50);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.name::text,
    p.status::text,
    p.client_id,
    COALESCE(NULLIF(trim(c.display_name), ''), NULLIF(trim(c.legal_name), ''), '')::text AS client_display_name,
    p.site_id,
    p.updated_at,
    p.created_at,
    agg.line_count,
    agg.subtotal,
    (p_client_id IS NOT NULL AND p.client_id IS NOT DISTINCT FROM p_client_id) AS same_client
  FROM data.projects p
  LEFT JOIN data.contacts c
    ON c.id = p.client_id AND c.tenant_id = p.tenant_id
  INNER JOIN LATERAL (
    SELECT
      COUNT(*)::int AS line_count,
      COALESCE(SUM(
        pl.quantity * pl.unit_price * (1 - COALESCE(pl.discount_pct, 0) / 100)
      ), 0) AS subtotal
    FROM data.project_lines pl
    WHERE pl.project_id = p.id AND pl.tenant_id = p.tenant_id
  ) agg ON agg.line_count > 0
  WHERE p.tenant_id = v_tenant_id
    AND p.type IN ('work_order', 'maintenance')
    AND (p_exclude_project_id IS NULL OR p.id <> p_exclude_project_id)
    AND (NOT COALESCE(p_completed_only, false) OR p.status = 'completed')
    AND (p_from IS NULL OR p.updated_at >= p_from)
    AND (p_to IS NULL OR p.updated_at <= p_to)
    AND (
      v_q IS NULL
      OR p.name ILIKE '%' || v_q || '%'
      OR COALESCE(c.display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(c.legal_name, '') ILIKE '%' || v_q || '%'
      OR EXISTS (
        SELECT 1
        FROM data.project_lines pl2
        WHERE pl2.project_id = p.id
          AND pl2.tenant_id = p.tenant_id
          AND pl2.name ILIKE '%' || v_q || '%'
      )
    )
  ORDER BY
    (p_client_id IS NOT NULL AND p.client_id IS NOT DISTINCT FROM p_client_id) DESC,
    p.updated_at DESC
  LIMIT v_limit;
END;
$$;

NOTIFY pgrst, 'reload schema';
