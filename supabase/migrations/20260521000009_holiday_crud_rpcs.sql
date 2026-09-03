-- =============================================================================
-- Migration: 20260521000009_holiday_crud_rpcs.sql
-- RPCs per al CRUD individual de festius (crear, actualitzar, eliminar)
--
-- Patró: SECURITY DEFINER + jwt_has_permission('labor_calendar.manage')
-- Permet crear/editar/eliminar festius individuals sense necessitat que la
-- vista api.holidays sigui auto-updatable (té JOIN, no ho és).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. api.create_holiday — Crea o actualitza un festiu (upsert per data)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_holiday(
  p_calendar_id    uuid,
  p_date           date,
  p_name           text,
  p_holiday_type   text    DEFAULT 'tenant_custom',
  p_is_half_day    boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_cal    data.holiday_calendars;
  v_result data.holidays;
BEGIN
  SELECT * INTO v_cal
  FROM data.holiday_calendars
  WHERE id = p_calendar_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'holiday_calendar_not_found: %', p_calendar_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_cal.tenant_id IS NULL THEN
    RAISE EXCEPTION 'cannot_modify_system_calendar'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT data.jwt_has_permission(v_cal.tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_holiday_type NOT IN ('national', 'regional', 'local', 'tenant_custom') THEN
    RAISE EXCEPTION 'invalid_holiday_type: %', p_holiday_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO data.holidays (calendar_id, date, name, holiday_type, is_half_day)
  VALUES (p_calendar_id, p_date, p_name, p_holiday_type, p_is_half_day)
  ON CONFLICT (calendar_id, date) DO UPDATE
    SET name         = EXCLUDED.name,
        holiday_type = EXCLUDED.holiday_type,
        is_half_day  = EXCLUDED.is_half_day
  RETURNING * INTO v_result;

  RETURN to_jsonb(v_result);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_holiday(uuid, date, text, text, boolean) TO authenticated;


-- ---------------------------------------------------------------------------
-- 2. api.update_holiday — Actualitza un festiu existent per id
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.update_holiday(
  p_id           uuid,
  p_date         date,
  p_name         text,
  p_holiday_type text,
  p_is_half_day  boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_cal    data.holiday_calendars;
  v_result data.holidays;
BEGIN
  SELECT hc.* INTO v_cal
  FROM data.holiday_calendars hc
  JOIN data.holidays h ON h.calendar_id = hc.id
  WHERE h.id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'holiday_not_found: %', p_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_cal.tenant_id IS NULL THEN
    RAISE EXCEPTION 'cannot_modify_system_calendar'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT data.jwt_has_permission(v_cal.tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_holiday_type NOT IN ('national', 'regional', 'local', 'tenant_custom') THEN
    RAISE EXCEPTION 'invalid_holiday_type: %', p_holiday_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE data.holidays
  SET date         = p_date,
      name         = p_name,
      holiday_type = p_holiday_type,
      is_half_day  = p_is_half_day
  WHERE id = p_id
  RETURNING * INTO v_result;

  RETURN to_jsonb(v_result);
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_holiday(uuid, date, text, text, boolean) TO authenticated;


-- ---------------------------------------------------------------------------
-- 3. api.delete_holiday — Elimina un festiu per id
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.delete_holiday(
  p_id   uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_cal data.holiday_calendars;
BEGIN
  SELECT hc.* INTO v_cal
  FROM data.holiday_calendars hc
  JOIN data.holidays h ON h.calendar_id = hc.id
  WHERE h.id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'holiday_not_found: %', p_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_cal.tenant_id IS NULL THEN
    RAISE EXCEPTION 'cannot_modify_system_calendar'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT data.jwt_has_permission(v_cal.tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  DELETE FROM data.holidays WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_holiday(uuid) TO authenticated;
