-- Project calendar_events must not leak titles to members without project access.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_client uuid;
  v_private uuid := gen_random_uuid();
  v_event uuid;
  v_title text := 'SECRET private calendar title';
  v_seen int;
BEGIN
  SELECT id INTO v_client
  FROM data.contacts
  WHERE tenant_id = v_tenant
  LIMIT 1;

  IF v_client IS NULL THEN
    RAISE EXCEPTION 'seed contact missing for project_calendar_events_access_tests';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
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
  ) VALUES (
    v_private, v_tenant, 'work_order', v_title, 'active', 'private', NULL, v_client,
    date_trunc('day', now()) + interval '1 day',
    date_trunc('day', now()) + interval '1 day 2 hours',
    v_owner
  );

  INSERT INTO data.calendar_events (
    tenant_id, site_id, entity_type, entity_id, title,
    start_at, end_at, required_permissions, owner_id
  ) VALUES (
    v_tenant, v_site, 'project', v_private, v_title,
    date_trunc('day', now()) + interval '1 day',
    date_trunc('day', now()) + interval '1 day 2 hours',
    '{}',
    v_owner
  )
  RETURNING id INTO v_event;

  -- Trigger should have rewritten empty perms
  IF NOT EXISTS (
    SELECT 1 FROM data.calendar_events
    WHERE id = v_event
      AND required_permissions = ARRAY['projects.view']::text[]
  ) THEN
    RAISE EXCEPTION 'project calendar event must not keep empty required_permissions';
  END IF;

  -- Member JWT without project membership
  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
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
            'global_permissions', json_build_array('projects.view', 'calendar.view'),
            'sites', json_build_object()
          )
        )
      )
    )::text,
    true
  );

  SET LOCAL ROLE authenticated;
  SELECT count(*)::int INTO v_seen
  FROM api.calendar_events
  WHERE id = v_event OR title = v_title;
  RESET ROLE;

  IF v_seen > 0 THEN
    RAISE EXCEPTION 'member without project access must not see project calendar title';
  END IF;

  -- Cleanup
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  DELETE FROM data.calendar_events WHERE id = v_event;
  DELETE FROM data.projects WHERE id = v_private;

  RAISE NOTICE 'project_calendar_events_access_tests OK';
END;
$$;
