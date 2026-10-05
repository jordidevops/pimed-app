-- api.list_field_visits: RLS, technician filter, unscheduled tray, date range
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_tech uuid := '20000000-0000-0000-0000-000000000004';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_client uuid;
  v_private uuid := gen_random_uuid();
  v_public uuid := gen_random_uuid();
  v_unscheduled uuid := gen_random_uuid();
  v_tech_job uuid := gen_random_uuid();
  v_from timestamptz := date_trunc('day', now());
  v_to timestamptz := v_from + interval '14 days';
  v_count int;
  v_ids uuid[];
BEGIN
  SELECT id INTO v_client
  FROM data.contacts
  WHERE tenant_id = v_tenant
  LIMIT 1;

  IF v_client IS NULL THEN
    RAISE EXCEPTION 'seed contact missing for field_visits_tests';
  END IF;

  -- Owner context: seed visits
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_owner,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text, json_build_object('global_role', 'owner', 'sites', json_build_object())
        ),
        'user_permissions', json_build_object(
          v_tenant::text, json_build_object(
            'global_permissions', json_build_array('*'),
            'sites', json_build_object()
          )
        )
      )
    )::text,
    true
  );
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );

  INSERT INTO data.projects (
    id, tenant_id, type, name, status, visibility, site_id, client_id,
    planned_start, planned_end, created_by
  ) VALUES
    (
      v_public, v_tenant, 'work_order', 'FV public visit', 'active', 'company', v_site, v_client,
      v_from + interval '1 day', v_from + interval '1 day 2 hours', v_owner
    ),
    (
      v_private, v_tenant, 'work_order', 'FV private visit', 'active', 'private', NULL, v_client,
      v_from + interval '2 days', v_from + interval '2 days 2 hours', v_owner
    ),
    (
      v_unscheduled, v_tenant, 'work_order', 'FV unscheduled', 'active', 'company', v_site, v_client,
      NULL, NULL, v_owner
    ),
    (
      v_tech_job, v_tenant, 'maintenance', 'FV tech visit', 'active', 'company', v_site, v_client,
      v_from + interval '3 days', v_from + interval '3 days 1 hour', v_owner
    );

  INSERT INTO data.project_members (project_id, user_id, role)
  VALUES (v_tech_job, v_tech, 'contributor')
  ON CONFLICT DO NOTHING;

  -- Inclusive range: visit at +1 day is returned
  SELECT count(*)::int INTO v_count
  FROM api.list_field_visits(v_tenant, v_from, v_to);

  IF v_count < 2 THEN
    RAISE EXCEPTION 'expected at least public+tech visits in range, got %', v_count;
  END IF;

  SELECT array_agg(id) INTO v_ids
  FROM api.list_field_visits(v_tenant, v_from, v_to);

  IF NOT (v_public = ANY (v_ids)) THEN
    RAISE EXCEPTION 'public visit missing from range results';
  END IF;
  IF v_unscheduled = ANY (v_ids) THEN
    RAISE EXCEPTION 'unscheduled visit must not appear in scheduled range';
  END IF;

  -- Unscheduled tray
  SELECT array_agg(id) INTO v_ids
  FROM api.list_field_visits(
    v_tenant, NULL, NULL,
    ARRAY['work_order', 'maintenance']::text[],
    NULL, NULL, true, true, 500
  );

  IF NOT (v_unscheduled = ANY (v_ids)) THEN
    RAISE EXCEPTION 'unscheduled tray missing FV unscheduled';
  END IF;
  IF v_public = ANY (v_ids) THEN
    RAISE EXCEPTION 'scheduled visit must not appear in unscheduled tray';
  END IF;

  -- Technician filter
  SELECT array_agg(id) INTO v_ids
  FROM api.list_field_visits(
    v_tenant, v_from, v_to,
    ARRAY['work_order', 'maintenance']::text[],
    ARRAY[v_tech]::uuid[],
    NULL, true, false, 500
  );

  IF v_ids IS NULL OR NOT (v_tech_job = ANY (v_ids)) THEN
    RAISE EXCEPTION 'technician filter should return FV tech visit';
  END IF;
  IF v_public = ANY (v_ids) THEN
    RAISE EXCEPTION 'technician filter should exclude unassigned public visit';
  END IF;

  -- Member cannot access private OS they are not assigned to.
  -- Auxiliary: can_access_project (SECURITY DEFINER) honours JWT.
  -- Primary: list_field_visits under SET ROLE authenticated so project RLS applies.
  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_member,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text, json_build_object('global_role', 'member', 'sites', json_build_object())
        ),
        'user_permissions', json_build_object(
          v_tenant::text, json_build_object(
            'global_permissions', json_build_array(),
            'sites', json_build_object()
          )
        )
      )
    )::text,
    true
  );

  IF data.can_access_project(v_private) THEN
    RAISE EXCEPTION 'member must not access private visit without membership';
  END IF;
  IF NOT data.can_access_project(v_public) THEN
    RAISE EXCEPTION 'member should still access company-visibility visit';
  END IF;

  SET LOCAL ROLE authenticated;
  SELECT coalesce(array_agg(id), ARRAY[]::uuid[]) INTO v_ids
  FROM api.list_field_visits(v_tenant, v_from, v_to);
  RESET ROLE;

  IF v_private = ANY (v_ids) THEN
    RAISE EXCEPTION 'member must not see private visit via list_field_visits';
  END IF;
  IF NOT (v_public = ANY (v_ids)) THEN
    RAISE EXCEPTION 'member should see company visit via list_field_visits';
  END IF;

  -- Cleanup as owner
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_owner,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text, json_build_object('global_role', 'owner', 'sites', json_build_object())
        ),
        'user_permissions', json_build_object(
          v_tenant::text, json_build_object(
            'global_permissions', json_build_array('*'),
            'sites', json_build_object()
          )
        )
      )
    )::text,
    true
  );

  DELETE FROM data.project_members WHERE project_id IN (v_private, v_public, v_unscheduled, v_tech_job);
  DELETE FROM data.projects WHERE id IN (v_private, v_public, v_unscheduled, v_tech_job);

  RAISE NOTICE 'field_visits_tests OK';
END;
$$;
