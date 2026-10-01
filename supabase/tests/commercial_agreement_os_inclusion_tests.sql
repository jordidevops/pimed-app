-- CF-21-c: included vs extra for OS from maintenance plans.
DO $$
DECLARE
  v_op_1 uuid := gen_random_uuid();
  v_op_2 uuid := gen_random_uuid();
  v_op_3 uuid := gen_random_uuid();
  v_op_4 uuid := gen_random_uuid();
  v_op_5 uuid := gen_random_uuid();
  v_op_6 uuid := gen_random_uuid();
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_source_project uuid := '51000000-0000-0000-0000-000000000101';
  v_client uuid;
  v_site uuid;
  v_quote uuid;
  v_agreement uuid;
  v_plan uuid;
  v_assignment uuid;
  v_os uuid;
  v_site_id uuid;
  v_result jsonb;
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

    SELECT client_id, site_id INTO v_client, v_site_id
    FROM data.projects WHERE id = v_source_project;

    INSERT INTO data.contact_sites (tenant_id, contact_id, name, city)
    VALUES (v_tenant, v_client, 'CF21c seu', 'Barcelona')
    RETURNING id INTO v_site;

    INSERT INTO data.maintenance_plans (
      tenant_id, name, locale, category, vertical, archetype, created_by
    ) VALUES (
      v_tenant, 'CF21c pla', 'ca', 'general', 'generic', 'field_service', v_owner
    ) RETURNING id INTO v_plan;

    INSERT INTO data.maintenance_plan_assignments (
      tenant_id, plan_id, entity_type, entity_id, frequency, next_due_at
    ) VALUES (
      v_tenant, v_plan, 'contact_site', v_site, 'monthly', now()
    ) RETURNING id INTO v_assignment;

    INSERT INTO data.projects (
      tenant_id, type, name, status, visibility, site_id,
      client_id, contact_site_id, planned_start, planned_end, created_by
    ) VALUES (
      v_tenant, 'maintenance', 'CF21c OS inclosa', 'active', 'company', v_site_id,
      v_client, v_site, now(), now() + interval '2 hours', v_owner
    ) RETURNING id INTO v_os;

    INSERT INTO data.maintenance_occurrences (
      tenant_id, assignment_id, due_at, status, project_id, generated_at
    ) VALUES (
      v_tenant, v_assignment, now(), 'generated', v_os, now()
    );

    -- No agreement linked → extra
    v_result := api.get_project_commercial_inclusion(v_os);
    IF v_result->>'status' IS DISTINCT FROM 'extra' THEN
      RAISE EXCEPTION 'CF21c expected extra without agreement, got %', v_result;
    END IF;

    -- Ordinary project (no occurrence) → none
    v_result := api.get_project_commercial_inclusion(v_source_project);
    IF v_result->>'status' IS DISTINCT FROM 'none' THEN
      RAISE EXCEPTION 'CF21c expected none for non-plan OS, got %', v_result;
    END IF;

    v_quote := api.issue_commercial_document(
      v_source_project, 'quote', true,
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

    PERFORM api.link_agreement_maintenance_plan(
      v_agreement, v_plan,
      v_op_4
    );

    -- Agreement not active yet → still extra
    v_result := api.get_project_commercial_inclusion(v_os);
    IF v_result->>'status' IS DISTINCT FROM 'extra' THEN
      RAISE EXCEPTION 'CF21c expected extra while agreement pending, got %', v_result;
    END IF;

    UPDATE data.commercial_agreements SET status = 'active' WHERE id = v_agreement;

    -- No coverage rows → plan link + active is enough → included
    v_result := api.get_project_commercial_inclusion(v_os);
    IF v_result->>'status' IS DISTINCT FROM 'included' THEN
      RAISE EXCEPTION 'CF21c expected included after activate, got %', v_result;
    END IF;
    IF (v_result->>'agreement_id')::uuid IS DISTINCT FROM v_agreement THEN
      RAISE EXCEPTION 'CF21c wrong agreement_id';
    END IF;
    IF NOT data.project_is_agreement_included(v_os) THEN
      RAISE EXCEPTION 'CF21c boolean helper false for included';
    END IF;

    -- Coverage that misses the OS entity → extra
    PERFORM api.link_agreement_coverage(
      v_agreement, 'contact', v_client,
      v_op_5
    );
    -- contact coverage matches client → still included
    v_result := api.get_project_commercial_inclusion(v_os);
    IF v_result->>'status' IS DISTINCT FROM 'included' THEN
      RAISE EXCEPTION 'CF21c expected included with contact coverage, got %', v_result;
    END IF;

    DELETE FROM data.commercial_agreement_coverage WHERE agreement_id = v_agreement;
    INSERT INTO data.contact_sites (tenant_id, contact_id, name, city)
    VALUES (v_tenant, v_client, 'CF21c altra seu', 'Girona')
    RETURNING id INTO v_site;

    PERFORM api.link_agreement_coverage(
      v_agreement, 'contact_site', v_site,
      v_op_6
    );

    v_result := api.get_project_commercial_inclusion(v_os);
    IF v_result->>'status' IS DISTINCT FROM 'extra' THEN
      RAISE EXCEPTION 'CF21c expected extra on coverage miss, got %', v_result;
    END IF;
    IF v_result->>'reason' IS DISTINCT FROM 'coverage_miss' THEN
      RAISE EXCEPTION 'CF21c expected coverage_miss reason, got %', v_result;
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'commercial_agreement_os_inclusion_tests OK';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN
      RAISE NOTICE 'commercial_agreement_os_inclusion_tests OK';
    WHEN OTHERS THEN
      RAISE EXCEPTION 'commercial_agreement_os_inclusion_tests FAILED: %', SQLERRM;
  END;
END;
$$;
