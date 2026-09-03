-- =============================================================================
-- EX-06.1 — RPCs CRUD rols/quals + herència role a plantilles/slots
-- =============================================================================

-- ─── work_roles ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_work_roles(p_site_id uuid DEFAULT NULL, p_include_inactive boolean DEFAULT false)
RETURNS SETOF api.work_roles
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT wr.*
  FROM api.work_roles wr
  WHERE wr.tenant_id = v_tenant
    AND (p_include_inactive OR wr.is_active)
    AND (p_site_id IS NULL OR wr.site_id IS NULL OR wr.site_id = p_site_id)
  ORDER BY wr.sort_order, wr.name;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_work_role(
  p_id         uuid DEFAULT NULL,
  p_site_id    uuid DEFAULT NULL,
  p_key        text DEFAULT NULL,
  p_name       text DEFAULT NULL,
  p_sort_order int DEFAULT 100,
  p_is_active  boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_row data.work_roles;
  v_key text;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.work_roles WHERE id = p_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'work_role_not_found' USING ERRCODE = 'P0002';
    END IF;
    UPDATE data.work_roles
    SET site_id = COALESCE(p_site_id, site_id),
        name = COALESCE(nullif(btrim(p_name), ''), name),
        sort_order = COALESCE(p_sort_order, sort_order),
        is_active = COALESCE(p_is_active, is_active),
        updated_at = now()
    WHERE id = p_id
    RETURNING * INTO v_row;
  ELSE
    IF p_name IS NULL OR btrim(p_name) = '' THEN
      RAISE EXCEPTION 'name_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    v_key := COALESCE(
      nullif(lower(btrim(p_key)), ''),
      regexp_replace(lower(btrim(p_name)), '[^a-z0-9]+', '_', 'g')
    );
    v_key := trim(both '_' from v_key);
    IF v_key = '' OR v_key !~ '^[a-z0-9_]{1,64}$' THEN
      RAISE EXCEPTION 'invalid_role_key' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO data.work_roles (tenant_id, site_id, key, name, sort_order, is_active)
    VALUES (v_tenant, p_site_id, v_key, btrim(p_name), COALESCE(p_sort_order, 100), COALESCE(p_is_active, true))
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.deactivate_work_role(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.work_roles;
BEGIN
  SELECT * INTO v_row FROM data.work_roles WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'work_role_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT COALESCE(data.jwt_has_permission(v_row.tenant_id, 'labor_calendar.manage', v_row.site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.work_roles
  SET is_active = false, updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_work_roles(uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_work_role(uuid, uuid, text, text, int, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.deactivate_work_role(uuid) TO authenticated, service_role;

-- ─── employee_role_assignments ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_employee_role_assignments(
  p_employee_id uuid,
  p_include_inactive boolean DEFAULT false
)
RETURNS TABLE (
  id uuid,
  tenant_id uuid,
  employee_id uuid,
  role_id uuid,
  role_key text,
  role_name text,
  level smallint,
  valid_from date,
  valid_to date,
  is_primary boolean,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
BEGIN
  RETURN QUERY
  SELECT
    a.id, a.tenant_id, a.employee_id, a.role_id,
    wr.key, wr.name,
    a.level, a.valid_from, a.valid_to, a.is_primary, a.is_active,
    a.created_at, a.updated_at
  FROM data.employee_role_assignments a
  JOIN data.work_roles wr ON wr.id = a.role_id
  WHERE a.employee_id = p_employee_id
    AND (p_include_inactive OR a.is_active)
  ORDER BY a.is_primary DESC, wr.sort_order, wr.name;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_employee_role_assignment(
  p_id          uuid DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL,
  p_role_id     uuid DEFAULT NULL,
  p_level       smallint DEFAULT 1,
  p_valid_from  date DEFAULT NULL,
  p_valid_to    date DEFAULT NULL,
  p_is_primary  boolean DEFAULT false,
  p_is_active   boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_role data.work_roles;
  v_row data.employee_role_assignments;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.employee_role_assignments WHERE id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_role_assignment_not_found' USING ERRCODE = 'P0002';
    END IF;
    SELECT e.tenant_id, e.site_id INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;
  ELSE
    IF p_employee_id IS NULL OR p_role_id IS NULL THEN
      RAISE EXCEPTION 'employee_and_role_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT e.tenant_id, e.site_id INTO v_emp FROM data.employees e WHERE e.id = p_employee_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_id IS NULL THEN
    SELECT * INTO v_role FROM data.work_roles
    WHERE id = p_role_id AND tenant_id = v_emp.tenant_id AND is_active = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'work_role_not_found_or_inactive' USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO data.employee_role_assignments (
      tenant_id, employee_id, role_id, level, valid_from, valid_to, is_primary, is_active
    ) VALUES (
      v_emp.tenant_id, p_employee_id, p_role_id,
      COALESCE(p_level, 1), p_valid_from, p_valid_to,
      COALESCE(p_is_primary, false), COALESCE(p_is_active, true)
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE data.employee_role_assignments
    SET level = COALESCE(p_level, level),
        valid_from = p_valid_from,
        valid_to = p_valid_to,
        is_primary = COALESCE(p_is_primary, is_primary),
        is_active = COALESCE(p_is_active, is_active),
        role_id = COALESCE(p_role_id, role_id),
        updated_at = now()
    WHERE id = p_id
    RETURNING * INTO v_row;
  END IF;

  IF v_row.is_primary THEN
    UPDATE data.employee_role_assignments
    SET is_primary = false, updated_at = now()
    WHERE employee_id = v_row.employee_id
      AND id <> v_row.id
      AND is_primary = true;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.deactivate_employee_role_assignment(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.employee_role_assignments;
  v_emp record;
BEGIN
  SELECT * INTO v_row FROM data.employee_role_assignments WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_role_assignment_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT e.tenant_id, e.site_id INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;
  IF NOT COALESCE(data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.employee_role_assignments
  SET is_active = false, updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_employee_role_assignments(uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_employee_role_assignment(uuid, uuid, uuid, smallint, date, date, boolean, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.deactivate_employee_role_assignment(uuid) TO authenticated, service_role;

-- ─── employee_qualifications ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_employee_qualifications(
  p_employee_id uuid,
  p_include_inactive boolean DEFAULT false
)
RETURNS SETOF api.employee_qualifications
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
BEGIN
  RETURN QUERY
  SELECT q.*
  FROM api.employee_qualifications q
  WHERE q.employee_id = p_employee_id
    AND (p_include_inactive OR q.is_active)
  ORDER BY q.label;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_employee_qualification(
  p_id          uuid DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL,
  p_key         text DEFAULT NULL,
  p_label       text DEFAULT NULL,
  p_issued_at   date DEFAULT NULL,
  p_expires_at  date DEFAULT NULL,
  p_notes       text DEFAULT NULL,
  p_is_active   boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_row data.employee_qualifications;
  v_key text;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.employee_qualifications WHERE id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_qualification_not_found' USING ERRCODE = 'P0002';
    END IF;
    SELECT e.tenant_id, e.site_id INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;
  ELSE
    IF p_employee_id IS NULL OR p_label IS NULL OR btrim(p_label) = '' THEN
      RAISE EXCEPTION 'employee_and_label_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT e.tenant_id, e.site_id INTO v_emp FROM data.employees e WHERE e.id = p_employee_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_id IS NULL THEN
    v_key := COALESCE(
      nullif(lower(btrim(p_key)), ''),
      regexp_replace(lower(btrim(p_label)), '[^a-z0-9]+', '_', 'g')
    );
    v_key := trim(both '_' from v_key);
    IF v_key !~ '^[a-z0-9_]{1,64}$' THEN
      RAISE EXCEPTION 'invalid_qualification_key' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO data.employee_qualifications (
      tenant_id, employee_id, key, label, issued_at, expires_at, notes, is_active
    ) VALUES (
      v_emp.tenant_id, p_employee_id, v_key, btrim(p_label),
      p_issued_at, p_expires_at, p_notes, COALESCE(p_is_active, true)
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE data.employee_qualifications
    SET label = COALESCE(nullif(btrim(p_label), ''), label),
        issued_at = COALESCE(p_issued_at, issued_at),
        expires_at = p_expires_at,
        notes = COALESCE(p_notes, notes),
        is_active = COALESCE(p_is_active, is_active),
        updated_at = now()
    WHERE id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.deactivate_employee_qualification(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.employee_qualifications;
  v_emp record;
BEGIN
  SELECT * INTO v_row FROM data.employee_qualifications WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_qualification_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT e.tenant_id, e.site_id INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;
  IF NOT COALESCE(data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.employee_qualifications
  SET is_active = false, updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_employee_qualifications(uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_employee_qualification(uuid, uuid, text, text, date, date, text, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.deactivate_employee_qualification(uuid) TO authenticated, service_role;

-- ─── role_qualification_requirements ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_role_qualification_requirements(
  p_role_id uuid,
  p_include_inactive boolean DEFAULT false
)
RETURNS SETOF api.role_qualification_requirements
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
BEGIN
  RETURN QUERY
  SELECT r.*
  FROM api.role_qualification_requirements r
  WHERE r.role_id = p_role_id
    AND (p_include_inactive OR r.is_active)
  ORDER BY r.qualification_key;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_role_qualification_requirement(
  p_id                uuid DEFAULT NULL,
  p_role_id           uuid DEFAULT NULL,
  p_qualification_key text DEFAULT NULL,
  p_required          boolean DEFAULT true,
  p_min_level         smallint DEFAULT NULL,
  p_is_active         boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_role data.work_roles;
  v_row data.role_qualification_requirements;
  v_key text;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.role_qualification_requirements WHERE id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'role_qualification_requirement_not_found' USING ERRCODE = 'P0002';
    END IF;
    SELECT * INTO v_role FROM data.work_roles WHERE id = v_row.role_id;
  ELSE
    IF p_role_id IS NULL OR p_qualification_key IS NULL OR btrim(p_qualification_key) = '' THEN
      RAISE EXCEPTION 'role_and_qualification_key_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT * INTO v_role FROM data.work_roles WHERE id = p_role_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'work_role_not_found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_role.tenant_id, 'labor_calendar.manage', v_role.site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_id IS NULL THEN
    v_key := lower(btrim(p_qualification_key));
    IF v_key !~ '^[a-z0-9_]{1,64}$' THEN
      RAISE EXCEPTION 'invalid_qualification_key' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO data.role_qualification_requirements (
      tenant_id, role_id, qualification_key, required, min_level, is_active
    ) VALUES (
      v_role.tenant_id, p_role_id, v_key,
      COALESCE(p_required, true), p_min_level, COALESCE(p_is_active, true)
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE data.role_qualification_requirements
    SET required = COALESCE(p_required, required),
        min_level = p_min_level,
        is_active = COALESCE(p_is_active, is_active),
        updated_at = now()
    WHERE id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.deactivate_role_qualification_requirement(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.role_qualification_requirements;
  v_role data.work_roles;
BEGIN
  SELECT * INTO v_row FROM data.role_qualification_requirements WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'role_qualification_requirement_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO v_role FROM data.work_roles WHERE id = v_row.role_id;
  IF NOT COALESCE(data.jwt_has_permission(v_role.tenant_id, 'labor_calendar.manage', v_role.site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.role_qualification_requirements
  SET is_active = false, updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_role_qualification_requirements(uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_role_qualification_requirement(uuid, uuid, text, boolean, smallint, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.deactivate_role_qualification_requirement(uuid) TO authenticated, service_role;

-- Helpers exposats per UI/tests
CREATE OR REPLACE FUNCTION api.employee_has_active_role(
  p_employee_id uuid,
  p_role_id uuid,
  p_on_date date DEFAULT CURRENT_DATE
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT data.employee_has_active_role(p_employee_id, p_role_id, p_on_date);
$$;

CREATE OR REPLACE FUNCTION api.employee_meets_role_qualifications(
  p_employee_id uuid,
  p_role_id uuid,
  p_on_date date DEFAULT CURRENT_DATE
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT data.employee_meets_role_qualifications(p_employee_id, p_role_id, p_on_date);
$$;

GRANT EXECUTE ON FUNCTION api.employee_has_active_role(uuid, uuid, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.employee_meets_role_qualifications(uuid, uuid, date) TO authenticated, service_role;

-- ─── Extendre create/update_work_shift amb default_role_id ───────────────────

DROP FUNCTION IF EXISTS api.create_work_shift(uuid, text, time, time, text);
CREATE OR REPLACE FUNCTION api.create_work_shift(
  p_site_id          uuid,
  p_name             text,
  p_start_time       time,
  p_end_time         time,
  p_color            text DEFAULT '#6366f1',
  p_default_role_id  uuid DEFAULT NULL
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

  IF p_default_role_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.work_roles wr
      WHERE wr.id = p_default_role_id
        AND wr.tenant_id = v_tenant_id
        AND wr.is_active = true
    ) THEN
      RAISE EXCEPTION 'work_role_not_found_or_inactive' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  INSERT INTO data.work_shifts (
    tenant_id, site_id, name, color, start_time, end_time, is_active, default_role_id
  ) VALUES (
    v_tenant_id, p_site_id, btrim(p_name), v_color, p_start_time, p_end_time, true, p_default_role_id
  )
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

DROP FUNCTION IF EXISTS api.update_work_shift(uuid, text, time, time, text);
CREATE OR REPLACE FUNCTION api.update_work_shift(
  p_id               uuid,
  p_name             text DEFAULT NULL,
  p_start_time       time DEFAULT NULL,
  p_end_time         time DEFAULT NULL,
  p_color            text DEFAULT NULL,
  p_default_role_id  uuid DEFAULT NULL,
  p_clear_role       boolean DEFAULT false
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
  v_role uuid;
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

  IF p_clear_role THEN
    v_role := NULL;
  ELSIF p_default_role_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.work_roles wr
      WHERE wr.id = p_default_role_id
        AND wr.tenant_id = v_row.tenant_id
        AND wr.is_active = true
    ) THEN
      RAISE EXCEPTION 'work_role_not_found_or_inactive' USING ERRCODE = 'P0002';
    END IF;
    v_role := p_default_role_id;
  ELSE
    v_role := v_row.default_role_id;
  END IF;

  UPDATE data.work_shifts
  SET name = COALESCE(nullif(btrim(p_name), ''), name),
      start_time = v_start,
      end_time = v_end,
      color = v_color,
      default_role_id = v_role,
      updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_work_shift(uuid, text, time, time, text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.update_work_shift(uuid, text, time, time, text, uuid, boolean) TO authenticated, service_role;

-- ─── assign_shift_slot: herència role + snapshot ─────────────────────────────

DROP FUNCTION IF EXISTS api.assign_shift_slot(uuid, date, uuid, text, uuid);
CREATE OR REPLACE FUNCTION api.assign_shift_slot(
  p_employee_id uuid,
  p_slot_date date,
  p_shift_id uuid,
  p_notes text DEFAULT NULL,
  p_location_id uuid DEFAULT NULL,
  p_role_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_shift record;
  v_slot_id uuid;
  v_anomalies text[] := '{}';
  v_week_start date;
  v_week_min numeric := 0;
  v_shift_min numeric;
  v_location_id uuid;
  v_site_id uuid;
  v_role_id uuid;
  v_role_name text;
BEGIN
  SELECT e.tenant_id, e.site_id, e.weekly_hours, e.status INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;

  IF v_emp.status = 'terminated' THEN
    RAISE EXCEPTION 'employee_terminated: no es pot assignar torn a un empleat donat de baixa'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.assert_shift_pairs_mutable(
    jsonb_build_array(jsonb_build_object(
      'employee_id', p_employee_id,
      'work_date', p_slot_date
    ))
  );

  SELECT ws.* INTO v_shift
  FROM data.work_shifts ws
  WHERE ws.id = p_shift_id
    AND ws.tenant_id = v_emp.tenant_id
    AND ws.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shift_not_found_or_inactive: %', p_shift_id USING ERRCODE = 'P0002';
  END IF;

  v_site_id := COALESCE(v_shift.site_id, v_emp.site_id);
  v_location_id := COALESCE(p_location_id, v_shift.default_location_id);
  v_role_id := COALESCE(p_role_id, v_shift.default_role_id);

  IF v_role_id IS NOT NULL THEN
    SELECT wr.name INTO v_role_name
    FROM data.work_roles wr
    WHERE wr.id = v_role_id
      AND wr.tenant_id = v_emp.tenant_id
      AND wr.is_active = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'work_role_not_found_or_inactive' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.shift_slots ss2
    WHERE ss2.employee_id = p_employee_id
      AND ss2.status <> 'cancelled'
      AND ss2.slot_date BETWEEN p_slot_date - 1 AND p_slot_date + 1
      AND data.shift_slots_overlap(
        p_slot_date, v_shift.start_time, v_shift.end_time,
        ss2.slot_date, ss2.start_time, ss2.end_time
      )
  ) THEN
    v_anomalies := array_append(v_anomalies, 'SHIFT_OVERLAP');
  END IF;

  v_week_start := date_trunc('week', p_slot_date::timestamptz)::date;

  v_shift_min := ROUND(EXTRACT(EPOCH FROM CASE WHEN v_shift.end_time > v_shift.start_time THEN v_shift.end_time - v_shift.start_time ELSE interval '24 hours' + (v_shift.end_time - v_shift.start_time) END) / 60);

  SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM CASE WHEN ss2.end_time > ss2.start_time THEN ss2.end_time - ss2.start_time ELSE interval '24 hours' + (ss2.end_time - ss2.start_time) END) / 60)), 0)
  INTO v_week_min
  FROM data.shift_slots ss2
  WHERE ss2.employee_id = p_employee_id
    AND ss2.slot_date >= v_week_start
    AND ss2.slot_date <= v_week_start + 6
    AND ss2.status <> 'cancelled';

  IF v_emp.weekly_hours IS NOT NULL AND (v_week_min + v_shift_min) > (v_emp.weekly_hours * 60) THEN
    v_anomalies := array_append(v_anomalies, 'WEEKLY_HOURS_EXCEEDED');
  END IF;

  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id, slot_date, status, notes, created_by,
    start_time, end_time, location_id, role_id, role_name_snapshot
  ) VALUES (
    v_emp.tenant_id, v_site_id, p_employee_id, p_shift_id,
    p_slot_date, 'draft', p_notes, auth.uid(),
    v_shift.start_time, v_shift.end_time, v_location_id, v_role_id, v_role_name
  )
  RETURNING id INTO v_slot_id;

  PERFORM data.log_audit_event(
    v_emp.tenant_id, auth.uid(), v_site_id,
    'SHIFT_SLOT_ASSIGNED', 'shift_slot', v_slot_id,
    jsonb_build_object(
      'employee_id', p_employee_id,
      'shift_id', p_shift_id,
      'slot_date', p_slot_date,
      'location_id', v_location_id,
      'role_id', v_role_id,
      'anomalies', v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'slot_id', v_slot_id,
    'status', 'draft',
    'location_id', v_location_id,
    'role_id', v_role_id,
    'anomalies', to_jsonb(v_anomalies)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.assign_shift_slot(uuid, date, uuid, text, uuid, uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
