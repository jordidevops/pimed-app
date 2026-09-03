-- EP-ACC-2a fix: resolve_public_site_for_employee és una RPC d'administració
-- (attendance.manage). No ha d'exigir public_portal_enabled ni fallar sense site
-- quan el client pot usar fallbacks de dev (VITE_PUBLIC_PORTAL_BASE_URL).

CREATE OR REPLACE FUNCTION api.resolve_public_site_for_employee(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_chosen record;
  v_fallback boolean := false;
  v_draft_used boolean := false;
  v_canonical text;
  v_base_url text;
  v_site_name text;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, t.slug AS tenant_slug
  INTO v_emp
  FROM data.employees e
  JOIN data.tenants t ON t.id = e.tenant_id
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'no_data_found';
  END IF;

  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
      RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  SELECT ps.id, ps.site_id, ps.slug, ps.primary_domain_id, ps.status
  INTO v_chosen
  FROM data.public_sites ps
  WHERE ps.tenant_id = v_emp.tenant_id
    AND ps.status = 'published'
    AND (
      (v_emp.site_id IS NOT NULL AND ps.site_id = v_emp.site_id)
      OR ps.site_id IS NULL
    )
  ORDER BY
    CASE
      WHEN v_emp.site_id IS NOT NULL AND ps.site_id = v_emp.site_id THEN 0
      ELSE 1
    END,
    ps.created_at ASC,
    ps.id ASC
  LIMIT 1;

  IF v_chosen.id IS NULL THEN
    SELECT ps.id, ps.site_id, ps.slug, ps.primary_domain_id, ps.status
    INTO v_chosen
    FROM data.public_sites ps
    WHERE ps.tenant_id = v_emp.tenant_id
      AND ps.status = 'draft'
      AND (
        (v_emp.site_id IS NOT NULL AND ps.site_id = v_emp.site_id)
        OR ps.site_id IS NULL
      )
    ORDER BY
      CASE
        WHEN v_emp.site_id IS NOT NULL AND ps.site_id = v_emp.site_id THEN 0
        ELSE 1
      END,
      ps.created_at ASC,
      ps.id ASC
    LIMIT 1;

    v_draft_used := v_chosen.id IS NOT NULL;
  END IF;

  IF v_emp.site_id IS NOT NULL THEN
    SELECT s.name INTO v_site_name
    FROM data.sites s
    WHERE s.id = v_emp.site_id;
  END IF;

  IF v_chosen.id IS NULL THEN
    RETURN jsonb_build_object(
      'public_site_id', NULL,
      'site_id', v_emp.site_id,
      'site_name', v_site_name,
      'slug', NULL,
      'canonical_domain', NULL,
      'portal_base_url', NULL,
      'fallback_used', false,
      'draft_site_used', false,
      'site_configured', false,
      'tenant_slug', v_emp.tenant_slug
    );
  END IF;

  v_fallback := v_emp.site_id IS NOT NULL AND v_chosen.site_id IS NULL;

  SELECT d.domain
  INTO v_canonical
  FROM data.public_domains d
  WHERE d.id = v_chosen.primary_domain_id
    AND d.public_site_id = v_chosen.id
    AND d.status = 'ssl_active'
  LIMIT 1;

  IF v_canonical IS NULL THEN
    SELECT d.domain
    INTO v_canonical
    FROM data.public_domains d
    WHERE d.public_site_id = v_chosen.id
      AND d.status = 'ssl_active'
      AND d.domain IS NOT NULL
    ORDER BY d.created_at ASC, d.id ASC
    LIMIT 1;
  END IF;

  IF v_canonical IS NOT NULL THEN
    v_base_url := 'https://' || v_canonical;
  ELSE
    v_base_url := NULL;
  END IF;

  RETURN jsonb_build_object(
    'public_site_id', v_chosen.id,
    'site_id', v_emp.site_id,
    'site_name', v_site_name,
    'slug', v_chosen.slug,
    'canonical_domain', v_canonical,
    'portal_base_url', v_base_url,
    'fallback_used', v_fallback,
    'draft_site_used', v_draft_used,
    'site_configured', true,
    'tenant_slug', v_emp.tenant_slug
  );
END;
$$;

COMMENT ON FUNCTION api.resolve_public_site_for_employee IS
  'Resol el public_site per generar URL del portal d''un empleat (admin). '
  'Prioritat: publicat site físic → publicat global → esborrany → sense site (site_configured=false).';

-- Dades de demo (public_portal_enabled, public_sites acme/beta): només a supabase/seed.sql.
