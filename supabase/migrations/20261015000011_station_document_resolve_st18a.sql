-- ST-18a / EX-02.3: resolve employee by document at station + anti-enumeration.
-- Default entry_mode for NEW stations → document_entry (decision #30).
-- PIN challenge remains EX-02.4.

-- -----------------------------------------------------------------------------
-- 1. Defaults + comments
-- -----------------------------------------------------------------------------

ALTER TABLE data.attendance_devices
  ALTER COLUMN entry_mode SET DEFAULT 'document_entry';

COMMENT ON COLUMN data.attendance_devices.entry_mode IS
  'ST-18: employee_list | document_entry. New stations default document_entry (ST-18a).';

COMMENT ON COLUMN data.attendance_devices.document_match IS
  'ST-18a: exact = document complet normalitzat; suffix = coincideix per sufix (mínim document_suffix_length).';

-- -----------------------------------------------------------------------------
-- 2. Rate-limit bucket type for document resolve
-- -----------------------------------------------------------------------------

ALTER TABLE data.station_rate_limit_events
  DROP CONSTRAINT IF EXISTS station_rate_limit_events_bucket_type_check;

ALTER TABLE data.station_rate_limit_events
  ADD CONSTRAINT station_rate_limit_events_bucket_type_check
  CHECK (bucket_type IN (
    'register',
    'identity_resolve',
    'identity_issue',
    'document_resolve'
  ));

CREATE OR REPLACE FUNCTION api.assert_station_document_resolve_rate_limit(
  p_client_key      text,
  p_max_attempts    int DEFAULT 20,
  p_window_minutes  int DEFAULT 15
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_key text := COALESCE(NULLIF(btrim(p_client_key), ''), 'unknown');
BEGIN
  IF char_length(v_key) > 128 THEN
    v_key := left(v_key, 128);
  END IF;

  RETURN data.assert_station_rate_limit_bucket(
    v_key,
    p_max_attempts,
    p_window_minutes,
    'station_document_resolve_rate_limited',
    'document_resolve',
    NULL,
    NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION api.assert_station_document_resolve_rate_limit(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.assert_station_document_resolve_rate_limit(text, int, int) TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Resolve by document (station scope, anti-enumeration shape)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.resolve_attendance_station_employee_document(
  p_device_id   uuid,
  p_document_id text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_device record;
  v_norm text;
  v_today date;
  v_scope boolean;
  v_matches jsonb := '[]'::jsonb;
  v_match_mode text;
  v_min_len int;
  v_count int;
BEGIN
  SELECT
    d.id,
    d.tenant_id,
    d.site_id,
    d.location_id,
    d.status,
    d.document_match,
    d.document_suffix_length,
    d.entry_mode
  INTO v_device
  FROM data.attendance_devices d
  WHERE d.id = p_device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active'
     OR v_device.site_id IS NULL
     OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_not_ready' USING ERRCODE = 'check_violation';
  END IF;

  v_norm := api.normalize_employee_document_id(p_document_id);
  v_match_mode := COALESCE(v_device.document_match, 'suffix');
  v_min_len := COALESCE(v_device.document_suffix_length, 4);

  -- Uniform empty response for blank / too-short input (anti-enumeration).
  IF v_norm IS NULL
     OR (v_match_mode = 'suffix' AND char_length(v_norm) < v_min_len)
     OR (v_match_mode = 'exact' AND char_length(v_norm) < 3) THEN
    RETURN jsonb_build_object(
      'status', 'not_found',
      'matches', '[]'::jsonb,
      'document_match', v_match_mode,
      'document_suffix_length', v_min_len,
      'pin_required', false
    );
  END IF;

  v_today := (now() AT TIME ZONE data.get_site_timezone(v_device.site_id, v_device.tenant_id))::date;
  v_scope := data.location_scope_has_attendance_assignments(v_device.location_id, v_today);

  SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_name), '[]'::jsonb)
    INTO v_matches
  FROM (
    SELECT
      jsonb_build_object(
        'employee_id', e.id,
        'full_name', e.full_name,
        'day_state', data.compute_employee_punch_day_state(e.id, v_today),
        'next_punch', data.station_kiosk_next_punch(
          data.compute_employee_punch_day_state(e.id, v_today)
        )
      ) AS row_data,
      e.full_name AS sort_name
    FROM data.employees e
    WHERE e.tenant_id = v_device.tenant_id
      AND e.site_id = v_device.site_id
      AND e.status = 'active'
      AND api.normalize_employee_document_id(e.document_id) IS NOT NULL
      AND (
        (
          v_match_mode = 'exact'
          AND api.normalize_employee_document_id(e.document_id) = v_norm
        )
        OR (
          v_match_mode = 'suffix'
          AND right(api.normalize_employee_document_id(e.document_id), char_length(v_norm)) = v_norm
        )
      )
      AND (
        NOT v_scope
        OR data.employee_can_punch_at_location(e.id, v_device.location_id, v_today)
      )
  ) sub;

  v_count := COALESCE(jsonb_array_length(v_matches), 0);

  IF v_count = 0 THEN
    RETURN jsonb_build_object(
      'status', 'not_found',
      'matches', '[]'::jsonb,
      'document_match', v_match_mode,
      'document_suffix_length', v_min_len,
      'pin_required', false
    );
  END IF;

  IF v_count = 1 THEN
    RETURN jsonb_build_object(
      'status', 'matched',
      'matches', v_matches,
      'employee_id', v_matches->0->>'employee_id',
      'full_name', v_matches->0->>'full_name',
      'day_state', v_matches->0->>'day_state',
      'next_punch', v_matches->0->>'next_punch',
      'document_match', v_match_mode,
      'document_suffix_length', v_min_len,
      'pin_required', false
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'ambiguous',
    'matches', v_matches,
    'document_match', v_match_mode,
    'document_suffix_length', v_min_len,
    'pin_required', false
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_attendance_station_employee_document(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_attendance_station_employee_document(uuid, text) TO service_role;

COMMENT ON FUNCTION api.resolve_attendance_station_employee_document(uuid, text) IS
  'ST-18a: resolució DNI/document a l''estació. Resposta uniforme not_found; col·lisions → ambiguous.';
