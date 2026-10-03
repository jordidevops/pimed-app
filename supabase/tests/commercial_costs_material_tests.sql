-- commercial.costs.view + private material cost. Rolls back.
-- Each DO sets the role itself: SET ROLE inside a finished DO does not leak,
-- and a nested helper would reset the role before the assertions.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000cf9';
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api'
      AND table_name = 'project_materials'
      AND column_name = 'unit_cost_cents'
  ) THEN
    RAISE EXCEPTION 'api.project_materials must not expose unit_cost_cents';
  END IF;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'Cost slice', 'disposable',
    'active', 'company', v_site, v_client, v_owner
  );

  INSERT INTO data.tenant_members (tenant_id, user_id, role)
  VALUES
    (v_tenant, v_manager, 'manager'),
    (v_tenant, v_member, 'member');

  -- jsonb_set does not create missing parents. Merge the object the same way
  -- update_tenant_role_permissions does. Custom member replaces the base, so
  -- commercial.pricing.edit (member default) is absent for the price trigger.
  UPDATE data.tenants
  SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
    'role_permissions', jsonb_build_object('member', '["storage.upload"]'::jsonb)
  )
  WHERE id = v_tenant;
END;
$$;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000cf9';
  v_material uuid;
  v_count int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_member,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text,
          json_build_object('global_role', 'member', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );
  SET ROLE authenticated;

  v_material := (
    api.add_project_material(
      v_project, 'Cable', 1, 'u', NULL, NULL,
      'cf130000-0000-0000-0000-000000000001'::uuid
    ) ->> 'result_id'
  )::uuid;
  PERFORM set_config('test.material_id', v_material::text, true);

  IF EXISTS (
    SELECT 1 FROM data.project_material_costs WHERE material_id = v_material
  ) THEN
    RAISE EXCEPTION 'add_project_material must not create a cost row';
  END IF;

  SELECT count(*) INTO v_count
  FROM api.project_material_costs
  WHERE material_id = v_material;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'member must not see material costs';
  END IF;

  BEGIN
    PERFORM api.set_project_material_amounts(
      v_material, '{"unit_cost_cents": 500}'::jsonb
    );
    RAISE EXCEPTION 'member cost write should have failed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%permission_denied:commercial.costs.view%' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    UPDATE data.project_materials
    SET unit_price_cents = 900
    WHERE id = v_material;
    RAISE EXCEPTION 'member price write should have failed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%permission_denied:commercial.pricing.edit%' THEN
        RAISE;
      END IF;
  END;

  IF EXISTS (
    SELECT 1 FROM data.project_materials
    WHERE id = v_material AND unit_price_cents IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'member must not persist a sale price';
  END IF;
END;
$$;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_material uuid;
  v_cost int;
BEGIN
  v_material := current_setting('test.material_id')::uuid;

  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_manager,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text,
          json_build_object('global_role', 'manager', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );
  SET ROLE authenticated;

  PERFORM api.set_project_material_amounts(
    v_material,
    '{"unit_price_cents": 1200, "unit_cost_cents": 400}'::jsonb
  );

  SELECT unit_cost_cents INTO v_cost
  FROM api.project_material_costs
  WHERE material_id = v_material;
  IF v_cost IS DISTINCT FROM 400 THEN
    RAISE EXCEPTION 'manager expected cost 400, got %', v_cost;
  END IF;

  SELECT unit_price_cents INTO v_cost
  FROM data.project_materials
  WHERE id = v_material;
  IF v_cost IS DISTINCT FROM 1200 THEN
    RAISE EXCEPTION 'manager expected price 1200, got %', v_cost;
  END IF;
END;
$$;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_material uuid;
  v_cost int;
BEGIN
  v_material := current_setting('test.material_id')::uuid;

  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_member,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text,
          json_build_object(
            'global_role', 'member',
            'sites', json_build_object(v_site::text, 'manager')
          )
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );
  SET ROLE authenticated;

  SELECT unit_cost_cents INTO v_cost
  FROM api.project_material_costs
  WHERE material_id = v_material;
  IF v_cost IS DISTINCT FROM 400 THEN
    RAISE EXCEPTION 'site manager expected cost 400, got %', v_cost;
  END IF;
END;
$$;

RESET ROLE;

UPDATE data.tenants
SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
  'role_permissions', jsonb_build_object('member', '["commercial.costs.view"]'::jsonb)
)
WHERE id = '10000000-0000-0000-0000-000000000003';

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_material uuid;
  v_cost int;
BEGIN
  v_material := current_setting('test.material_id')::uuid;

  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_member,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text,
          json_build_object('global_role', 'member', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );
  SET ROLE authenticated;

  SELECT unit_cost_cents INTO v_cost
  FROM api.project_material_costs
  WHERE material_id = v_material;
  IF v_cost IS DISTINCT FROM 400 THEN
    RAISE EXCEPTION 'granted member expected cost 400, got %', v_cost;
  END IF;

  RAISE NOTICE 'commercial costs material tests passed';
END;
$$;

ROLLBACK;
