-- =============================================================================
-- Migration: 20260515000018_attendance_core.sql
-- Propòsit : Mòdul de Control Horari — Phase 1A (Legal Foundation Backend)
--
-- Conté:
--   1.  DDL  : data.attendance_devices
--   2.  DDL  : data.attendance_location_assignments
--   3.  DDL  : data.time_punches   (fitxatges raw IMMUTABLES)
--   4.  DDL  : data.time_entries   (intervals processats per dia)
--   5.  DDL  : data.time_daily_summaries (resum diari per aprovació/payroll)
--   6.  Settings Registry — claus de configuració de fitxatge
--   7.  RBAC — CREATE OR REPLACE data.get_role_permissions (+ permisos attendance)
--   8.  RLS  — polítiques per a les 5 taules noves
--   9.  Audit — triggers per time_punches i time_daily_summaries
--  10.  Vistes API — api.attendance_devices, api.attendance_locations,
--                    api.time_punches, api.time_entries, api.time_daily_summaries
--  11.  RPC  : api.record_time_punch (individual, idempotent)
--  12.  RPC  : api.sync_time_punches (batch offline)
--  13.  RPC  : api.my_attendance_today
--  14.  RPC  : api.approve_time_day
--  15.  RPC  : api.adjust_time_entry
--  16.  RPC  : api.export_payroll_days
--  17.  PGMQ : pgmq.create('attendance_recompute_queue')
--  18.  Dispatcher: data.invoke_attendance_queue_worker + cron
--  19.  Grants + NOTIFY pgrst
--
-- Depèn de:
--   20260401000002 (tenants, sites, profiles)
--   20260429000002 (rbac — data.get_role_permissions, data.jwt_has_permission)
--   20260502000002 (data.locations)
--   20260503000002 (async_infra — data.log_audit_event, PGMQ helpers)
--   20260504000001 (data.employees)
--   20260506000005 (data.validate_geo_payload)
--   20260511000005 (settings_engine — data.settings_registry, data.system_settings)
--
-- Restriccions legals (RDL 8/2019, obligatori 2026):
--   · time_punches IMMUTABLE: cap UPDATE ni DELETE (polítiques RLS restrictives)
--   · Retenció mínima 4 anys
--   · Traçabilitat: received_at (servidor) + occurred_at (client)
-- =============================================================================


-- =============================================================================
-- 1. DDL: data.attendance_devices
--    Dispositius físics o virtuals per a fitxatge. No consumeixen llicències
--    TenantMember; s'autentiquen via device_secret_hash (Phase 3 Edge Function).
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.attendance_devices (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid        NOT NULL REFERENCES data.tenants(id)    ON DELETE CASCADE,
  site_id            uuid        NOT NULL REFERENCES data.sites(id)      ON DELETE CASCADE,
  location_id        uuid                 REFERENCES data.locations(id)  ON DELETE SET NULL,
  name               text        NOT NULL,
  device_public_id   text        NOT NULL,
  device_secret_hash text        NOT NULL,
  type               text        NOT NULL DEFAULT 'station'
                     CHECK (type IN ('mobile', 'station', 'tablet')),
  status             text        NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active', 'suspended', 'retired')),
  last_seen_at       timestamptz,
  metadata           jsonb       NOT NULL DEFAULT '{}',
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, device_public_id)
);

CREATE INDEX IF NOT EXISTS idx_attendance_devices_tenant
  ON data.attendance_devices (tenant_id);
CREATE INDEX IF NOT EXISTS idx_attendance_devices_site
  ON data.attendance_devices (site_id);
CREATE INDEX IF NOT EXISTS idx_attendance_devices_location
  ON data.attendance_devices (location_id)
  WHERE location_id IS NOT NULL;

CREATE TRIGGER trg_set_updated_at_attendance_devices
  BEFORE UPDATE ON data.attendance_devices
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

COMMENT ON TABLE data.attendance_devices
  IS 'Dispositius de fitxatge (estacions, tablets, mòbils corporatius). '
     'Identitat tècnica: no facturable, no TenantMember. '
     'Autenticació via device_secret_hash (bcrypt). Phase 3: Edge Function punch-from-station.';


-- =============================================================================
-- 2. DDL: data.attendance_location_assignments
--    Vincula empleats a locations per a validació de geofencing.
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.attendance_location_assignments (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES data.tenants(id)      ON DELETE CASCADE,
  employee_id  uuid        NOT NULL REFERENCES data.employees(id)    ON DELETE CASCADE,
  location_id  uuid        NOT NULL REFERENCES data.locations(id)    ON DELETE CASCADE,
  starts_on    date,
  ends_on      date,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, location_id)
);

CREATE INDEX IF NOT EXISTS idx_attend_loc_assign_tenant
  ON data.attendance_location_assignments (tenant_id);
CREATE INDEX IF NOT EXISTS idx_attend_loc_assign_employee
  ON data.attendance_location_assignments (employee_id);

COMMENT ON TABLE data.attendance_location_assignments
  IS 'Assignació d''empleats a zones de fitxatge. Usada per geofencing i estacions fixes.';


-- =============================================================================
-- 3. DDL: data.time_punches
--    Fitxatges raw IMMUTABLES. Cap UPDATE ni DELETE permès (requisit legal).
--    client_op_id: UUID v7 generat pel client (idempotència offline).
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.time_punches (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id)             ON DELETE CASCADE,
  site_id             uuid        NOT NULL REFERENCES data.sites(id)               ON DELETE CASCADE,
  employee_id         uuid        NOT NULL REFERENCES data.employees(id)           ON DELETE CASCADE,
  device_id           uuid                 REFERENCES data.attendance_devices(id)  ON DELETE SET NULL,
  client_op_id        uuid        NOT NULL,
  punch_type          text        NOT NULL
                      CHECK (punch_type IN ('in', 'out', 'break_start', 'break_end')),
  occurred_at         timestamptz NOT NULL,
  received_at         timestamptz NOT NULL DEFAULT now(),
  geo                 jsonb,
  location_permission text        NOT NULL DEFAULT 'notrequired'
                      CHECK (location_permission IN (
                        'granted', 'denied', 'timeout', 'error', 'notrequired'
                      )),
  anomaly_codes       text[]      NOT NULL DEFAULT '{}',
  source              text        NOT NULL DEFAULT 'mobile'
                      CHECK (source IN ('mobile', 'station', 'manual_entry')),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, client_op_id)
);

CREATE INDEX IF NOT EXISTS idx_time_punches_employee_occurred
  ON data.time_punches (employee_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_time_punches_tenant_occurred
  ON data.time_punches (tenant_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_time_punches_site_occurred
  ON data.time_punches (site_id, occurred_at DESC);

COMMENT ON TABLE data.time_punches
  IS 'Fitxatges raw immutables (RDL 8/2019). Cap UPDATE ni DELETE. '
     'received_at = hora servidor; occurred_at = hora client. '
     'Retenció mínima 4 anys.';
COMMENT ON COLUMN data.time_punches.client_op_id
  IS 'UUID v7 generat pel client. UNIQUE per tenant → idempotència offline.';
COMMENT ON COLUMN data.time_punches.anomaly_codes
  IS 'HIGH_UNCERTAINTY (GPS>100m), CLOCK_SKEW (desfasament>threshold), GEOFENCE_WARN/BLOCK.';


-- =============================================================================
-- 4. DDL: data.time_entries
--    Intervals processats (IN→OUT) per dia de feina. Un registre per empleat
--    per work_date. Calculat pel recompute worker. Pot ser ajustat per un manager
--    (els raw punches no s'alteren mai).
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.time_entries (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid        NOT NULL REFERENCES data.tenants(id)       ON DELETE CASCADE,
  site_id           uuid        NOT NULL REFERENCES data.sites(id)         ON DELETE CASCADE,
  employee_id       uuid        NOT NULL REFERENCES data.employees(id)     ON DELETE CASCADE,
  work_date         date        NOT NULL,
  starts_at         timestamptz,
  ends_at           timestamptz,
  punch_in_id       uuid        REFERENCES data.time_punches(id)           ON DELETE SET NULL,
  punch_out_id      uuid        REFERENCES data.time_punches(id)           ON DELETE SET NULL,
  gross_minutes     int,
  break_minutes     int         NOT NULL DEFAULT 0,
  net_minutes       int,
  regular_minutes   int,
  overtime_minutes  int         NOT NULL DEFAULT 0,
  status            text        NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open', 'closed', 'adjusted', 'missing')),
  adjustment_note   text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, work_date)
);

CREATE INDEX IF NOT EXISTS idx_time_entries_employee_date
  ON data.time_entries (employee_id, work_date DESC);
CREATE INDEX IF NOT EXISTS idx_time_entries_site_date
  ON data.time_entries (site_id, work_date DESC);

CREATE TRIGGER trg_set_updated_at_time_entries
  BEFORE UPDATE ON data.time_entries
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

COMMENT ON TABLE data.time_entries
  IS 'Interval diari processat per empleat (primer IN → darrer OUT). '
     'work_date = dia d''inici del torn (suport torns nocturns). '
     'Calculat asíncronament pel worker process-attendance-queue. '
     'Ajustos de manager via api.adjust_time_entry (raw punches intocables).';


-- =============================================================================
-- 5. DDL: data.time_daily_summaries
--    Resum diari per aprovació i exportació a payroll. Un registre per empleat
--    per work_date. Calculat a partir de time_entries + calendari laboral (1B).
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.time_daily_summaries (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid        NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  site_id           uuid        NOT NULL REFERENCES data.sites(id)     ON DELETE CASCADE,
  employee_id       uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  work_date         date        NOT NULL,
  day_type          text        NOT NULL DEFAULT 'unknown'
                    CHECK (day_type IN ('work', 'holiday', 'absence', 'weekend', 'unknown')),
  expected_minutes  int         NOT NULL DEFAULT 0,
  worked_minutes    int         NOT NULL DEFAULT 0,
  break_minutes     int         NOT NULL DEFAULT 0,
  overtime_minutes  int         NOT NULL DEFAULT 0,
  absence_minutes   int         NOT NULL DEFAULT 0,
  punch_count       int         NOT NULL DEFAULT 0,
  anomaly_codes     text[]      NOT NULL DEFAULT '{}',
  needs_review      boolean     NOT NULL DEFAULT false,
  status            text        NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'approved', 'exported')),
  approved_by       uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  approved_at       timestamptz,
  exported_at       timestamptz,
  payroll_locked_at timestamptz,
  recomputed_at     timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, work_date)
);

CREATE INDEX IF NOT EXISTS idx_time_daily_summaries_employee_date
  ON data.time_daily_summaries (employee_id, work_date DESC);
CREATE INDEX IF NOT EXISTS idx_time_daily_summaries_site_date
  ON data.time_daily_summaries (site_id, work_date DESC);
CREATE INDEX IF NOT EXISTS idx_time_daily_summaries_tenant_status
  ON data.time_daily_summaries (tenant_id, status, work_date DESC);
CREATE INDEX IF NOT EXISTS idx_time_daily_summaries_needs_review
  ON data.time_daily_summaries (tenant_id, needs_review, work_date DESC)
  WHERE needs_review = true;

CREATE TRIGGER trg_set_updated_at_time_daily_summaries
  BEFORE UPDATE ON data.time_daily_summaries
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

COMMENT ON TABLE data.time_daily_summaries
  IS 'Resum diari per revisió, aprovació i exportació a payroll. '
     'payroll_locked_at: dia bloquejat post-exportació (no es pot tornar a aprovar). '
     'expected_minutes: poblat per Phase 1B (schedules + festius).';


-- =============================================================================
-- 6. Settings Registry — claus de configuració de fitxatge
-- =============================================================================

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('attendance_geofencing_mode',          'site',   'attendance.devices.manage', false, true,
   'Mode de geofencing: off | informative | warn | block. Per defecte: informative'),
  ('attendance_rounding_mode',            'tenant', 'attendance.devices.manage', false, true,
   'Arrodoniment de minuts per payroll: real_minute | 15_min | 30_min'),
  ('attendance_overtime_policy',          'tenant', 'attendance.devices.manage', false, true,
   'Política d''hores extra: auto_if_allowed | approval_required'),
  ('attendance_clock_offset_threshold_ms','site',   'attendance.devices.manage', false, true,
   'Desfasament màxim de rellotge client (ms) abans de marcar CLOCK_SKEW. Per defecte: 300000')
ON CONFLICT (setting_key) DO UPDATE SET
  scope               = EXCLUDED.scope,
  required_permission = EXCLUDED.required_permission,
  owner_only          = EXCLUDED.owner_only,
  is_active           = EXCLUDED.is_active,
  description         = EXCLUDED.description,
  updated_at          = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{
  "attendance_geofencing_mode":           "informative",
  "attendance_rounding_mode":             "real_minute",
  "attendance_overtime_policy":           "approval_required",
  "attendance_clock_offset_threshold_ms": 300000
}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();


-- =============================================================================
-- 7. RBAC — Ampliem data.get_role_permissions amb permisos d'assistència
-- =============================================================================

CREATE OR REPLACE FUNCTION data.get_role_permissions(
  p_role              text,
  p_custom_perms      jsonb DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_viewer_base  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view',
    'attendance.view_own', 'labor_calendar.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'attendance.punch_own', 'absences.request'
  ];
  v_manager_base text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage',
    'attendance.view_all', 'attendance.adjust', 'attendance.approve',
    'attendance.export', 'attendance.devices.manage',
    'labor_calendar.manage', 'absences.approve'
  ];

  v_accumulated  text[] := '{}';
BEGIN
  IF p_role = 'owner' THEN
    RETURN ARRAY['*'];
  END IF;

  IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'viewer' THEN
    v_accumulated := v_accumulated ||
      ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'viewer'));
  ELSE
    v_accumulated := v_accumulated || v_viewer_base;
  END IF;

  IF p_role IN ('member', 'manager') THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'member' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'member'));
    ELSE
      v_accumulated := v_accumulated || v_member_base;
    END IF;
  END IF;

  IF p_role = 'manager' THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'manager' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'manager'));
    ELSE
      v_accumulated := v_accumulated || v_manager_base;
    END IF;
  END IF;

  RETURN ARRAY(SELECT DISTINCT unnest(v_accumulated));
END;
$$;

GRANT EXECUTE ON FUNCTION data.get_role_permissions TO authenticated;
GRANT EXECUTE ON FUNCTION data.get_role_permissions TO supabase_auth_admin;


-- =============================================================================
-- 8. Row Level Security
-- =============================================================================

-- ---------------------------------------------------------------------------
-- data.attendance_devices
-- · SELECT: managers del tenant
-- · INSERT/UPDATE: managers (via vista o RPC directa per owner)
-- · DELETE: owner global
-- ---------------------------------------------------------------------------
ALTER TABLE data.attendance_devices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "attendance_devices: veure si manager del tenant"
  ON data.attendance_devices FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.devices.manage')
    )
  );

CREATE POLICY "attendance_devices: gestionar si manager"
  ON data.attendance_devices FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.devices.manage')
    )
  );

CREATE POLICY "attendance_devices: actualitzar si manager"
  ON data.attendance_devices FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.devices.manage')
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.devices.manage')
    )
  );

CREATE POLICY "attendance_devices: eliminar si owner"
  ON data.attendance_devices FOR DELETE
  TO authenticated
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
  );

-- ---------------------------------------------------------------------------
-- data.attendance_location_assignments
-- · SELECT: membres del tenant
-- · INSERT/UPDATE/DELETE: managers
-- ---------------------------------------------------------------------------
ALTER TABLE data.attendance_location_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "attend_loc_assign: veure si membre"
  ON data.attendance_location_assignments FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

CREATE POLICY "attend_loc_assign: gestionar si manager"
  ON data.attendance_location_assignments FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.devices.manage')
    )
  );

CREATE POLICY "attend_loc_assign: actualitzar si manager"
  ON data.attendance_location_assignments FOR UPDATE
  TO authenticated
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(tenant_id, 'attendance.devices.manage')
  )
  WITH CHECK (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(tenant_id, 'attendance.devices.manage')
  );

CREATE POLICY "attend_loc_assign: eliminar si manager"
  ON data.attendance_location_assignments FOR DELETE
  TO authenticated
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(tenant_id, 'attendance.devices.manage')
  );

-- ---------------------------------------------------------------------------
-- data.time_punches — IMMUTABLE
-- · SELECT: l'empleat veu els seus propis, managers veuen tots
-- · INSERT: BLOQUEJAT (exclusivament via api.record_time_punch — SECURITY DEFINER)
-- · UPDATE: BLOQUEJAT (immutabilitat legal)
-- · DELETE: BLOQUEJAT (immutabilitat legal — retenció 4 anys)
-- ---------------------------------------------------------------------------
ALTER TABLE data.time_punches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "time_punches: veure propis o ser manager"
  ON data.time_punches FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = time_punches.employee_id
          AND e.user_id = auth.uid()
      )
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.view_all')
    )
  );

-- ---------------------------------------------------------------------------
-- data.time_entries
-- · SELECT: l'empleat veu els seus propis, managers veuen tots
-- · INSERT/UPDATE: BLOQUEJAT — exclusivament via SECURITY DEFINER RPCs
-- · DELETE: BLOQUEJAT
-- ---------------------------------------------------------------------------
ALTER TABLE data.time_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "time_entries: veure propis o ser manager"
  ON data.time_entries FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = time_entries.employee_id
          AND e.user_id = auth.uid()
      )
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.view_all')
    )
  );

-- ---------------------------------------------------------------------------
-- data.time_daily_summaries
-- · SELECT: l'empleat veu els seus propis, managers veuen tots
-- · INSERT/UPDATE/DELETE: via SECURITY DEFINER RPCs
-- ---------------------------------------------------------------------------
ALTER TABLE data.time_daily_summaries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "time_daily_summaries: veure propis o ser manager"
  ON data.time_daily_summaries FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = time_daily_summaries.employee_id
          AND e.user_id = auth.uid()
      )
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.view_all')
    )
  );


-- =============================================================================
-- 9. Audit triggers
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Audit: time_punches (INSERT only — immutable, no UPDATE/DELETE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_time_punches()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      NEW.site_id,
      'TIME_PUNCH_RECORDED',
      'time_punch',
      NEW.id,
      jsonb_build_object(
        'employee_id',   NEW.employee_id,
        'punch_type',    NEW.punch_type,
        'occurred_at',   NEW.occurred_at,
        'source',        NEW.source,
        'anomaly_codes', NEW.anomaly_codes
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_time_punches
  AFTER INSERT ON data.time_punches
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_time_punches();

-- ---------------------------------------------------------------------------
-- Audit: time_daily_summaries (status transitions)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_time_daily_summaries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    IF NEW.status = 'approved' THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'TIME_DAY_APPROVED', 'time_daily_summary', NEW.id,
        jsonb_build_object(
          'employee_id',   NEW.employee_id,
          'work_date',     NEW.work_date,
          'worked_minutes', NEW.worked_minutes
        )
      );
    ELSIF NEW.status = 'exported' THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'TIME_DAY_EXPORTED', 'time_daily_summary', NEW.id,
        jsonb_build_object(
          'employee_id', NEW.employee_id,
          'work_date',   NEW.work_date
        )
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_time_daily_summaries
  AFTER UPDATE ON data.time_daily_summaries
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_time_daily_summaries();

-- ---------------------------------------------------------------------------
-- Immutabilitat legal: bloqueja UPDATE i DELETE sobre time_punches (RDL 8/2019)
-- Cap trigger de negoci, cap error de schema, no bypass silenciós.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_immutable_time_punches()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RAISE EXCEPTION 'time_punches_immutable: UPDATE i DELETE no permesos (RDL 8/2019)'
    USING ERRCODE = 'check_violation';
END;
$$;

DROP TRIGGER IF EXISTS trg_immutable_time_punches ON data.time_punches;
CREATE TRIGGER trg_immutable_time_punches
  BEFORE UPDATE OR DELETE ON data.time_punches
  FOR EACH ROW EXECUTE FUNCTION data.trg_immutable_time_punches();


-- =============================================================================
-- 10. Vistes API
-- =============================================================================

CREATE OR REPLACE VIEW api.attendance_devices
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, location_id, name, device_public_id,
    type, status, last_seen_at, metadata, created_at, updated_at
  FROM data.attendance_devices;
  -- device_secret_hash exclòs intencionadament

GRANT SELECT, INSERT, UPDATE, DELETE ON api.attendance_devices TO authenticated;
GRANT SELECT ON data.attendance_devices TO authenticated;

-- ---------------------------------------------------------------------------
-- api.attendance_locations — locations habilitades per a fitxatge
-- (filtre: locations amb geo_coordinates definides o amb estació assignada)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.attendance_locations
  WITH (security_invoker = true) AS
  SELECT
    l.id, l.tenant_id, l.site_id, l.parent_id, l.name,
    l.type, l.status, l.geo_coordinates, l.metadata,
    l.created_at, l.updated_at
  FROM data.locations l
  WHERE l.status = 'active';

GRANT SELECT ON api.attendance_locations TO authenticated;
GRANT SELECT ON data.locations TO authenticated;

-- ---------------------------------------------------------------------------
-- api.time_punches (read-only — mutacions via RPC)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.time_punches
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, employee_id, device_id, client_op_id,
    punch_type, occurred_at, received_at, geo, location_permission,
    anomaly_codes, source, notes, created_at
  FROM data.time_punches;

GRANT SELECT ON api.time_punches TO authenticated;
GRANT SELECT ON data.time_punches TO authenticated;

-- ---------------------------------------------------------------------------
-- api.time_entries (read-only — mutacions via RPC)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.time_entries
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, employee_id, work_date,
    starts_at, ends_at, punch_in_id, punch_out_id,
    gross_minutes, break_minutes, net_minutes,
    regular_minutes, overtime_minutes,
    status, adjustment_note,
    created_at, updated_at
  FROM data.time_entries;

GRANT SELECT ON api.time_entries TO authenticated;
GRANT SELECT ON data.time_entries TO authenticated;

-- ---------------------------------------------------------------------------
-- api.time_daily_summaries (read-only — mutacions via RPC)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.time_daily_summaries
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, employee_id, work_date,
    day_type, expected_minutes, worked_minutes, break_minutes,
    overtime_minutes, absence_minutes, punch_count,
    anomaly_codes, needs_review, status,
    approved_by, approved_at, exported_at, payroll_locked_at,
    recomputed_at, created_at, updated_at
  FROM data.time_daily_summaries;

GRANT SELECT ON api.time_daily_summaries TO authenticated;
GRANT SELECT ON data.time_daily_summaries TO authenticated;


-- =============================================================================
-- 10.5 PGMQ: Crear la cua ABANS dels RPCs perquè pgmq.send pugui executar-se
-- =============================================================================
SELECT pgmq.create('attendance_recompute_queue');


-- =============================================================================
-- 11. RPC: api.record_time_punch
--     Registra un fitxatge individual. Idempotent via client_op_id.
--     SECURITY DEFINER: tenant_id i site_id llegits de l'empleat (zero-trust).
--
--     Retorna: { punch_id, status: 'created'|'duplicate', anomaly_codes }
-- =============================================================================
CREATE OR REPLACE FUNCTION api.record_time_punch(
  p_employee_id   uuid,
  p_client_op_id  uuid,
  p_punch_type    text,
  p_occurred_at   timestamptz DEFAULT now(),
  p_geo           jsonb       DEFAULT NULL,
  p_location_perm text        DEFAULT 'notrequired',
  p_notes         text        DEFAULT NULL,
  p_source        text        DEFAULT 'mobile',
  p_device_id     uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_employee       record;
  v_punch_id       uuid;
  v_anomalies      text[];
  v_offset_ms      bigint;
  v_threshold_ms   bigint;
  v_settings       jsonb;
BEGIN
  -- 1. Carreguem l'empleat (zero-trust: tenant_id i site_id des de la BD)
  SELECT e.tenant_id, e.site_id, e.user_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND (data.active_tenant_id() IS NULL OR e.tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_employee.status != 'active' THEN
    RAISE EXCEPTION 'employee_not_active: %', p_employee_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_employee.site_id IS NULL THEN
    RAISE EXCEPTION 'employee_no_site: el fitxatge requereix site assignat per a l''empleat %', p_employee_id
      USING ERRCODE = 'check_violation';
  END IF;

  -- 2. Control d'accés: l'empleat fitxa ell mateix (punch_own), o un manager per ell (adjust)
  --    Comprova permisos al site de l'empleat (membres site-only no tenen global_permissions).
  IF auth.uid() IS NOT NULL THEN
    IF v_employee.user_id IS DISTINCT FROM auth.uid() THEN
      IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.adjust', v_employee.site_id) THEN
        RAISE EXCEPTION 'insufficient_privilege: cannot punch for another employee'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
    ELSE
      IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.punch_own', v_employee.site_id) THEN
        RAISE EXCEPTION 'insufficient_privilege: attendance.punch_own required'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
    END IF;
  END IF;
  -- Si auth.uid() IS NULL → service_role (estació via Edge Function) → permès

  -- 3. Idempotència
  SELECT id INTO v_punch_id
  FROM data.time_punches
  WHERE tenant_id    = v_employee.tenant_id
    AND client_op_id = p_client_op_id;

  IF v_punch_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'punch_id',     v_punch_id,
      'status',       'duplicate',
      'anomaly_codes', ARRAY[]::text[]
    );
  END IF;

  -- 4. Validació geo
  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);

  -- 5. Comprovació desfasament de rellotge (configurable per site)
  SELECT api.get_effective_settings(
    p_site_id   => v_employee.site_id,
    p_user_id   => auth.uid(),
    p_tenant_id => v_employee.tenant_id
  ) INTO v_settings;

  v_threshold_ms := COALESCE(
    (v_settings->>'attendance_clock_offset_threshold_ms')::bigint,
    300000
  );
  v_offset_ms := ABS(EXTRACT(EPOCH FROM (p_occurred_at - now())) * 1000)::bigint;

  IF v_offset_ms > v_threshold_ms
    AND NOT ('CLOCK_SKEW' = ANY(v_anomalies)) THEN
    v_anomalies := array_append(v_anomalies, 'CLOCK_SKEW');
  END IF;

  -- 6. Inserció (time_punches és immutable: no hi ha UPDATE ni DELETE)
  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, device_id, client_op_id,
    punch_type, occurred_at, received_at,
    geo, location_permission, anomaly_codes,
    source, notes
  )
  VALUES (
    v_employee.tenant_id, v_employee.site_id, p_employee_id, p_device_id, p_client_op_id,
    p_punch_type, p_occurred_at, now(),
    p_geo, p_location_perm, v_anomalies,
    p_source, p_notes
  )
  RETURNING id INTO v_punch_id;

  -- 7. Encuar recomputació asíncrona per al dia afectat
  PERFORM pgmq.send(
    'attendance_recompute_queue',
    jsonb_build_object(
      'task',            'recompute_attendance_day',
      'tenant_id',       v_employee.tenant_id,
      'employee_id',     p_employee_id,
      'work_date',       (p_occurred_at AT TIME ZONE 'Europe/Madrid')::date,
      'idempotency_key', 'recompute-' || p_employee_id::text || '-'
                         || ((p_occurred_at AT TIME ZONE 'Europe/Madrid')::date)::text
                         || '-' || v_punch_id::text
    )
  );

  RETURN jsonb_build_object(
    'punch_id',      v_punch_id,
    'status',        'created',
    'anomaly_codes', v_anomalies
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.record_time_punch(uuid, uuid, text, timestamptz, jsonb, text, text, text, uuid)
  TO authenticated;


-- =============================================================================
-- 12. RPC: api.sync_time_punches
--     Batch idempotent per a sincronització offline. Processa un array de
--     LocalAttendanceOp i retorna l'estat de cada operació.
--
--     Input:  p_batch jsonb — array de { id: uuid, kind: 'punch', payload: {...} }
--     Retorna: jsonb — array de { client_op_id, status, server_id, message }
-- =============================================================================
CREATE OR REPLACE FUNCTION api.sync_time_punches(
  p_batch jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_op      jsonb;
  v_result  jsonb;
  v_results jsonb[] := '{}';
BEGIN
  FOR v_op IN SELECT jsonb_array_elements(p_batch)
  LOOP
    BEGIN
      IF (v_op->>'kind') = 'punch' THEN
        v_result := api.record_time_punch(
          p_employee_id   => (v_op->'payload'->>'employee_id')::uuid,
          p_client_op_id  => (v_op->>'id')::uuid,
          p_punch_type    => v_op->'payload'->>'punch_type',
          p_occurred_at   => (v_op->'payload'->>'occurred_at')::timestamptz,
          p_geo           => v_op->'payload'->'geo',
          p_location_perm => COALESCE(v_op->'payload'->>'location_permission', 'notrequired'),
          p_notes         => v_op->'payload'->>'notes',
          p_source        => COALESCE(v_op->'payload'->>'source', 'mobile')
        );

        v_results := array_append(v_results, jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status',       v_result->>'status',
          'server_id',    v_result->>'punch_id',
          'message',      NULL
        ));

      ELSE
        v_results := array_append(v_results, jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status',       'rejected',
          'server_id',    NULL,
          'message',      'unknown_kind: ' || COALESCE(v_op->>'kind', 'null')
        ));
      END IF;

    EXCEPTION WHEN OTHERS THEN
      PERFORM data.log_audit_event(
        NULL, auth.uid(), NULL,
        'TIME_PUNCH_REJECTED', 'time_punch', NULL,
        jsonb_build_object(
          'client_op_id', v_op->>'id',
          'kind',         v_op->>'kind',
          'error',        SQLERRM
        )
      );

      v_results := array_append(v_results, jsonb_build_object(
        'client_op_id', v_op->>'id',
        'status',       'rejected',
        'server_id',    NULL,
        'message',      SQLERRM
      ));
    END;
  END LOOP;

  RETURN (SELECT jsonb_agg(elem) FROM unnest(v_results) AS elem);
END;
$$;

GRANT EXECUTE ON FUNCTION api.sync_time_punches(jsonb) TO authenticated;


-- =============================================================================
-- 13. RPC: api.my_attendance_today
--     Estat actual de fitxatge per a un empleat (propi o per manager).
--
--     Retorna: { employee_id, work_date, last_punch_type, last_punch_at,
--                punch_count_today, entry_status, worked_minutes, needs_review }
-- =============================================================================
CREATE OR REPLACE FUNCTION api.my_attendance_today(
  p_employee_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_employee_id  uuid;
  v_tenant_id    uuid;
  v_today        date;
  v_last_punch   record;
  v_entry        record;
  v_summary      record;
  v_punch_count  int;
BEGIN
  -- Resolem quin employee consultem
  IF p_employee_id IS NOT NULL THEN
    -- Manager consultant un altre empleat
    SELECT e.id, e.tenant_id INTO v_employee_id, v_tenant_id
    FROM data.employees e
    WHERE e.id = p_employee_id
      AND data.jwt_has_permission(e.tenant_id, 'attendance.view_all');

    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_not_found_or_access_denied: %', p_employee_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSE
    -- Empleat consultant el seu propi estat
    SELECT e.id, e.tenant_id INTO v_employee_id, v_tenant_id
    FROM data.employees e
    WHERE e.user_id = auth.uid()
      AND (data.active_tenant_id() IS NULL OR e.tenant_id = data.active_tenant_id())
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_not_found_for_current_user'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  v_today := (now() AT TIME ZONE 'Europe/Madrid')::date;

  -- Últim punch del dia
  SELECT punch_type, occurred_at INTO v_last_punch
  FROM data.time_punches
  WHERE employee_id = v_employee_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
  ORDER BY occurred_at DESC
  LIMIT 1;

  -- Compte de punches del dia
  SELECT COUNT(*) INTO v_punch_count
  FROM data.time_punches
  WHERE employee_id = v_employee_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today;

  -- Entrada del dia
  SELECT status, net_minutes INTO v_entry
  FROM data.time_entries
  WHERE employee_id = v_employee_id AND work_date = v_today;

  -- Resum del dia
  SELECT needs_review INTO v_summary
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee_id AND work_date = v_today;

  RETURN jsonb_build_object(
    'employee_id',       v_employee_id,
    'work_date',         v_today,
    'last_punch_type',   v_last_punch.punch_type,
    'last_punch_at',     v_last_punch.occurred_at,
    'punch_count_today', COALESCE(v_punch_count, 0),
    'entry_status',      COALESCE(v_entry.status, 'no_entry'),
    'worked_minutes',    v_entry.net_minutes,
    'needs_review',      COALESCE(v_summary.needs_review, false)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.my_attendance_today(uuid) TO authenticated;


-- =============================================================================
-- 14. RPC: api.approve_time_day
--     Manager aprova el resum diari d'un empleat (draft → approved).
--     Bloquejat si el dia ja ha estat exportat (payroll_locked_at IS NOT NULL).
-- =============================================================================
CREATE OR REPLACE FUNCTION api.approve_time_day(
  p_employee_id uuid,
  p_work_date   date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id  uuid;
  v_summary_id uuid;
  v_status     text;
  v_locked_at  timestamptz;
BEGIN
  SELECT e.tenant_id INTO v_tenant_id
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id;
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.approve') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT id, status, payroll_locked_at
    INTO v_summary_id, v_status, v_locked_at
  FROM data.time_daily_summaries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'summary_not_found: employee %, date %', p_employee_id, p_work_date;
  END IF;

  IF v_locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'day_payroll_locked: cannot approve after export on %', p_work_date
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_status = 'approved' THEN
    RETURN jsonb_build_object('summary_id', v_summary_id, 'status', 'already_approved');
  END IF;

  UPDATE data.time_daily_summaries
  SET status      = 'approved',
      approved_by = auth.uid(),
      approved_at = now(),
      updated_at  = now()
  WHERE id = v_summary_id;

  RETURN jsonb_build_object('summary_id', v_summary_id, 'status', 'approved');
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_time_day(uuid, date) TO authenticated;


-- =============================================================================
-- 15. RPC: api.adjust_time_entry
--     Manager ajusta l'entrada processada d'un dia (raw punches intocables).
--     Actualitza net_minutes, break_minutes i marca l'entrada com 'adjusted'.
--     Recalcula time_daily_summary de forma asíncrona via cua.
-- =============================================================================
CREATE OR REPLACE FUNCTION api.adjust_time_entry(
  p_employee_id        uuid,
  p_work_date          date,
  p_adjusted_net_min   int,
  p_break_minutes      int  DEFAULT NULL,
  p_reason             text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id  uuid;
  v_site_id    uuid;
  v_entry_id   uuid;
  v_locked_at  timestamptz;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_tenant_id, v_site_id
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id;
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.adjust') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.adjust required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT tds.payroll_locked_at INTO v_locked_at
  FROM data.time_daily_summaries tds
  WHERE tds.employee_id = p_employee_id AND tds.work_date = p_work_date;

  IF v_locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'day_payroll_locked: cannot adjust after export on %', p_work_date
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT id INTO v_entry_id
  FROM data.time_entries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'entry_not_found: employee %, date %', p_employee_id, p_work_date;
  END IF;

  UPDATE data.time_entries
  SET net_minutes     = p_adjusted_net_min,
      break_minutes   = COALESCE(p_break_minutes, break_minutes),
      status          = 'adjusted',
      adjustment_note = p_reason,
      updated_at      = now()
  WHERE id = v_entry_id;

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(), v_site_id,
    'TIME_ENTRY_ADJUSTED', 'time_entry', v_entry_id,
    jsonb_build_object(
      'employee_id',   p_employee_id,
      'work_date',     p_work_date,
      'net_minutes',   p_adjusted_net_min,
      'reason',        p_reason
    )
  );

  -- Reencuar recomputació del resum diari
  PERFORM pgmq.send(
    'attendance_recompute_queue',
    jsonb_build_object(
      'task',            'recompute_attendance_day',
      'tenant_id',       v_tenant_id,
      'employee_id',     p_employee_id,
      'work_date',       p_work_date,
      'idempotency_key', 'recompute-' || p_employee_id::text || '-' || p_work_date::text
                         || '-adj-' || EXTRACT(EPOCH FROM now())::bigint::text
    )
  );

  RETURN jsonb_build_object('entry_id', v_entry_id, 'status', 'adjusted');
END;
$$;

GRANT EXECUTE ON FUNCTION api.adjust_time_entry(uuid, date, int, int, text) TO authenticated;


-- =============================================================================
-- 16. RPC: api.export_payroll_days
--     Retorna tots els dies aprovats en el període i els marca com 'exported'.
--     Estableix payroll_locked_at per impedir modificacions posteriors.
--     Requereix permission: attendance.export
-- =============================================================================
CREATE OR REPLACE FUNCTION api.export_payroll_days(
  p_site_id  uuid,
  p_from     date,
  p_to       date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id  uuid;
  v_count      int;
  v_rows       jsonb;
BEGIN
  SELECT s.tenant_id INTO v_tenant_id
  FROM data.sites s WHERE s.id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id;
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.export') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.export required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Recollim les dades ABANS de marcar (per retornar-les)
  SELECT
    jsonb_agg(
      jsonb_build_object(
        'summary_id',       tds.id,
        'employee_id',      tds.employee_id,
        'work_date',        tds.work_date,
        'worked_minutes',   tds.worked_minutes,
        'overtime_minutes', tds.overtime_minutes,
        'day_type',         tds.day_type,
        'punch_count',      tds.punch_count
      ) ORDER BY tds.employee_id, tds.work_date
    ),
    COUNT(*)
  INTO v_rows, v_count
  FROM data.time_daily_summaries tds
  WHERE tds.site_id   = p_site_id
    AND tds.work_date BETWEEN p_from AND p_to
    AND tds.status    = 'approved';

  IF v_count = 0 OR v_rows IS NULL THEN
    RETURN jsonb_build_object('exported_count', 0, 'rows', '[]'::jsonb);
  END IF;

  -- Marcar com a exportats i bloquejar
  UPDATE data.time_daily_summaries
  SET status            = 'exported',
      exported_at       = now(),
      payroll_locked_at = now(),
      updated_at        = now()
  WHERE site_id   = p_site_id
    AND work_date BETWEEN p_from AND p_to
    AND status    = 'approved';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(), p_site_id,
    'TIME_DAY_EXPORTED', 'time_daily_summary', NULL,
    jsonb_build_object(
      'site_id',        p_site_id,
      'from',           p_from,
      'to',             p_to,
      'exported_count', v_count
    )
  );

  RETURN jsonb_build_object(
    'exported_count', v_count,
    'rows',           COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.export_payroll_days(uuid, date, date) TO authenticated;


-- =============================================================================
-- 16.5 RPC: api.recompute_attendance_worker
--      Recomputa time_entries i time_daily_summaries a partir dels time_punches
--      raw per a un empleat i dia. Crida exclusivament del worker
--      process-attendance-queue (service_role). Zero RLS — SECURITY DEFINER.
--
--      Respecta invariants:
--        · time_entries.status = 'adjusted'       → no sobreescriu ajusts
--        · time_daily_summaries.payroll_locked_at  → no toca dies exportats
--        · time_daily_summaries.status != 'draft'  → no actualitza summary
--
--      Retorna: jsonb amb { success|skipped, punch_count, net_minutes, ... }
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

  -- 2. Comptar i agregar punches del work_date (zona Europe/Madrid)
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
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date;

  -- IDs dels punches de referència (primer IN, darrer OUT)
  SELECT id INTO v_first_in_id
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND punch_type = 'in'
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
  ORDER BY occurred_at ASC LIMIT 1;

  SELECT id INTO v_last_out_id
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND punch_type = 'out'
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
  ORDER BY occurred_at DESC LIMIT 1;

  -- 3. Recollir anomalies heretades dels punches
  SELECT ARRAY(
    SELECT DISTINCT unnest_a
    FROM data.time_punches tp,
         LATERAL unnest(tp.anomaly_codes) AS unnest_a
    WHERE tp.employee_id = p_employee_id
      AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
      AND cardinality(tp.anomaly_codes) > 0
  ) INTO v_anomalies;

  v_anomalies := COALESCE(v_anomalies, '{}');

  -- 4. Detectar anomalies de parellament IN/OUT
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

  -- 5. Calcular minuts bruts, pauses i nets
  IF v_first_in_at IS NOT NULL AND v_last_out_at IS NOT NULL THEN
    v_gross_min := ROUND(EXTRACT(EPOCH FROM (v_last_out_at - v_first_in_at)) / 60)::int;

    -- Pauses aparellades per ordre cronològic
    SELECT COALESCE(ROUND(SUM(
      EXTRACT(EPOCH FROM (be.occurred_at - bs.occurred_at))
    ) / 60)::int, 0)
    INTO v_break_min
    FROM (
      SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
      FROM data.time_punches
      WHERE employee_id = p_employee_id
        AND punch_type = 'break_start'
        AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
    ) bs
    JOIN (
      SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
      FROM data.time_punches
      WHERE employee_id = p_employee_id
        AND punch_type = 'break_end'
        AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
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

  -- 6. Comprovar bloqueig payroll
  SELECT payroll_locked_at
  INTO v_locked_at
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

  -- 7. Si time_entry té status='adjusted' → actualitzar només el summary
  SELECT status INTO v_existing_status
  FROM data.time_entries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF v_existing_status = 'adjusted' THEN
    UPDATE data.time_daily_summaries
    SET punch_count   = v_punch_count,
        anomaly_codes = v_anomalies,
        needs_review  = (cardinality(v_anomalies) > 0),
        recomputed_at = now(),
        updated_at    = now()
    WHERE employee_id = p_employee_id AND work_date = p_work_date
      AND status = 'draft';

    RETURN jsonb_build_object(
      'skipped_entry', true,
      'reason',        'entry_adjusted',
      'employee_id',   p_employee_id,
      'work_date',     p_work_date
    );
  END IF;

  -- 8. Upsert time_entries (WHERE protegeix status='adjusted' a nivell de fila)
  INSERT INTO data.time_entries (
    tenant_id, site_id, employee_id, work_date,
    starts_at, ends_at, punch_in_id, punch_out_id,
    gross_minutes, break_minutes, net_minutes,
    regular_minutes, overtime_minutes, status, updated_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date,
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

  -- 9. Upsert time_daily_summaries (WHERE protegeix approved/exported)
  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date,
    day_type, expected_minutes, worked_minutes, break_minutes,
    overtime_minutes, absence_minutes, punch_count,
    anomaly_codes, needs_review, recomputed_at, updated_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date,
    'unknown', 0, COALESCE(v_net_min, 0), v_break_min,
    0, 0, v_punch_count,
    v_anomalies,
    (cardinality(v_anomalies) > 0 OR v_entry_status = 'missing'),
    now(), now()
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE SET
    worked_minutes   = EXCLUDED.worked_minutes,
    break_minutes    = EXCLUDED.break_minutes,
    punch_count      = EXCLUDED.punch_count,
    anomaly_codes    = EXCLUDED.anomaly_codes,
    needs_review     = EXCLUDED.needs_review,
    recomputed_at    = EXCLUDED.recomputed_at,
    updated_at       = EXCLUDED.updated_at
  WHERE data.time_daily_summaries.status = 'draft';

  RETURN jsonb_build_object(
    'success',       true,
    'employee_id',   p_employee_id,
    'work_date',     p_work_date,
    'punch_count',   v_punch_count,
    'net_minutes',   v_net_min,
    'entry_status',  v_entry_status,
    'anomaly_codes', v_anomalies
  );
END;
$$;

REVOKE ALL ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) TO service_role;


-- =============================================================================
-- 17. PGMQ: cua de recomputació d'assistència
--     (Creada anticipadament al pas 10.5, just abans dels RPCs, per garantir que
--      pgmq.send tingui la cua disponible. Referència aquí per ordre lògic.)
-- =============================================================================


-- =============================================================================
-- 18. Dispatcher: data.invoke_attendance_queue_worker + pg_cron
-- =============================================================================

CREATE OR REPLACE FUNCTION data.invoke_attendance_queue_worker(
  p_batch_size integer DEFAULT 20
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_supabase_url text;
  v_service_key  text;
  v_request_id   bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING 'invoke_attendance_queue_worker: pg_net not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets WHERE name = 'app_supabase_url' LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'app_service_role_key' LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING 'invoke_attendance_queue_worker: vault secrets not configured. Skipping.';
    RETURN -1;
  END IF;

  BEGIN
    SELECT extensions.http_post(
      url     := v_supabase_url || '/functions/v1/process-attendance-queue',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body    := jsonb_build_object('batch_size', COALESCE(p_batch_size, 20)),
      timeout_milliseconds := 30000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'invoke_attendance_queue_worker: http_post failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_attendance_queue_worker(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_attendance_queue_worker(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_attendance_queue_worker(integer) FROM anon;

COMMENT ON FUNCTION data.invoke_attendance_queue_worker IS
  'Dispatcher pg_cron → Edge Function process-attendance-queue via pg_net. '
  'Crida cada minut per reprocessar entries i summaries de fitxatge. '
  'Retorna request_id si èxit, -1 si secrets absents (dev), -2 si pg_net absent.';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('process-attendance-queue-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-attendance-queue-worker'
    );

    PERFORM cron.schedule(
      'process-attendance-queue-worker',
      '*/1 * * * *',
      'SELECT data.invoke_attendance_queue_worker(20)'
    );
  END IF;
END;
$$;


-- =============================================================================
-- 19. Grants addicionals per service_role (Edge Functions)
-- =============================================================================

GRANT SELECT, INSERT ON data.time_punches            TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.time_entries     TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.time_daily_summaries TO service_role;
GRANT SELECT ON data.attendance_devices               TO service_role;
GRANT SELECT ON data.attendance_location_assignments  TO service_role;
GRANT SELECT ON data.employees                        TO service_role;

GRANT SELECT ON api.time_punches          TO service_role;
GRANT SELECT ON api.time_entries          TO service_role;
GRANT SELECT ON api.time_daily_summaries  TO service_role;


-- =============================================================================
-- 20. NOTIFY PostgREST
-- =============================================================================

NOTIFY pgrst, 'reload schema';
