-- resolve_attendance_geo_enabled: suport service_role (portal punch sense auth.users)

CREATE OR REPLACE FUNCTION data.resolve_attendance_geo_enabled(p_employee_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_dept_enabled boolean;
  v_group_enabled boolean;
  v_settings jsonb;
BEGIN
  SELECT
    e.attendance_geo_enabled,
    e.department_id,
    e.calendar_group_id,
    e.site_id,
    e.tenant_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_emp.attendance_geo_enabled IS NOT NULL THEN
    RETURN v_emp.attendance_geo_enabled;
  END IF;

  IF v_emp.department_id IS NOT NULL THEN
    SELECT d.attendance_geo_enabled
    INTO v_dept_enabled
    FROM data.departments d
    WHERE d.id = v_emp.department_id;

    IF v_dept_enabled IS NOT NULL THEN
      RETURN v_dept_enabled;
    END IF;
  END IF;

  IF v_emp.calendar_group_id IS NOT NULL THEN
    SELECT cg.attendance_geo_enabled
    INTO v_group_enabled
    FROM data.calendar_groups cg
    WHERE cg.id = v_emp.calendar_group_id;

    IF v_group_enabled IS NOT NULL THEN
      RETURN v_group_enabled;
    END IF;
  END IF;

  IF auth.uid() IS NULL THEN
    v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  ELSE
    v_settings := api.get_effective_settings(
      p_site_id => v_emp.site_id,
      p_user_id => auth.uid(),
      p_tenant_id => v_emp.tenant_id
    );
  END IF;

  IF v_settings ? 'attendance_geo_enabled'
     AND NULLIF(v_settings ->> 'attendance_geo_enabled', '') IS NOT NULL THEN
    RETURN (v_settings ->> 'attendance_geo_enabled')::boolean;
  END IF;

  RETURN COALESCE((v_settings ->> 'attendance_location_consent_required')::boolean, false);
END;
$$;

NOTIFY pgrst, 'reload schema';
