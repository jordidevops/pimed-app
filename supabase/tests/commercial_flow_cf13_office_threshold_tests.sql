-- CF-13: office threshold gate on quote_amendment accept + pending blocks delivery.
-- Kept as one statement so `supabase db query --file` can execute it.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000cf3';
  v_quote uuid;
  v_amend uuid;
  v_status text;
  v_prev_settings jsonb;
  v_threshold numeric;
BEGIN
  INSERT INTO data.tenant_members (tenant_id, user_id, role)
  VALUES (v_tenant, v_member, 'member')
  ON CONFLICT (tenant_id, user_id) WHERE site_id IS NULL DO NOTHING;

  SELECT settings INTO v_prev_settings FROM data.tenants WHERE id = v_tenant;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb) || jsonb_build_object(
    'commercial', jsonb_build_object('deviation_approval_threshold_eur', 10)
  )
  WHERE id = v_tenant;

  v_threshold := data.commercial_deviation_approval_threshold_eur(v_tenant);
  IF v_threshold IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION 'T0 threshold helper failed: %', v_threshold;
  END IF;

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
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project,
    v_tenant,
    'work_order',
    'CF-13 threshold test',
    'Disposable project for SQL tests',
    'active',
    'company',
    v_site,
    v_client,
    v_owner
  )
  ON CONFLICT (id) DO UPDATE SET
    status = 'active',
    client_id = EXCLUDED.client_id,
    updated_at = now();

  DELETE FROM data.commercial_document_events
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  DELETE FROM data.commercial_document_lines
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  DELETE FROM data.commercial_documents WHERE project_id = v_project;
  DELETE FROM data.project_lines WHERE project_id = v_project;

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Base CF-13', NULL, 'u',
    1, 100, 0, 21, 0, NULL,
    'cf130000-0000-0000-0000-000000000001'::uuid
  );

  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf130000-0000-0000-0000-000000000002'::uuid,
    NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote,
    '{"method":"sql_test"}'::jsonb,
    'cf130000-0000-0000-0000-000000000003'::uuid
  );

  -- Extra line → overage ~60.5 € (> threshold 10).
  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Extra CF-13', NULL, 'u',
    1, 50, 0, 21, 1, NULL,
    'cf130000-0000-0000-0000-000000000004'::uuid
  );

  v_amend := api.issue_commercial_document(
    v_project, 'quote_amendment', true,
    'cf130000-0000-0000-0000-000000000005'::uuid,
    v_quote
  );

  BEGIN
    PERFORM api.issue_commercial_document(
      v_project, 'delivery_note', true,
      'cf130000-0000-0000-0000-000000000006'::uuid,
      NULL
    );
    RAISE EXCEPTION 'T1 pending amendment did not block delivery note';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%pending_amendment_blocks_delivery%' THEN
      RAISE;
    END IF;
  END;

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
            'global_permissions', json_build_array(),
            'sites', json_build_object()
          )
        )
      )
    )::text,
    true
  );

  BEGIN
    PERFORM api.accept_commercial_document(
      v_amend,
      '{"method":"sql_test_member"}'::jsonb,
      'cf130000-0000-0000-0000-000000000007'::uuid
    );
    RAISE EXCEPTION 'T2 member accepted over-threshold amendment';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%office_approval_required%' THEN
      RAISE;
    END IF;
  END;

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

  PERFORM api.accept_commercial_document(
    v_amend,
    '{"method":"sql_test_owner"}'::jsonb,
    'cf130000-0000-0000-0000-000000000008'::uuid
  );

  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_amend;
  IF v_status IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'T3 owner accept failed: status=%', v_status;
  END IF;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb) || jsonb_build_object(
    'commercial', jsonb_build_object('deviation_approval_threshold_eur', 0)
  )
  WHERE id = v_tenant;

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Extra2 CF-13', NULL, 'u',
    1, 20, 0, 21, 2, NULL,
    'cf130000-0000-0000-0000-000000000009'::uuid
  );

  v_amend := api.issue_commercial_document(
    v_project, 'quote_amendment', true,
    'cf130000-0000-0000-0000-00000000000a'::uuid,
    v_quote
  );
  PERFORM api.accept_commercial_document(
    v_amend,
    '{"method":"sql_test_threshold0"}'::jsonb,
    'cf130000-0000-0000-0000-00000000000b'::uuid
  );

  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_amend;
  IF v_status IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'T4 threshold-0 owner accept failed: status=%', v_status;
  END IF;

  UPDATE data.tenants
  SET settings = COALESCE(v_prev_settings, '{}'::jsonb)
  WHERE id = v_tenant;

  RAISE NOTICE 'CF-13 office threshold tests passed';
END;
$$;
