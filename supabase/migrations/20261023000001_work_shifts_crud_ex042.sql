-- =============================================================================
-- EX-04.2 — CRUD work_shifts (create / update / soft-deactivate)
-- UI multi-slot + anomalies es frontend; backend ja permet multi-slot no solapat.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_work_shift(
  p_site_id    uuid,
  p_name       text,
  p_start_time time,
  p_end_time   time,
  p_color      text DEFAULT '#6366f1'
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_row data.work_shifts;
  v_color text := COALESCE(nullif(btrim(p_color), ''), '#6366f1');
BEGIN
  IF p_site_id IS NULL THEN
    RAISE EXCEPTION 'site_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'name_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_start_time IS NULL OR p_end_time IS NULL OR p_start_time = p_end_time THEN
    RAISE EXCEPTION 'invalid_shift_times' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_color !~* '^#[0-9a-fA-F]{3,6}$' THEN
    RAISE EXCEPTION 'invalid_color' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage', p_site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO data.work_shifts (
    tenant_id, site_id, name, color, start_time, end_time, is_active
  ) VALUES (
    v_tenant_id, p_site_id, btrim(p_name), v_color, p_start_time, p_end_time, true
  )
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.update_work_shift(
  p_id         uuid,
  p_name       text DEFAULT NULL,
  p_start_time time DEFAULT NULL,
  p_end_time   time DEFAULT NULL,
  p_color      text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row data.work_shifts;
  v_start time;
  v_end time;
  v_color text;
BEGIN
  SELECT * INTO v_row FROM data.work_shifts WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'work_shift_not_found: %', p_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_row.tenant_id, 'labor_calendar.manage', v_row.site_id),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_start := COALESCE(p_start_time, v_row.start_time);
  v_end := COALESCE(p_end_time, v_row.end_time);
  IF v_start = v_end THEN
    RAISE EXCEPTION 'invalid_shift_times' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_color := COALESCE(nullif(btrim(p_color), ''), v_row.color);
  IF v_color !~* '^#[0-9a-fA-F]{3,6}$' THEN
    RAISE EXCEPTION 'invalid_color' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE data.work_shifts
  SET name = COALESCE(nullif(btrim(p_name), ''), name),
      start_time = v_start,
      end_time = v_end,
      color = v_color,
      updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.deactivate_work_shift(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row data.work_shifts;
BEGIN
  SELECT * INTO v_row FROM data.work_shifts WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'work_shift_not_found: %', p_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_row.tenant_id, 'labor_calendar.manage', v_row.site_id),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.work_shifts
  SET is_active = false, updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('id', v_row.id, 'is_active', v_row.is_active);
END;
$$;

COMMENT ON FUNCTION api.create_work_shift(uuid, text, time, time, text) IS
  'EX-04.2: crea plantilla work_shift per site.';
COMMENT ON FUNCTION api.update_work_shift(uuid, text, time, time, text) IS
  'EX-04.2: actualitza plantilla (no reescriu slots published — tenen snapshot).';
COMMENT ON FUNCTION api.deactivate_work_shift(uuid) IS
  'EX-04.2: soft-deactivate (is_active=false); slots existents intactes.';

GRANT EXECUTE ON FUNCTION api.create_work_shift(uuid, text, time, time, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.update_work_shift(uuid, text, time, time, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.deactivate_work_shift(uuid) TO authenticated;
