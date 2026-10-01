-- CF-21-b: coverage + maintenance plan links (no OS gate).
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
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_client uuid;
  v_site uuid;
  v_quote uuid;
  v_agreement uuid;
  v_plan uuid;
  v_link uuid;
  v_retry uuid;
  v_count integer;
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

    INSERT INTO data.contact_sites (tenant_id, contact_id, name, city)
    VALUES (v_tenant, v_client, 'CF21b seu test', 'Barcelona')
    RETURNING id INTO v_site;

    INSERT INTO data.maintenance_plans (
      tenant_id, name, locale, category, vertical, archetype, created_by
    ) VALUES (
      v_tenant, 'CF21b pla test', 'ca', 'general', 'generic', 'field_service', v_owner
    ) RETURNING id INTO v_plan;

    v_quote := api.issue_commercial_document(
      v_project, 'quote', true,
      v_op_1,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote,
      '{"method":"sql_test"}'::jsonb,
      v_op_2
    );
    v_agreement := api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_3,
      'recurring',
      CURRENT_DATE,
      CURRENT_DATE + 365,
      30
    );

    -- Coverage: contact (client)
    v_link := api.link_agreement_coverage(
      v_agreement, 'contact', v_client,
      v_op_4
    );
    v_retry := api.link_agreement_coverage(
      v_agreement, 'contact', v_client,
      v_op_4
    );
    IF v_link IS DISTINCT FROM v_retry THEN
      RAISE EXCEPTION 'CF21b coverage client_op not idempotent';
    END IF;

    v_link := api.link_agreement_coverage(
      v_agreement, 'contact_site', v_site,
      v_op_5
    );
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_coverage WHERE agreement_id = v_agreement;
    IF v_count <> 2 THEN
      RAISE EXCEPTION 'CF21b expected 2 coverage rows, got %', v_count;
    END IF;

    BEGIN
      PERFORM api.link_agreement_coverage(
        v_agreement, 'contact',
        '20000000-0000-0000-0000-000000000099'::uuid,
        v_op_6
      );
      RAISE EXCEPTION 'CF21b foreign contact coverage was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_coverage_client_mismatch%'
         AND SQLERRM NOT LIKE '%agreement_not_found%' THEN
        -- contact may not exist → still mismatch path preferred
        IF SQLERRM NOT LIKE '%agreement_coverage_client_mismatch%' THEN
          RAISE;
        END IF;
      END IF;
    END;

    PERFORM api.unlink_agreement_coverage(
      v_agreement, 'contact_site', v_site,
      v_op_7
    );
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_coverage
    WHERE agreement_id = v_agreement AND entity_type = 'contact_site';
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'CF21b coverage unlink failed';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM data.commercial_agreement_events
      WHERE agreement_id = v_agreement AND event_type = 'coverage_unlinked'
    ) THEN
      RAISE EXCEPTION 'CF21b coverage_unlinked event missing';
    END IF;

    -- Maintenance plan link
    v_link := api.link_agreement_maintenance_plan(
      v_agreement, v_plan,
      v_op_8
    );
    v_retry := api.link_agreement_maintenance_plan(
      v_agreement, v_plan,
      v_op_8
    );
    IF v_link IS DISTINCT FROM v_retry THEN
      RAISE EXCEPTION 'CF21b plan client_op not idempotent';
    END IF;

    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_maintenance_plans WHERE agreement_id = v_agreement;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21b expected 1 plan link, got %', v_count;
    END IF;

    PERFORM api.unlink_agreement_maintenance_plan(
      v_agreement, v_plan,
      v_op_9
    );
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_maintenance_plans WHERE agreement_id = v_agreement;
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'CF21b plan unlink failed';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM data.maintenance_plans WHERE id = v_plan
    ) THEN
      RAISE EXCEPTION 'CF21b plan was deleted on unlink';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'CF-21-b coverage/plans tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'CF-21-b coverage/plans tests passed';
  END;
END;
$$;