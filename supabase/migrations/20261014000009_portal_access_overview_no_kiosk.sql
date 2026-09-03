-- Overview hub without kiosk/shared_device (companion to 20261014000008)

CREATE OR REPLACE FUNCTION api.list_employee_portal_access_overview(
  p_site_id         uuid DEFAULT NULL,
  p_department_id   uuid DEFAULT NULL,
  p_employee_status text DEFAULT 'active',
  p_portal_filter   text DEFAULT NULL,
  p_search          text DEFAULT NULL,
  p_sort            text DEFAULT 'name',
  p_sort_dir        text DEFAULT 'asc',
  p_limit           int DEFAULT 100,
  p_offset          int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
  v_offset int := GREATEST(COALESCE(p_offset, 0), 0);
  v_sort text := lower(COALESCE(NULLIF(btrim(p_sort), ''), 'name'));
  v_sort_dir text := lower(COALESCE(NULLIF(btrim(p_sort_dir), ''), 'asc'));
  v_search text := NULLIF(lower(btrim(p_search)), '');
  v_status text := NULLIF(lower(btrim(p_employee_status)), '');
  v_portal_filter text := NULLIF(lower(btrim(p_portal_filter)), '');
  v_rows jsonb;
  v_total int;
  v_summary jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'check_violation';
  END IF;

  IF v_sort NOT IN ('name', 'last_access', 'link_created') THEN
    RAISE EXCEPTION 'invalid_sort: %', v_sort USING ERRCODE = 'check_violation';
  END IF;

  IF v_sort_dir NOT IN ('asc', 'desc') THEN
    RAISE EXCEPTION 'invalid_sort_dir: %', v_sort_dir USING ERRCODE = 'check_violation';
  END IF;

  IF v_status IS NOT NULL AND v_status NOT IN ('active', 'inactive', 'terminated', 'all') THEN
    RAISE EXCEPTION 'invalid_employee_status: %', v_status USING ERRCODE = 'check_violation';
  END IF;

  IF v_portal_filter IS NOT NULL AND v_portal_filter NOT IN (
    'no_personal_link',
    'has_personal_link',
    'never_opened',
    'pin_not_configured',
    'missing_document_id'
  ) THEN
    RAISE EXCEPTION 'invalid_portal_filter: %', v_portal_filter USING ERRCODE = 'check_violation';
  END IF;

  WITH permitted AS (
    SELECT
      e.id AS employee_id,
      e.full_name,
      e.document_id,
      e.email,
      e.site_id,
      s.name AS site_name,
      e.department_id,
      e.status,
      api.normalize_employee_document_id(e.document_id) IS NULL AS missing_document_id,
      EXISTS (
        SELECT 1
        FROM data.public_sites ps
        WHERE ps.tenant_id = e.tenant_id
          AND ps.status = 'published'
          AND (e.site_id IS NULL OR ps.site_id IS NULL OR ps.site_id = e.site_id)
      ) AS site_configured
    FROM data.employees e
    LEFT JOIN data.sites s ON s.id = e.site_id
    WHERE e.tenant_id = v_tenant_id
      AND data.jwt_has_permission(v_tenant_id, 'attendance.manage', e.site_id)
      AND (p_site_id IS NULL OR e.site_id IS NOT DISTINCT FROM p_site_id)
      AND (p_department_id IS NULL OR e.department_id IS NOT DISTINCT FROM p_department_id)
      AND (v_status IS NULL OR v_status = 'all' OR e.status = v_status)
      AND (
        v_search IS NULL
        OR lower(COALESCE(e.full_name, '')) LIKE '%' || v_search || '%'
        OR lower(COALESCE(e.email, '')) LIKE '%' || v_search || '%'
        OR lower(COALESCE(e.document_id, '')) LIKE '%' || v_search || '%'
        OR lower(COALESCE(e.job_title, '')) LIKE '%' || v_search || '%'
      )
  ),
  enriched AS (
    SELECT
      p.*,
      personal.token_id AS personal_token_id,
      personal.pin_must_set AS personal_pin_must_set,
      personal.pin_required AS personal_pin_required,
      personal.pin_configured AS personal_pin_configured,
      personal.first_accessed_at AS personal_first_accessed_at,
      personal.last_accessed_at AS personal_last_accessed_at,
      personal.created_at AS personal_created_at,
      personal.label AS personal_label,
      personal.last_accessed_at AS last_access_any
    FROM permitted p
    LEFT JOIN LATERAL (
      SELECT
        t.id AS token_id,
        t.pin_must_set,
        (t.pin_hash IS NOT NULL OR COALESCE(t.pin_must_set, false)) AS pin_required,
        (t.pin_hash IS NOT NULL) AS pin_configured,
        t.first_accessed_at,
        t.last_accessed_at,
        t.created_at,
        t.label
      FROM data.employee_portal_tokens t
      WHERE t.employee_id = p.employee_id
        AND t.is_active = true
        AND t.revoked_at IS NULL
        AND (t.expires_at IS NULL OR t.expires_at > now())
      ORDER BY t.created_at DESC
      LIMIT 1
    ) personal ON true
  ),
  filtered AS (
    SELECT *
    FROM enriched e
    WHERE
      v_portal_filter IS NULL
      OR (v_portal_filter = 'missing_document_id' AND e.missing_document_id)
      OR (v_portal_filter = 'no_personal_link' AND e.personal_token_id IS NULL)
      OR (v_portal_filter = 'has_personal_link' AND e.personal_token_id IS NOT NULL)
      OR (
        v_portal_filter = 'never_opened'
        AND e.personal_token_id IS NOT NULL
        AND e.personal_first_accessed_at IS NULL
      )
      OR (
        v_portal_filter = 'pin_not_configured'
        AND e.personal_token_id IS NOT NULL
        AND COALESCE(e.personal_pin_required, false) = true
        AND COALESCE(e.personal_pin_configured, false) = false
      )
  ),
  paged AS (
    SELECT
      f.employee_id,
      f.full_name,
      f.document_id,
      f.email,
      f.site_id,
      f.site_name,
      f.department_id,
      f.status,
      f.missing_document_id,
      f.site_configured,
      f.last_access_any,
      jsonb_build_object(
        'has_active', f.personal_token_id IS NOT NULL,
        'token_id', f.personal_token_id,
        'pin_must_set', COALESCE(f.personal_pin_must_set, false),
        'pin_required', COALESCE(f.personal_pin_required, false),
        'pin_configured', COALESCE(f.personal_pin_configured, false),
        'first_accessed_at', f.personal_first_accessed_at,
        'last_accessed_at', f.personal_last_accessed_at,
        'created_at', f.personal_created_at,
        'label', f.personal_label
      ) AS personal
    FROM filtered f
    ORDER BY
      CASE WHEN v_sort = 'name' AND v_sort_dir = 'asc' THEN f.full_name END ASC NULLS LAST,
      CASE WHEN v_sort = 'name' AND v_sort_dir = 'desc' THEN f.full_name END DESC NULLS LAST,
      CASE WHEN v_sort = 'last_access' AND v_sort_dir = 'asc' THEN f.last_access_any END ASC NULLS LAST,
      CASE WHEN v_sort = 'last_access' AND v_sort_dir = 'desc' THEN f.last_access_any END DESC NULLS LAST,
      CASE WHEN v_sort = 'link_created' AND v_sort_dir = 'asc' THEN f.personal_created_at END ASC NULLS LAST,
      CASE WHEN v_sort = 'link_created' AND v_sort_dir = 'desc' THEN f.personal_created_at END DESC NULLS LAST,
      f.full_name ASC
    LIMIT v_limit
    OFFSET v_offset
  )
  SELECT
    COALESCE(jsonb_agg(to_jsonb(paged) ORDER BY paged.full_name), '[]'::jsonb),
    (SELECT count(*)::int FROM filtered)
  INTO v_rows, v_total
  FROM paged;

  WITH permitted_active AS (
    SELECT
      e.id AS employee_id,
      api.normalize_employee_document_id(e.document_id) IS NULL AS missing_document_id
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id
      AND e.status = 'active'
      AND data.jwt_has_permission(v_tenant_id, 'attendance.manage', e.site_id)
  ),
  active_enriched AS (
    SELECT
      pa.employee_id,
      pa.missing_document_id,
      personal.token_id AS personal_token_id,
      personal.first_accessed_at AS personal_first_accessed_at
    FROM permitted_active pa
    LEFT JOIN LATERAL (
      SELECT t.id AS token_id, t.first_accessed_at
      FROM data.employee_portal_tokens t
      WHERE t.employee_id = pa.employee_id
        AND t.is_active = true
        AND t.revoked_at IS NULL
        AND (t.expires_at IS NULL OR t.expires_at > now())
      ORDER BY t.created_at DESC
      LIMIT 1
    ) personal ON true
  )
  SELECT jsonb_build_object(
    'total_employees', (SELECT count(*)::int FROM permitted_active),
    'without_personal_link', (
      SELECT count(*)::int FROM active_enriched ae WHERE ae.personal_token_id IS NULL
    ),
    'never_opened', (
      SELECT count(*)::int FROM active_enriched ae
      WHERE ae.personal_token_id IS NOT NULL AND ae.personal_first_accessed_at IS NULL
    ),
    'missing_document_id', (
      SELECT count(*)::int FROM permitted_active pa WHERE pa.missing_document_id
    ),
    'identity_rejected_recent', (
      SELECT count(DISTINCT l.employee_id)::int
      FROM data.employee_portal_access_logs l
      JOIN permitted_active pa ON pa.employee_id = l.employee_id
      WHERE l.tenant_id = v_tenant_id
        AND l.action = 'identity_rejected'
        AND l.accessed_at > now() - interval '7 days'
    )
  )
  INTO v_summary;

  RETURN jsonb_build_object(
    'summary', v_summary,
    'rows', COALESCE(v_rows, '[]'::jsonb),
    'total', COALESCE(v_total, 0)
  );
END;
$$;
