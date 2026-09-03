-- =============================================================================
-- Migration: 20260521000013_work_schedule_interval_triggers.sql
--
-- Propòsit: Afegir INSTEAD OF INSERT/DELETE triggers a api.work_schedule_intervals.
--
-- Context: La vista api.work_schedule_intervals té columnes calculades
--   (expected_minutes, spans_midnight) que impedeixen que PostgreSQL la tracti
--   com a vista auto-actualitzable. Sense triggers, INSERT/DELETE fallaria amb
--   "cannot insert into a non-updatable view" malgrat el GRANT de la migració 007.
--
-- Seguretat: SECURITY DEFINER + validació explícita de jwt_user_tenants() i
--   jwt_has_permission(tenant_id, 'labor_calendar.manage'), igual que la resta
--   de RPCs de gestió d'horaris.
-- =============================================================================

-- ─── INSTEAD OF INSERT ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.fn_wsi_instead_of_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant_id  uuid;
  v_id         uuid;
  v_created_at timestamptz;
BEGIN
  -- Obtenir tenant_id de l'horari pare
  SELECT ws.tenant_id
    INTO v_tenant_id
    FROM data.work_schedules ws
   WHERE ws.id = NEW.schedule_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_not_found: schedule % does not exist', NEW.schedule_id
      USING ERRCODE = 'P0001';
  END IF;

  -- Validar pertinença al tenant i permís de gestió
  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_privilege: not a member of tenant %', v_tenant_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: requires labor_calendar.manage'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Inserir a la taula real
  INSERT INTO data.work_schedule_intervals (schedule_id, day_of_week, start_time, end_time)
  VALUES (NEW.schedule_id, NEW.day_of_week, NEW.start_time, NEW.end_time)
  RETURNING id, created_at INTO v_id, v_created_at;

  -- Poblar les columnes generades perquè PostgREST pugui retornar-les
  NEW.id               := v_id;
  NEW.created_at       := v_created_at;
  NEW.expected_minutes := ROUND(
    EXTRACT(EPOCH FROM
      CASE WHEN NEW.end_time > NEW.start_time
           THEN NEW.end_time - NEW.start_time
           ELSE interval '24 hours' + (NEW.end_time - NEW.start_time)
      END
    ) / 60
  )::int;
  NEW.spans_midnight := (NEW.end_time < NEW.start_time);

  RETURN NEW;
END;
$$;

CREATE TRIGGER wsi_instead_of_insert
  INSTEAD OF INSERT ON api.work_schedule_intervals
  FOR EACH ROW EXECUTE FUNCTION api.fn_wsi_instead_of_insert();


-- ─── INSTEAD OF DELETE ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.fn_wsi_instead_of_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  -- Obtenir tenant_id via l'horari pare
  SELECT ws.tenant_id
    INTO v_tenant_id
    FROM data.work_schedule_intervals wsi
    JOIN data.work_schedules ws ON ws.id = wsi.schedule_id
   WHERE wsi.id = OLD.id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'interval_not_found: interval % does not exist', OLD.id
      USING ERRCODE = 'P0001';
  END IF;

  -- Validar pertinença i permís
  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_privilege: not a member of tenant %', v_tenant_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: requires labor_calendar.manage'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  DELETE FROM data.work_schedule_intervals WHERE id = OLD.id;

  RETURN OLD;
END;
$$;

CREATE TRIGGER wsi_instead_of_delete
  INSTEAD OF DELETE ON api.work_schedule_intervals
  FOR EACH ROW EXECUTE FUNCTION api.fn_wsi_instead_of_delete();
