-- =============================================================================
-- Phase 2 — Shift Planning Backend
-- Migració: 20260521000002_shift_planning.sql
--
-- Conté:
--   1.  DDL  : data.work_shifts           (plantilles de torn)
--   2.  DDL  : data.shift_slots           (instàncies concretes per dia/empleat)
--   3.  DDL  : data.shift_swap_requests   (sol·licituds de canvi de torn)
--   4.  Indexes
--   5.  Triggers updated_at
--   6.  RLS
--   7.  API Views
--   8.  RPCs
--       8.1  api.assign_shift_slot        — assignar torn, detectar anomalies
--       8.2  api.bulk_delete_shift_slots  — eliminar slots (cancel·lació)
--       8.3  api.publish_shifts           — publicar esborranys + sincronitzar calendar_events
--       8.4  api.get_coverage_for_period  — cobertura per dia
--       8.5  api.request_shift_swap       — sol·licitar canvi de torn
--       8.6  api.approve_shift_swap       — aprovar/rebutjar canvi
--   9.  Grants
--
-- Prerequisits:
--   · 20260515000018_attendance_core.sql  (RBAC labor_calendar.manage, etc.)
--   · 20260521000001_labor_calendar.sql   (data.work_schedules, absències)
--   · 20260503000001_calendar_events.sql  (data.calendar_events)
--   · 20260504000001_employees_module.sql (data.employees.weekly_hours)
-- =============================================================================


-- =============================================================================
-- 1. DDL: data.work_shifts
--    Plantilla de torn reutilitzable: nom, color, horari (start_time/end_time).
--    Si end_time < start_time → torn nocturn (creua mitjanit).
-- =============================================================================

CREATE TABLE data.work_shifts (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id)  ON DELETE CASCADE,
  site_id     uuid                 REFERENCES data.sites(id)    ON DELETE CASCADE,
  name        text        NOT NULL,
  color       text        NOT NULL DEFAULT '#6366f1',
  start_time  time        NOT NULL,
  end_time    time        NOT NULL,
  is_active   boolean     NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_work_shifts_color      CHECK (color ~* '^#[0-9a-fA-F]{3,6}$'),
  CONSTRAINT chk_work_shifts_time_diff  CHECK (start_time <> end_time)
);

COMMENT ON TABLE  data.work_shifts IS 'Plantilles de torn reutilitzables per site.';
COMMENT ON COLUMN data.work_shifts.end_time
  IS 'Si end_time < start_time → torn nocturn (creuament de mitjanit).';


-- =============================================================================
-- 2. DDL: data.shift_slots
--    Instàncies concretes: un empleat assignat a un torn en una data concreta.
--    status: draft → published → cancelled
--    Un empleat no pot tenir dos slots actius iguals (employee+date+shift).
-- =============================================================================

CREATE TABLE data.shift_slots (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  site_id       uuid        NOT NULL REFERENCES data.sites(id)      ON DELETE CASCADE,
  employee_id   uuid        NOT NULL REFERENCES data.employees(id)  ON DELETE CASCADE,
  shift_id      uuid        NOT NULL REFERENCES data.work_shifts(id) ON DELETE CASCADE,
  slot_date     date        NOT NULL,
  status        text        NOT NULL DEFAULT 'draft',
  notes         text,
  created_by    uuid                 REFERENCES auth.users(id)      ON DELETE SET NULL,
  published_at  timestamptz,
  cancelled_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_shift_slots_status CHECK (status IN ('draft', 'published', 'cancelled'))
);

COMMENT ON TABLE  data.shift_slots IS 'Instàncies de torn: assignació d''un empleat a un torn en una data.';
COMMENT ON COLUMN data.shift_slots.status
  IS 'draft = esborrany (no visible a l''empleat); published = publicat; cancelled = cancel·lat.';


-- =============================================================================
-- 3. DDL: data.shift_swap_requests
--    Sol·licitud d'intercanvi de torn entre dos empleats.
--    requester_slot_id → slot del sol·licitant.
--    target_slot_id    → slot del destinatari (nullable: pot ser obert).
-- =============================================================================

CREATE TABLE data.shift_swap_requests (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid        NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  requester_slot_id  uuid        NOT NULL REFERENCES data.shift_slots(id) ON DELETE CASCADE,
  target_slot_id     uuid                 REFERENCES data.shift_slots(id) ON DELETE SET NULL,
  requester_id       uuid        NOT NULL REFERENCES data.employees(id)  ON DELETE CASCADE,
  target_employee_id uuid                 REFERENCES data.employees(id)  ON DELETE SET NULL,
  status             text        NOT NULL DEFAULT 'pending',
  requester_notes    text,
  review_comment     text,
  reviewed_by        uuid                 REFERENCES auth.users(id)      ON DELETE SET NULL,
  reviewed_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_swap_status CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled'))
);

COMMENT ON TABLE data.shift_swap_requests
  IS 'Sol·licituds de canvi de torn entre empleats. Un cop aprovada, es fan els canvis als shift_slots.';


-- =============================================================================
-- 4. Indexes
-- =============================================================================

-- work_shifts
CREATE INDEX idx_work_shifts_tenant   ON data.work_shifts (tenant_id);
CREATE INDEX idx_work_shifts_site     ON data.work_shifts (site_id) WHERE site_id IS NOT NULL;

-- shift_slots — principals (queries per planificador)
CREATE INDEX idx_shift_slots_employee_date  ON data.shift_slots (employee_id, slot_date);
CREATE INDEX idx_shift_slots_site_date      ON data.shift_slots (site_id, slot_date);
CREATE INDEX idx_shift_slots_tenant_status  ON data.shift_slots (tenant_id, status);

-- Unicitat: un empleat no pot tenir el mateix torn dues vegades el mateix dia (si no cancel·lat)
CREATE UNIQUE INDEX idx_shift_slots_no_dup
  ON data.shift_slots (employee_id, slot_date, shift_id)
  WHERE status <> 'cancelled';

-- shift_swap_requests
CREATE INDEX idx_swap_requests_requester  ON data.shift_swap_requests (requester_id);
CREATE INDEX idx_swap_requests_target     ON data.shift_swap_requests (target_employee_id)
  WHERE target_employee_id IS NOT NULL;
CREATE INDEX idx_swap_requests_status     ON data.shift_swap_requests (tenant_id, status);


-- =============================================================================
-- 5. Triggers updated_at
-- =============================================================================

CREATE TRIGGER trg_updated_at_work_shifts
  BEFORE UPDATE ON data.work_shifts
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

CREATE TRIGGER trg_updated_at_shift_slots
  BEFORE UPDATE ON data.shift_slots
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

CREATE TRIGGER trg_updated_at_shift_swap_requests
  BEFORE UPDATE ON data.shift_swap_requests
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();


-- =============================================================================
-- 6. RLS
-- =============================================================================

ALTER TABLE data.work_shifts           ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.shift_slots           ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.shift_swap_requests   ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- work_shifts: tothom al tenant veu; gestió requereix labor_calendar.manage
-- ---------------------------------------------------------------------------

CREATE POLICY ws2_select ON data.work_shifts FOR SELECT
  USING (data.jwt_user_tenants() ? tenant_id::text);

CREATE POLICY ws2_insert ON data.work_shifts FOR INSERT
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY ws2_update ON data.work_shifts FOR UPDATE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY ws2_delete ON data.work_shifts FOR DELETE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

-- ---------------------------------------------------------------------------
-- shift_slots: empleat veu els seus propis; managers veuen tots
-- ---------------------------------------------------------------------------

CREATE POLICY ss_select ON data.shift_slots FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = shift_slots.employee_id AND e.user_id = auth.uid()
      )
    )
  );

CREATE POLICY ss_insert ON data.shift_slots FOR INSERT
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY ss_update ON data.shift_slots FOR UPDATE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

-- No DELETE: usar status = 'cancelled'

-- ---------------------------------------------------------------------------
-- shift_swap_requests: requester o target veuen; attendance.approve pot gestionar
-- ---------------------------------------------------------------------------

CREATE POLICY ssr_select ON data.shift_swap_requests FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.approve')
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = shift_swap_requests.requester_id AND e.user_id = auth.uid()
      )
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = shift_swap_requests.target_employee_id AND e.user_id = auth.uid()
      )
    )
  );

CREATE POLICY ssr_insert ON data.shift_swap_requests FOR INSERT
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = shift_swap_requests.requester_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY ssr_update ON data.shift_swap_requests FOR UPDATE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.approve')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = shift_swap_requests.requester_id AND e.user_id = auth.uid()
      )
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.approve')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = shift_swap_requests.requester_id AND e.user_id = auth.uid()
      )
    )
  );


-- =============================================================================
-- 7. API Views (security_invoker = true)
-- =============================================================================

CREATE OR REPLACE VIEW api.work_shifts
  WITH (security_invoker = true)
AS
SELECT
  ws.id,
  ws.tenant_id,
  ws.site_id,
  ws.name,
  ws.color,
  ws.start_time,
  ws.end_time,
  (ws.end_time < ws.start_time)  AS spans_midnight,
  ROUND(
    EXTRACT(EPOCH FROM
      CASE WHEN ws.end_time > ws.start_time
           THEN ws.end_time - ws.start_time
           ELSE interval '24 hours' + (ws.end_time - ws.start_time)
      END
    ) / 60
  )::int                         AS duration_minutes,
  ws.is_active,
  ws.created_at,
  ws.updated_at
FROM data.work_shifts ws;

CREATE OR REPLACE VIEW api.shift_slots
  WITH (security_invoker = true)
AS
SELECT
  ss.id,
  ss.tenant_id,
  ss.site_id,
  ss.employee_id,
  ss.shift_id,
  ss.slot_date,
  ss.status,
  ss.notes,
  ss.created_by,
  ss.published_at,
  ss.cancelled_at,
  ws.name         AS shift_name,
  ws.color        AS shift_color,
  ws.start_time,
  ws.end_time,
  (ws.end_time < ws.start_time) AS spans_midnight,
  ss.created_at,
  ss.updated_at
FROM data.shift_slots ss
JOIN data.work_shifts ws ON ws.id = ss.shift_id;

CREATE OR REPLACE VIEW api.shift_swap_requests
  WITH (security_invoker = true)
AS
SELECT
  ssr.id,
  ssr.tenant_id,
  ssr.requester_slot_id,
  ssr.target_slot_id,
  ssr.requester_id,
  ssr.target_employee_id,
  ssr.status,
  ssr.requester_notes,
  ssr.review_comment,
  ssr.reviewed_by,
  ssr.reviewed_at,
  ssr.created_at,
  ssr.updated_at
FROM data.shift_swap_requests ssr;


-- =============================================================================
-- 8.1 api.assign_shift_slot
--
--     Assigna un torn a un empleat per a una data concreta (status='draft').
--     Detecta anomalies sense bloquejar:
--       · SHIFT_OVERLAP        — l'empleat ja té un altre torn actiu el mateix dia
--       · WEEKLY_HOURS_EXCEEDED — el total de minuts setmanals superaria weekly_hours
--
--     Requereix: labor_calendar.manage
-- =============================================================================

CREATE OR REPLACE FUNCTION api.assign_shift_slot(
  p_employee_id  uuid,
  p_slot_date    date,
  p_shift_id     uuid,
  p_notes        text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp         record;
  v_shift       record;
  v_slot_id     uuid;
  v_anomalies   text[] := '{}';
  v_week_start  date;
  v_week_min    numeric := 0;
  v_shift_min   numeric;
BEGIN
  -- 1. Carregar empleat
  SELECT e.tenant_id, e.site_id, e.weekly_hours
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 2. Permís
  IF auth.uid() IS NOT NULL
     AND NOT data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 3. Carregar torn i validar mateix tenant
  SELECT ws.* INTO v_shift
  FROM data.work_shifts ws
  WHERE ws.id = p_shift_id
    AND ws.tenant_id = v_emp.tenant_id
    AND ws.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shift_not_found_or_inactive: %', p_shift_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 4. Anomalia: solapament de torns (altre slot actiu el mateix dia)
  IF EXISTS (
    SELECT 1 FROM data.shift_slots ss2
    WHERE ss2.employee_id = p_employee_id
      AND ss2.slot_date   = p_slot_date
      AND ss2.shift_id   <> p_shift_id
      AND ss2.status     <> 'cancelled'
  ) THEN
    v_anomalies := array_append(v_anomalies, 'SHIFT_OVERLAP');
  END IF;

  -- 5. Anomalia: hores setmanals excedides
  v_week_start := date_trunc('week', p_slot_date::timestamptz)::date;

  v_shift_min := ROUND(
    EXTRACT(EPOCH FROM
      CASE WHEN v_shift.end_time > v_shift.start_time
           THEN v_shift.end_time - v_shift.start_time
           ELSE interval '24 hours' + (v_shift.end_time - v_shift.start_time)
      END
    ) / 60
  );

  SELECT COALESCE(SUM(
    ROUND(
      EXTRACT(EPOCH FROM
        CASE WHEN ws2.end_time > ws2.start_time
             THEN ws2.end_time - ws2.start_time
             ELSE interval '24 hours' + (ws2.end_time - ws2.start_time)
        END
      ) / 60
    )
  ), 0)
  INTO v_week_min
  FROM data.shift_slots ss2
  JOIN data.work_shifts ws2 ON ws2.id = ss2.shift_id
  WHERE ss2.employee_id = p_employee_id
    AND ss2.slot_date  >= v_week_start
    AND ss2.slot_date  <= v_week_start + 6
    AND ss2.status     <> 'cancelled';

  IF v_emp.weekly_hours IS NOT NULL
     AND (v_week_min + v_shift_min) > (v_emp.weekly_hours * 60) THEN
    v_anomalies := array_append(v_anomalies, 'WEEKLY_HOURS_EXCEEDED');
  END IF;

  -- 6. Inserció
  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id,
    slot_date, status, notes, created_by
  )
  VALUES (
    v_emp.tenant_id,
    COALESCE(v_shift.site_id, v_emp.site_id),
    p_employee_id, p_shift_id,
    p_slot_date, 'draft', p_notes, auth.uid()
  )
  RETURNING id INTO v_slot_id;

  -- 7. Audit
  PERFORM data.log_audit_event(
    p_tenant_id   => v_emp.tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => v_emp.site_id,
    p_action      => 'SHIFT_SLOT_ASSIGNED',
    p_entity_type => 'shift_slot',
    p_entity_id   => v_slot_id,
    p_payload     => jsonb_build_object(
      'employee_id', p_employee_id,
      'shift_id',    p_shift_id,
      'slot_date',   p_slot_date,
      'anomalies',   v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'slot_id',    v_slot_id,
    'status',     'draft',
    'anomalies',  v_anomalies
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.assign_shift_slot(uuid, date, uuid, text) TO authenticated;


-- =============================================================================
-- 8.2 api.bulk_delete_shift_slots
--
--     Cancel·la (soft-delete) un conjunt de slot_ids.
--     Requereix: labor_calendar.manage
-- =============================================================================

CREATE OR REPLACE FUNCTION api.bulk_delete_shift_slots(
  p_slot_ids  uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id  uuid;
  v_count      int;
BEGIN
  -- Obtenir tenant del primer slot (tots han d'estar al mateix tenant)
  SELECT tenant_id INTO v_tenant_id
  FROM data.shift_slots
  WHERE id = ANY(p_slot_ids)
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('cancelled_count', 0);
  END IF;

  IF auth.uid() IS NOT NULL
     AND NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.shift_slots
  SET status       = 'cancelled',
      cancelled_at = now(),
      updated_at   = now()
  WHERE id = ANY(p_slot_ids)
    AND tenant_id = v_tenant_id
    AND status   <> 'cancelled';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object('cancelled_count', v_count);
END;
$$;

GRANT EXECUTE ON FUNCTION api.bulk_delete_shift_slots(uuid[]) TO authenticated;


-- =============================================================================
-- 8.3 api.publish_shifts
--
--     Publica tots els slots 'draft' d'un site per a una setmana donada
--     (p_week_start = dilluns de la setmana). Crea/actualitza els
--     calendar_events corresponents.
--
--     Requereix: labor_calendar.manage
-- =============================================================================

CREATE OR REPLACE FUNCTION api.publish_shifts(
  p_site_id     uuid,
  p_week_start  date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id   uuid;
  v_tz          text;
  v_week_end    date;
  v_count       int;
  v_slot        record;
  v_start_at    timestamptz;
  v_end_at      timestamptz;
BEGIN
  SELECT s.tenant_id INTO v_tenant_id
  FROM data.sites s WHERE s.id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id
      USING ERRCODE = 'P0002';
  END IF;

  IF auth.uid() IS NOT NULL
     AND NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Timezone del site
  v_tz := COALESCE(
    (api.get_effective_settings(
      p_site_id   => p_site_id,
      p_user_id   => NULL,
      p_tenant_id => v_tenant_id
    ) ->> 'site_timezone'),
    'Europe/Madrid'
  );

  v_week_end := p_week_start + 6;

  -- Publicar tots els drafts de la setmana
  UPDATE data.shift_slots
  SET status       = 'published',
      published_at = now(),
      updated_at   = now()
  WHERE site_id  = p_site_id
    AND slot_date BETWEEN p_week_start AND v_week_end
    AND status   = 'draft';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Sincronitzar calendar_events per als slots publicats de la setmana
  -- (esborrem els existents i reinsertem per evitar duplicats)
  FOR v_slot IN
    SELECT ss.id AS slot_id, ss.employee_id, ss.slot_date, ss.site_id,
           ws.name, ws.color, ws.start_time, ws.end_time
    FROM data.shift_slots ss
    JOIN data.work_shifts ws ON ws.id = ss.shift_id
    WHERE ss.site_id  = p_site_id
      AND ss.slot_date BETWEEN p_week_start AND v_week_end
      AND ss.status  = 'published'
  LOOP
    -- Calcular timestamps localitzats
    v_start_at := (v_slot.slot_date::text || ' ' || v_slot.start_time::text)::timestamptz
                  AT TIME ZONE v_tz;

    IF v_slot.end_time > v_slot.start_time THEN
      v_end_at := (v_slot.slot_date::text || ' ' || v_slot.end_time::text)::timestamptz
                  AT TIME ZONE v_tz;
    ELSE
      -- Torn nocturn: end_at = dia_seguent + end_time
      v_end_at := ((v_slot.slot_date + 1)::text || ' ' || v_slot.end_time::text)::timestamptz
                  AT TIME ZONE v_tz;
    END IF;

    -- Eliminar event anterior si existia (no hi ha UNIQUE sobre entity_type+entity_id)
    DELETE FROM data.calendar_events
    WHERE entity_type = 'shift_slot' AND entity_id = v_slot.slot_id;

    -- Crear nou event
    INSERT INTO data.calendar_events (
      tenant_id, site_id, entity_type, entity_id,
      title, start_at, end_at,
      color, required_permissions, owner_id,
      metadata
    )
    VALUES (
      v_tenant_id,
      v_slot.site_id,
      'shift_slot',
      v_slot.slot_id,
      v_slot.name,
      v_start_at,
      v_end_at,
      v_slot.color,
      ARRAY['labor_calendar.view'],
      (SELECT id FROM data.profiles WHERE id = auth.uid() LIMIT 1),
      jsonb_build_object(
        'employee_id', v_slot.employee_id,
        'slot_date',   v_slot.slot_date
      )
    );
  END LOOP;

  -- Audit
  PERFORM data.log_audit_event(
    p_tenant_id   => v_tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => p_site_id,
    p_action      => 'SHIFTS_PUBLISHED',
    p_entity_type => 'shift_slot',
    p_entity_id   => NULL,
    p_payload     => jsonb_build_object(
      'site_id',     p_site_id,
      'week_start',  p_week_start,
      'published',   v_count
    )
  );

  RETURN jsonb_build_object(
    'site_id',     p_site_id,
    'week_start',  p_week_start,
    'published',   v_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.publish_shifts(uuid, date) TO authenticated;


-- =============================================================================
-- 8.4 api.get_coverage_for_period
--
--     Retorna per a cada dia del rang: recompte d'empleats amb torn actiu
--     (draft o published) i detall dels slots. Útil per al planificador visual.
--
--     Accessible a: authenticated (labor_calendar.view o view_all)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_coverage_for_period(
  p_site_id  uuid,
  p_from     date,
  p_to       date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id  uuid;
  v_result     jsonb;
BEGIN
  SELECT s.tenant_id INTO v_tenant_id
  FROM data.sites s WHERE s.id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id
      USING ERRCODE = 'P0002';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege: no ets membre del tenant'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage')
      OR data.jwt_has_permission(v_tenant_id, 'labor_calendar.view')
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege: labor_calendar.view o view_all requerit'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  SELECT jsonb_agg(day_row ORDER BY work_date)
  INTO v_result
  FROM (
    SELECT
      gs.d::date                                 AS work_date,
      COUNT(DISTINCT ss.employee_id)             AS employee_count,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'slot_id',     ss.id,
            'employee_id', ss.employee_id,
            'shift_id',    ss.shift_id,
            'shift_name',  ws.name,
            'color',       ws.color,
            'start_time',  ws.start_time,
            'end_time',    ws.end_time,
            'spans_midnight', (ws.end_time < ws.start_time),
            'status',      ss.status
          ) ORDER BY ws.start_time
        ) FILTER (WHERE ss.id IS NOT NULL),
        '[]'::jsonb
      )                                           AS slots
    FROM generate_series(p_from, p_to, '1 day'::interval) AS gs(d)
    LEFT JOIN data.shift_slots ss
           ON ss.slot_date = gs.d::date
          AND ss.site_id   = p_site_id
          AND ss.status   <> 'cancelled'
    LEFT JOIN data.work_shifts ws ON ws.id = ss.shift_id
    GROUP BY gs.d::date
  ) AS day_row;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_coverage_for_period(uuid, date, date) TO authenticated;


-- =============================================================================
-- 8.5 api.request_shift_swap
--
--     Un empleat sol·licita intercanviar el seu torn amb un altre empleat
--     (o deixa target_employee_id NULL per a una sol·licitud oberta).
--
--     Requereix: ser el propietari del requester_slot_id
-- =============================================================================

CREATE OR REPLACE FUNCTION api.request_shift_swap(
  p_requester_slot_id   uuid,
  p_target_employee_id  uuid  DEFAULT NULL,
  p_target_slot_id      uuid  DEFAULT NULL,
  p_notes               text  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_slot       record;
  v_req_emp    record;
  v_request_id uuid;
BEGIN
  -- Carregar slot
  SELECT ss.tenant_id, ss.employee_id, ss.status, ss.site_id
  INTO v_slot
  FROM data.shift_slots ss
  WHERE ss.id = p_requester_slot_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'slot_not_found: %', p_requester_slot_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_slot.status = 'cancelled' THEN
    RAISE EXCEPTION 'slot_cancelled: no es pot intercanviar un slot cancel·lat'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Verificar que qui fa la sol·licitud és l'empleat del slot
  SELECT e.id INTO v_req_emp
  FROM data.employees e
  WHERE e.id = v_slot.employee_id AND e.user_id = auth.uid();

  IF NOT FOUND AND auth.uid() IS NOT NULL THEN
    -- Permetre managers també
    IF NOT data.jwt_has_permission(v_slot.tenant_id, 'labor_calendar.manage') THEN
      RAISE EXCEPTION 'insufficient_privilege: has de ser el propietari del slot o tenir labor_calendar.manage'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- Validar target_slot_id pertany al target_employee_id si ambdós especificats
  IF p_target_slot_id IS NOT NULL AND p_target_employee_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.shift_slots ss2
      WHERE ss2.id = p_target_slot_id
        AND ss2.employee_id = p_target_employee_id
        AND ss2.tenant_id   = v_slot.tenant_id
        AND ss2.status     <> 'cancelled'
    ) THEN
      RAISE EXCEPTION 'target_slot_not_found_or_invalid: %', p_target_slot_id
        USING ERRCODE = 'P0002';
    END IF;
  END IF;

  -- Comprovar que no hi ha una sol·licitud pendent per a aquest slot
  IF EXISTS (
    SELECT 1 FROM data.shift_swap_requests ssr
    WHERE ssr.requester_slot_id = p_requester_slot_id
      AND ssr.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'swap_request_already_pending: ja existeix una sol·licitud pendent per a aquest slot'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  INSERT INTO data.shift_swap_requests (
    tenant_id,
    requester_slot_id,
    target_slot_id,
    requester_id,
    target_employee_id,
    status,
    requester_notes
  )
  VALUES (
    v_slot.tenant_id,
    p_requester_slot_id,
    p_target_slot_id,
    v_slot.employee_id,
    p_target_employee_id,
    'pending',
    p_notes
  )
  RETURNING id INTO v_request_id;

  PERFORM data.log_audit_event(
    p_tenant_id   => v_slot.tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => v_slot.site_id,
    p_action      => 'SHIFT_SWAP_REQUESTED',
    p_entity_type => 'shift_swap_request',
    p_entity_id   => v_request_id,
    p_payload     => jsonb_build_object(
      'requester_slot_id',  p_requester_slot_id,
      'target_employee_id', p_target_employee_id,
      'target_slot_id',     p_target_slot_id
    )
  );

  RETURN jsonb_build_object(
    'request_id', v_request_id,
    'status',     'pending'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.request_shift_swap(uuid, uuid, uuid, text) TO authenticated;


-- =============================================================================
-- 8.6 api.approve_shift_swap
--
--     Aprova o rebutja una sol·licitud de canvi de torn.
--     Si s'aprova: intercanvia els employee_id dels slots afectats i
--                  actualitza els calendar_events si els slots estaven publicats.
--
--     Requereix: attendance.approve
-- =============================================================================

CREATE OR REPLACE FUNCTION api.approve_shift_swap(
  p_request_id    uuid,
  p_new_status    text,
  p_comment       text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_req        record;
  v_req_slot   record;
  v_tgt_slot   record;
BEGIN
  SELECT ssr.* INTO v_req
  FROM data.shift_swap_requests ssr
  WHERE ssr.id = p_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'swap_request_not_found: %', p_request_id
      USING ERRCODE = 'P0002';
  END IF;

  IF auth.uid() IS NOT NULL
     AND NOT data.jwt_has_permission(v_req.tenant_id, 'attendance.approve') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_new_status NOT IN ('approved', 'rejected', 'cancelled') THEN
    RAISE EXCEPTION 'invalid_status: % — valid: approved, rejected, cancelled', p_new_status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'swap_not_actionable: status actual = %', v_req.status
      USING ERRCODE = 'check_violation';
  END IF;

  -- Actualitzar la sol·licitud
  UPDATE data.shift_swap_requests
  SET status         = p_new_status,
      review_comment = p_comment,
      reviewed_by    = auth.uid(),
      reviewed_at    = now(),
      updated_at     = now()
  WHERE id = p_request_id;

  -- Si s'aprova: intercanviar employee_id dels slots
  IF p_new_status = 'approved' THEN
    -- Carregar slots
    SELECT ss.employee_id, ss.status, ss.site_id INTO v_req_slot
    FROM data.shift_slots ss WHERE ss.id = v_req.requester_slot_id;

    -- Slot del requester → target employee
    UPDATE data.shift_slots
    SET employee_id = v_req.target_employee_id,
        updated_at  = now()
    WHERE id = v_req.requester_slot_id;

    -- Slot del target (si existeix) → requester employee
    IF v_req.target_slot_id IS NOT NULL THEN
      UPDATE data.shift_slots
      SET employee_id = v_req.requester_id,
          updated_at  = now()
      WHERE id = v_req.target_slot_id;
    END IF;

    -- Actualitzar metadata dels calendar_events afectats
    UPDATE data.calendar_events
    SET metadata   = metadata || jsonb_build_object('employee_id', v_req.target_employee_id),
        updated_at = now()
    WHERE entity_type = 'shift_slot'
      AND entity_id   = v_req.requester_slot_id;

    IF v_req.target_slot_id IS NOT NULL THEN
      UPDATE data.calendar_events
      SET metadata   = metadata || jsonb_build_object('employee_id', v_req.requester_id),
          updated_at = now()
      WHERE entity_type = 'shift_slot'
        AND entity_id   = v_req.target_slot_id;
    END IF;
  END IF;

  PERFORM data.log_audit_event(
    p_tenant_id   => v_req.tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => NULL,
    p_action      => 'SHIFT_SWAP_' || upper(p_new_status),
    p_entity_type => 'shift_swap_request',
    p_entity_id   => p_request_id,
    p_payload     => jsonb_build_object(
      'request_id',         p_request_id,
      'requester_slot_id',  v_req.requester_slot_id,
      'target_slot_id',     v_req.target_slot_id,
      'new_status',         p_new_status
    )
  );

  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'status',     p_new_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_shift_swap(uuid, text, text) TO authenticated;


-- =============================================================================
-- 9. Grants
-- =============================================================================

-- Accés directe a taules (necessari per security_invoker views)
GRANT SELECT ON data.work_shifts           TO authenticated;
GRANT SELECT ON data.shift_slots           TO authenticated;
GRANT SELECT ON data.shift_swap_requests   TO authenticated;

-- service_role (Edge Functions, workers)
GRANT SELECT, INSERT, UPDATE ON data.work_shifts           TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.shift_slots           TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.shift_swap_requests   TO service_role;

-- API Views
GRANT SELECT ON api.work_shifts           TO authenticated;
GRANT SELECT ON api.shift_slots           TO authenticated;
GRANT SELECT ON api.shift_swap_requests   TO authenticated;
