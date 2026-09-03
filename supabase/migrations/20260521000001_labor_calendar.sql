-- =============================================================================
-- Migration: 20260521000001_labor_calendar.sql
-- Propòsit : Phase 1B — Calendari Laboral Backend
--
-- Conté:
--   1.  Settings registry: claus d'assistència Phase 1B
--   2.  Taules:
--         data.work_schedules, data.work_schedule_intervals
--         data.employee_schedule_assignments
--         data.holiday_calendars, data.holidays
--         data.site_holiday_calendar_assignments
--         data.employee_absences
--   3.  Índexs
--   4.  Triggers updated_at
--   5.  RLS
--   6.  Audit triggers (absences)
--   7.  Vistes API (security_invoker = true)
--   8.  RPCs:
--         api.resolve_work_day          — nucli del calendari laboral
--         api.request_absence           — sol·licitar absència
--         api.approve_absence           — aprovar/rebutjar absència
--         api.import_holidays           — importar festius (JSON → Nager.Date)
--   9.  UPDATE api.recompute_attendance_worker — Phase 1B upgrade:
--         · timezone del site (site_timezone)
--         · expected_minutes + day_type via resolve_work_day
--         · night shift punch range (intervals que creuen mitjanit)
--  10.  Grants
--
-- Convencions:
--   · day_of_week: 0=Diumenge, 1=Dilluns, ..., 6=Dissabte  (PG DOW)
--     Coincideix amb EXTRACT(DOW FROM date)
--   · Night shift: work_schedule_intervals.end_time < start_time → creua mitjanit
--   · Timezone: llegida de settings 'site_timezone'; fallback 'Europe/Madrid'
-- =============================================================================


-- =============================================================================
-- 1. Settings registry — claus Phase 1B
-- =============================================================================

INSERT INTO data.settings_registry (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('attendance_default_absence_workflow',  'tenant', 'attendance.approve',   false, true,
   'Flux d''aprovació d''absències: auto_approve | require_approval (default)'),
  ('attendance_max_absence_days_per_year', 'tenant', 'attendance.approve',   false, true,
   'Màxim de dies de vacances anuals per empleat (0 = sense límit)'),
  ('attendance_holiday_region_code',       'site',   'settings.manage',      false, true,
   'Codi de region ISO per a festius automàtics (ex: ES-CAT, ES-MAD). Usada per import_holidays.')
ON CONFLICT (setting_key)
DO UPDATE SET
  scope               = EXCLUDED.scope,
  required_permission = EXCLUDED.required_permission,
  owner_only          = EXCLUDED.owner_only,
  is_active           = EXCLUDED.is_active,
  description         = EXCLUDED.description,
  updated_at          = now();

-- Defaults del sistema per a les noves settings
INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{
  "attendance_default_absence_workflow":  "require_approval",
  "attendance_max_absence_days_per_year": 0,
  "attendance_holiday_region_code":       ""
}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings   = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();


-- =============================================================================
-- 2. Taules
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 2.1 data.work_schedules — Plantilles d'horari setmanal
-- ---------------------------------------------------------------------------

CREATE TABLE data.work_schedules (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES data.tenants(id)  ON DELETE CASCADE,
  site_id      uuid                 REFERENCES data.sites(id)    ON DELETE SET NULL,
  name         text        NOT NULL,
  description  text,
  is_default   boolean     NOT NULL DEFAULT false,
  is_active    boolean     NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.work_schedules IS
  'Plantilles d''horari setmanal reutilitzables. Cada plantilla pot tenir '
  'intervals de temps (work_schedule_intervals) per dia de setmana.';

COMMENT ON COLUMN data.work_schedules.is_default IS
  'Si true, s''aplica als empleats sense assignació explícita (màxim 1 per tenant/site).';


-- ---------------------------------------------------------------------------
-- 2.2 data.work_schedule_intervals — Intervals horaris per dia de setmana
-- ---------------------------------------------------------------------------

CREATE TABLE data.work_schedule_intervals (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  schedule_id  uuid        NOT NULL REFERENCES data.work_schedules(id) ON DELETE CASCADE,
  day_of_week  smallint    NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  start_time   time        NOT NULL,
  end_time     time        NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_interval_not_zero CHECK (end_time != start_time)
);

COMMENT ON TABLE data.work_schedule_intervals IS
  'Intervals de treball per dia de setmana (0=Diumenge..6=Dissabte, PG DOW). '
  'Un dia pot tenir 0 intervals (no laborable) o múltiples (torns partits). '
  'Si end_time < start_time l''interval creua mitjanit (torn nocturn).';

COMMENT ON COLUMN data.work_schedule_intervals.day_of_week IS
  'PostgreSQL DOW: 0=Diumenge, 1=Dilluns, 2=Dimarts, 3=Dimecres, '
  '4=Dijous, 5=Divendres, 6=Dissabte. Coincideix amb EXTRACT(DOW FROM date).';


-- ---------------------------------------------------------------------------
-- 2.3 data.employee_schedule_assignments — Assignació horari a empleat
-- ---------------------------------------------------------------------------

CREATE TABLE data.employee_schedule_assignments (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid        NOT NULL REFERENCES data.tenants(id)    ON DELETE CASCADE,
  employee_id    uuid        NOT NULL REFERENCES data.employees(id)  ON DELETE CASCADE,
  schedule_id    uuid        NOT NULL REFERENCES data.work_schedules(id) ON DELETE CASCADE,
  effective_from date        NOT NULL,
  effective_to   date,
  notes          text,
  created_by     uuid                 REFERENCES data.profiles(id)   ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_assignment_dates CHECK (effective_to IS NULL OR effective_to > effective_from)
);

COMMENT ON TABLE data.employee_schedule_assignments IS
  'Assignació d''horari a empleat amb dates de vigència. Permet historial '
  'd''horaris (canvi de torn, reducció de jornada, etc.).';

COMMENT ON COLUMN data.employee_schedule_assignments.effective_to IS
  'NULL = vigència indefinida (horari actual). Si no NULL, l''assignació '
  'expira el dia indicat (exclusiu).';


-- ---------------------------------------------------------------------------
-- 2.4 data.holiday_calendars — Calendaris de festius
-- ---------------------------------------------------------------------------

CREATE TABLE data.holiday_calendars (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid                 REFERENCES data.tenants(id)  ON DELETE CASCADE,
  name          text        NOT NULL,
  country_code  text        NOT NULL DEFAULT 'ES',
  region_code   text,
  year          smallint,
  is_active     boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.holiday_calendars IS
  'Calendaris de festius. tenant_id IS NULL = calendari del sistema (nacional/regional). '
  'tenant_id NOT NULL = calendari personalitzat del tenant (festius d''empresa). '
  'country_code + region_code identifiquen el calendari (ex: ES, ES-CAT, ES-MAD).';

COMMENT ON COLUMN data.holiday_calendars.region_code IS
  'Codi de subdivisió ISO 3166-2 (ex: ES-CAT, ES-MAD, ES-VLC). '
  'NULL = calendari nacional sense distinció de CCAA.';

COMMENT ON COLUMN data.holiday_calendars.year IS
  'Any del calendari (ex: 2026). NULL = calendari multi-any (festius recurrents).';


-- ---------------------------------------------------------------------------
-- 2.5 data.holidays — Festius individuals
-- ---------------------------------------------------------------------------

CREATE TABLE data.holidays (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  calendar_id   uuid        NOT NULL REFERENCES data.holiday_calendars(id) ON DELETE CASCADE,
  date          date        NOT NULL,
  name          text        NOT NULL,
  holiday_type  text        NOT NULL DEFAULT 'national'
                            CHECK (holiday_type IN ('national', 'regional', 'local', 'tenant_custom')),
  is_half_day   boolean     NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_holiday_calendar_date UNIQUE (calendar_id, date)
);

COMMENT ON TABLE data.holidays IS
  'Festius individuals dins d''un calendari. UNIQUE per calendari + data.';


-- ---------------------------------------------------------------------------
-- 2.6 data.site_holiday_calendar_assignments — Sites ↔ Calendaris de festius
-- ---------------------------------------------------------------------------

CREATE TABLE data.site_holiday_calendar_assignments (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id      uuid        NOT NULL REFERENCES data.sites(id)            ON DELETE CASCADE,
  calendar_id  uuid        NOT NULL REFERENCES data.holiday_calendars(id) ON DELETE CASCADE,
  priority     smallint    NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_site_calendar UNIQUE (site_id, calendar_id)
);

COMMENT ON TABLE data.site_holiday_calendar_assignments IS
  'Un site pot usar múltiples calendaris de festius (nacional + regional + empresa). '
  'priority: ordre de desempat (valor més alt = prioritat més alta).';


-- ---------------------------------------------------------------------------
-- 2.7 data.employee_absences — Absències (vacances, baixes, permisos, ...)
-- ---------------------------------------------------------------------------

CREATE TABLE data.employee_absences (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  site_id         uuid                 REFERENCES data.sites(id)     ON DELETE SET NULL,
  employee_id     uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  absence_type    text        NOT NULL
                              CHECK (absence_type IN (
                                'vacation', 'sick_leave', 'personal',
                                'maternity_paternity', 'accident_leave',
                                'bereavement', 'other'
                              )),
  start_date      date        NOT NULL,
  end_date        date        NOT NULL,
  status          text        NOT NULL DEFAULT 'requested'
                              CHECK (status IN ('requested', 'approved', 'rejected', 'cancelled')),
  is_paid         boolean     NOT NULL DEFAULT true,
  hours_per_day   numeric(4,2),
  notes           text,
  requested_by    uuid                 REFERENCES data.profiles(id)  ON DELETE SET NULL,
  reviewed_by     uuid                 REFERENCES data.profiles(id)  ON DELETE SET NULL,
  reviewed_at     timestamptz,
  review_comment  text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_absence_dates CHECK (end_date >= start_date),
  CONSTRAINT chk_absence_hours CHECK (hours_per_day IS NULL OR hours_per_day > 0)
);

COMMENT ON TABLE data.employee_absences IS
  'Absències d''empleats (vacances, baixes, permisos, ...). Workflow: '
  'requested → approved / rejected. Aprovació per attendance.approve.';

COMMENT ON COLUMN data.employee_absences.hours_per_day IS
  'Hores d''absència per dia laborable. NULL = usar les hores esperades de l''horari assignat.';


-- =============================================================================
-- 3. Índexs
-- =============================================================================

CREATE INDEX idx_work_schedules_tenant_id   ON data.work_schedules (tenant_id);
CREATE INDEX idx_work_schedules_site_id     ON data.work_schedules (site_id);
CREATE UNIQUE INDEX uq_work_schedule_default
  ON data.work_schedules (tenant_id, site_id) WHERE is_default = true;

CREATE INDEX idx_wsi_schedule_dow           ON data.work_schedule_intervals (schedule_id, day_of_week);

CREATE INDEX idx_esa_employee_id            ON data.employee_schedule_assignments (employee_id);
CREATE INDEX idx_esa_schedule_id            ON data.employee_schedule_assignments (schedule_id);
CREATE INDEX idx_esa_tenant_employee        ON data.employee_schedule_assignments (tenant_id, employee_id, effective_from);

CREATE INDEX idx_holiday_calendars_tenant   ON data.holiday_calendars (tenant_id);
CREATE INDEX idx_holiday_calendars_country  ON data.holiday_calendars (country_code, region_code, year);

CREATE INDEX idx_holidays_calendar_date     ON data.holidays (calendar_id, date);

CREATE INDEX idx_shca_site_id              ON data.site_holiday_calendar_assignments (site_id);
CREATE INDEX idx_shca_calendar_id          ON data.site_holiday_calendar_assignments (calendar_id);

CREATE INDEX idx_absences_employee_id      ON data.employee_absences (employee_id, start_date, end_date);
CREATE INDEX idx_absences_tenant_status    ON data.employee_absences (tenant_id, status);
CREATE INDEX idx_absences_site_id         ON data.employee_absences (site_id);


-- =============================================================================
-- 4. Triggers updated_at
-- =============================================================================

CREATE TRIGGER trg_updated_at_work_schedules
  BEFORE UPDATE ON data.work_schedules
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

CREATE TRIGGER trg_updated_at_employee_schedule_assignments
  BEFORE UPDATE ON data.employee_schedule_assignments
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

CREATE TRIGGER trg_updated_at_holiday_calendars
  BEFORE UPDATE ON data.holiday_calendars
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

CREATE TRIGGER trg_updated_at_employee_absences
  BEFORE UPDATE ON data.employee_absences
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();


-- =============================================================================
-- 5. RLS
-- =============================================================================

ALTER TABLE data.work_schedules                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.work_schedule_intervals        ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employee_schedule_assignments  ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.holiday_calendars              ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.holidays                       ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.site_holiday_calendar_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employee_absences              ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- work_schedules
-- ---------------------------------------------------------------------------

CREATE POLICY ws_select ON data.work_schedules FOR SELECT
  USING (data.jwt_user_tenants() ? tenant_id::text);

CREATE POLICY ws_insert ON data.work_schedules FOR INSERT
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY ws_update ON data.work_schedules FOR UPDATE
  USING  (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY ws_delete ON data.work_schedules FOR DELETE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

-- ---------------------------------------------------------------------------
-- work_schedule_intervals (accés via schedule → tenant)
-- ---------------------------------------------------------------------------

CREATE POLICY wsi_select ON data.work_schedule_intervals FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM data.work_schedules ws
    WHERE ws.id = schedule_id
      AND data.jwt_user_tenants() ? ws.tenant_id::text
  ));

CREATE POLICY wsi_insert ON data.work_schedule_intervals FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM data.work_schedules ws
    WHERE ws.id = schedule_id
      AND data.jwt_user_tenants() ? ws.tenant_id::text
      AND data.jwt_has_permission(ws.tenant_id, 'labor_calendar.manage')
  ));

CREATE POLICY wsi_update ON data.work_schedule_intervals FOR UPDATE
  USING (EXISTS (
    SELECT 1 FROM data.work_schedules ws
    WHERE ws.id = schedule_id
      AND data.jwt_user_tenants() ? ws.tenant_id::text
      AND data.jwt_has_permission(ws.tenant_id, 'labor_calendar.manage')
  ));

CREATE POLICY wsi_delete ON data.work_schedule_intervals FOR DELETE
  USING (EXISTS (
    SELECT 1 FROM data.work_schedules ws
    WHERE ws.id = schedule_id
      AND data.jwt_user_tenants() ? ws.tenant_id::text
      AND data.jwt_has_permission(ws.tenant_id, 'labor_calendar.manage')
  ));

-- ---------------------------------------------------------------------------
-- employee_schedule_assignments
-- ---------------------------------------------------------------------------

CREATE POLICY esa_select ON data.employee_schedule_assignments FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_id AND e.user_id = auth.uid()
      )
    )
  );

CREATE POLICY esa_insert ON data.employee_schedule_assignments FOR INSERT
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY esa_update ON data.employee_schedule_assignments FOR UPDATE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY esa_delete ON data.employee_schedule_assignments FOR DELETE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

-- ---------------------------------------------------------------------------
-- holiday_calendars: sistema (tenant_id IS NULL) = lectura global;
--                    tenant-specific = sol per membres del tenant
-- ---------------------------------------------------------------------------

CREATE POLICY hc_select ON data.holiday_calendars FOR SELECT
  USING (
    tenant_id IS NULL
    OR data.jwt_user_tenants() ? tenant_id::text
  );

CREATE POLICY hc_insert ON data.holiday_calendars FOR INSERT
  WITH CHECK (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY hc_update ON data.holiday_calendars FOR UPDATE
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY hc_delete ON data.holiday_calendars FOR DELETE
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

-- ---------------------------------------------------------------------------
-- holidays (accés via calendar)
-- ---------------------------------------------------------------------------

CREATE POLICY hol_select ON data.holidays FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM data.holiday_calendars hc
    WHERE hc.id = calendar_id
      AND (hc.tenant_id IS NULL OR data.jwt_user_tenants() ? hc.tenant_id::text)
  ));

CREATE POLICY hol_insert ON data.holidays FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM data.holiday_calendars hc
    WHERE hc.id = calendar_id
      AND hc.tenant_id IS NOT NULL
      AND data.jwt_user_tenants() ? hc.tenant_id::text
      AND data.jwt_has_permission(hc.tenant_id, 'labor_calendar.manage')
  ));

CREATE POLICY hol_update ON data.holidays FOR UPDATE
  USING (EXISTS (
    SELECT 1 FROM data.holiday_calendars hc
    WHERE hc.id = calendar_id
      AND hc.tenant_id IS NOT NULL
      AND data.jwt_user_tenants() ? hc.tenant_id::text
      AND data.jwt_has_permission(hc.tenant_id, 'labor_calendar.manage')
  ));

CREATE POLICY hol_delete ON data.holidays FOR DELETE
  USING (EXISTS (
    SELECT 1 FROM data.holiday_calendars hc
    WHERE hc.id = calendar_id
      AND hc.tenant_id IS NOT NULL
      AND data.jwt_user_tenants() ? hc.tenant_id::text
      AND data.jwt_has_permission(hc.tenant_id, 'labor_calendar.manage')
  ));

-- ---------------------------------------------------------------------------
-- site_holiday_calendar_assignments
-- ---------------------------------------------------------------------------

CREATE POLICY shca_select ON data.site_holiday_calendar_assignments FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM data.sites s
    JOIN data.tenant_members tm ON tm.tenant_id = s.tenant_id
      AND tm.user_id   = auth.uid()
      AND tm.is_active = true
    WHERE s.id = site_id
  ));

CREATE POLICY shca_insert ON data.site_holiday_calendar_assignments FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM data.sites s
    WHERE s.id = site_id
      AND data.jwt_user_tenants() ? s.tenant_id::text
      AND data.jwt_has_permission(s.tenant_id, 'labor_calendar.manage')
  ));

CREATE POLICY shca_delete ON data.site_holiday_calendar_assignments FOR DELETE
  USING (EXISTS (
    SELECT 1 FROM data.sites s
    WHERE s.id = site_id
      AND data.jwt_user_tenants() ? s.tenant_id::text
      AND data.jwt_has_permission(s.tenant_id, 'labor_calendar.manage')
  ));

-- ---------------------------------------------------------------------------
-- employee_absences
-- ---------------------------------------------------------------------------

CREATE POLICY abs_select ON data.employee_absences FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_id AND e.user_id = auth.uid()
      )
    )
  );

CREATE POLICY abs_insert ON data.employee_absences FOR INSERT
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'absences.request')
      OR data.jwt_has_permission(tenant_id, 'attendance.approve')
    )
  );

CREATE POLICY abs_update ON data.employee_absences FOR UPDATE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'attendance.approve')
  );

CREATE POLICY abs_delete ON data.employee_absences FOR DELETE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'attendance.approve')
    AND status IN ('requested', 'rejected', 'cancelled')
  );


-- =============================================================================
-- 6. Audit trigger — employee_absences (canvis d'estat)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_audit_employee_absences()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_action text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := 'ABSENCE_REQUESTED';
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.status != NEW.status THEN
      v_action := CASE NEW.status
        WHEN 'approved'   THEN 'ABSENCE_APPROVED'
        WHEN 'rejected'   THEN 'ABSENCE_REJECTED'
        WHEN 'cancelled'  THEN 'ABSENCE_CANCELLED'
        ELSE 'ABSENCE_UPDATED'
      END;
    ELSE
      v_action := 'ABSENCE_UPDATED';
    END IF;
  ELSE
    v_action := 'ABSENCE_DELETED';
  END IF;

  PERFORM data.log_audit_event(
    p_tenant_id   => COALESCE(NEW.tenant_id, OLD.tenant_id),
    p_user_id     => auth.uid(),
    p_site_id     => COALESCE(NEW.site_id, OLD.site_id),
    p_action      => v_action,
    p_entity_type => 'employee_absences',
    p_entity_id   => COALESCE(NEW.id, OLD.id),
    p_payload     => CASE TG_OP
      WHEN 'INSERT' THEN to_jsonb(NEW)
      WHEN 'DELETE' THEN to_jsonb(OLD)
      ELSE jsonb_build_object(
        'before', to_jsonb(OLD),
        'after',  to_jsonb(NEW)
      )
    END
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_employee_absences ON data.employee_absences;
CREATE TRIGGER trg_audit_employee_absences
  AFTER INSERT OR UPDATE OR DELETE ON data.employee_absences
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_employee_absences();


-- =============================================================================
-- 7. Vistes API (security_invoker = true)
-- =============================================================================

CREATE OR REPLACE VIEW api.work_schedules
  WITH (security_invoker = true)
AS
SELECT
  ws.id,
  ws.tenant_id,
  ws.site_id,
  ws.name,
  ws.description,
  ws.is_default,
  ws.is_active,
  ws.created_at,
  ws.updated_at
FROM data.work_schedules ws;

CREATE OR REPLACE VIEW api.work_schedule_intervals
  WITH (security_invoker = true)
AS
SELECT
  wsi.id,
  wsi.schedule_id,
  wsi.day_of_week,
  wsi.start_time,
  wsi.end_time,
  ROUND(
    EXTRACT(EPOCH FROM
      CASE WHEN wsi.end_time > wsi.start_time
           THEN wsi.end_time - wsi.start_time
           ELSE interval '24 hours' + (wsi.end_time - wsi.start_time)
      END
    ) / 60
  )::int AS expected_minutes,
  (wsi.end_time < wsi.start_time) AS spans_midnight,
  wsi.created_at
FROM data.work_schedule_intervals wsi;

CREATE OR REPLACE VIEW api.employee_schedule_assignments
  WITH (security_invoker = true)
AS
SELECT
  esa.id,
  esa.tenant_id,
  esa.employee_id,
  esa.schedule_id,
  ws.name  AS schedule_name,
  esa.effective_from,
  esa.effective_to,
  esa.notes,
  esa.created_by,
  esa.created_at,
  esa.updated_at
FROM data.employee_schedule_assignments esa
JOIN data.work_schedules ws ON ws.id = esa.schedule_id;

CREATE OR REPLACE VIEW api.holiday_calendars
  WITH (security_invoker = true)
AS
SELECT
  hc.id,
  hc.tenant_id,
  hc.name,
  hc.country_code,
  hc.region_code,
  hc.year,
  hc.is_active,
  hc.created_at,
  hc.updated_at
FROM data.holiday_calendars hc;

CREATE OR REPLACE VIEW api.holidays
  WITH (security_invoker = true)
AS
SELECT
  h.id,
  h.calendar_id,
  hc.name        AS calendar_name,
  hc.country_code,
  hc.region_code,
  h.date,
  h.name,
  h.holiday_type,
  h.is_half_day,
  h.created_at
FROM data.holidays h
JOIN data.holiday_calendars hc ON hc.id = h.calendar_id;

CREATE OR REPLACE VIEW api.site_holiday_calendar_assignments
  WITH (security_invoker = true)
AS
SELECT
  shca.id,
  shca.site_id,
  shca.calendar_id,
  hc.name        AS calendar_name,
  hc.country_code,
  hc.region_code,
  hc.year,
  hc.is_active   AS calendar_active,
  shca.priority,
  shca.created_at
FROM data.site_holiday_calendar_assignments shca
JOIN data.holiday_calendars hc ON hc.id = shca.calendar_id;

CREATE OR REPLACE VIEW api.employee_absences
  WITH (security_invoker = true)
AS
SELECT
  ea.id,
  ea.tenant_id,
  ea.site_id,
  ea.employee_id,
  ea.absence_type,
  ea.start_date,
  ea.end_date,
  (ea.end_date - ea.start_date + 1)  AS calendar_days,
  ea.status,
  ea.is_paid,
  ea.hours_per_day,
  ea.notes,
  ea.requested_by,
  ea.reviewed_by,
  ea.reviewed_at,
  ea.review_comment,
  ea.created_at,
  ea.updated_at
FROM data.employee_absences ea;


-- =============================================================================
-- 8. RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 8.1 api.resolve_work_day
--
--     Retorna tota la informació laboral d'un empleat per a un dia concret.
--     Prioritat: absència aprovada > festiu > horari > sense horari
--
--     Útil per:
--       · Frontend: mostrar estat del dia al calendari
--       · recompute_attendance_worker: obtenir expected_minutes i day_type
--
--     Accessible a: authenticated (si membre del tenant) + service_role
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.resolve_work_day(
  p_employee_id  uuid,
  p_work_date    date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp             record;
  v_tz              text;
  v_schedule_id     uuid;
  v_schedule_name   text;
  v_dow             smallint;
  v_expected_min    int     := 0;
  v_spans_midnight  boolean := false;
  v_shift_start     time;
  v_shift_end       time;
  v_day_type        text    := 'unknown';
  v_holiday         record;
  v_absence         record;
  v_interval_count  int;
BEGIN
  -- 1. Validar empleat i obtenir tenant/site
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'day_type',        'unknown',
      'expected_minutes', 0,
      'error',           'employee_not_found'
    );
  END IF;

  -- Comprovació d'accés: service_role (auth.uid() IS NULL),
  -- propi empleat, o qui tingui attendance.view_all / labor_calendar.manage
  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_emp.tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege: access denied for employee %', p_employee_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = p_employee_id AND e.user_id = auth.uid()
      )
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege: necessites attendance.view_all o ser l''empleat consultat'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- 2. Timezone del site
  v_tz := COALESCE(
    (api.get_effective_settings(
      p_site_id   => v_emp.site_id,
      p_user_id   => NULL,
      p_tenant_id => v_emp.tenant_id
    ) ->> 'site_timezone'),
    'Europe/Madrid'
  );

  -- 3. Comprovar absència aprovada (prioritat màxima)
  SELECT ea.id, ea.absence_type, ea.is_paid, ea.hours_per_day
  INTO v_absence
  FROM data.employee_absences ea
  WHERE ea.employee_id = p_employee_id
    AND ea.status      = 'approved'
    AND ea.start_date  <= p_work_date
    AND ea.end_date    >= p_work_date
  ORDER BY ea.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    -- Calcular expected_minutes de l'horari perquè el worker pugui derivar absence_minutes
    -- (COALESCE(absence.hours_per_day * 60, expected_minutes))
    SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM
      CASE WHEN wsi.end_time > wsi.start_time
           THEN wsi.end_time - wsi.start_time
           ELSE interval '24 hours' + (wsi.end_time - wsi.start_time) END
    ) / 60))::int, 0)
    INTO v_expected_min
    FROM data.work_schedule_intervals wsi
    WHERE wsi.schedule_id = (
      SELECT esa.schedule_id FROM data.employee_schedule_assignments esa
      WHERE esa.employee_id   = p_employee_id
        AND esa.effective_from <= p_work_date
        AND (esa.effective_to IS NULL OR esa.effective_to > p_work_date)
      ORDER BY esa.effective_from DESC LIMIT 1
    )
    AND wsi.day_of_week = EXTRACT(DOW FROM p_work_date)::smallint;

    RETURN jsonb_build_object(
      'day_type',         'absence',
      'expected_minutes', v_expected_min,
      'site_timezone',    v_tz,
      'is_holiday',       false,
      'holiday_name',     null,
      'is_absence',       true,
      'absence_id',       v_absence.id,
      'absence_type',     v_absence.absence_type,
      'absence_is_paid',  v_absence.is_paid,
      'absence_hours_per_day', v_absence.hours_per_day,
      'schedule_id',      null,
      'schedule_name',    null,
      'spans_midnight',   false,
      'shift_start_time', null,
      'shift_end_time',   null
    );
  END IF;

  -- 4. Comprovar festiu (calendaris assignats al site)
  IF v_emp.site_id IS NOT NULL THEN
    SELECT h.name, h.holiday_type, h.is_half_day
    INTO v_holiday
    FROM data.holidays h
    JOIN data.holiday_calendars hc ON hc.id = h.calendar_id
    JOIN data.site_holiday_calendar_assignments shca ON shca.calendar_id = hc.id
    WHERE shca.site_id = v_emp.site_id
      AND h.date = p_work_date
      AND hc.is_active = true
    ORDER BY shca.priority DESC, hc.tenant_id NULLS LAST
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'day_type',         CASE WHEN v_holiday.is_half_day THEN 'half_holiday' ELSE 'holiday' END,
        'expected_minutes', 0,
        'site_timezone',    v_tz,
        'is_holiday',       true,
        'holiday_name',     v_holiday.name,
        'holiday_type',     v_holiday.holiday_type,
        'is_half_day',      v_holiday.is_half_day,
        'is_absence',       false,
        'absence_id',       null,
        'absence_type',     null,
        'schedule_id',      null,
        'schedule_name',    null,
        'spans_midnight',   false,
        'shift_start_time', null,
        'shift_end_time',   null
      );
    END IF;
  END IF;

  -- 5. Obtenir horari actiu de l'empleat per a p_work_date
  SELECT esa.schedule_id, ws.name
  INTO v_schedule_id, v_schedule_name
  FROM data.employee_schedule_assignments esa
  JOIN data.work_schedules ws ON ws.id = esa.schedule_id
  WHERE esa.employee_id  = p_employee_id
    AND esa.effective_from <= p_work_date
    AND (esa.effective_to IS NULL OR esa.effective_to > p_work_date)
  ORDER BY esa.effective_from DESC
  LIMIT 1;

  -- Fallback: horari per defecte del site/tenant
  IF NOT FOUND AND v_emp.site_id IS NOT NULL THEN
    SELECT ws.id, ws.name
    INTO v_schedule_id, v_schedule_name
    FROM data.work_schedules ws
    WHERE ws.tenant_id = v_emp.tenant_id
      AND ws.site_id   = v_emp.site_id
      AND ws.is_default = true
      AND ws.is_active  = true
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    SELECT ws.id, ws.name
    INTO v_schedule_id, v_schedule_name
    FROM data.work_schedules ws
    WHERE ws.tenant_id = v_emp.tenant_id
      AND ws.site_id   IS NULL
      AND ws.is_default = true
      AND ws.is_active  = true
    LIMIT 1;
  END IF;

  -- Sense horari → 'unknown'
  IF v_schedule_id IS NULL THEN
    RETURN jsonb_build_object(
      'day_type',         'unknown',
      'expected_minutes', 0,
      'site_timezone',    v_tz,
      'is_holiday',       false,
      'holiday_name',     null,
      'is_absence',       false,
      'absence_id',       null,
      'absence_type',     null,
      'schedule_id',      null,
      'schedule_name',    null,
      'spans_midnight',   false,
      'shift_start_time', null,
      'shift_end_time',   null
    );
  END IF;

  -- 6. DOW del dia (PG: 0=Diumenge, 1=Dilluns, ..., 6=Dissabte)
  v_dow := EXTRACT(DOW FROM p_work_date)::smallint;

  -- 7. Intervals per a aquest DOW
  SELECT COUNT(*) INTO v_interval_count
  FROM data.work_schedule_intervals
  WHERE schedule_id = v_schedule_id AND day_of_week = v_dow;

  IF v_interval_count = 0 THEN
    -- Dia no laborable (e.g., diumenge sense intervals)
    RETURN jsonb_build_object(
      'day_type',         'non_working',
      'expected_minutes', 0,
      'site_timezone',    v_tz,
      'is_holiday',       false,
      'holiday_name',     null,
      'is_absence',       false,
      'absence_id',       null,
      'absence_type',     null,
      'schedule_id',      v_schedule_id,
      'schedule_name',    v_schedule_name,
      'spans_midnight',   false,
      'shift_start_time', null,
      'shift_end_time',   null
    );
  END IF;

  -- 8. Calcular expected_minutes i detectar torn nocturn
  SELECT
    COALESCE(SUM(
      ROUND(
        EXTRACT(EPOCH FROM
          CASE WHEN end_time > start_time
               THEN end_time - start_time
               ELSE interval '24 hours' + (end_time - start_time)
          END
        ) / 60
      )
    )::int, 0),
    bool_or(end_time < start_time),
    MIN(start_time),
    MAX(end_time)
  INTO v_expected_min, v_spans_midnight, v_shift_start, v_shift_end
  FROM data.work_schedule_intervals
  WHERE schedule_id = v_schedule_id AND day_of_week = v_dow;

  RETURN jsonb_build_object(
    'day_type',         'working',
    'expected_minutes', v_expected_min,
    'site_timezone',    v_tz,
    'is_holiday',       false,
    'holiday_name',     null,
    'is_absence',       false,
    'absence_id',       null,
    'absence_type',     null,
    'schedule_id',      v_schedule_id,
    'schedule_name',    v_schedule_name,
    'spans_midnight',   v_spans_midnight,
    'shift_start_time', v_shift_start,
    'shift_end_time',   v_shift_end
  );
END;
$$;


-- ---------------------------------------------------------------------------
-- 8.2 api.request_absence
--
--     Empleat o manager sol·licita una absència. La crea amb status='requested'.
--     Comprova que no hi hagi solapament amb absències aprovades existents.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.request_absence(
  p_employee_id   uuid,
  p_absence_type  text,
  p_start_date    date,
  p_end_date      date,
  p_notes         text        DEFAULT NULL,
  p_hours_per_day numeric     DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp           record;
  v_absence_id    uuid;
  v_workflow      text;
  v_init_status   text := 'requested';
BEGIN
  -- Validar empleat i tenant
  SELECT e.tenant_id, e.site_id, e.user_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Comprovació d'accés: propi empleat o attendance.approve
  IF auth.uid() IS NOT NULL THEN
    IF v_emp.user_id IS DISTINCT FROM auth.uid() THEN
      IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve') THEN
        RAISE EXCEPTION 'insufficient_privilege: absences.request o attendance.approve requerit'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
    ELSE
      IF NOT data.jwt_has_permission(v_emp.tenant_id, 'absences.request') THEN
        RAISE EXCEPTION 'insufficient_privilege: absences.request requerit'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
    END IF;
  END IF;

  -- Validar tipus
  IF p_absence_type NOT IN ('vacation','sick_leave','personal','maternity_paternity',
                             'accident_leave','bereavement','other') THEN
    RAISE EXCEPTION 'invalid_absence_type: %', p_absence_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'invalid_date_range: end_date ha de ser >= start_date'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Comprovar solapament amb absències actives (aprovades o en espera)
  IF EXISTS (
    SELECT 1 FROM data.employee_absences
    WHERE employee_id = p_employee_id
      AND status IN ('approved', 'requested')
      AND start_date <= p_end_date
      AND end_date   >= p_start_date
  ) THEN
    RAISE EXCEPTION 'absence_overlap: ja existeix una absència aprovada o pendent que se solapa amb el període indicat'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  -- Workflow auto-approve per sick_leave si el tenant ho permet
  SELECT COALESCE(
    (api.get_effective_settings(
      p_site_id   => v_emp.site_id,
      p_user_id   => NULL,
      p_tenant_id => v_emp.tenant_id
    ) ->> 'attendance_default_absence_workflow'),
    'require_approval'
  ) INTO v_workflow;

  IF v_workflow = 'auto_approve' AND p_absence_type IN ('sick_leave', 'accident_leave') THEN
    v_init_status := 'approved';
  END IF;

  INSERT INTO data.employee_absences (
    tenant_id, site_id, employee_id,
    absence_type, start_date, end_date,
    status, is_paid, hours_per_day, notes,
    requested_by,
    reviewed_by, reviewed_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id,
    p_absence_type, p_start_date, p_end_date,
    v_init_status, true, p_hours_per_day, p_notes,
    auth.uid(),
    CASE WHEN v_init_status = 'approved' THEN auth.uid() ELSE NULL END,
    CASE WHEN v_init_status = 'approved' THEN now()      ELSE NULL END
  )
  RETURNING id INTO v_absence_id;

  RETURN jsonb_build_object(
    'absence_id',  v_absence_id,
    'status',      v_init_status,
    'employee_id', p_employee_id,
    'start_date',  p_start_date,
    'end_date',    p_end_date
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.request_absence(uuid, text, date, date, text, numeric) TO authenticated;


-- ---------------------------------------------------------------------------
-- 8.3 api.approve_absence
--
--     Manager aprova o rebutja una absència. Requereix attendance.approve.
--     Si s'aprova, encua recomputació dels dies afectats.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.approve_absence(
  p_absence_id     uuid,
  p_new_status     text,
  p_review_comment text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_abs    record;
  v_d      date;
  v_emp    record;
BEGIN
  -- Carregar absència
  SELECT ea.*, e.tenant_id AS emp_tenant_id
  INTO v_abs
  FROM data.employee_absences ea
  JOIN data.employees e ON e.id = ea.employee_id
  WHERE ea.id = p_absence_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'absence_not_found: %', p_absence_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Permís
  IF auth.uid() IS NOT NULL
     AND NOT data.jwt_has_permission(v_abs.tenant_id, 'attendance.approve') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_new_status NOT IN ('approved', 'rejected', 'cancelled') THEN
    RAISE EXCEPTION 'invalid_status: % — valid: approved, rejected, cancelled', p_new_status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_abs.status NOT IN ('requested', 'approved') THEN
    RAISE EXCEPTION 'absence_not_actionable: status actual = %', v_abs.status
      USING ERRCODE = 'check_violation';
  END IF;

  -- Comprovar solapament amb altres absències ja aprovades en el moment d'aprovar
  IF p_new_status = 'approved' THEN
    IF EXISTS (
      SELECT 1 FROM data.employee_absences
      WHERE employee_id = v_abs.employee_id
        AND id          != p_absence_id
        AND status       = 'approved'
        AND start_date  <= v_abs.end_date
        AND end_date    >= v_abs.start_date
    ) THEN
      RAISE EXCEPTION 'absence_overlap: ja existeix una absència aprovada que se solapa amb el període indicat'
        USING ERRCODE = 'exclusion_violation';
    END IF;
  END IF;

  UPDATE data.employee_absences
  SET status         = p_new_status,
      reviewed_by    = auth.uid(),
      reviewed_at    = now(),
      review_comment = p_review_comment,
      updated_at     = now()
  WHERE id = p_absence_id;

  -- Si s'ha aprovat → encuar recomputació de cada dia del rang afectat
  IF p_new_status = 'approved' THEN
    v_d := v_abs.start_date;
    WHILE v_d <= v_abs.end_date LOOP
      PERFORM pgmq.send(
        'attendance_recompute_queue',
        jsonb_build_object(
          'task',            'recompute_attendance_day',
          'tenant_id',       v_abs.tenant_id,
          'employee_id',     v_abs.employee_id,
          'work_date',       v_d::text,
          'idempotency_key', 'recompute-' || v_abs.employee_id::text
                             || '-' || v_d::text || '-abs-' || p_absence_id::text
        )
      );
      v_d := v_d + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'absence_id', p_absence_id,
    'status',     p_new_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_absence(uuid, text, text) TO authenticated;


-- ---------------------------------------------------------------------------
-- 8.4 api.import_holidays
--
--     Importa festius en format Nager.Date (o compatible) al calendari indicat.
--     El frontend crida l'API externa (Nager.Date) i passa les dades com JSONB.
--
--     Format p_holidays_json esperat (array):
--       [{ "date": "2026-01-01", "name": "Any Nou", "holidayType": "Public" }, ...]
--
--     Requereix: labor_calendar.manage
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.import_holidays(
  p_calendar_id    uuid,
  p_holidays_json  jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_cal      record;
  v_item     jsonb;
  v_inserted int := 0;
  v_skipped  int := 0;
  v_date     date;
  v_name     text;
  v_type     text;
BEGIN
  -- Carregar calendari i validar accés
  SELECT hc.* INTO v_cal
  FROM data.holiday_calendars hc
  WHERE hc.id = p_calendar_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'holiday_calendar_not_found: %', p_calendar_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_cal.tenant_id IS NULL THEN
    RAISE EXCEPTION 'cannot_modify_system_calendar: els calendaris del sistema no es poden modificar'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF auth.uid() IS NOT NULL
     AND NOT data.jwt_has_permission(v_cal.tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF jsonb_typeof(p_holidays_json) != 'array' THEN
    RAISE EXCEPTION 'invalid_format: p_holidays_json ha de ser un array JSON'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Processar cada festiu
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_holidays_json)
  LOOP
    BEGIN
      v_date := (v_item->>'date')::date;
      v_name := COALESCE(v_item->>'localName', v_item->>'name', 'Festiu');
      v_type := CASE
        WHEN lower(COALESCE(v_item->>'holidayType', '')) IN ('public', 'national') THEN 'national'
        WHEN lower(COALESCE(v_item->>'holidayType', '')) = 'regional'              THEN 'regional'
        WHEN lower(COALESCE(v_item->>'holidayType', '')) = 'local'                 THEN 'local'
        ELSE 'tenant_custom'
      END;

      INSERT INTO data.holidays (calendar_id, date, name, holiday_type)
      VALUES (p_calendar_id, v_date, v_name, v_type)
      ON CONFLICT (calendar_id, date) DO UPDATE
        SET name         = EXCLUDED.name,
            holiday_type = EXCLUDED.holiday_type;

      v_inserted := v_inserted + 1;

    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'calendar_id', p_calendar_id,
    'inserted',    v_inserted,
    'skipped',     v_skipped,
    'total',       jsonb_array_length(p_holidays_json)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.import_holidays(uuid, jsonb) TO authenticated;


-- =============================================================================
-- 9. api.recompute_attendance_worker — Phase 1B upgrade
--
--    Canvis respecte Phase 1A:
--      · Timezone del site llegida de settings ('site_timezone') en lloc de
--        la constant 'Europe/Madrid'. Fallback: 'Europe/Madrid'.
--      · Crida a api.resolve_work_day per obtenir expected_minutes + day_type.
--      · Suport de torns nocturns: si spans_midnight, el rang de punches
--        s'expandeix des de shift_start (work_date) fins a shift_end (work_date+1).
--      · Upsert time_daily_summaries inclou expected_minutes i day_type.
--      · Si day_type = 'absence' → summary amb absence_minutes = expected_minutes.
--      · Si day_type = 'non_working' | 'holiday' i punch_count = 0 → skip.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.recompute_attendance_worker(
  p_employee_id  uuid,
  p_work_date    date,
  p_tenant_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp              record;
  v_tz               text;
  v_resolve          jsonb;
  v_day_type         text;
  v_expected_min     int;
  v_spans_midnight   boolean;
  v_shift_start      time;
  v_shift_end        time;
  v_punch_from       timestamptz;
  v_punch_to         timestamptz;
  v_first_in_at      timestamptz;
  v_first_in_id      uuid;
  v_last_out_at      timestamptz;
  v_last_out_id      uuid;
  v_gross_min        int;
  v_break_min        int  := 0;
  v_net_min          int;
  v_punch_count      int;
  v_in_count         int;
  v_out_count        int;
  v_bs_count         int;
  v_be_count         int;
  v_anomalies        text[] := '{}';
  v_entry_status     text;
  v_locked_at        timestamptz;
  v_existing_status  text;
  v_absence_min      int  := 0;
BEGIN
  -- 1. Validar empleat i obtenir site_id (zero-trust)
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND OR v_emp.site_id IS NULL THEN
    RETURN jsonb_build_object(
      'skipped', true, 'reason', 'employee_not_found_or_no_site'
    );
  END IF;

  -- 2. Timezone del site
  v_tz := COALESCE(
    (api.get_effective_settings(
      p_site_id   => v_emp.site_id,
      p_user_id   => NULL,
      p_tenant_id => p_tenant_id
    ) ->> 'site_timezone'),
    'Europe/Madrid'
  );

  -- 3. Resolució del dia laboral (absència, festiu, horari, ...)
  v_resolve        := api.resolve_work_day(p_employee_id, p_work_date);
  v_day_type       := COALESCE(v_resolve->>'day_type', 'unknown');
  v_expected_min   := COALESCE((v_resolve->>'expected_minutes')::int, 0);
  v_spans_midnight := COALESCE((v_resolve->>'spans_midnight')::boolean, false);

  IF v_resolve->>'shift_start_time' IS NOT NULL THEN
    v_shift_start := (v_resolve->>'shift_start_time')::time;
    v_shift_end   := (v_resolve->>'shift_end_time')::time;
  END IF;

  -- 4. Si absència aprovada: omplir absence_minutes i no processar punches
  IF v_day_type = 'absence' THEN
    v_absence_min := COALESCE(
      ((v_resolve->>'absence_hours_per_day')::numeric * 60)::int,
      v_expected_min
    );

    -- Comprovar bloqueig payroll
    SELECT payroll_locked_at INTO v_locked_at
    FROM data.time_daily_summaries
    WHERE employee_id = p_employee_id AND work_date = p_work_date;

    IF v_locked_at IS NOT NULL THEN
      RETURN jsonb_build_object('skipped', true, 'reason', 'payroll_locked');
    END IF;

    INSERT INTO data.time_daily_summaries (
      tenant_id, site_id, employee_id, work_date,
      day_type, expected_minutes, worked_minutes, break_minutes,
      overtime_minutes, absence_minutes, punch_count,
      anomaly_codes, needs_review, recomputed_at, updated_at
    ) VALUES (
      p_tenant_id, v_emp.site_id, p_employee_id, p_work_date,
      'absence', v_expected_min, 0, 0,
      0, v_absence_min, 0,
      '{}', false, now(), now()
    )
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      day_type         = 'absence',
      expected_minutes = v_expected_min,
      worked_minutes   = 0,
      absence_minutes  = v_absence_min,
      punch_count      = 0,
      anomaly_codes    = '{}',
      needs_review     = false,
      recomputed_at    = now(),
      updated_at       = now()
    WHERE data.time_daily_summaries.status = 'draft';

    RETURN jsonb_build_object(
      'success',       true,
      'day_type',      'absence',
      'employee_id',   p_employee_id,
      'work_date',     p_work_date,
      'absence_minutes', v_absence_min
    );
  END IF;

  -- 5. Determinar rang de punches (normal vs torn nocturn)
  IF v_spans_midnight AND v_shift_start IS NOT NULL THEN
    -- Torn nocturn: de shift_start (work_date) a shift_end (work_date+1)
    v_punch_from := (p_work_date + v_shift_start) AT TIME ZONE v_tz;
    v_punch_to   := ((p_work_date + 1) + v_shift_end) AT TIME ZONE v_tz;
  ELSE
    -- Dia normal: tot el dia en la timezone del site
    v_punch_from := p_work_date AT TIME ZONE v_tz;
    v_punch_to   := (p_work_date + 1) AT TIME ZONE v_tz;
  END IF;

  -- 6. Comptar i agregar punches del rang
  SELECT
    COUNT(*)                                               AS total,
    COUNT(*) FILTER (WHERE punch_type = 'in')              AS in_c,
    COUNT(*) FILTER (WHERE punch_type = 'out')             AS out_c,
    COUNT(*) FILTER (WHERE punch_type = 'break_start')     AS bs_c,
    COUNT(*) FILTER (WHERE punch_type = 'break_end')       AS be_c,
    MIN(occurred_at) FILTER (WHERE punch_type = 'in')      AS first_in,
    MAX(occurred_at) FILTER (WHERE punch_type = 'out')     AS last_out
  INTO
    v_punch_count, v_in_count, v_out_count, v_bs_count, v_be_count,
    v_first_in_at, v_last_out_at
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND occurred_at >= v_punch_from
    AND occurred_at <  v_punch_to;

  -- Festiu / no laborable sense punches → skip (sense recomputació)
  IF v_punch_count = 0 AND v_day_type IN ('holiday', 'half_holiday', 'non_working') THEN
    RETURN jsonb_build_object(
      'skipped',   true,
      'reason',    'no_punches_on_' || v_day_type,
      'day_type',  v_day_type
    );
  END IF;

  -- IDs de referència
  SELECT id INTO v_first_in_id
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND punch_type  = 'in'
    AND occurred_at >= v_punch_from
    AND occurred_at <  v_punch_to
  ORDER BY occurred_at ASC LIMIT 1;

  SELECT id INTO v_last_out_id
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND punch_type  = 'out'
    AND occurred_at >= v_punch_from
    AND occurred_at <  v_punch_to
  ORDER BY occurred_at DESC LIMIT 1;

  -- 7. Anomalies heretades dels punches
  SELECT ARRAY(
    SELECT DISTINCT a
    FROM data.time_punches tp,
         LATERAL unnest(tp.anomaly_codes) AS a
    WHERE tp.employee_id = p_employee_id
      AND tp.occurred_at >= v_punch_from
      AND tp.occurred_at <  v_punch_to
      AND cardinality(tp.anomaly_codes) > 0
  ) INTO v_anomalies;

  v_anomalies := COALESCE(v_anomalies, '{}');

  -- 8. Anomalies de parellament IN/OUT
  IF v_punch_count > 0 AND v_in_count = 0 THEN
    v_anomalies := array_append(v_anomalies, 'MISSING_IN');
  END IF;
  IF v_in_count > v_out_count AND v_out_count > 0 THEN
    v_anomalies := array_append(v_anomalies, 'EXTRA_IN');
  END IF;
  IF v_out_count > v_in_count THEN
    v_anomalies := array_append(v_anomalies, 'EXTRA_OUT');
  END IF;
  IF v_bs_count != v_be_count THEN
    v_anomalies := array_append(v_anomalies, 'BREAK_MISMATCH');
  END IF;

  -- 9. Calcular minuts bruts, pauses i nets
  IF v_first_in_at IS NOT NULL AND v_last_out_at IS NOT NULL THEN
    v_gross_min := ROUND(EXTRACT(EPOCH FROM (v_last_out_at - v_first_in_at)) / 60)::int;

    SELECT COALESCE(ROUND(SUM(
      EXTRACT(EPOCH FROM (be.occurred_at - bs.occurred_at))
    ) / 60)::int, 0)
    INTO v_break_min
    FROM (
      SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
      FROM data.time_punches
      WHERE employee_id = p_employee_id
        AND punch_type  = 'break_start'
        AND occurred_at >= v_punch_from
        AND occurred_at <  v_punch_to
    ) bs
    JOIN (
      SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
      FROM data.time_punches
      WHERE employee_id = p_employee_id
        AND punch_type  = 'break_end'
        AND occurred_at >= v_punch_from
        AND occurred_at <  v_punch_to
    ) be ON bs.rn = be.rn
    WHERE be.occurred_at > bs.occurred_at;

    v_net_min      := GREATEST(0, v_gross_min - v_break_min);
    v_entry_status := 'closed';

  ELSIF v_first_in_at IS NOT NULL THEN
    v_gross_min    := NULL;
    v_net_min      := NULL;
    v_entry_status := 'open';

  ELSE
    v_gross_min    := NULL;
    v_net_min      := NULL;
    v_entry_status := CASE WHEN v_punch_count = 0 THEN 'missing' ELSE 'open' END;
  END IF;

  -- 10. Comprovar bloqueig payroll
  SELECT payroll_locked_at INTO v_locked_at
  FROM data.time_daily_summaries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF v_locked_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'skipped',     true,
      'reason',      'payroll_locked',
      'employee_id', p_employee_id,
      'work_date',   p_work_date
    );
  END IF;

  -- 11. Si time_entry té status='adjusted' → actualitzar només el summary
  SELECT status INTO v_existing_status
  FROM data.time_entries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF v_existing_status = 'adjusted' THEN
    UPDATE data.time_daily_summaries
    SET day_type         = v_day_type,
        expected_minutes = v_expected_min,
        punch_count      = v_punch_count,
        anomaly_codes    = v_anomalies,
        needs_review     = (cardinality(v_anomalies) > 0),
        recomputed_at    = now(),
        updated_at       = now()
    WHERE employee_id = p_employee_id AND work_date = p_work_date
      AND status = 'draft';

    RETURN jsonb_build_object(
      'skipped_entry', true,
      'reason',        'entry_adjusted',
      'employee_id',   p_employee_id,
      'work_date',     p_work_date
    );
  END IF;

  -- 12. Upsert time_entries
  INSERT INTO data.time_entries (
    tenant_id, site_id, employee_id, work_date,
    starts_at, ends_at, punch_in_id, punch_out_id,
    gross_minutes, break_minutes, net_minutes,
    regular_minutes, overtime_minutes, status, updated_at
  ) VALUES (
    p_tenant_id, v_emp.site_id, p_employee_id, p_work_date,
    v_first_in_at, v_last_out_at, v_first_in_id, v_last_out_id,
    v_gross_min, v_break_min, v_net_min,
    v_net_min, 0, v_entry_status, now()
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE SET
    starts_at        = EXCLUDED.starts_at,
    ends_at          = EXCLUDED.ends_at,
    punch_in_id      = EXCLUDED.punch_in_id,
    punch_out_id     = EXCLUDED.punch_out_id,
    gross_minutes    = EXCLUDED.gross_minutes,
    break_minutes    = EXCLUDED.break_minutes,
    net_minutes      = EXCLUDED.net_minutes,
    regular_minutes  = EXCLUDED.regular_minutes,
    overtime_minutes = EXCLUDED.overtime_minutes,
    status           = EXCLUDED.status,
    updated_at       = EXCLUDED.updated_at
  WHERE data.time_entries.status != 'adjusted';

  -- 13. Upsert time_daily_summaries (Phase 1B: inclou day_type + expected_minutes)
  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date,
    day_type, expected_minutes, worked_minutes, break_minutes,
    overtime_minutes, absence_minutes, punch_count,
    anomaly_codes, needs_review, recomputed_at, updated_at
  ) VALUES (
    p_tenant_id, v_emp.site_id, p_employee_id, p_work_date,
    v_day_type, v_expected_min, COALESCE(v_net_min, 0), v_break_min,
    0, 0, v_punch_count,
    v_anomalies,
    (cardinality(v_anomalies) > 0 OR v_entry_status = 'missing'),
    now(), now()
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE SET
    day_type         = EXCLUDED.day_type,
    expected_minutes = EXCLUDED.expected_minutes,
    worked_minutes   = EXCLUDED.worked_minutes,
    break_minutes    = EXCLUDED.break_minutes,
    punch_count      = EXCLUDED.punch_count,
    anomaly_codes    = EXCLUDED.anomaly_codes,
    needs_review     = EXCLUDED.needs_review,
    recomputed_at    = EXCLUDED.recomputed_at,
    updated_at       = EXCLUDED.updated_at
  WHERE data.time_daily_summaries.status = 'draft';

  RETURN jsonb_build_object(
    'success',         true,
    'employee_id',     p_employee_id,
    'work_date',       p_work_date,
    'day_type',        v_day_type,
    'expected_minutes', v_expected_min,
    'punch_count',     v_punch_count,
    'net_minutes',     v_net_min,
    'entry_status',    v_entry_status,
    'anomaly_codes',   v_anomalies,
    'site_timezone',   v_tz,
    'spans_midnight',  v_spans_midnight
  );
END;
$$;

REVOKE ALL ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) TO service_role;


-- =============================================================================
-- 10. Grants
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON data.work_schedules                 TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.work_schedule_intervals        TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.employee_schedule_assignments  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.holiday_calendars              TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.holidays                       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.site_holiday_calendar_assignments TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.employee_absences              TO authenticated;

GRANT SELECT ON data.work_schedules                  TO service_role;
GRANT SELECT ON data.work_schedule_intervals         TO service_role;
GRANT SELECT ON data.employee_schedule_assignments   TO service_role;
GRANT SELECT ON data.holiday_calendars               TO service_role;
GRANT SELECT ON data.holidays                        TO service_role;
GRANT SELECT ON data.site_holiday_calendar_assignments TO service_role;
GRANT SELECT, UPDATE ON data.employee_absences       TO service_role;

GRANT SELECT ON api.work_schedules                   TO authenticated;
GRANT SELECT ON api.work_schedule_intervals          TO authenticated;
GRANT SELECT ON api.employee_schedule_assignments    TO authenticated;
GRANT SELECT ON api.holiday_calendars                TO authenticated;
GRANT SELECT ON api.holidays                         TO authenticated;
GRANT SELECT ON api.site_holiday_calendar_assignments TO authenticated;
GRANT SELECT ON api.employee_absences                TO authenticated;

GRANT EXECUTE ON FUNCTION api.resolve_work_day(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION api.resolve_work_day(uuid, date) TO service_role;
