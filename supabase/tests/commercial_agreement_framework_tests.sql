-- CF-21-d: framework without quote; source_quote nullable.
DO $$
DECLARE
  v_op_1 uuid := gen_random_uuid();
  v_op_2 uuid := gen_random_uuid();
  v_op_3 uuid := gen_random_uuid();
  v_op_4 uuid := gen_random_uuid();
  v_op_5 uuid := gen_random_uuid();
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_client uuid;
  v_agreement uuid;
  v_retry uuid;
  v_quote uuid;
  v_kind text;
  v_src uuid;
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

    SELECT client_id INTO v_client FROM data.projects WHERE id = v_project;

    v_agreement := api.create_framework_agreement(
      v_tenant,
      v_client,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_1,
      CURRENT_DATE,
      CURRENT_DATE + 365,
      30,
      'ca'
    );

    SELECT kind, source_quote_id INTO v_kind, v_src
    FROM data.commercial_agreements WHERE id = v_agreement;
    IF v_kind IS DISTINCT FROM 'framework' THEN
      RAISE EXCEPTION 'CF21d expected framework kind, got %', v_kind;
    END IF;
    IF v_src IS NOT NULL THEN
      RAISE EXCEPTION 'CF21d framework must have null source_quote_id';
    END IF;

    v_retry := api.create_framework_agreement(
      v_tenant,
      v_client,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_1,
      CURRENT_DATE,
      CURRENT_DATE + 365,
      30,
      'ca'
    );
    IF v_retry IS DISTINCT FROM v_agreement THEN
      RAISE EXCEPTION 'CF21d create_framework not idempotent';
    END IF;

    BEGIN
      PERFORM api.create_framework_agreement(
        v_tenant,
        v_client,
        '76100000-0000-0000-0000-000000000001'::uuid,
        'none',
        v_op_2,
        CURRENT_DATE,
        NULL,
        30,
        'ca'
      );
      RAISE EXCEPTION 'CF21d allowed framework without ends_on';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%recurring_ends_on_required%' THEN
        RAISE;
      END IF;
    END;

    -- project kind still reserved
    BEGIN
      INSERT INTO data.commercial_agreements (
        tenant_id, client_id, kind, source_quote_id, work_gate, created_by
      ) VALUES (
        v_tenant, v_client, 'project', NULL, 'none', v_owner
      );
      RAISE EXCEPTION 'CF21d allowed project kind';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_kind_reserved%' THEN
        RAISE;
      END IF;
    END;

    -- prepare still works with quote + framework kind
    v_quote := api.issue_commercial_document(
      v_project, 'quote', true,
      v_op_3,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote,
      '{"method":"sql_test"}'::jsonb,
      v_op_4
    );
    v_agreement := api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_5,
      'framework',
      CURRENT_DATE,
      CURRENT_DATE + 180,
      15
    );
    SELECT kind INTO v_kind FROM data.commercial_agreements WHERE id = v_agreement;
    IF v_kind IS DISTINCT FROM 'framework' THEN
      RAISE EXCEPTION 'CF21d prepare framework kind failed';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'commercial_agreement_framework_tests OK';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN
      RAISE NOTICE 'commercial_agreement_framework_tests OK';
    WHEN OTHERS THEN
      RAISE EXCEPTION 'commercial_agreement_framework_tests FAILED: %', SQLERRM;
  END;
END;
$$;
