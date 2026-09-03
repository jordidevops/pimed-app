-- =============================================================================
-- Estacions de fitxatge (ST-1 / ST-1b / ST-3 schema + RPCs)
-- Pla: docs/plans/checkin/plan-attendance-stations.md
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Schema: attendance_devices (pending, PIN, allowed_methods)
-- -----------------------------------------------------------------------------
ALTER TABLE data.attendance_devices
  ALTER COLUMN site_id DROP NOT NULL,
  ALTER COLUMN device_secret_hash DROP NOT NULL;

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_status_check;

ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_status_check
  CHECK (status IN ('pending', 'active', 'suspended', 'retired'));

ALTER TABLE data.attendance_devices
  ADD COLUMN IF NOT EXISTS local_pin_hash text,
  ADD COLUMN IF NOT EXISTS allowed_methods text[] NOT NULL DEFAULT ARRAY['manual']::text[];

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_active_requires_placement;

ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_active_requires_placement
  CHECK (
    status IS DISTINCT FROM 'active'
    OR (
      site_id IS NOT NULL
      AND location_id IS NOT NULL
      AND device_secret_hash IS NOT NULL
      AND local_pin_hash IS NOT NULL
    )
  );

COMMENT ON COLUMN data.attendance_devices.local_pin_hash IS
  'Hash del PIN kiosk local (sha256). Obligatori quan status=active.';
COMMENT ON COLUMN data.attendance_devices.allowed_methods IS
  'Mètodes de fitxatge permesos: manual, qr (futur barcode).';

-- -----------------------------------------------------------------------------
-- 2. Schema: time_punches location snapshots
-- -----------------------------------------------------------------------------
ALTER TABLE data.time_punches
  ADD COLUMN IF NOT EXISTS location_id uuid REFERENCES data.locations(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS location_name_snapshot text,
  ADD COLUMN IF NOT EXISTS device_name_snapshot text;

CREATE INDEX IF NOT EXISTS idx_time_punches_location_id
  ON data.time_punches (location_id)
  WHERE location_id IS NOT NULL;

ALTER TABLE data.time_punches
  DROP CONSTRAINT IF EXISTS time_punches_source_check;

ALTER TABLE data.time_punches
  ADD CONSTRAINT time_punches_source_check
  CHECK (source IN ('mobile', 'station', 'manual_entry', 'portal', 'manager_correction', 'qr'));

-- -----------------------------------------------------------------------------
-- 3. Pairing codes (one-shot, tenant-scoped)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.attendance_device_pairing_codes (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id         uuid        REFERENCES data.sites(id) ON DELETE SET NULL,
  location_id     uuid        REFERENCES data.locations(id) ON DELETE SET NULL,
  code_hash       bytea       NOT NULL,
  expires_at      timestamptz NOT NULL,
  used_at         timestamptz,
  used_device_id  uuid        REFERENCES data.attendance_devices(id) ON DELETE SET NULL,
  created_by      uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT attendance_device_pairing_codes_hash_nonempty
    CHECK (code_hash IS NOT NULL AND length(code_hash) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_attendance_device_pairing_code_hash
  ON data.attendance_device_pairing_codes (code_hash);

CREATE INDEX IF NOT EXISTS idx_attendance_device_pairing_tenant
  ON data.attendance_device_pairing_codes (tenant_id, created_at DESC);

COMMENT ON TABLE data.attendance_device_pairing_codes IS
  'Codis d''aparellament d''un sol ús per registrar estacions (ST-1b).';

ALTER TABLE data.attendance_device_pairing_codes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "pairing_codes: manager select"
  ON data.attendance_device_pairing_codes FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.devices.manage')
    )
  );

-- Mutacions només via RPC SECURITY DEFINER

-- -----------------------------------------------------------------------------
-- 4. Helpers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.hash_attendance_station_pin(p_pin text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, extensions
AS $$
  SELECT 'sha256:' || encode(digest('attendance-station-pin:' || p_pin, 'sha256'), 'hex');
$$;

CREATE OR REPLACE FUNCTION data.hash_attendance_device_secret(p_secret text)
RETURNS text
LANGUAGE sql
VOLATILE
SET search_path = extensions, public
AS $$
  SELECT extensions.crypt(p_secret, extensions.gen_salt('bf'));
$$;

CREATE OR REPLACE FUNCTION data.build_location_path_snapshot(p_location_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = data
AS $$
  WITH RECURSIVE chain AS (
    SELECT id, parent_id, name, 0 AS level
    FROM data.locations
    WHERE id = p_location_id
    UNION ALL
    SELECT l.id, l.parent_id, l.name, c.level + 1
    FROM data.locations l
    JOIN chain c ON l.id = c.parent_id
  )
  SELECT string_agg(name, ' › ' ORDER BY level DESC)
  FROM chain;
$$;

CREATE OR REPLACE FUNCTION data.normalize_attendance_pairing_code(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT upper(regexp_replace(btrim(COALESCE(p_code, '')), '[^A-Z0-9]', '', 'g'));
$$;

-- -----------------------------------------------------------------------------
-- 5. RPC: create pairing code (tenant-portal)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_attendance_station_pairing_code(
  p_site_id     uuid DEFAULT NULL,
  p_location_id uuid DEFAULT NULL,
  p_ttl_minutes int  DEFAULT 15
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant_id    uuid := data.active_tenant_id();
  v_site         record;
  v_location     record;
  v_code         text;
  v_code_hash    bytea;
  v_expires_at   timestamptz;
  v_id           uuid;
  v_ttl_minutes  int;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(v_tenant_id, 'attendance.devices.manage')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_site_id IS NOT NULL THEN
    SELECT id, tenant_id INTO v_site FROM data.sites WHERE id = p_site_id;
    IF NOT FOUND OR v_site.tenant_id IS DISTINCT FROM v_tenant_id THEN
      RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  IF p_location_id IS NOT NULL THEN
    SELECT id, tenant_id, site_id INTO v_location FROM data.locations WHERE id = p_location_id;
    IF NOT FOUND OR v_location.tenant_id IS DISTINCT FROM v_tenant_id THEN
      RAISE EXCEPTION 'location_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF p_site_id IS NOT NULL AND v_location.site_id IS DISTINCT FROM p_site_id THEN
      RAISE EXCEPTION 'location_site_mismatch' USING ERRCODE = 'check_violation';
    END IF;
    p_site_id := COALESCE(p_site_id, v_location.site_id);
  END IF;

  v_ttl_minutes := GREATEST(5, LEAST(COALESCE(p_ttl_minutes, 15), 60));
  v_expires_at := now() + make_interval(mins => v_ttl_minutes);

  LOOP
    v_code := upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 8));
    v_code_hash := digest(v_code, 'sha256');
    BEGIN
      INSERT INTO data.attendance_device_pairing_codes (
        tenant_id, site_id, location_id, code_hash, expires_at, created_by
      ) VALUES (
        v_tenant_id, p_site_id, p_location_id, v_code_hash, v_expires_at, auth.uid()
      )
      RETURNING id INTO v_id;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'pairing_code_id', v_id,
    'code', v_code,
    'expires_at', v_expires_at,
    'site_id', p_site_id,
    'location_id', p_location_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_attendance_station_pairing_code(uuid, uuid, int)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. RPC: register device (Edge / service_role)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.register_attendance_device(
  p_pairing_code      text,
  p_device_public_id  text,
  p_device_secret     text,
  p_local_pin         text,
  p_name              text DEFAULT NULL,
  p_metadata          jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_code_norm    text;
  v_code_hash    bytea;
  v_pairing      record;
  v_device_id    uuid;
  v_name         text;
BEGIN
  v_code_norm := data.normalize_attendance_pairing_code(p_pairing_code);
  IF length(v_code_norm) < 6 THEN
    RAISE EXCEPTION 'invalid_pairing_code' USING ERRCODE = 'check_violation';
  END IF;

  IF p_device_public_id IS NULL OR btrim(p_device_public_id) = '' THEN
    RAISE EXCEPTION 'device_public_id_required' USING ERRCODE = 'check_violation';
  END IF;

  IF p_device_secret IS NULL OR length(p_device_secret) < 16 THEN
    RAISE EXCEPTION 'device_secret_too_short' USING ERRCODE = 'check_violation';
  END IF;

  IF p_local_pin IS NULL OR p_local_pin !~ '^\d{4,6}$' THEN
    RAISE EXCEPTION 'invalid_local_pin' USING ERRCODE = 'check_violation';
  END IF;

  v_code_hash := digest(v_code_norm, 'sha256');

  SELECT *
    INTO v_pairing
  FROM data.attendance_device_pairing_codes c
  WHERE c.code_hash = v_code_hash
    AND c.used_at IS NULL
    AND c.expires_at > now()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pairing_code_invalid_or_expired' USING ERRCODE = 'check_violation';
  END IF;

  v_name := COALESCE(NULLIF(btrim(p_name), ''), 'Estació ' || left(p_device_public_id, 8));

  INSERT INTO data.attendance_devices (
    tenant_id,
    site_id,
    location_id,
    name,
    device_public_id,
    device_secret_hash,
    local_pin_hash,
    type,
    status,
    metadata
  ) VALUES (
    v_pairing.tenant_id,
    v_pairing.site_id,
    v_pairing.location_id,
    v_name,
    btrim(p_device_public_id),
    data.hash_attendance_device_secret(p_device_secret),
    data.hash_attendance_station_pin(p_local_pin),
    'station',
    'pending',
    COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_device_id;

  UPDATE data.attendance_device_pairing_codes
  SET used_at = now(), used_device_id = v_device_id
  WHERE id = v_pairing.id;

  RETURN jsonb_build_object(
    'device_id', v_device_id,
    'tenant_id', v_pairing.tenant_id,
    'site_id', v_pairing.site_id,
    'location_id', v_pairing.location_id,
    'status', 'pending',
    'device_public_id', btrim(p_device_public_id)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.register_attendance_device(text, text, text, text, text, jsonb)
  TO service_role;

-- -----------------------------------------------------------------------------
-- 7. RPC: verify station credentials (Edge)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.verify_attendance_station_credentials(
  p_device_public_id text,
  p_device_secret    text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_row record;
BEGIN
  SELECT
    d.id,
    d.tenant_id,
    d.site_id,
    d.location_id,
    d.name,
    d.status,
    d.type,
    d.allowed_methods,
    d.device_secret_hash,
    d.last_seen_at,
    data.build_location_path_snapshot(d.location_id) AS location_path
  INTO v_row
  FROM data.attendance_devices d
  WHERE d.device_public_id = btrim(p_device_public_id)
    AND d.device_secret_hash IS NOT NULL
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'station_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_row.device_secret_hash IS DISTINCT FROM extensions.crypt(p_device_secret, v_row.device_secret_hash) THEN
    RAISE EXCEPTION 'station_invalid_secret' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN jsonb_build_object(
    'device_id', v_row.id,
    'tenant_id', v_row.tenant_id,
    'site_id', v_row.site_id,
    'location_id', v_row.location_id,
    'location_path', v_row.location_path,
    'name', v_row.name,
    'status', v_row.status,
    'type', v_row.type,
    'allowed_methods', v_row.allowed_methods
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.verify_attendance_station_credentials(text, text)
  TO service_role;

-- -----------------------------------------------------------------------------
-- 8. RPC: update station (tenant-portal)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_attendance_station(
  p_device_id   uuid,
  p_name        text DEFAULT NULL,
  p_site_id     uuid DEFAULT NULL,
  p_location_id uuid DEFAULT NULL,
  p_status      text DEFAULT NULL,
  p_allowed_methods text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
  v_status text;
BEGIN
  SELECT * INTO v_row
  FROM data.attendance_devices
  WHERE id = p_device_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_row.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(v_row.tenant_id, 'attendance.devices.manage')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_site_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.sites s
      WHERE s.id = p_site_id AND s.tenant_id = v_row.tenant_id
    ) THEN
      RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  IF p_location_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.locations l
      WHERE l.id = p_location_id
        AND l.tenant_id = v_row.tenant_id
        AND (p_site_id IS NULL OR l.site_id = p_site_id OR l.site_id = COALESCE(p_site_id, v_row.site_id))
    ) THEN
      RAISE EXCEPTION 'location_not_found' USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  v_status := COALESCE(p_status, v_row.status);
  IF v_status = 'active' THEN
    IF COALESCE(p_site_id, v_row.site_id) IS NULL
       OR COALESCE(p_location_id, v_row.location_id) IS NULL
       OR v_row.device_secret_hash IS NULL
       OR v_row.local_pin_hash IS NULL THEN
      RAISE EXCEPTION 'active_requires_site_location_and_secrets' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  UPDATE data.attendance_devices d
  SET
    name = COALESCE(NULLIF(btrim(p_name), ''), d.name),
    site_id = COALESCE(p_site_id, d.site_id),
    location_id = COALESCE(p_location_id, d.location_id),
    status = v_status,
    allowed_methods = COALESCE(p_allowed_methods, d.allowed_methods),
    updated_at = now()
  WHERE d.id = p_device_id;

  RETURN (
    SELECT jsonb_build_object(
      'device_id', d.id,
      'name', d.name,
      'site_id', d.site_id,
      'location_id', d.location_id,
      'status', d.status,
      'allowed_methods', d.allowed_methods,
      'location_path', data.build_location_path_snapshot(d.location_id)
    )
    FROM data.attendance_devices d
    WHERE d.id = p_device_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_attendance_station(uuid, text, uuid, uuid, text, text[])
  TO authenticated;

-- -----------------------------------------------------------------------------
-- 9. RPC: revoke station secret
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.revoke_attendance_station_secret(p_device_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
BEGIN
  SELECT * INTO v_row FROM data.attendance_devices WHERE id = p_device_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_row.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(v_row.tenant_id, 'attendance.devices.manage')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.attendance_devices
  SET
    device_secret_hash = NULL,
    status = 'pending',
    updated_at = now()
  WHERE id = p_device_id;

  RETURN jsonb_build_object('device_id', p_device_id, 'status', 'pending', 'secret_revoked', true);
END;
$$;

GRANT EXECUTE ON FUNCTION api.revoke_attendance_station_secret(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 10. RPC: list employees for station (V1 = actius del site)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_attendance_station_employees(p_device_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_device record;
  v_rows   jsonb;
BEGIN
  SELECT d.id, d.tenant_id, d.site_id, d.location_id, d.status
    INTO v_device
  FROM data.attendance_devices d
  WHERE d.id = p_device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active' OR v_device.site_id IS NULL OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_not_ready' USING ERRCODE = 'check_violation';
  END IF;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_name), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'employee_id', e.id,
        'full_name', e.full_name,
        'last_punch_type', lp.punch_type,
        'last_punch_at', lp.occurred_at
      ) AS row_data,
      e.full_name AS sort_name
    FROM data.employees e
    LEFT JOIN LATERAL (
      SELECT tp.punch_type, tp.occurred_at
      FROM data.time_punches tp
      WHERE tp.employee_id = e.id
        AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = (now() AT TIME ZONE 'Europe/Madrid')::date
      ORDER BY tp.occurred_at DESC, tp.id DESC
      LIMIT 1
    ) lp ON true
    WHERE e.tenant_id = v_device.tenant_id
      AND e.site_id = v_device.site_id
      AND e.status = 'active'
  ) sub;

  RETURN jsonb_build_object('employees', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_attendance_station_employees(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 11. RPC: record station punch (no employee GPS)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.record_station_time_punch(
  p_device_id    uuid,
  p_employee_id  uuid,
  p_client_op_id uuid,
  p_punch_type   text,
  p_pause_type   text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, pgmq
AS $$
DECLARE
  v_device           record;
  v_location_path    text;
  v_location_name    text;
  v_device_name      text;
  v_result           jsonb;
BEGIN
  SELECT d.*, l.name AS location_name
    INTO v_device
  FROM data.attendance_devices d
  LEFT JOIN data.locations l ON l.id = d.location_id
  WHERE d.id = p_device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'station_not_active' USING ERRCODE = 'check_violation';
  END IF;

  IF v_device.site_id IS NULL OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_missing_location' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id
      AND e.tenant_id = v_device.tenant_id
      AND e.site_id = v_device.site_id
      AND e.status = 'active'
  ) THEN
    RAISE EXCEPTION 'employee_not_allowed_at_station' USING ERRCODE = 'check_violation';
  END IF;

  v_location_path := data.build_location_path_snapshot(v_device.location_id);
  v_location_name := COALESCE(v_location_path, v_device.location_name);
  v_device_name := v_device.name;

  UPDATE data.attendance_devices
  SET last_seen_at = now(), updated_at = now()
  WHERE id = p_device_id;

  v_result := api.record_time_punch(
    p_employee_id          => p_employee_id,
    p_client_op_id         => p_client_op_id,
    p_punch_type           => p_punch_type,
    p_occurred_at          => now(),
    p_geo                  => NULL,
    p_location_perm        => 'notrequired',
    p_notes                => NULL,
    p_source               => 'station',
    p_device_id            => p_device_id,
    p_pause_type           => p_pause_type,
    p_pause_counts_as_work => NULL,
    p_is_remote            => false,
    p_geo_consent          => false,
    p_geo_error            => NULL,
    p_device_info          => NULL,
    p_location_id          => v_device.location_id,
    p_location_name_snapshot => v_location_name,
    p_device_name_snapshot => v_device_name
  );

  RETURN v_result || jsonb_build_object(
    'location_id', v_device.location_id,
    'location_name', v_location_name,
    'device_name', v_device_name
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.record_station_time_punch(uuid, uuid, uuid, text, text)
  TO service_role;

-- -----------------------------------------------------------------------------
-- 12. Patch record_time_punch — station source + location snapshots
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.record_time_punch(
  p_employee_id          uuid,
  p_client_op_id         uuid,
  p_punch_type           text,
  p_occurred_at          timestamptz DEFAULT now(),
  p_geo                  jsonb       DEFAULT NULL,
  p_location_perm        text        DEFAULT 'notrequired',
  p_notes                text        DEFAULT NULL,
  p_source               text        DEFAULT 'mobile',
  p_device_id            uuid        DEFAULT NULL,
  p_pause_type           text        DEFAULT NULL,
  p_pause_counts_as_work boolean     DEFAULT NULL,
  p_is_remote            boolean     DEFAULT false,
  p_geo_consent          boolean     DEFAULT false,
  p_geo_error            text        DEFAULT NULL,
  p_device_info          jsonb       DEFAULT NULL,
  p_location_id          uuid        DEFAULT NULL,
  p_location_name_snapshot text      DEFAULT NULL,
  p_device_name_snapshot text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, pgmq
AS $$
DECLARE
  v_employee       record;
  v_punch_id       uuid;
  v_anomalies      text[];
  v_offset_ms      bigint;
  v_threshold_ms   bigint;
  v_settings       jsonb;
  v_pause_cfg      record;
  v_counts_work    boolean;
  v_geo_lat        numeric(10,7);
  v_geo_lng        numeric(10,7);
  v_geo_acc        real;
  v_geo_alt        real;
  v_geo_spd        real;
  v_work_date      date;
  v_work_profile   text;
  v_occurred_at    timestamptz := p_occurred_at;
  v_geo            jsonb := p_geo;
  v_location_perm  text := p_location_perm;
  v_geo_consent    boolean := COALESCE(p_geo_consent, false);
  v_geo_error      text := p_geo_error;
BEGIN
  SELECT e.tenant_id, e.site_id, e.user_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND (data.active_tenant_id() IS NULL OR e.tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_employee.status != 'active' THEN
    RAISE EXCEPTION 'employee_not_active: %', p_employee_id USING ERRCODE = 'check_violation';
  END IF;
  IF v_employee.site_id IS NULL THEN
    RAISE EXCEPTION 'employee_no_site' USING ERRCODE = 'check_violation';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_employee.user_id IS DISTINCT FROM auth.uid() THEN
      IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.adjust', v_employee.site_id) THEN
        RAISE EXCEPTION 'insufficient_privilege: cannot punch for another employee' USING ERRCODE = 'insufficient_privilege';
      END IF;
    ELSE
      IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.punch_own', v_employee.site_id) THEN
        RAISE EXCEPTION 'insufficient_privilege: attendance.punch_own required' USING ERRCODE = 'insufficient_privilege';
      END IF;
    END IF;
  ELSIF p_source NOT IN ('portal', 'station', 'qr') THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_source IN ('station', 'qr') THEN
    v_occurred_at := now();
    v_geo := NULL;
    v_location_perm := 'notrequired';
    v_geo_consent := false;
    v_geo_error := NULL;
    IF p_device_id IS NULL THEN
      RAISE EXCEPTION 'station_punch_requires_device' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  SELECT id INTO v_punch_id FROM data.time_punches
  WHERE tenant_id = v_employee.tenant_id AND client_op_id = p_client_op_id;

  IF v_punch_id IS NOT NULL THEN
    RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'duplicate', 'anomaly_codes', ARRAY[]::text[]);
  END IF;

  v_work_date := (v_occurred_at AT TIME ZONE 'Europe/Madrid')::date;

  PERFORM data.validate_time_punch_sequence(p_employee_id, v_work_date, p_punch_type);

  v_counts_work := p_pause_counts_as_work;
  IF p_punch_type IN ('break_start', 'break_end') AND p_pause_type IS NOT NULL THEN
    SELECT counts_as_work INTO v_pause_cfg
    FROM data.tenant_pause_configs
    WHERE tenant_id = v_employee.tenant_id AND key = p_pause_type AND is_active = true;
    IF FOUND THEN
      v_counts_work := v_pause_cfg.counts_as_work;
    END IF;
  END IF;

  IF auth.uid() IS NULL AND p_source IN ('portal', 'station', 'qr') THEN
    v_settings := data.merge_effective_settings_for_service(v_employee.tenant_id, v_employee.site_id);
  ELSE
    SELECT api.get_effective_settings(
      p_site_id => v_employee.site_id, p_user_id => auth.uid(), p_tenant_id => v_employee.tenant_id
    ) INTO v_settings;
  END IF;

  IF p_source NOT IN ('station', 'qr') AND NOT data.resolve_attendance_geo_enabled(p_employee_id) THEN
    v_geo := NULL;
    v_location_perm := 'notrequired';
    v_geo_consent := false;
    v_geo_error := NULL;
  END IF;

  IF p_source IN ('station', 'qr') THEN
    v_anomalies := ARRAY[]::text[];
  ELSE
    v_anomalies := data.validate_geo_payload(v_geo, v_location_perm);
  END IF;

  v_threshold_ms := COALESCE((v_settings->>'attendance_clock_offset_threshold_ms')::bigint, 300000);
  IF p_source NOT IN ('station', 'qr') THEN
    v_offset_ms := ABS(EXTRACT(EPOCH FROM (v_occurred_at - now())) * 1000)::bigint;
    IF v_offset_ms > v_threshold_ms AND NOT ('CLOCK_SKEW' = ANY(v_anomalies)) THEN
      v_anomalies := array_append(v_anomalies, 'CLOCK_SKEW');
    END IF;
  END IF;

  v_work_profile := COALESCE(
    (data.resolve_attendance_record_policy(p_employee_id, v_work_date)->>'work_profile'),
    'fixed_site'
  );
  IF NOT data.is_mobile_work_profile(v_work_profile)
     AND p_punch_type IN ('day_start', 'day_end', 'travel_start', 'travel_end') THEN
    v_anomalies := array_append(v_anomalies, 'WORK_PROFILE_MISMATCH');
  END IF;

  v_geo_lat := CASE WHEN p_source IN ('station', 'qr') THEN NULL
    ELSE COALESCE((v_geo->>'lat')::numeric, (v_geo->>'latitude')::numeric) END;
  v_geo_lng := CASE WHEN p_source IN ('station', 'qr') THEN NULL
    ELSE COALESCE((v_geo->>'lng')::numeric, (v_geo->>'longitude')::numeric) END;
  v_geo_acc := CASE WHEN p_source IN ('station', 'qr') THEN NULL
    ELSE COALESCE((v_geo->>'accuracy')::real, (v_geo->>'accuracy_m')::real) END;
  v_geo_alt := CASE WHEN p_source IN ('station', 'qr') THEN NULL ELSE (v_geo->>'altitude')::real END;
  v_geo_spd := CASE WHEN p_source IN ('station', 'qr') THEN NULL ELSE (v_geo->>'speed')::real END;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, device_id, location_id,
    client_op_id, punch_type, occurred_at, received_at,
    geo, location_permission, anomaly_codes, source, notes,
    pause_type, pause_counts_as_work, is_remote,
    geo_lat, geo_lng, geo_accuracy_m, geo_altitude_m, geo_speed_ms,
    geo_consent, geo_error, device_info,
    location_name_snapshot, device_name_snapshot
  ) VALUES (
    v_employee.tenant_id, v_employee.site_id, p_employee_id, p_device_id, p_location_id, p_client_op_id,
    p_punch_type, v_occurred_at, now(),
    v_geo, v_location_perm, v_anomalies, p_source, p_notes,
    p_pause_type, v_counts_work, COALESCE(p_is_remote, false),
    v_geo_lat, v_geo_lng, v_geo_acc, v_geo_alt, v_geo_spd,
    v_geo_consent, v_geo_error, p_device_info,
    p_location_name_snapshot, p_device_name_snapshot
  )
  RETURNING id INTO v_punch_id;

  PERFORM pgmq.send('attendance_recompute_queue', jsonb_build_object(
    'task', 'recompute_attendance_day',
    'tenant_id', v_employee.tenant_id,
    'employee_id', p_employee_id,
    'work_date', v_work_date,
    'idempotency_key', 'recompute-' || p_employee_id::text || '-' || v_work_date::text || '-' || v_punch_id::text
  ));

  BEGIN
    PERFORM pgmq.send('workflow_trigger_queue', jsonb_build_object(
      'trigger_event', CASE p_punch_type
        WHEN 'in' THEN 'PUNCH_IN'
        WHEN 'out' THEN 'PUNCH_OUT'
        WHEN 'break_start' THEN 'PAUSE_START'
        WHEN 'break_end' THEN 'PAUSE_END'
        WHEN 'day_start' THEN 'DAY_START'
        WHEN 'day_end' THEN 'DAY_END'
        ELSE 'PUNCH_OTHER'
      END,
      'tenant_id', v_employee.tenant_id,
      'trigger_entity_type', 'employee',
      'trigger_entity_id', p_employee_id,
      'payload', jsonb_build_object(
        'punch_id', v_punch_id, 'punch_type', p_punch_type,
        'pause_type', p_pause_type, 'occurred_at', v_occurred_at, 'is_remote', p_is_remote,
        'location_id', p_location_id, 'device_id', p_device_id
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'created', 'anomaly_codes', v_anomalies);
END;
$$;

GRANT EXECUTE ON FUNCTION api.record_time_punch(
  uuid, uuid, text, timestamptz, jsonb, text, text, text, uuid,
  text, boolean, boolean, boolean, text, jsonb,
  uuid, text, text
) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 13. Vista api.attendance_devices (sense secrets)
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS api.attendance_devices;

CREATE VIEW api.attendance_devices
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, location_id, name, device_public_id,
    type, status, last_seen_at, metadata,
    created_at, updated_at,
    allowed_methods,
    data.build_location_path_snapshot(location_id) AS location_path
  FROM data.attendance_devices;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.attendance_devices TO authenticated;
GRANT SELECT ON data.attendance_devices TO authenticated;
