-- Delete manual calendar events: owner OR calendar.manage; never derived entity types.

CREATE OR REPLACE FUNCTION api.delete_manual_calendar_event(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_user uuid := auth.uid();
  v_row data.calendar_events%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL OR NOT COALESCE(data.jwt_user_tenants() ? v_tenant::text, false) THEN
    RAISE EXCEPTION 'tenant_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'event_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_row
  FROM data.calendar_events
  WHERE id = p_id
    AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_row.entity_type IS DISTINCT FROM 'manual' THEN
    RAISE EXCEPTION 'not_manual_event' USING ERRCODE = 'P0001';
  END IF;

  IF v_row.owner_id IS DISTINCT FROM v_user
     AND NOT data.jwt_has_permission(v_tenant, 'calendar.manage', v_row.site_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM data.calendar_events WHERE id = v_row.id;

  RETURN jsonb_build_object('id', v_row.id, 'deleted', true);
END;
$$;

REVOKE ALL ON FUNCTION api.delete_manual_calendar_event(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.delete_manual_calendar_event(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.delete_manual_calendar_event(uuid) IS
  'Deletes a manual calendar_events row when actor is owner or has calendar.manage. Derived events are rejected.';

NOTIFY pgrst, 'reload schema';
