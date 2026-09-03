-- =============================================================================
-- Control Horari v2 — Core schema, pause configs, entitlements, GDPR geo
-- =============================================================================

-- 1. time_punches — nous camps
ALTER TABLE data.time_punches
  ADD COLUMN IF NOT EXISTS pause_type           text,
  ADD COLUMN IF NOT EXISTS pause_counts_as_work boolean,
  ADD COLUMN IF NOT EXISTS is_remote            boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS geo_lat              numeric(10,7),
  ADD COLUMN IF NOT EXISTS geo_lng              numeric(10,7),
  ADD COLUMN IF NOT EXISTS geo_accuracy_m       real,
  ADD COLUMN IF NOT EXISTS geo_altitude_m       real,
  ADD COLUMN IF NOT EXISTS geo_speed_ms         real,
  ADD COLUMN IF NOT EXISTS geo_consent          boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS geo_error            text,
  ADD COLUMN IF NOT EXISTS geo_anonymized_at    timestamptz,
  ADD COLUMN IF NOT EXISTS device_info          jsonb;

COMMENT ON COLUMN data.time_punches.pause_counts_as_work IS
  'Snapshot de si la pausa comptava com a treball en el moment del punch.';

-- 2. employees — consentiment geolocalització
ALTER TABLE data.employees
  ADD COLUMN IF NOT EXISTS location_consent_given    boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS location_consent_at       timestamptz,
  ADD COLUMN IF NOT EXISTS location_consent_version  text;

-- 3. tenant_pause_configs
CREATE TABLE IF NOT EXISTS data.tenant_pause_configs (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  key                   text        NOT NULL,
  label_i18n            jsonb       NOT NULL DEFAULT '{}',
  counts_as_work        boolean     NOT NULL DEFAULT false,
  max_duration_minutes  int,
  is_active             boolean     NOT NULL DEFAULT true,
  sort_order            int         NOT NULL DEFAULT 0,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, key)
);

CREATE INDEX IF NOT EXISTS idx_tenant_pause_configs_tenant
  ON data.tenant_pause_configs (tenant_id, is_active, sort_order);

CREATE TRIGGER trg_set_updated_at_tenant_pause_configs
  BEFORE UPDATE ON data.tenant_pause_configs
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.tenant_pause_configs ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_pause_configs_select ON data.tenant_pause_configs
  FOR SELECT USING (tenant_id = data.active_tenant_id());

CREATE POLICY tenant_pause_configs_manage ON data.tenant_pause_configs
  FOR ALL USING (
    tenant_id = data.active_tenant_id()
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

-- 4. vacation_entitlements
CREATE TABLE IF NOT EXISTS data.vacation_entitlements (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  scope           text        NOT NULL CHECK (scope IN ('tenant', 'department', 'employee')),
  department_id   uuid        REFERENCES data.departments(id) ON DELETE CASCADE,
  employee_id     uuid        REFERENCES data.employees(id) ON DELETE CASCADE,
  year            int         NOT NULL,
  leave_type      text        NOT NULL DEFAULT 'vacation',
  days_allocated  numeric(5,1) NOT NULL,
  days_used       numeric(5,1) NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_vacation_entitlement_scope CHECK (
    (scope = 'tenant' AND department_id IS NULL AND employee_id IS NULL)
    OR (scope = 'department' AND department_id IS NOT NULL AND employee_id IS NULL)
    OR (scope = 'employee' AND employee_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_vacation_entitlement_scope
  ON data.vacation_entitlements (
    tenant_id, year, leave_type, scope,
    COALESCE(department_id, '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(employee_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

CREATE TRIGGER trg_set_updated_at_vacation_entitlements
  BEFORE UPDATE ON data.vacation_entitlements
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.vacation_entitlements ENABLE ROW LEVEL SECURITY;

CREATE POLICY vacation_entitlements_select ON data.vacation_entitlements
  FOR SELECT USING (
    tenant_id = data.active_tenant_id()
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR (scope = 'employee' AND employee_id IN (
        SELECT id FROM data.employees WHERE user_id = auth.uid() AND tenant_id = data.vacation_entitlements.tenant_id
      ))
    )
  );

CREATE POLICY vacation_entitlements_manage ON data.vacation_entitlements
  FOR ALL USING (
    tenant_id = data.active_tenant_id()
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

-- 5. Settings registry — geo i retenció
INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('attendance_location_consent_required', 'tenant', 'settings.manage', false, true,
   'Requereix consentiment explícit de l''empleat per recollir geolocalització al fitxar'),
  ('attendance_geo_anonymize_months',      'tenant', 'settings.manage', false, true,
   'Mesos després dels quals s''anonimitza la geolocalització dels punches (GDPR)')
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope, description = EXCLUDED.description, updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{
  "attendance_location_consent_required": false,
  "attendance_geo_anonymize_months": 24
}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

-- 6. Pausa per defecte per tenants existents
INSERT INTO data.tenant_pause_configs (tenant_id, key, label_i18n, counts_as_work, max_duration_minutes, sort_order)
SELECT t.id, v.key, v.label_i18n, v.counts_as_work, v.max_duration_minutes, v.sort_order
FROM data.tenants t
CROSS JOIN (VALUES
  ('lunch',   '{"ca": "Menjar", "es": "Comida"}'::jsonb,   false, 90,  1),
  ('rest',    '{"ca": "Descans", "es": "Descanso"}'::jsonb, true,  240, 2),
  ('medical', '{"ca": "Metge", "es": "Médico"}'::jsonb,    false, 240, 3)
) AS v(key, label_i18n, counts_as_work, max_duration_minutes, sort_order)
ON CONFLICT (tenant_id, key) DO NOTHING;

-- 7. Vistes API actualitzades
CREATE OR REPLACE VIEW api.time_punches
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, employee_id, device_id, client_op_id,
    punch_type, occurred_at, received_at, geo, location_permission,
    anomaly_codes, source, notes, created_at,
    pause_type, pause_counts_as_work, is_remote,
    geo_lat, geo_lng, geo_accuracy_m, geo_altitude_m, geo_speed_ms,
    geo_consent, geo_error, device_info
  FROM data.time_punches;

CREATE OR REPLACE VIEW api.tenant_pause_configs
  WITH (security_invoker = true) AS
  SELECT * FROM data.tenant_pause_configs;

GRANT SELECT ON api.tenant_pause_configs TO authenticated;

CREATE OR REPLACE VIEW api.vacation_entitlements
  WITH (security_invoker = true) AS
  SELECT * FROM data.vacation_entitlements;

GRANT SELECT ON api.vacation_entitlements TO authenticated;

-- 8. RPC: list_pause_configs
CREATE OR REPLACE FUNCTION api.list_pause_configs()
RETURNS SETOF api.tenant_pause_configs
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
  SELECT *
  FROM data.tenant_pause_configs
  WHERE tenant_id = data.active_tenant_id()
    AND is_active = true
  ORDER BY sort_order, key;
$$;

GRANT EXECUTE ON FUNCTION api.list_pause_configs() TO authenticated;

-- 9. RPC: upsert_pause_config
CREATE OR REPLACE FUNCTION api.upsert_pause_config(
  p_key                  text,
  p_label_i18n           jsonb,
  p_counts_as_work       boolean,
  p_max_duration_minutes int DEFAULT NULL,
  p_is_active            boolean DEFAULT true,
  p_sort_order           int DEFAULT 0
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id        uuid;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO data.tenant_pause_configs (
    tenant_id, key, label_i18n, counts_as_work, max_duration_minutes, is_active, sort_order
  ) VALUES (
    v_tenant_id, p_key, p_label_i18n, p_counts_as_work, p_max_duration_minutes, p_is_active, p_sort_order
  )
  ON CONFLICT (tenant_id, key) DO UPDATE SET
    label_i18n           = EXCLUDED.label_i18n,
    counts_as_work       = EXCLUDED.counts_as_work,
    max_duration_minutes = EXCLUDED.max_duration_minutes,
    is_active            = EXCLUDED.is_active,
    sort_order           = EXCLUDED.sort_order,
    updated_at           = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_pause_config(text, jsonb, boolean, int, boolean, int)
  TO authenticated;

-- 10. RPC: get_vacation_entitlement (cascada employee → department → tenant)
CREATE OR REPLACE FUNCTION api.get_vacation_entitlement(
  p_employee_id uuid,
  p_year        int,
  p_leave_type  text DEFAULT 'vacation'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp   record;
  v_ent   record;
BEGIN
  SELECT e.tenant_id, e.department_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND (data.active_tenant_id() IS NULL OR e.tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  SELECT * INTO v_ent
  FROM data.vacation_entitlements ve
  WHERE ve.tenant_id = v_emp.tenant_id
    AND ve.year = p_year
    AND ve.leave_type = p_leave_type
    AND (
      (ve.scope = 'employee' AND ve.employee_id = p_employee_id)
      OR (ve.scope = 'department' AND ve.department_id = v_emp.department_id)
      OR (ve.scope = 'tenant')
    )
  ORDER BY CASE ve.scope
    WHEN 'employee' THEN 1
    WHEN 'department' THEN 2
    WHEN 'tenant' THEN 3
  END
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false, 'days_allocated', 0, 'days_used', 0, 'days_remaining', 0);
  END IF;

  RETURN jsonb_build_object(
    'found', true,
    'id', v_ent.id,
    'scope', v_ent.scope,
    'days_allocated', v_ent.days_allocated,
    'days_used', v_ent.days_used,
    'days_remaining', GREATEST(0, v_ent.days_allocated - v_ent.days_used)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_vacation_entitlement(uuid, int, text) TO authenticated;

-- 11. RPC: upsert_vacation_entitlement
CREATE OR REPLACE FUNCTION api.upsert_vacation_entitlement(
  p_scope           text,
  p_year            int,
  p_leave_type      text,
  p_days_allocated  numeric,
  p_department_id   uuid DEFAULT NULL,
  p_employee_id     uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id        uuid;
  v_dept      uuid := COALESCE(p_department_id, '00000000-0000-0000-0000-000000000000'::uuid);
  v_emp       uuid := COALESCE(p_employee_id, '00000000-0000-0000-0000-000000000000'::uuid);
BEGIN
  IF v_tenant_id IS NULL OR NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT id INTO v_id
  FROM data.vacation_entitlements
  WHERE tenant_id = v_tenant_id
    AND year = p_year
    AND leave_type = p_leave_type
    AND scope = p_scope
    AND COALESCE(department_id, '00000000-0000-0000-0000-000000000000'::uuid) = v_dept
    AND COALESCE(employee_id, '00000000-0000-0000-0000-000000000000'::uuid) = v_emp;

  IF v_id IS NOT NULL THEN
    UPDATE data.vacation_entitlements
    SET days_allocated = p_days_allocated, updated_at = now()
    WHERE id = v_id;
    RETURN v_id;
  END IF;

  INSERT INTO data.vacation_entitlements (
    tenant_id, scope, department_id, employee_id, year, leave_type, days_allocated
  ) VALUES (
    v_tenant_id, p_scope, p_department_id, p_employee_id, p_year, p_leave_type, p_days_allocated
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_vacation_entitlement(text, int, text, numeric, uuid, uuid)
  TO authenticated;

-- 12. RPC: give_location_consent
CREATE OR REPLACE FUNCTION api.give_location_consent(p_version text DEFAULT '1.0')
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  UPDATE data.employees
  SET location_consent_given = true,
      location_consent_at = now(),
      location_consent_version = p_version,
      updated_at = now()
  WHERE user_id = auth.uid()
    AND tenant_id = v_tenant_id
    AND status = 'active';

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION api.give_location_consent(text) TO authenticated;

-- 13. GDPR: anonimitzar geo
CREATE OR REPLACE FUNCTION api.anonymize_punch_geo(p_punch_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
BEGIN
  UPDATE data.time_punches
  SET geo_lat = NULL, geo_lng = NULL, geo_accuracy_m = NULL,
      geo_altitude_m = NULL, geo_speed_ms = NULL, geo = NULL,
      geo_anonymized_at = now()
  WHERE id = p_punch_id AND geo_anonymized_at IS NULL;
  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION api.anonymize_punch_geo(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.anonymize_punch_geo(uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.anonymize_old_punch_geo(p_months int DEFAULT 24)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE data.time_punches
  SET geo_lat = NULL, geo_lng = NULL, geo_accuracy_m = NULL,
      geo_altitude_m = NULL, geo_speed_ms = NULL, geo = NULL,
      geo_anonymized_at = now()
  WHERE geo_anonymized_at IS NULL
    AND (geo_lat IS NOT NULL OR geo IS NOT NULL)
    AND occurred_at < now() - (p_months || ' months')::interval;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION api.anonymize_old_punch_geo(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.anonymize_old_punch_geo(int) TO service_role;

NOTIFY pgrst, 'reload schema';
