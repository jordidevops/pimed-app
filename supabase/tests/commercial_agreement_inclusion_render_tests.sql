-- CF-21-h6: deterministic inclusion — project link wins; else ambiguous if >1 candidate.
DO $$
DECLARE
  v_op_1 uuid := gen_random_uuid();
  v_op_2 uuid := gen_random_uuid();
  v_op_3 uuid := gen_random_uuid();
  v_op_4 uuid := gen_random_uuid();
  v_op_5 uuid := gen_random_uuid();
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_source_project uuid := '51000000-0000-0000-0000-000000000101';
  v_client uuid;
  v_site uuid;
  v_site_id uuid;
  v_plan uuid;
  v_assignment uuid;
  v_os uuid;
  v_a1 uuid;
  v_a2 uuid;
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
    VALUES (v_tenant, v_client, 'CF21h6 seu', 'Barcelona')
    RETURNING id INTO v_site;

    INSERT INTO data.maintenance_plans (
      tenant_id, name, locale, category, vertical, archetype, created_by
    ) VALUES (
      v_tenant, 'CF21h6 pla', 'ca', 'general', 'generic', 'field_service', v_owner
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
      v_tenant, 'maintenance', 'CF21h6 OS', 'active', 'company', v_site_id,
      v_client, v_site, now(), now() + interval '2 hours', v_owner
    ) RETURNING id INTO v_os;

    INSERT INTO data.maintenance_occurrences (
      tenant_id, assignment_id, due_at, status, project_id, generated_at
    ) VALUES (
      v_tenant, v_assignment, now(), 'generated', v_os, now()
    );

    v_a1 := api.create_framework_agreement(
      v_tenant, v_client,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_1,
      CURRENT_DATE, CURRENT_DATE + 365, 30, 'ca'
    );
    v_a2 := api.create_framework_agreement(
      v_tenant, v_client,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_2,
      CURRENT_DATE, CURRENT_DATE + 365, 30, 'ca'
    );

    UPDATE data.commercial_agreements SET status = 'active' WHERE id IN (v_a1, v_a2);

    PERFORM api.link_agreement_maintenance_plan(
      v_a1, v_plan, v_op_3
    );
    PERFORM api.link_agreement_maintenance_plan(
      v_a2, v_plan, v_op_4
    );

    v_result := data.project_commercial_inclusion(v_os);
    IF (v_result->>'reason') IS DISTINCT FROM 'ambiguous_agreements' THEN
      RAISE EXCEPTION 'CF21h6 expected ambiguous, got %', v_result;
    END IF;

    PERFORM api.link_agreement_project(
      v_a2, v_os, v_op_5
    );
    v_result := data.project_commercial_inclusion(v_os);
    IF (v_result->>'status') IS DISTINCT FROM 'included'
       OR (v_result->>'agreement_id')::uuid IS DISTINCT FROM v_a2 THEN
      RAISE EXCEPTION 'CF21h6 expected linked agreement %, got %', v_a2, v_result;
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'CF-21-h6 inclusion/render tests PASS';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN
      RAISE NOTICE 'CF-21-h6 inclusion/render tests PASS';
    WHEN OTHERS THEN
      RAISE EXCEPTION 'CF-21-h6 inclusion/render tests FAIL: %', SQLERRM;
  END;
END;
$$;
