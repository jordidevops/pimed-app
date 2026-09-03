-- Delete calendar groups safely (reassign or unassign employees first).

CREATE OR REPLACE FUNCTION api.list_calendar_group_employees(p_group_id uuid)
RETURNS TABLE (
  employee_id uuid,
  full_name   text,
  site_id     uuid
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = api, data, public
AS $$
  SELECT e.id, e.full_name, e.site_id
  FROM data.employees e
  WHERE e.tenant_id = data.active_tenant_id()
    AND e.calendar_group_id = p_group_id
    AND e.status = 'active'
  ORDER BY e.full_name;
$$;

GRANT EXECUTE ON FUNCTION api.list_calendar_group_employees(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.delete_calendar_group(
  p_group_id              uuid,
  p_reassign_to_group_id  uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id      uuid := data.active_tenant_id();
  v_group_site_id  uuid;
  v_target_site_id uuid;
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required';
  END IF;

  SELECT site_id INTO v_group_site_id
  FROM data.calendar_groups
  WHERE id = p_group_id AND tenant_id = v_tenant_id AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'calendar_group_not_found';
  END IF;

  IF p_reassign_to_group_id IS NOT NULL THEN
    IF p_reassign_to_group_id = p_group_id THEN
      RAISE EXCEPTION 'cannot_reassign_to_same_group';
    END IF;

    SELECT site_id INTO v_target_site_id
    FROM data.calendar_groups
    WHERE id = p_reassign_to_group_id AND tenant_id = v_tenant_id AND is_active = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'reassign_group_not_found';
    END IF;

    IF v_target_site_id IS NOT NULL AND EXISTS (
      SELECT 1
      FROM data.employees e
      WHERE e.tenant_id = v_tenant_id
        AND e.calendar_group_id = p_group_id
        AND e.status = 'active'
        AND e.site_id IS DISTINCT FROM v_target_site_id
    ) THEN
      RAISE EXCEPTION 'reassign_site_mismatch: alguns empleats no pertanyen al local del grup de destí';
    END IF;

    UPDATE data.employees
    SET calendar_group_id = p_reassign_to_group_id,
        updated_at        = now()
    WHERE tenant_id = v_tenant_id
      AND calendar_group_id = p_group_id;
  ELSE
    UPDATE data.employees
    SET calendar_group_id = NULL,
        updated_at        = now()
    WHERE tenant_id = v_tenant_id
      AND calendar_group_id = p_group_id;
  END IF;

  DELETE FROM data.calendar_groups
  WHERE id = p_group_id AND tenant_id = v_tenant_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_calendar_group(uuid, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
