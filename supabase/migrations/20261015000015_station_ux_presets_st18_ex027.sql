-- EX-02.7: secure UX presets + waiting auto-blank + name masking (IN-08).

-- -----------------------------------------------------------------------------
-- 1. Columns
-- -----------------------------------------------------------------------------

ALTER TABLE data.attendance_devices
  ADD COLUMN IF NOT EXISTS ux_preset text NOT NULL DEFAULT 'custom',
  ADD COLUMN IF NOT EXISTS waiting_idle_seconds integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS mask_names_on_waiting boolean NOT NULL DEFAULT false;

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_ux_preset_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_ux_preset_check
  CHECK (ux_preset IN ('custom', 'estricte', 'rapid_supervisat', 'qr'));

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_waiting_idle_seconds_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_waiting_idle_seconds_check
  CHECK (waiting_idle_seconds = 0 OR waiting_idle_seconds BETWEEN 30 AND 600);

COMMENT ON COLUMN data.attendance_devices.ux_preset IS
  'EX-02.7: curated bundle (estricte|rapid_supervisat|qr) or custom.';
COMMENT ON COLUMN data.attendance_devices.waiting_idle_seconds IS
  'EX-02.7/IN-08: idle seconds on waiting before privacy blank; 0 = disabled.';
COMMENT ON COLUMN data.attendance_devices.mask_names_on_waiting IS
  'EX-02.7/IN-08: mask employee names on waiting list / ambiguous match.';

-- -----------------------------------------------------------------------------
-- 2. verify_attendance_station_credentials — expose new fields
-- -----------------------------------------------------------------------------

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
    'mask_names_on_waiting', v_row.mask_names_on_waiting
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. update_attendance_station — presets + privacy fields + combo validation
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer, text, text,
  text, text, text, integer, text, text, integer, integer, boolean, integer,
  boolean, boolean, boolean, boolean
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
  p_block_wrong_scheduled_location    boolean DEFAULT NULL,
  p_ux_preset                         text DEFAULT NULL,
  p_waiting_idle_seconds              integer DEFAULT NULL,
  p_mask_names_on_waiting             boolean DEFAULT NULL
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
  v_new_preset text;
  v_new_waiting_idle int;
  v_new_mask_names boolean;
  v_changes jsonb := '[]'::jsonb;
  v_has_manual boolean;
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

  IF p_ux_preset IS NOT NULL AND p_ux_preset NOT IN ('custom', 'estricte', 'rapid_supervisat', 'qr') THEN
    RAISE EXCEPTION 'invalid_ux_preset' USING ERRCODE = 'check_violation';
  END IF;
  IF p_waiting_idle_seconds IS NOT NULL
     AND p_waiting_idle_seconds <> 0
     AND (p_waiting_idle_seconds < 30 OR p_waiting_idle_seconds > 600) THEN
    RAISE EXCEPTION 'waiting_idle_seconds_out_of_range' USING ERRCODE = 'check_violation';
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
  IF p_identity_confirm IS NOT NULL AND p_identity_confirm NOT IN ('none', 'tap_name', 'portal_pin') THEN
    RAISE EXCEPTION 'invalid_identity_confirm' USING ERRCODE = 'check_violation';
  END IF;
  IF p_qr_identity_confirm IS NOT NULL AND p_qr_identity_confirm NOT IN ('none', 'tap_name', 'portal_pin') THEN
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

  v_new_preset := COALESCE(p_ux_preset, v_row.ux_preset, 'custom');

  IF v_new_preset = 'estricte' THEN
    v_new_entry_mode := 'document_entry';
    v_new_layout := 'search_first';
    v_new_doc_match := 'suffix';
    v_new_doc_suffix := 4;
    v_new_identity_confirm := 'tap_name';
    v_new_qr_confirm := 'tap_name';
    v_new_idle := 45;
    v_new_countdown := 10;
    v_new_allow_history := false;
    v_new_history_days := COALESCE(p_session_history_max_days, v_row.session_history_max_days, 90);
    v_new_waiting_idle := 90;
    v_new_mask_names := true;
    IF NOT ('manual' = ANY (COALESCE(v_new_allowed_methods, ARRAY[]::text[]))) THEN
      v_new_allowed_methods := ARRAY['manual']::text[];
    END IF;
  ELSIF v_new_preset = 'rapid_supervisat' THEN
    v_new_entry_mode := 'employee_list';
    v_new_layout := 'two_column';
    v_new_doc_match := COALESCE(p_document_match, v_row.document_match, 'suffix');
    v_new_doc_suffix := COALESCE(p_document_suffix_length, v_row.document_suffix_length, 4);
    v_new_identity_confirm := 'tap_name';
    v_new_qr_confirm := 'none';
    v_new_idle := 90;
    v_new_countdown := 15;
    v_new_allow_history := false;
    v_new_history_days := COALESCE(p_session_history_max_days, v_row.session_history_max_days, 90);
    v_new_waiting_idle := 180;
    v_new_mask_names := false;
    IF NOT ('manual' = ANY (COALESCE(v_new_allowed_methods, ARRAY[]::text[]))) THEN
      v_new_allowed_methods := ARRAY['manual']::text[];
    END IF;
  ELSIF v_new_preset = 'qr' THEN
    v_new_entry_mode := 'document_entry';
    v_new_layout := COALESCE(p_employee_list_layout, v_row.employee_list_layout, 'compact');
    v_new_doc_match := COALESCE(p_document_match, v_row.document_match, 'suffix');
    v_new_doc_suffix := COALESCE(p_document_suffix_length, v_row.document_suffix_length, 4);
    v_new_identity_confirm := 'tap_name';
    v_new_qr_confirm := 'tap_name';
    v_new_idle := 60;
    v_new_countdown := 12;
    v_new_allow_history := false;
    v_new_history_days := COALESCE(p_session_history_max_days, v_row.session_history_max_days, 90);
    v_new_waiting_idle := 120;
    v_new_mask_names := true;
    v_new_allowed_methods := ARRAY['qr']::text[];
  ELSE
    -- custom
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
    v_new_waiting_idle := COALESCE(p_waiting_idle_seconds, v_row.waiting_idle_seconds, 0);
    v_new_mask_names := COALESCE(p_mask_names_on_waiting, v_row.mask_names_on_waiting, false);
  END IF;

  v_new_allow_unassigned := COALESCE(p_allow_unassigned_punch, v_row.allow_unassigned_punch);
  v_new_warn_unassigned := COALESCE(p_warn_unassigned_punch, v_row.warn_unassigned_punch);
  v_new_warn_wrong := COALESCE(p_warn_wrong_scheduled_location, v_row.warn_wrong_scheduled_location);
  v_new_block_wrong := COALESCE(p_block_wrong_scheduled_location, v_row.block_wrong_scheduled_location);

  -- Safe combination gate (RC / EX-02.7)
  v_has_manual := 'manual' = ANY (COALESCE(v_new_allowed_methods, ARRAY[]::text[]));
  IF v_has_manual
     AND v_new_entry_mode = 'employee_list'
     AND v_new_identity_confirm = 'none' THEN
    RAISE EXCEPTION 'unsafe_station_config: employee_list requires identity_confirm' USING ERRCODE = 'check_violation';
  END IF;

  IF v_new_allowed_methods IS NULL OR cardinality(v_new_allowed_methods) = 0 THEN
    RAISE EXCEPTION 'allowed_methods_required' USING ERRCODE = 'check_violation';
  END IF;

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
  IF COALESCE(v_row.ux_preset, 'custom') IS DISTINCT FROM v_new_preset THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'ux_preset',
      'old', to_jsonb(COALESCE(v_row.ux_preset, 'custom')),
      'new', to_jsonb(v_new_preset)
    ));
  END IF;
  IF COALESCE(v_row.waiting_idle_seconds, 0) IS DISTINCT FROM v_new_waiting_idle THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'waiting_idle_seconds',
      'old', to_jsonb(COALESCE(v_row.waiting_idle_seconds, 0)),
      'new', to_jsonb(v_new_waiting_idle)
    ));
  END IF;
  IF COALESCE(v_row.mask_names_on_waiting, false) IS DISTINCT FROM v_new_mask_names THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'mask_names_on_waiting',
      'old', to_jsonb(COALESCE(v_row.mask_names_on_waiting, false)),
      'new', to_jsonb(v_new_mask_names)
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
    ux_preset = v_new_preset,
    waiting_idle_seconds = v_new_waiting_idle,
    mask_names_on_waiting = v_new_mask_names,
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
      'block_wrong_scheduled_location', d.block_wrong_scheduled_location,
      'ux_preset', d.ux_preset,
      'waiting_idle_seconds', d.waiting_idle_seconds,
      'mask_names_on_waiting', d.mask_names_on_waiting
    )
    FROM data.attendance_devices d
    WHERE d.id = p_device_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer, text, text,
  text, text, text, integer, text, text, integer, integer, boolean, integer,
  boolean, boolean, boolean, boolean, text, integer, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer, text, text,
  text, text, text, integer, text, text, integer, integer, boolean, integer,
  boolean, boolean, boolean, boolean, text, integer, boolean
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
