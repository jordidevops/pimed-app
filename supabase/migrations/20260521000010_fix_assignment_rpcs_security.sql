-- =============================================================================
-- Migration: 20260521000010_fix_assignment_rpcs_security.sql
--
-- Problema: assign_site_holiday_calendar, remove_site_holiday_calendar_assignment,
--           assign_tenant_holiday_calendar, remove_tenant_holiday_calendar_assignment
--           eren SECURITY INVOKER → la RLS de INSERT/DELETE bloquejava l'operació
--           si el claim jwt_has_permission no era al token en aquell moment.
--
-- Solució: convertir-los a SECURITY DEFINER + validació explícita de permís,
--          igual que el patró dels RPCs de CRUD de festius (migr. 00009).
--
-- Afegit: api.delete_holiday_calendar — elimina un calendari del tenant
--         (cascada sobre holidays, site_assignments i tenant_assignments).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. api.assign_site_holiday_calendar  (SECURITY DEFINER)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.assign_site_holiday_calendar(
  p_site_id     uuid,
  p_calendar_id uuid,
  p_priority    smallint DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id     uuid;
  v_assignment_id uuid;
BEGIN
  IF p_site_id IS NULL OR p_calendar_id IS NULL THEN
    RAISE EXCEPTION 'invalid_params: site_id and calendar_id are required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Obtenir tenant_id del site i verificar que el calendari pertany al mateix tenant
  SELECT s.tenant_id INTO v_tenant_id
  FROM data.sites s
  JOIN data.holiday_calendars hc ON hc.id = p_calendar_id
  WHERE s.id = p_site_id
    AND (hc.tenant_id = s.tenant_id OR hc.tenant_id IS NULL);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_calendar_tenant_mismatch: site o calendari no trobat o no del mateix tenant'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO data.site_holiday_calendar_assignments (site_id, calendar_id, priority)
  VALUES (p_site_id, p_calendar_id, COALESCE(p_priority, 0))
  ON CONFLICT (site_id, calendar_id) DO NOTHING
  RETURNING id INTO v_assignment_id;

  IF v_assignment_id IS NULL THEN
    SELECT id INTO v_assignment_id
    FROM data.site_holiday_calendar_assignments
    WHERE site_id = p_site_id AND calendar_id = p_calendar_id;
  END IF;

  RETURN jsonb_build_object(
    'success',       true,
    'assignment_id', v_assignment_id,
    'site_id',       p_site_id,
    'calendar_id',   p_calendar_id,
    'priority',      COALESCE(p_priority, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.assign_site_holiday_calendar(uuid, uuid, smallint)
  TO authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 2. api.remove_site_holiday_calendar_assignment  (SECURITY DEFINER)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.remove_site_holiday_calendar_assignment(
  p_assignment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_site_id     uuid;
  v_calendar_id uuid;
  v_tenant_id   uuid;
  v_deleted     integer := 0;
BEGIN
  IF p_assignment_id IS NULL THEN
    RAISE EXCEPTION 'invalid_params: assignment_id is required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT shca.site_id, shca.calendar_id, s.tenant_id
    INTO v_site_id, v_calendar_id, v_tenant_id
  FROM data.site_holiday_calendar_assignments shca
  JOIN data.sites s ON s.id = shca.site_id
  WHERE shca.id = p_assignment_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', true, 'deleted', false, 'assignment_id', p_assignment_id);
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  DELETE FROM data.site_holiday_calendar_assignments WHERE id = p_assignment_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'success',       true,
    'deleted',       (v_deleted = 1),
    'assignment_id', p_assignment_id,
    'site_id',       v_site_id,
    'calendar_id',   v_calendar_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.remove_site_holiday_calendar_assignment(uuid)
  TO authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 3. api.assign_tenant_holiday_calendar  (SECURITY DEFINER)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.assign_tenant_holiday_calendar(
  p_tenant_id   uuid,
  p_calendar_id uuid,
  p_priority    smallint DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_assignment_id uuid;
BEGIN
  IF p_tenant_id IS NULL OR p_calendar_id IS NULL THEN
    RAISE EXCEPTION 'invalid_params: tenant_id and calendar_id are required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT data.jwt_has_permission(p_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Verificar que el calendari pertany al tenant o és de sistema
  IF NOT EXISTS (
    SELECT 1 FROM data.holiday_calendars hc
    WHERE hc.id = p_calendar_id
      AND (hc.tenant_id = p_tenant_id OR hc.tenant_id IS NULL)
  ) THEN
    RAISE EXCEPTION 'calendar_not_found_or_tenant_mismatch'
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.tenant_holiday_calendar_assignments (tenant_id, calendar_id, priority)
  VALUES (p_tenant_id, p_calendar_id, COALESCE(p_priority, 0))
  ON CONFLICT (tenant_id, calendar_id) DO NOTHING
  RETURNING id INTO v_assignment_id;

  IF v_assignment_id IS NULL THEN
    SELECT id INTO v_assignment_id
    FROM data.tenant_holiday_calendar_assignments
    WHERE tenant_id = p_tenant_id AND calendar_id = p_calendar_id;
  END IF;

  RETURN jsonb_build_object(
    'success',       true,
    'assignment_id', v_assignment_id,
    'tenant_id',     p_tenant_id,
    'calendar_id',   p_calendar_id,
    'priority',      COALESCE(p_priority, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.assign_tenant_holiday_calendar(uuid, uuid, smallint)
  TO authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 4. api.remove_tenant_holiday_calendar_assignment  (SECURITY DEFINER)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.remove_tenant_holiday_calendar_assignment(
  p_assignment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id   uuid;
  v_calendar_id uuid;
  v_deleted     integer := 0;
BEGIN
  IF p_assignment_id IS NULL THEN
    RAISE EXCEPTION 'invalid_params: assignment_id is required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT thca.tenant_id, thca.calendar_id
    INTO v_tenant_id, v_calendar_id
  FROM data.tenant_holiday_calendar_assignments thca
  WHERE thca.id = p_assignment_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', true, 'deleted', false, 'assignment_id', p_assignment_id);
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  DELETE FROM data.tenant_holiday_calendar_assignments WHERE id = p_assignment_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'success',       true,
    'deleted',       (v_deleted = 1),
    'assignment_id', p_assignment_id,
    'tenant_id',     v_tenant_id,
    'calendar_id',   v_calendar_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.remove_tenant_holiday_calendar_assignment(uuid)
  TO authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 5. api.delete_holiday_calendar — elimina un calendari i tot el seu contingut
--    (cascada sobre data.holidays, site_assignments, tenant_assignments)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.delete_holiday_calendar(
  p_calendar_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_cal data.holiday_calendars;
BEGIN
  SELECT * INTO v_cal
  FROM data.holiday_calendars
  WHERE id = p_calendar_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'holiday_calendar_not_found: %', p_calendar_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_cal.tenant_id IS NULL THEN
    RAISE EXCEPTION 'cannot_delete_system_calendar'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT data.jwt_has_permission(v_cal.tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- La cascada del FK elimina holidays, site_assignments i tenant_assignments
  DELETE FROM data.holiday_calendars WHERE id = p_calendar_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_holiday_calendar(uuid) TO authenticated;
