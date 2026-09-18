-- commercial_regime + service_mode + policy gates
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_person uuid := '80000000-0000-0000-0000-000000000102';
  v_company uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_proj_person uuid := gen_random_uuid();
  v_proj_company uuid := gen_random_uuid();
  v_proj_assess uuid := gen_random_uuid();
  v_proj_waiver uuid := gen_random_uuid();
  v_created_person uuid;
  v_created_company uuid;
  v_follow jsonb;
  v_child uuid;
  v_contractual_close uuid := gen_random_uuid();
  v_block_proj uuid := gen_random_uuid();
  v_old_settings jsonb;
  v_policy jsonb;
  v_err text;
  v_status text;
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

  UPDATE data.contacts
  SET is_consumer = false
  WHERE id = v_company AND tenant_id = v_tenant;

  UPDATE data.contacts
  SET is_consumer = true
  WHERE id = v_person AND tenant_id = v_tenant;

  INSERT INTO data.projects (
    id, tenant_id, type, name, status, visibility, site_id, client_id, created_by
  ) VALUES
    (v_proj_person, v_tenant, 'work_order', 'Regime person', 'active', 'company', v_site, v_person, v_owner),
    (v_proj_company, v_tenant, 'work_order', 'Regime company', 'active', 'company', v_site, v_company, v_owner),
    (v_proj_assess, v_tenant, 'work_order', 'Assessment visit', 'active', 'company', v_site, v_person, v_owner),
    (v_proj_waiver, v_tenant, 'work_order', 'Waiver consumer', 'active', 'company', v_site, v_person, v_owner);

  IF (SELECT commercial_regime FROM data.projects WHERE id = v_proj_person) IS DISTINCT FROM 'consumer' THEN
    RAISE EXCEPTION 'expected consumer regime for person contact';
  END IF;
  IF (SELECT commercial_regime FROM data.projects WHERE id = v_proj_company) IS DISTINCT FROM 'contractual' THEN
    RAISE EXCEPTION 'expected contractual regime for company contact';
  END IF;

  PERFORM api.set_project_commercial_regime(v_proj_person, 'contractual');
  IF (SELECT commercial_regime FROM data.projects WHERE id = v_proj_person) IS DISTINCT FROM 'contractual' THEN
    RAISE EXCEPTION 'set_project_commercial_regime failed';
  END IF;
  PERFORM api.set_project_commercial_regime(v_proj_person, 'consumer');

  PERFORM api.set_project_service_mode(v_proj_assess, 'assessment');
  v_policy := data.project_commercial_policy(v_proj_assess);
  IF v_policy->>'service_mode' IS DISTINCT FROM 'assessment'
     OR v_policy->>'overage_on_close' IS DISTINCT FROM 'off' THEN
    RAISE EXCEPTION 'assessment policy expected off overage: %', v_policy;
  END IF;

  PERFORM api.upsert_project_line(
    v_proj_assess, NULL, NULL, 'service', 'Nota avaluacio', NULL, 'u',
    1, 80, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_status := data.complete_project_close_out_offline(
    v_proj_assess, gen_random_uuid(), NULL
  )->>'project_status';
  IF v_status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'assessment close expected completed, got %', v_status;
  END IF;

  PERFORM api.upsert_project_line(
    v_proj_person, NULL, NULL, 'service', 'Feina cara', NULL, 'u',
    1, 200, 0, 21, 0, NULL, gen_random_uuid()
  );
  BEGIN
    PERFORM api.issue_commercial_document(
      v_proj_person, 'delivery_note', true, gen_random_uuid(), NULL
    );
    RAISE EXCEPTION 'expected delivery_note_exceeds_authorized_total';
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err NOT LIKE 'delivery_note_exceeds_authorized_total%' THEN
        RAISE;
      END IF;
  END;

  PERFORM api.upsert_project_line(
    v_proj_waiver, NULL, NULL, 'service', 'Feina waiver', NULL, 'u',
    1, 150, 0, 21, 0, NULL, gen_random_uuid()
  );
  PERFORM api.create_quote_waiver(
    v_proj_waiver,
    'Renuncio al pressupost previ.',
    'Reparacio urgent',
    jsonb_build_object('type', 'drawn', 'data', 'x'),
    gen_random_uuid()
  );
  v_status := data.complete_project_close_out_offline(
    v_proj_waiver, gen_random_uuid(), NULL
  )->>'project_status';
  IF v_status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'waiver consumer close expected completed, got %', v_status;
  END IF;

  BEGIN
    PERFORM api.issue_commercial_document(
      v_proj_assess, 'delivery_note', true, gen_random_uuid(), NULL
    );
    RAISE EXCEPTION 'expected assessment_requires_quote_first';
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err NOT LIKE 'assessment_requires_quote_first%' THEN
        RAISE;
      END IF;
  END;

  PERFORM api.set_contact_is_consumer(v_company, true);
  IF NOT (SELECT is_consumer FROM data.contacts WHERE id = v_company) THEN
    RAISE EXCEPTION 'set_contact_is_consumer failed';
  END IF;
  PERFORM api.set_contact_is_consumer(v_company, false);

  -- RPC create_project inherits regime from contact
  v_created_person := api.create_project(
    v_tenant, 'RPC person OS', 'work_order', NULL, 'active', 'company',
    NULL, v_site, NULL, v_person, NULL, NULL, NULL
  );
  IF (SELECT commercial_regime FROM data.projects WHERE id = v_created_person)
     IS DISTINCT FROM 'consumer' THEN
    RAISE EXCEPTION 'create_project person expected consumer';
  END IF;
  IF (SELECT service_mode FROM data.projects WHERE id = v_created_person)
     IS DISTINCT FROM 'execute' THEN
    RAISE EXCEPTION 'create_project expected execute service_mode';
  END IF;

  v_created_company := api.create_project(
    v_tenant, 'RPC company OS', 'work_order', NULL, 'active', 'company',
    NULL, v_site, NULL, v_company, NULL, NULL, NULL
  );
  IF (SELECT commercial_regime FROM data.projects WHERE id = v_created_company)
     IS DISTINCT FROM 'contractual' THEN
    RAISE EXCEPTION 'create_project company expected contractual';
  END IF;

  -- Follow-up from assessment+contractual → execute + same regime
  PERFORM api.set_project_service_mode(v_created_company, 'assessment');
  PERFORM api.set_project_commercial_regime(v_created_company, 'contractual');
  v_follow := api.create_follow_up_work_order(
    v_created_company, 'Seguiment contractual', false, NULL
  );
  v_child := COALESCE(
    (v_follow->>'project_id')::uuid,
    (v_follow->>'id')::uuid
  );
  IF v_child IS NULL THEN
    RAISE EXCEPTION 'follow_up missing project_id: %', v_follow;
  END IF;
  IF (SELECT service_mode FROM data.projects WHERE id = v_child)
     IS DISTINCT FROM 'execute' THEN
    RAISE EXCEPTION 'follow_up expected execute, got %',
      (SELECT service_mode FROM data.projects WHERE id = v_child);
  END IF;
  IF (SELECT commercial_regime FROM data.projects WHERE id = v_child)
     IS DISTINCT FROM 'contractual' THEN
    RAISE EXCEPTION 'follow_up expected contractual regime';
  END IF;

  -- Contractual default: overage close allowed (warn)
  INSERT INTO data.projects (
    id, tenant_id, type, name, status, visibility, site_id, client_id,
    created_by, commercial_regime, service_mode
  ) VALUES (
    v_contractual_close, v_tenant, 'work_order', 'Contractual overage',
    'active', 'company', v_site, v_company, v_owner, 'contractual', 'execute'
  );
  PERFORM api.upsert_project_line(
    v_contractual_close, NULL, NULL, 'service', 'Extra', NULL, 'u',
    1, 500, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_status := data.complete_project_close_out_offline(
    v_contractual_close, gen_random_uuid(), NULL
  )->>'project_status';
  IF v_status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'contractual overage close expected completed, got %', v_status;
  END IF;

  -- Tenant policy block on contractual overage_on_close
  SELECT settings INTO v_old_settings FROM data.tenants WHERE id = v_tenant;
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb) || jsonb_build_object(
    'commercial',
    COALESCE(settings->'commercial', '{}'::jsonb) || jsonb_build_object(
      'regimes',
      COALESCE(settings->'commercial'->'regimes', '{}'::jsonb) || jsonb_build_object(
        'contractual',
        jsonb_build_object(
          'require_auth_before_work', 'off',
          'overage_on_close', 'block',
          'overage_on_delivery', 'warn'
        )
      )
    )
  )
  WHERE id = v_tenant;

  INSERT INTO data.projects (
    id, tenant_id, type, name, status, visibility, site_id, client_id,
    created_by, commercial_regime, service_mode
  ) VALUES (
    v_block_proj, v_tenant, 'work_order', 'Contractual block',
    'active', 'company', v_site, v_company, v_owner, 'contractual', 'execute'
  );
  PERFORM api.upsert_project_line(
    v_block_proj, NULL, NULL, 'service', 'Extra block', NULL, 'u',
    1, 400, 0, 21, 0, NULL, gen_random_uuid()
  );
  BEGIN
    PERFORM data.complete_project_close_out_offline(
      v_block_proj, gen_random_uuid(), NULL
    );
    RAISE EXCEPTION 'expected consumer_overage_requires_amendment on contractual block';
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err NOT LIKE 'consumer_overage_requires_amendment%' THEN
        RAISE;
      END IF;
  END;

  UPDATE data.tenants SET settings = v_old_settings WHERE id = v_tenant;

  RAISE NOTICE 'commercial_regime_assessment_tests OK';
END;
$$;
