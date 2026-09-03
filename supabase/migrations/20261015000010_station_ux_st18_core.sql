-- ST-18 core: session UX config on attendance_devices + admin/bootstrap surface.
-- Default entry_mode = employee_list (preserve MVP until ST-18a document resolve).

-- -----------------------------------------------------------------------------
-- 1. Columns
-- -----------------------------------------------------------------------------

ALTER TABLE data.attendance_devices
  ADD COLUMN IF NOT EXISTS entry_mode text NOT NULL DEFAULT 'employee_list',
  ADD COLUMN IF NOT EXISTS employee_list_layout text NOT NULL DEFAULT 'compact',
  ADD COLUMN IF NOT EXISTS document_match text NOT NULL DEFAULT 'suffix',
  ADD COLUMN IF NOT EXISTS document_suffix_length integer NOT NULL DEFAULT 4,
  ADD COLUMN IF NOT EXISTS identity_confirm text NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS qr_identity_confirm text NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS session_idle_seconds integer NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS session_return_countdown_seconds integer NOT NULL DEFAULT 15,
  ADD COLUMN IF NOT EXISTS session_allow_history boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS session_history_max_days integer NOT NULL DEFAULT 90,
  ADD COLUMN IF NOT EXISTS allow_unassigned_punch boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS warn_unassigned_punch boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS warn_wrong_scheduled_location boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS block_wrong_scheduled_location boolean NOT NULL DEFAULT false;

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_entry_mode_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_entry_mode_check
  CHECK (entry_mode IN ('employee_list', 'document_entry'));

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_employee_list_layout_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_employee_list_layout_check
  CHECK (employee_list_layout IN ('compact', 'two_column', 'search_first'));

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_document_match_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_document_match_check
  CHECK (document_match IN ('exact', 'suffix'));

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_document_suffix_length_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_document_suffix_length_check
  CHECK (document_suffix_length BETWEEN 3 AND 8);

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_identity_confirm_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_identity_confirm_check
  CHECK (identity_confirm IN ('none', 'tap_name'));

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_qr_identity_confirm_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_qr_identity_confirm_check
  CHECK (qr_identity_confirm IN ('none', 'tap_name'));

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_session_idle_seconds_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_session_idle_seconds_check
  CHECK (session_idle_seconds BETWEEN 15 AND 600);

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_session_return_countdown_seconds_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_session_return_countdown_seconds_check
  CHECK (session_return_countdown_seconds BETWEEN 5 AND 120);

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_session_history_max_days_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_session_history_max_days_check
  CHECK (session_history_max_days BETWEEN 1 AND 90);

COMMENT ON COLUMN data.attendance_devices.entry_mode IS
  'ST-18: employee_list | document_entry. Default employee_list until ST-18a.';
COMMENT ON COLUMN data.attendance_devices.session_idle_seconds IS
  'ST-18: idle timeout before returning to waiting.';
COMMENT ON COLUMN data.attendance_devices.session_return_countdown_seconds IS
  'ST-18: countdown after successful punch before waiting.';

-- -----------------------------------------------------------------------------
-- 2. verify — expose ST-18 config for bootstrap
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.verify_attendance_station_credentials(
  p_device_public_id text,
  p_device_secret    text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
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
    'block_wrong_scheduled_location', v_row.block_wrong_scheduled_location
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. update_attendance_station — ST-18 params (optional, NULL = keep)
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer, text, text
);

CREATE OR REPLACE FUNCTION api.update_attendance_station(
  p_device_id                         uuid,
  p_name                              text DEFAULT NULL,
  p_site_id                           uuid DEFAULT NULL,
  p_location_id                       uuid DEFAULT NULL,
  p_status                            text DEFAULT NULL,
  p_allowed_methods                   text[] DEFAULT NULL,
  p_geo_antifraud_enabled             boolean DEFAULT NULL,
  p_geo_antifraud_radius_m            integer DEFAULT NULL,
  p_display_title                     text DEFAULT NULL,
  p_display_logo_url                  text DEFAULT NULL,
  p_entry_mode                        text DEFAULT NULL,
  p_employee_list_layout              text DEFAULT NULL,
  p_document_match                    text DEFAULT NULL,
  p_document_suffix_length            integer DEFAULT NULL,
  p_identity_confirm                  text DEFAULT NULL,
  p_qr_identity_confirm               text DEFAULT NULL,
  p_session_idle_seconds              integer DEFAULT NULL,
  p_session_return_countdown_seconds  integer DEFAULT NULL,
  p_session_allow_history             boolean DEFAULT NULL,
  p_session_history_max_days          integer DEFAULT NULL,
  p_allow_unassigned_punch            boolean DEFAULT NULL,
  p_warn_unassigned_punch             boolean DEFAULT NULL,
  p_warn_wrong_scheduled_location     boolean DEFAULT NULL,
  p_block_wrong_scheduled_location    boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
  v_status text;
  v_target_location_id uuid;
  v_location_geo jsonb;
  v_geo_enabled boolean;
  v_geo_radius integer;
  v_new_name text;
  v_new_site_id uuid;
  v_new_location_id uuid;
  v_new_allowed_methods text[];
  v_new_display_title text;
  v_new_display_logo_url text;
  v_new_entry_mode text;
  v_new_layout text;
  v_new_doc_match text;
  v_new_doc_suffix int;
  v_new_identity_confirm text;
  v_new_qr_confirm text;
  v_new_idle int;
  v_new_countdown int;
  v_new_allow_history boolean;
  v_new_history_days int;
  v_new_allow_unassigned boolean;
  v_new_warn_unassigned boolean;
  v_new_warn_wrong boolean;
  v_new_block_wrong boolean;
  v_changes jsonb := '[]'::jsonb;
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

  IF p_geo_antifraud_radius_m IS NOT NULL THEN
    IF p_geo_antifraud_radius_m < 25 OR p_geo_antifraud_radius_m > 2000 THEN
      RAISE EXCEPTION 'geo_antifraud_radius_out_of_range' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF p_display_title IS NOT NULL AND char_length(btrim(p_display_title)) > 120 THEN
    RAISE EXCEPTION 'display_title_too_long' USING ERRCODE = 'check_violation';
  END IF;

  IF p_display_logo_url IS NOT NULL AND char_length(btrim(p_display_logo_url)) > 2048 THEN
    RAISE EXCEPTION 'display_logo_url_too_long' USING ERRCODE = 'check_violation';
  END IF;

  IF p_entry_mode IS NOT NULL AND p_entry_mode NOT IN ('employee_list', 'document_entry') THEN
    RAISE EXCEPTION 'invalid_entry_mode' USING ERRCODE = 'check_violation';
  END IF;
  IF p_employee_list_layout IS NOT NULL AND p_employee_list_layout NOT IN ('compact', 'two_column', 'search_first') THEN
    RAISE EXCEPTION 'invalid_employee_list_layout' USING ERRCODE = 'check_violation';
  END IF;
  IF p_document_match IS NOT NULL AND p_document_match NOT IN ('exact', 'suffix') THEN
    RAISE EXCEPTION 'invalid_document_match' USING ERRCODE = 'check_violation';
  END IF;
  IF p_document_suffix_length IS NOT NULL AND (p_document_suffix_length < 3 OR p_document_suffix_length > 8) THEN
    RAISE EXCEPTION 'document_suffix_length_out_of_range' USING ERRCODE = 'check_violation';
  END IF;
  IF p_identity_confirm IS NOT NULL AND p_identity_confirm NOT IN ('none', 'tap_name') THEN
    RAISE EXCEPTION 'invalid_identity_confirm' USING ERRCODE = 'check_violation';
  END IF;
  IF p_qr_identity_confirm IS NOT NULL AND p_qr_identity_confirm NOT IN ('none', 'tap_name') THEN
    RAISE EXCEPTION 'invalid_qr_identity_confirm' USING ERRCODE = 'check_violation';
  END IF;
  IF p_session_idle_seconds IS NOT NULL AND (p_session_idle_seconds < 15 OR p_session_idle_seconds > 600) THEN
    RAISE EXCEPTION 'session_idle_seconds_out_of_range' USING ERRCODE = 'check_violation';
  END IF;
  IF p_session_return_countdown_seconds IS NOT NULL
     AND (p_session_return_countdown_seconds < 5 OR p_session_return_countdown_seconds > 120) THEN
    RAISE EXCEPTION 'session_return_countdown_seconds_out_of_range' USING ERRCODE = 'check_violation';
  END IF;
  IF p_session_history_max_days IS NOT NULL AND (p_session_history_max_days < 1 OR p_session_history_max_days > 90) THEN
    RAISE EXCEPTION 'session_history_max_days_out_of_range' USING ERRCODE = 'check_violation';
  END IF;

  v_geo_enabled := COALESCE(p_geo_antifraud_enabled, v_row.geo_antifraud_enabled, false);
  v_geo_radius := COALESCE(p_geo_antifraud_radius_m, v_row.geo_antifraud_radius_m, 150);
  v_target_location_id := COALESCE(p_location_id, v_row.location_id);

  IF v_geo_enabled THEN
    SELECT l.geo_coordinates
      INTO v_location_geo
    FROM data.locations l
    WHERE l.id = v_target_location_id;

    IF data.extract_geo_point(v_location_geo) IS NULL THEN
      RAISE EXCEPTION 'geo_antifraud_requires_location_geo' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  v_status := COALESCE(p_status, v_row.status);
  IF v_status = 'active' THEN
    IF COALESCE(p_site_id, v_row.site_id) IS NULL
       OR v_target_location_id IS NULL
       OR v_row.device_secret_hash IS NULL
       OR v_row.local_pin_hash IS NULL THEN
      RAISE EXCEPTION 'active_requires_site_location_and_secrets' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  v_new_name := COALESCE(NULLIF(btrim(p_name), ''), v_row.name);
  v_new_site_id := COALESCE(p_site_id, v_row.site_id);
  v_new_location_id := COALESCE(p_location_id, v_row.location_id);
  v_new_allowed_methods := COALESCE(p_allowed_methods, v_row.allowed_methods);
  v_new_display_title := CASE
    WHEN p_display_title IS NOT NULL THEN NULLIF(btrim(p_display_title), '')
    ELSE v_row.display_title
  END;
  v_new_display_logo_url := CASE
    WHEN p_display_logo_url IS NOT NULL THEN NULLIF(btrim(p_display_logo_url), '')
    ELSE v_row.display_logo_url
  END;
  v_new_entry_mode := COALESCE(p_entry_mode, v_row.entry_mode);
  v_new_layout := COALESCE(p_employee_list_layout, v_row.employee_list_layout);
  v_new_doc_match := COALESCE(p_document_match, v_row.document_match);
  v_new_doc_suffix := COALESCE(p_document_suffix_length, v_row.document_suffix_length);
  v_new_identity_confirm := COALESCE(p_identity_confirm, v_row.identity_confirm);
  v_new_qr_confirm := COALESCE(p_qr_identity_confirm, v_row.qr_identity_confirm);
  v_new_idle := COALESCE(p_session_idle_seconds, v_row.session_idle_seconds);
  v_new_countdown := COALESCE(p_session_return_countdown_seconds, v_row.session_return_countdown_seconds);
  v_new_allow_history := COALESCE(p_session_allow_history, v_row.session_allow_history);
  v_new_history_days := COALESCE(p_session_history_max_days, v_row.session_history_max_days);
  v_new_allow_unassigned := COALESCE(p_allow_unassigned_punch, v_row.allow_unassigned_punch);
  v_new_warn_unassigned := COALESCE(p_warn_unassigned_punch, v_row.warn_unassigned_punch);
  v_new_warn_wrong := COALESCE(p_warn_wrong_scheduled_location, v_row.warn_wrong_scheduled_location);
  v_new_block_wrong := COALESCE(p_block_wrong_scheduled_location, v_row.block_wrong_scheduled_location);

  IF v_row.name IS DISTINCT FROM v_new_name THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'name', 'old', to_jsonb(v_row.name), 'new', to_jsonb(v_new_name)
    ));
  END IF;
  IF v_row.site_id IS DISTINCT FROM v_new_site_id THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'site_id', 'old', to_jsonb(v_row.site_id), 'new', to_jsonb(v_new_site_id)
    ));
  END IF;
  IF v_row.location_id IS DISTINCT FROM v_new_location_id THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'location_id',
      'old', to_jsonb(v_row.location_id),
      'new', to_jsonb(v_new_location_id),
      'old_location_path', to_jsonb(data.build_location_path_snapshot(v_row.location_id)),
      'new_location_path', to_jsonb(data.build_location_path_snapshot(v_new_location_id))
    ));
  END IF;
  IF v_row.status IS DISTINCT FROM v_status THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'status', 'old', to_jsonb(v_row.status), 'new', to_jsonb(v_status)
    ));
  END IF;
  IF v_row.allowed_methods IS DISTINCT FROM v_new_allowed_methods THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'allowed_methods',
      'old', to_jsonb(v_row.allowed_methods),
      'new', to_jsonb(v_new_allowed_methods)
    ));
  END IF;
  IF COALESCE(v_row.geo_antifraud_enabled, false) IS DISTINCT FROM v_geo_enabled THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'geo_antifraud_enabled',
      'old', to_jsonb(COALESCE(v_row.geo_antifraud_enabled, false)),
      'new', to_jsonb(v_geo_enabled)
    ));
  END IF;
  IF COALESCE(v_row.geo_antifraud_radius_m, 150) IS DISTINCT FROM v_geo_radius THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'geo_antifraud_radius_m',
      'old', to_jsonb(COALESCE(v_row.geo_antifraud_radius_m, 150)),
      'new', to_jsonb(v_geo_radius)
    ));
  END IF;
  IF v_row.display_title IS DISTINCT FROM v_new_display_title THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'display_title', 'old', to_jsonb(v_row.display_title), 'new', to_jsonb(v_new_display_title)
    ));
  END IF;
  IF v_row.display_logo_url IS DISTINCT FROM v_new_display_logo_url THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'display_logo_url', 'old', to_jsonb(v_row.display_logo_url), 'new', to_jsonb(v_new_display_logo_url)
    ));
  END IF;
  IF v_row.entry_mode IS DISTINCT FROM v_new_entry_mode THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'entry_mode', 'old', to_jsonb(v_row.entry_mode), 'new', to_jsonb(v_new_entry_mode)
    ));
  END IF;
  IF v_row.employee_list_layout IS DISTINCT FROM v_new_layout THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'employee_list_layout', 'old', to_jsonb(v_row.employee_list_layout), 'new', to_jsonb(v_new_layout)
    ));
  END IF;
  IF v_row.identity_confirm IS DISTINCT FROM v_new_identity_confirm THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'identity_confirm', 'old', to_jsonb(v_row.identity_confirm), 'new', to_jsonb(v_new_identity_confirm)
    ));
  END IF;
  IF v_row.qr_identity_confirm IS DISTINCT FROM v_new_qr_confirm THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'qr_identity_confirm', 'old', to_jsonb(v_row.qr_identity_confirm), 'new', to_jsonb(v_new_qr_confirm)
    ));
  END IF;
  IF v_row.session_idle_seconds IS DISTINCT FROM v_new_idle THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'session_idle_seconds', 'old', to_jsonb(v_row.session_idle_seconds), 'new', to_jsonb(v_new_idle)
    ));
  END IF;
  IF v_row.session_return_countdown_seconds IS DISTINCT FROM v_new_countdown THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'session_return_countdown_seconds',
      'old', to_jsonb(v_row.session_return_countdown_seconds),
      'new', to_jsonb(v_new_countdown)
    ));
  END IF;
  IF v_row.session_allow_history IS DISTINCT FROM v_new_allow_history THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'session_allow_history',
      'old', to_jsonb(v_row.session_allow_history),
      'new', to_jsonb(v_new_allow_history)
    ));
  END IF;

  UPDATE data.attendance_devices d
  SET
    name = v_new_name,
    site_id = v_new_site_id,
    location_id = v_new_location_id,
    status = v_status,
    allowed_methods = v_new_allowed_methods,
    geo_antifraud_enabled = v_geo_enabled,
    geo_antifraud_radius_m = v_geo_radius,
    display_title = v_new_display_title,
    display_logo_url = v_new_display_logo_url,
    entry_mode = v_new_entry_mode,
    employee_list_layout = v_new_layout,
    document_match = v_new_doc_match,
    document_suffix_length = v_new_doc_suffix,
    identity_confirm = v_new_identity_confirm,
    qr_identity_confirm = v_new_qr_confirm,
    session_idle_seconds = v_new_idle,
    session_return_countdown_seconds = v_new_countdown,
    session_allow_history = v_new_allow_history,
    session_history_max_days = v_new_history_days,
    allow_unassigned_punch = v_new_allow_unassigned,
    warn_unassigned_punch = v_new_warn_unassigned,
    warn_wrong_scheduled_location = v_new_warn_wrong,
    block_wrong_scheduled_location = v_new_block_wrong,
    updated_at = now()
  WHERE d.id = p_device_id;

  IF jsonb_array_length(v_changes) > 0 THEN
    PERFORM data.log_audit_event(
      v_row.tenant_id,
      auth.uid(),
      v_new_site_id,
      'ATTENDANCE_STATION_UPDATED',
      'attendance_device',
      p_device_id,
      jsonb_build_object(
        'device_id', p_device_id,
        'name', v_new_name,
        'changes', v_changes
      )
    );
  END IF;

  RETURN (
    SELECT jsonb_build_object(
      'device_id', d.id,
      'name', d.name,
      'site_id', d.site_id,
      'location_id', d.location_id,
      'status', d.status,
      'allowed_methods', d.allowed_methods,
      'geo_antifraud_enabled', d.geo_antifraud_enabled,
      'geo_antifraud_radius_m', d.geo_antifraud_radius_m,
      'display_title', d.display_title,
      'display_logo_url', d.display_logo_url,
      'effective_display_title', data.station_effective_display_title(d.name, d.display_title),
      'location_path', data.build_location_path_snapshot(d.location_id),
      'entry_mode', d.entry_mode,
      'employee_list_layout', d.employee_list_layout,
      'document_match', d.document_match,
      'document_suffix_length', d.document_suffix_length,
      'identity_confirm', d.identity_confirm,
      'qr_identity_confirm', d.qr_identity_confirm,
      'session_idle_seconds', d.session_idle_seconds,
      'session_return_countdown_seconds', d.session_return_countdown_seconds,
      'session_allow_history', d.session_allow_history,
      'session_history_max_days', d.session_history_max_days,
      'allow_unassigned_punch', d.allow_unassigned_punch,
      'warn_unassigned_punch', d.warn_unassigned_punch,
      'warn_wrong_scheduled_location', d.warn_wrong_scheduled_location,
      'block_wrong_scheduled_location', d.block_wrong_scheduled_location
    )
    FROM data.attendance_devices d
    WHERE d.id = p_device_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer, text, text,
  text, text, text, integer, text, text, integer, integer, boolean, integer,
  boolean, boolean, boolean, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer, text, text,
  text, text, text, integer, text, text, integer, integer, boolean, integer,
  boolean, boolean, boolean, boolean
) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. Vista api.attendance_devices
-- -----------------------------------------------------------------------------

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
    block_wrong_scheduled_location
  FROM data.attendance_devices;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.attendance_devices TO authenticated;
GRANT SELECT ON data.attendance_devices TO authenticated;
