-- delete_manual_calendar_event: owner/manage OK; stranger KO; derived KO.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_stranger uuid := '20000000-0000-0000-0000-000000000099';
  v_manual_id uuid;
  v_task_id uuid;
  v_result jsonb;
BEGIN
  INSERT INTO data.calendar_events (
    tenant_id, site_id, entity_type, entity_id, title, start_at, end_at, all_day,
    required_permissions, owner_id
  ) VALUES (
    v_tenant, NULL, 'manual', gen_random_uuid(), 'Manual test',
    timestamptz '2026-10-05 09:00:00+00', NULL, false,
    ARRAY['calendar.view'], v_owner
  ) RETURNING id INTO v_manual_id;

  INSERT INTO data.calendar_events (
    tenant_id, site_id, entity_type, entity_id, title, start_at, end_at, all_day,
    required_permissions, owner_id
  ) VALUES (
    v_tenant, NULL, 'task', gen_random_uuid(), 'Task event',
    timestamptz '2026-10-05 10:00:00+00', NULL, false,
    ARRAY['calendar.view'], v_owner
  ) RETURNING id INTO v_task_id;

  -- Owner can delete own manual
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

  v_result := api.delete_manual_calendar_event(v_manual_id);
  IF (v_result->>'deleted')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'owner delete failed: %', v_result;
  END IF;

  -- Recreate manual for stranger test
  INSERT INTO data.calendar_events (
    tenant_id, site_id, entity_type, entity_id, title, start_at, end_at, all_day,
    required_permissions, owner_id
  ) VALUES (
    v_tenant, NULL, 'manual', gen_random_uuid(), 'Manual 2',
    timestamptz '2026-10-06 09:00:00+00', NULL, false,
    ARRAY['calendar.view'], v_owner
  ) RETURNING id INTO v_manual_id;

  -- Stranger member without manage cannot delete
  PERFORM set_config('request.jwt.claim.sub', v_stranger::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_stranger,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text, json_build_object('global_role', 'member', 'sites', json_build_object())
        ),
        'user_permissions', json_build_object(
          v_tenant::text, json_build_object(
            'global_permissions', json_build_array('calendar.view', 'calendar.edit'),
            'sites', json_build_object()
          )
        )
      )
    )::text,
    true
  );

  BEGIN
    PERFORM api.delete_manual_calendar_event(v_manual_id);
    RAISE EXCEPTION 'stranger delete should have failed';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT ILIKE '%forbidden%' THEN
        RAISE EXCEPTION 'unexpected stranger error: %', SQLERRM;
      END IF;
  END;

  -- Derived task cannot be deleted via this RPC (as owner)
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

  BEGIN
    PERFORM api.delete_manual_calendar_event(v_task_id);
    RAISE EXCEPTION 'derived delete should have failed';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT ILIKE '%not_manual_event%' THEN
        RAISE EXCEPTION 'unexpected derived error: %', SQLERRM;
      END IF;
  END;

  RAISE NOTICE 'delete_manual_calendar_event_tests ok';
END;
$$;

ROLLBACK;
