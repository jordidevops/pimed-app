-- Reject creating work_order projects already completed/cancelled.

CREATE OR REPLACE FUNCTION api.create_project(
  p_tenant_id       uuid,
  p_name            text,
  p_type            data.project_type       DEFAULT 'internal',
  p_description     text                    DEFAULT NULL,
  p_status          varchar                 DEFAULT 'draft',
  p_visibility      data.project_visibility DEFAULT 'company',
  p_department_id   uuid                    DEFAULT NULL,
  p_site_id         uuid                    DEFAULT NULL,
  p_location_id     uuid                    DEFAULT NULL,
  p_client_id       uuid                    DEFAULT NULL,
  p_planned_start   timestamptz             DEFAULT NULL,
  p_planned_end     timestamptz             DEFAULT NULL,
  p_contact_site_id uuid                    DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_project_id uuid;
  v_role       text;
  v_status     text := COALESCE(NULLIF(btrim(p_status), ''), 'draft');
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'member') THEN
    RAISE EXCEPTION 'forbidden: el rol ''%'' no pot crear projectes al tenant %', v_role, p_tenant_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_type = 'work_order' AND p_site_id IS NULL THEN
    RAISE EXCEPTION 'work_order_requires_site_id'
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_type = 'work_order' AND v_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'work_order_create_terminal_status'
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, client_id, contact_site_id,
    planned_start, planned_end, created_by
  )
  VALUES (
    p_tenant_id, p_type, p_name, p_description,
    v_status, COALESCE(p_visibility, 'company'),
    p_department_id, p_site_id, p_location_id, p_client_id, p_contact_site_id,
    p_planned_start, p_planned_end, v_user_id
  )
  RETURNING id INTO v_project_id;

  INSERT INTO data.project_members (project_id, user_id, role)
  VALUES (v_project_id, v_user_id, 'manager');

  IF p_planned_start IS NOT NULL THEN
    PERFORM pgmq.send(
      'project_events',
      jsonb_build_object(
        'event',         'PROJECT_CREATED',
        'project_id',    v_project_id,
        'tenant_id',     p_tenant_id,
        'name',          p_name,
        'type',          p_type,
        'planned_start', p_planned_start,
        'created_by',    v_user_id
      )
    );
  END IF;

  RETURN v_project_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_project(
  uuid, text, data.project_type, text, varchar, data.project_visibility,
  uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid
) TO authenticated, service_role;
