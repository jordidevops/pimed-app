-- CT-4: N:M links, audited unlink, and field start gate.
DO $$
DECLARE
  v_op_1 uuid := gen_random_uuid();
  v_op_2 uuid := gen_random_uuid();
  v_op_3 uuid := gen_random_uuid();
  v_op_4 uuid := gen_random_uuid();
  v_op_5 uuid := gen_random_uuid();
  v_op_6 uuid := gen_random_uuid();
  v_op_7 uuid := gen_random_uuid();
  v_op_8 uuid := gen_random_uuid();
  v_op_9 uuid := gen_random_uuid();
  v_op_10 uuid := gen_random_uuid();
  v_op_11 uuid := gen_random_uuid();
  v_op_12 uuid := gen_random_uuid();
  v_op_13 uuid := gen_random_uuid();
  v_op_14 uuid := gen_random_uuid();
  v_op_15 uuid := gen_random_uuid();
  v_op_16 uuid := gen_random_uuid();
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_source uuid := '51000000-0000-0000-0000-000000000101';
  v_project_n uuid := '52000000-0000-0000-0000-000000000401';
  v_project_g uuid := '52000000-0000-0000-0000-000000000402';
  v_site uuid;
  v_client uuid;
  v_quote_n uuid;
  v_quote_g uuid;
  v_none uuid;
  v_gate uuid;
  v_link uuid;
  v_retry uuid;
  v_links integer;
  v_projects integer;
  v_docs integer;
  v_docs_after integer;
  v_hash text;
  v_hash_after text;
  v_version uuid;
  v_result jsonb;
  v_visible integer;
BEGIN
  BEGIN
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
            v_tenant::text, json_build_object('global_permissions', json_build_array('*'), 'sites', json_build_object())
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

    SELECT site_id, client_id INTO v_site, v_client
    FROM data.projects WHERE id = v_source;
    IF v_site IS NULL OR v_client IS NULL THEN
      RAISE EXCEPTION 'CT4 source project missing site or client';
    END IF;

    INSERT INTO data.projects (
      id, tenant_id, type, name, status, visibility, site_id, client_id,
      created_by, commercial_regime, service_mode
    ) VALUES
      (v_project_n, v_tenant, 'work_order', 'CT4 none', 'active', 'company', v_site, v_client, v_owner, 'contractual', 'execute'),
      (v_project_g, v_tenant, 'work_order', 'CT4 gate', 'active', 'company', v_site, v_client, v_owner, 'contractual', 'execute');

    PERFORM api.upsert_project_line(
      v_project_n, NULL, NULL, 'service', 'CT4 none', NULL, 'u',
      1, 10, 0, 21, 0, NULL, v_op_1
    );
    PERFORM api.upsert_project_line(
      v_project_g, NULL, NULL, 'service', 'CT4 gate', NULL, 'u',
      1, 10, 0, 21, 0, NULL, v_op_2
    );

    v_quote_n := api.issue_commercial_document(
      v_project_n, 'quote', true,
      v_op_3,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote_n, '{"method":"sql_test"}'::jsonb,
      v_op_4
    );
    v_none := api.prepare_agreement_from_quote(
      v_quote_n,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_5
    );

    v_quote_g := api.issue_commercial_document(
      v_project_g, 'quote', true,
      v_op_6,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote_g, '{"method":"sql_test"}'::jsonb,
      v_op_7
    );
    v_gate := api.prepare_agreement_from_quote(
      v_quote_g,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'require_signed_agreement',
      v_op_8
    );

    v_link := api.link_agreement_project(
      v_none, v_project_g, v_op_9
    );
    v_retry := api.link_agreement_project(
      v_none, v_project_g, v_op_9
    );
    IF v_link IS NULL OR v_link IS DISTINCT FROM v_retry THEN
      RAISE EXCEPTION 'CT4 link was not idempotent';
    END IF;

    SELECT count(*) INTO v_links
    FROM data.commercial_agreement_projects
    WHERE project_id = v_project_g;
    SELECT count(*) INTO v_projects
    FROM data.commercial_agreement_projects
    WHERE agreement_id = v_none;
    IF v_links <> 2 OR v_projects <> 2 THEN
      RAISE EXCEPTION 'CT4 N:M counts links=% projects=%', v_links, v_projects;
    END IF;

    PERFORM set_config(
      'request.headers',
      '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}',
      true
    );
    SELECT count(*) INTO v_visible
    FROM api.commercial_agreement_projects
    WHERE agreement_id = v_none;
    IF v_visible <> 0 THEN
      RAISE EXCEPTION 'CT4 other tenant saw the links: %', v_visible;
    END IF;
    PERFORM set_config(
      'request.headers',
      json_build_object('x-tenant-id', v_tenant)::text,
      true
    );

    UPDATE data.tenant_members
    SET role = 'member'
    WHERE tenant_id = v_tenant AND user_id = v_member AND site_id IS NULL;
    PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
    PERFORM set_config(
      'request.jwt.claim',
      json_build_object(
        'sub', v_member,
        'role', 'authenticated',
        'app_metadata', json_build_object(
          'user_tenants', json_build_object(
            v_tenant::text, json_build_object('global_role', 'member', 'sites', json_build_object())
          )
        )
      )::text,
      true
    );
    BEGIN
      PERFORM api.link_agreement_project(
        v_none, v_project_n, v_op_10
      );
      RAISE EXCEPTION 'CT4 member link was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%permission_denied%' THEN
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
            v_tenant::text, json_build_object('global_permissions', json_build_array('*'), 'sites', json_build_object())
          )
        )
      )::text,
      true
    );

    INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
    SELECT v_tenant, 'employee_readiness_gate_enabled', false
    WHERE EXISTS (
      SELECT 1 FROM data.feature_flags WHERE key = 'employee_readiness_gate_enabled'
    )
    ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = false;

    BEGIN
      PERFORM api.start_work_log(
        v_op_11,
        v_project_g, NULL, now(), NULL, 'notrequired', NULL
      );
      RAISE EXCEPTION 'CT4 gated start was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_work_gate_blocked%' THEN
        RAISE;
      END IF;
    END;

    v_result := api.start_work_log(
      v_op_12,
      v_project_n, NULL, now(), NULL, 'notrequired', NULL
    );
    IF v_result->>'status' IS DISTINCT FROM 'created' THEN
      RAISE EXCEPTION 'CT4 none-gate start failed: %', v_result;
    END IF;
    PERFORM api.stop_work_log(
      (v_result->>'work_log_id')::uuid,
      NULL, now(), NULL, 'notrequired', false, NULL
    );

    SELECT count(*) INTO v_docs FROM data.documents WHERE tenant_id = v_tenant;
    SELECT v.id, v.content_hash, v.rendered_document_id
    INTO v_version, v_hash, v_retry
    FROM data.commercial_agreement_versions v
    WHERE v.agreement_id = v_none
    ORDER BY v.version_no DESC
    LIMIT 1;

    PERFORM api.unlink_agreement_project(
      v_none, v_project_g, v_op_13
    );
    PERFORM api.unlink_agreement_project(
      v_none, v_project_g, v_op_13
    );

    SELECT count(*) INTO v_docs_after FROM data.documents WHERE tenant_id = v_tenant;
    SELECT content_hash INTO v_hash_after
    FROM data.commercial_agreement_versions WHERE id = v_version;
    IF v_docs_after IS DISTINCT FROM v_docs OR v_hash_after IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'CT4 unlink mutated documents or the version';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM data.commercial_agreement_events
      WHERE agreement_id = v_none AND event_type = 'project_unlinked'
    ) THEN
      RAISE EXCEPTION 'CT4 unlink wrote no event';
    END IF;
    IF EXISTS (
      SELECT 1 FROM data.commercial_agreement_projects
      WHERE agreement_id = v_none AND project_id = v_project_g
    ) THEN
      RAISE EXCEPTION 'CT4 link row survived unlink';
    END IF;

    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature'
    WHERE agreement_id = v_gate;
    BEGIN
      PERFORM api.unlink_agreement_project(
        v_gate, v_project_g, v_op_14
      );
      RAISE EXCEPTION 'CT4 pending unlink was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_unlink_forbidden%' THEN
        RAISE;
      END IF;
    END;

    UPDATE data.commercial_agreements SET status = 'active' WHERE id = v_gate;
    v_result := api.start_work_log(
      v_op_15,
      v_project_g, NULL, now(), NULL, 'notrequired', NULL
    );
    IF v_result->>'status' IS DISTINCT FROM 'created' THEN
      RAISE EXCEPTION 'CT4 active agreement still blocked start: %', v_result;
    END IF;
    PERFORM api.stop_work_log(
      (v_result->>'work_log_id')::uuid,
      NULL, now(), NULL, 'notrequired', false, NULL
    );

    BEGIN
      PERFORM api.unlink_agreement_project(
        v_gate, v_project_g, v_op_16
      );
      RAISE EXCEPTION 'CT4 active unlink was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_unlink_forbidden%' THEN
        RAISE;
      END IF;
    END;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'agreement project link tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: N:M links, audited unlink, work gate';
  END;
END;
$$;
