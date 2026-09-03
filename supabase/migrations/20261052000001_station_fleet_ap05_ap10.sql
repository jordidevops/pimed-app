-- =============================================================================
-- AP-05 / AP-10 — Fleet health dashboard + outbox telemetry + ops lockdown/bulk
-- =============================================================================

-- ─── 1. Schema ───────────────────────────────────────────────────────────────

ALTER TABLE data.attendance_devices
  ADD COLUMN IF NOT EXISTS outbox_pending_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS outbox_quarantined_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS outbox_reported_at timestamptz,
  ADD COLUMN IF NOT EXISTS config_version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS ops_lockdown boolean NOT NULL DEFAULT false;

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_outbox_pending_count_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_outbox_pending_count_check
  CHECK (outbox_pending_count >= 0 AND outbox_pending_count <= 10000);

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_outbox_quarantined_count_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_outbox_quarantined_count_check
  CHECK (outbox_quarantined_count >= 0 AND outbox_quarantined_count <= 10000);

COMMENT ON COLUMN data.attendance_devices.outbox_pending_count IS
  'AP-05: darrer recompte d''outbox pendent reportat pel kiosk via heartbeat.';
COMMENT ON COLUMN data.attendance_devices.outbox_quarantined_count IS
  'AP-05: darrer recompte d''outbox en quarantena reportat pel kiosk.';
COMMENT ON COLUMN data.attendance_devices.config_version IS
  'AP-10: versió monòtona de configuració (s''incrementa en canvis ops).';
COMMENT ON COLUMN data.attendance_devices.ops_lockdown IS
  'AP-10: si true, el kiosk no accepta fitxatges (lockdown operatiu).';

-- ─── 2. Touch + heartbeat amb telemetry ──────────────────────────────────────

CREATE OR REPLACE FUNCTION data.touch_attendance_station_seen(
  p_device_id uuid,
  p_pending_count integer DEFAULT NULL,
  p_quarantined_count integer DEFAULT NULL
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_seen timestamptz;
BEGIN
  UPDATE data.attendance_devices
  SET last_seen_at = now(),
      updated_at = now(),
      outbox_pending_count = COALESCE(p_pending_count, outbox_pending_count),
      outbox_quarantined_count = COALESCE(p_quarantined_count, outbox_quarantined_count),
      outbox_reported_at = CASE
        WHEN p_pending_count IS NOT NULL OR p_quarantined_count IS NOT NULL THEN now()
        ELSE outbox_reported_at
      END
  WHERE id = p_device_id
  RETURNING last_seen_at INTO v_seen;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  RETURN v_seen;
END;
$$;

REVOKE ALL ON FUNCTION data.touch_attendance_station_seen(uuid, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.touch_attendance_station_seen(uuid, integer, integer) TO service_role;

-- Drop legacy 1-arg overload to avoid ambiguity with DEFAULT params
DROP FUNCTION IF EXISTS data.touch_attendance_station_seen(uuid);

DROP FUNCTION IF EXISTS api.record_attendance_station_heartbeat(text, text);

CREATE OR REPLACE FUNCTION api.record_attendance_station_heartbeat(
  p_device_public_id text,
  p_device_secret    text,
  p_pending_count    integer DEFAULT NULL,
  p_quarantined_count integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_id uuid;
  v_status text;
  v_hash text;
  v_seen timestamptz;
  v_pending int;
  v_quar int;
  v_cfg int;
  v_lock boolean;
BEGIN
  IF p_pending_count IS NOT NULL AND (p_pending_count < 0 OR p_pending_count > 10000) THEN
    RAISE EXCEPTION 'invalid_pending_count' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_quarantined_count IS NOT NULL AND (p_quarantined_count < 0 OR p_quarantined_count > 10000) THEN
    RAISE EXCEPTION 'invalid_quarantined_count' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT d.id, d.status, d.device_secret_hash
    INTO v_id, v_status, v_hash
  FROM data.attendance_devices d
  WHERE d.device_public_id = btrim(p_device_public_id)
    AND d.device_secret_hash IS NOT NULL
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'station_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_hash IS DISTINCT FROM extensions.crypt(p_device_secret, v_hash) THEN
    RAISE EXCEPTION 'station_invalid_secret' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_seen := data.touch_attendance_station_seen(v_id, p_pending_count, p_quarantined_count);

  SELECT d.outbox_pending_count, d.outbox_quarantined_count, d.config_version, d.ops_lockdown
    INTO v_pending, v_quar, v_cfg, v_lock
  FROM data.attendance_devices d
  WHERE d.id = v_id;

  RETURN jsonb_build_object(
    'device_id', v_id,
    'last_seen_at', v_seen,
    'connectivity_status', data.station_connectivity_status(v_seen, v_status),
    'seconds_since_seen', 0,
    'outbox_pending_count', COALESCE(v_pending, 0),
    'outbox_quarantined_count', COALESCE(v_quar, 0),
    'config_version', COALESCE(v_cfg, 1),
    'ops_lockdown', COALESCE(v_lock, false)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.record_attendance_station_heartbeat(text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_attendance_station_heartbeat(text, text, integer, integer)
  TO service_role;

-- ─── 3. Fleet health enriquit ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_attendance_station_fleet_health(
  p_tenant_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := COALESCE(p_tenant_id, data.active_tenant_id());
  v_conn jsonb;
  v_status jsonb;
  v_outbox jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'check_violation';
  END IF;

  IF auth.uid() IS NOT NULL AND NOT (
    COALESCE(data.jwt_has_permission(v_tenant_id, 'attendance.manage', NULL), false)
    OR COALESCE(data.jwt_has_permission(v_tenant_id, 'attendance.devices.manage', NULL), false)
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT jsonb_object_agg(status_key, cnt)
    INTO v_conn
  FROM (
    SELECT
      data.station_connectivity_status(d.last_seen_at, d.status) AS status_key,
      count(*)::int AS cnt
    FROM data.attendance_devices d
    WHERE d.tenant_id = v_tenant_id AND d.type = 'station'
    GROUP BY 1
  ) sub;

  SELECT jsonb_object_agg(status, cnt)
    INTO v_status
  FROM (
    SELECT d.status, count(*)::int AS cnt
    FROM data.attendance_devices d
    WHERE d.tenant_id = v_tenant_id AND d.type = 'station'
    GROUP BY 1
  ) sub;

  SELECT jsonb_build_object(
    'stations_with_pending', count(*) FILTER (WHERE d.outbox_pending_count > 0)::int,
    'stations_with_quarantine', count(*) FILTER (WHERE d.outbox_quarantined_count > 0)::int,
    'pending_total', COALESCE(sum(d.outbox_pending_count), 0)::int,
    'quarantined_total', COALESCE(sum(d.outbox_quarantined_count), 0)::int,
    'lockdown_count', count(*) FILTER (WHERE d.ops_lockdown)::int
  )
    INTO v_outbox
  FROM data.attendance_devices d
  WHERE d.tenant_id = v_tenant_id AND d.type = 'station';

  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'station_counts', COALESCE(v_conn, '{}'::jsonb),
    'status_counts', COALESCE(v_status, '{}'::jsonb),
    'outbox', COALESCE(v_outbox, '{}'::jsonb),
    'offline_stations', COALESCE(
      (
        SELECT jsonb_agg(jsonb_build_object(
          'device_id', d.id,
          'name', d.name,
          'site_id', d.site_id,
          'status', d.status,
          'location_path', data.build_location_path_snapshot(d.location_id),
          'last_seen_at', d.last_seen_at,
          'connectivity_status', data.station_connectivity_status(d.last_seen_at, d.status),
          'outbox_pending_count', d.outbox_pending_count,
          'outbox_quarantined_count', d.outbox_quarantined_count,
          'ops_lockdown', d.ops_lockdown,
          'config_version', d.config_version
        ) ORDER BY d.last_seen_at NULLS FIRST)
        FROM data.attendance_devices d
        WHERE d.tenant_id = v_tenant_id
          AND d.type = 'station'
          AND d.status = 'active'
          AND data.station_connectivity_status(d.last_seen_at, d.status) IN ('offline', 'never_seen', 'stale')
      ),
      '[]'::jsonb
    ),
    'attention_stations', COALESCE(
      (
        SELECT jsonb_agg(jsonb_build_object(
          'device_id', d.id,
          'name', d.name,
          'site_id', d.site_id,
          'status', d.status,
          'location_path', data.build_location_path_snapshot(d.location_id),
          'connectivity_status', data.station_connectivity_status(d.last_seen_at, d.status),
          'outbox_pending_count', d.outbox_pending_count,
          'outbox_quarantined_count', d.outbox_quarantined_count,
          'ops_lockdown', d.ops_lockdown,
          'reason', CASE
            WHEN d.ops_lockdown THEN 'lockdown'
            WHEN d.outbox_quarantined_count > 0 THEN 'quarantine'
            WHEN d.outbox_pending_count > 0 THEN 'pending_outbox'
            WHEN d.status = 'pending' THEN 'pending_device'
            WHEN d.status = 'suspended' THEN 'suspended'
            ELSE 'other'
          END
        ) ORDER BY d.outbox_quarantined_count DESC, d.outbox_pending_count DESC, d.name)
        FROM data.attendance_devices d
        WHERE d.tenant_id = v_tenant_id
          AND d.type = 'station'
          AND (
            d.ops_lockdown
            OR d.outbox_pending_count > 0
            OR d.outbox_quarantined_count > 0
            OR d.status IN ('pending', 'suspended')
          )
      ),
      '[]'::jsonb
    ),
    'checked_at', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_attendance_station_fleet_health(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_attendance_station_fleet_health(uuid)
  TO authenticated, service_role;

-- ─── 4. Bulk ops (AP-10) ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.assert_attendance_station_manage_privilege(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT (
    COALESCE(data.jwt_has_permission(p_tenant_id, 'attendance.manage', NULL), false)
    OR COALESCE(data.jwt_has_permission(p_tenant_id, 'attendance.devices.manage', NULL), false)
    OR (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_attendance_station_manage_privilege(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_attendance_station_manage_privilege(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.bulk_update_attendance_station_ops(
  p_device_ids uuid[],
  p_status text DEFAULT NULL,
  p_ops_lockdown boolean DEFAULT NULL,
  p_bump_config_version boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_updated int := 0;
  v_id uuid;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'check_violation';
  END IF;
  PERFORM data.assert_attendance_station_manage_privilege(v_tenant);

  IF p_device_ids IS NULL OR cardinality(p_device_ids) = 0 THEN
    RAISE EXCEPTION 'device_ids_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF cardinality(p_device_ids) > 50 THEN
    RAISE EXCEPTION 'too_many_devices' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('active', 'suspended', 'pending', 'retired') THEN
    RAISE EXCEPTION 'invalid_status' USING ERRCODE = 'check_violation';
  END IF;
  IF p_status IS NULL AND p_ops_lockdown IS NULL THEN
    RAISE EXCEPTION 'no_ops_change' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOREACH v_id IN ARRAY p_device_ids
  LOOP
    UPDATE data.attendance_devices d
    SET status = COALESCE(p_status, d.status),
        ops_lockdown = COALESCE(p_ops_lockdown, d.ops_lockdown),
        config_version = CASE
          WHEN COALESCE(p_bump_config_version, true) THEN d.config_version + 1
          ELSE d.config_version
        END,
        updated_at = now()
    WHERE d.id = v_id
      AND d.tenant_id = v_tenant
      AND d.type = 'station';
    IF FOUND THEN
      v_updated := v_updated + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'updated', v_updated);
END;
$$;

REVOKE ALL ON FUNCTION api.bulk_update_attendance_station_ops(uuid[], text, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.bulk_update_attendance_station_ops(uuid[], text, boolean, boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION api.bulk_revoke_attendance_station_secrets(p_device_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_revoked int := 0;
  v_id uuid;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'check_violation';
  END IF;
  PERFORM data.assert_attendance_station_manage_privilege(v_tenant);

  IF p_device_ids IS NULL OR cardinality(p_device_ids) = 0 THEN
    RAISE EXCEPTION 'device_ids_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF cardinality(p_device_ids) > 50 THEN
    RAISE EXCEPTION 'too_many_devices' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOREACH v_id IN ARRAY p_device_ids
  LOOP
    BEGIN
      PERFORM api.revoke_attendance_station_secret(v_id);
      v_revoked := v_revoked + 1;
    EXCEPTION WHEN OTHERS THEN
      NULL; -- skip missing / unauthorized rows
    END;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'revoked', v_revoked);
END;
$$;

REVOKE ALL ON FUNCTION api.bulk_revoke_attendance_station_secrets(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.bulk_revoke_attendance_station_secrets(uuid[]) TO authenticated;

-- ─── 5. Vista api.attendance_devices (completa + AP-05/10) ───────────────────

DROP VIEW IF EXISTS api.attendance_devices;

CREATE VIEW api.attendance_devices
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, location_id, name, device_public_id,
    type, status, last_seen_at, metadata,
    created_at, updated_at,
    allowed_methods,
    geo_antifraud_enabled,
    geo_antifraud_radius_m,
    display_title,
    display_logo_url,
    data.station_effective_display_title(name, display_title) AS effective_display_title,
    data.build_location_path_snapshot(location_id) AS location_path,
    data.station_connectivity_status(last_seen_at, status) AS connectivity_status,
    entry_mode,
    employee_list_layout,
    document_match,
    document_suffix_length,
    identity_confirm,
    qr_identity_confirm,
    session_idle_seconds,
    session_return_countdown_seconds,
    session_allow_history,
    session_history_max_days,
    allow_unassigned_punch,
    warn_unassigned_punch,
    warn_wrong_scheduled_location,
    block_wrong_scheduled_location,
    ux_preset,
    waiting_idle_seconds,
    mask_names_on_waiting,
    outbox_pending_count,
    outbox_quarantined_count,
    outbox_reported_at,
    config_version,
    ops_lockdown
  FROM data.attendance_devices;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.attendance_devices TO authenticated;
GRANT SELECT ON data.attendance_devices TO authenticated;

-- ─── 6. verify credentials: exposa lockdown + outbox + config_version ────────

CREATE OR REPLACE FUNCTION api.verify_attendance_station_credentials(
  p_device_public_id text,
  p_device_secret text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_row record;
  v_location_geo jsonb;
  v_seen timestamptz;
BEGIN
  SELECT
    d.id,
    d.tenant_id,
    d.site_id,
    d.location_id,
    d.name,
    d.display_title,
    d.display_logo_url,
    d.status,
    d.type,
    d.allowed_methods,
    d.geo_antifraud_enabled,
    d.geo_antifraud_radius_m,
    d.device_secret_hash,
    d.last_seen_at,
    d.entry_mode,
    d.employee_list_layout,
    d.document_match,
    d.document_suffix_length,
    d.identity_confirm,
    d.qr_identity_confirm,
    d.session_idle_seconds,
    d.session_return_countdown_seconds,
    d.session_allow_history,
    d.session_history_max_days,
    d.allow_unassigned_punch,
    d.warn_unassigned_punch,
    d.warn_wrong_scheduled_location,
    d.block_wrong_scheduled_location,
    d.ux_preset,
    d.waiting_idle_seconds,
    d.mask_names_on_waiting,
    d.outbox_pending_count,
    d.outbox_quarantined_count,
    d.config_version,
    d.ops_lockdown,
    data.build_location_path_snapshot(d.location_id) AS location_path,
    l.geo_coordinates AS location_geo_coordinates
  INTO v_row
  FROM data.attendance_devices d
  LEFT JOIN data.locations l ON l.id = d.location_id
  WHERE d.device_public_id = btrim(p_device_public_id)
    AND d.device_secret_hash IS NOT NULL
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'station_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_row.device_secret_hash IS DISTINCT FROM extensions.crypt(p_device_secret, v_row.device_secret_hash) THEN
    RAISE EXCEPTION 'station_invalid_secret' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_seen := data.touch_attendance_station_seen(v_row.id);
  v_location_geo := v_row.location_geo_coordinates;

  RETURN jsonb_build_object(
    'device_id', v_row.id,
    'tenant_id', v_row.tenant_id,
    'site_id', v_row.site_id,
    'location_id', v_row.location_id,
    'location_path', v_row.location_path,
    'name', v_row.name,
    'display_title', v_row.display_title,
    'display_logo_url', v_row.display_logo_url,
    'effective_display_title', data.station_effective_display_title(v_row.name, v_row.display_title),
    'status', v_row.status,
    'type', v_row.type,
    'allowed_methods', v_row.allowed_methods,
    'geo_antifraud_enabled', COALESCE(v_row.geo_antifraud_enabled, false),
    'geo_antifraud_radius_m', COALESCE(v_row.geo_antifraud_radius_m, 150),
    'location_has_geo', data.extract_geo_point(v_location_geo) IS NOT NULL,
    'site_timezone', data.get_site_timezone(v_row.site_id, v_row.tenant_id),
    'last_seen_at', v_seen,
    'connectivity_status', data.station_connectivity_status(v_seen, v_row.status),
    'seconds_since_seen', GREATEST(0, floor(extract(epoch FROM (now() - v_seen))))::int,
    'entry_mode', v_row.entry_mode,
    'employee_list_layout', v_row.employee_list_layout,
    'document_match', v_row.document_match,
    'document_suffix_length', v_row.document_suffix_length,
    'identity_confirm', v_row.identity_confirm,
    'qr_identity_confirm', v_row.qr_identity_confirm,
    'session_idle_seconds', v_row.session_idle_seconds,
    'session_return_countdown_seconds', v_row.session_return_countdown_seconds,
    'session_allow_history', v_row.session_allow_history,
    'session_history_max_days', v_row.session_history_max_days,
    'allow_unassigned_punch', v_row.allow_unassigned_punch,
    'warn_unassigned_punch', v_row.warn_unassigned_punch,
    'warn_wrong_scheduled_location', v_row.warn_wrong_scheduled_location,
    'block_wrong_scheduled_location', v_row.block_wrong_scheduled_location,
    'ux_preset', v_row.ux_preset,
    'waiting_idle_seconds', v_row.waiting_idle_seconds,
    'mask_names_on_waiting', v_row.mask_names_on_waiting,
    'outbox_pending_count', COALESCE(v_row.outbox_pending_count, 0),
    'outbox_quarantined_count', COALESCE(v_row.outbox_quarantined_count, 0),
    'config_version', COALESCE(v_row.config_version, 1),
    'ops_lockdown', COALESCE(v_row.ops_lockdown, false)
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
