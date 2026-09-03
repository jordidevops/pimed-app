-- EP-ACC-2a: resolució canònica de public_site per empleat (multi-site URL).

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

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT data.public_portal_enabled_for_tenant(v_emp.tenant_id) THEN
    RAISE EXCEPTION 'public_portal_disabled' USING ERRCODE = 'check_violation';
  END IF;

  SELECT ps.id, ps.site_id, ps.slug, ps.primary_domain_id
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
    RAISE EXCEPTION 'no_published_public_site' USING ERRCODE = 'check_violation';
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

  IF v_emp.site_id IS NOT NULL THEN
    SELECT s.name INTO v_site_name
    FROM data.sites s
    WHERE s.id = v_emp.site_id;
  END IF;

  RETURN jsonb_build_object(
    'public_site_id', v_chosen.id,
    'site_id', v_emp.site_id,
    'site_name', v_site_name,
    'slug', v_chosen.slug,
    'canonical_domain', v_canonical,
    'portal_base_url', v_base_url,
    'fallback_used', v_fallback,
    'tenant_slug', v_emp.tenant_slug
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_public_site_for_employee(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION api.resolve_public_site_for_employee IS
  'Resol el public_site publicat per generar URL del portal d''un empleat. '
  'Prioritat: portal del site físic de l''empleat → portal global del tenant. '
  'Domini: primary_domain_id ssl_active → primer ssl_active → subdomini (portal_base_url NULL).';
