-- =============================================================================
-- Migration: labor calendar assignment RPCs
-- Date: 2026-05-21
-- Purpose:
--   - Provide stable API RPCs for assigning/removing holiday calendars to sites
--   - Avoid relying on direct writes against api.site_holiday_calendar_assignments view
-- =============================================================================

CREATE OR REPLACE FUNCTION api.assign_site_holiday_calendar(
  p_site_id uuid,
  p_calendar_id uuid,
  p_priority smallint DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, api
AS $$
DECLARE
  v_assignment_id uuid;
BEGIN
  IF p_site_id IS NULL OR p_calendar_id IS NULL THEN
    RAISE EXCEPTION 'invalid_params: site_id and calendar_id are required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM data.sites s
    JOIN data.holiday_calendars hc ON hc.id = p_calendar_id
    WHERE s.id = p_site_id
      AND s.tenant_id = hc.tenant_id
  ) THEN
    RAISE EXCEPTION 'site_calendar_tenant_mismatch'
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.site_holiday_calendar_assignments (site_id, calendar_id, priority)
  VALUES (p_site_id, p_calendar_id, COALESCE(p_priority, 0))
  ON CONFLICT (site_id, calendar_id) DO NOTHING
  RETURNING id INTO v_assignment_id;

  IF v_assignment_id IS NULL THEN
    SELECT shca.id
      INTO v_assignment_id
    FROM data.site_holiday_calendar_assignments shca
    WHERE shca.site_id = p_site_id
      AND shca.calendar_id = p_calendar_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'assignment_id', v_assignment_id,
    'site_id', p_site_id,
    'calendar_id', p_calendar_id,
    'priority', COALESCE(p_priority, 0)
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.remove_site_holiday_calendar_assignment(
  p_assignment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, api
AS $$
DECLARE
  v_site_id uuid;
  v_calendar_id uuid;
  v_deleted integer := 0;
BEGIN
  IF p_assignment_id IS NULL THEN
    RAISE EXCEPTION 'invalid_params: assignment_id is required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT shca.site_id, shca.calendar_id
    INTO v_site_id, v_calendar_id
  FROM data.site_holiday_calendar_assignments shca
  WHERE shca.id = p_assignment_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'deleted', false,
      'assignment_id', p_assignment_id
    );
  END IF;

  DELETE FROM data.site_holiday_calendar_assignments
  WHERE id = p_assignment_id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'success', true,
    'deleted', (v_deleted = 1),
    'assignment_id', p_assignment_id,
    'site_id', v_site_id,
    'calendar_id', v_calendar_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.assign_site_holiday_calendar(uuid, uuid, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION api.assign_site_holiday_calendar(uuid, uuid, smallint) TO service_role;

GRANT EXECUTE ON FUNCTION api.remove_site_holiday_calendar_assignment(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.remove_site_holiday_calendar_assignment(uuid) TO service_role;
