-- CF-19 catalog + project line financials. Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000c19';
  v_catalog uuid := '71000000-0000-0000-0000-000000000c19';
  v_template uuid := '72000000-0000-0000-0000-000000000c19';
  v_tmpl_item uuid := '72100000-0000-0000-0000-000000000c19';
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'catalog_items'
      AND column_name IN ('unit_cost_cents', 'target_margin_bps')
  ) THEN
    RAISE EXCEPTION 'api.catalog_items must not expose cost/margin columns';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'project_lines'
      AND column_name IN ('unit_cost_cents', 'target_margin_bps')
  ) THEN
    RAISE EXCEPTION 'api.project_lines must not expose cost/margin columns';
  END IF;

  IF data.suggest_pvp_euros_from_cost(1000, 5000) IS DISTINCT FROM 20.0000 THEN
    RAISE EXCEPTION 'suggest_pvp formula failed: %',
      data.suggest_pvp_euros_from_cost(1000, 5000);
  END IF;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-19 financials', 'disposable',
    'active', 'company', v_site, v_client, v_owner
  );

  INSERT INTO data.tenant_members (tenant_id, user_id, role)
  VALUES
    (v_tenant, v_manager, 'manager'),
    (v_tenant, v_member, 'member')
  ON CONFLICT DO NOTHING;

  UPDATE data.tenants
  SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
    'role_permissions', jsonb_build_object('member', '["storage.upload"]'::jsonb)
  )
  WHERE id = v_tenant;

  INSERT INTO data.catalog_items (
    id, tenant_id, kind, name, unit, unit_price, tax_rate, is_active
  ) VALUES (
    v_catalog, v_tenant, 'service', 'CF19 Cable', 'u', 25.50, 21, true
  );

  INSERT INTO data.pricing_templates (
    id, tenant_id, name, is_active
  ) VALUES (
    v_template, v_tenant, 'CF19 pack', true
  );

  INSERT INTO data.pricing_template_items (
    id, tenant_id, template_id, catalog_item_id, default_quantity, position
  ) VALUES (
    v_tmpl_item, v_tenant, v_template, v_catalog, 1, 0
  );
END;
$$;

-- Manager sets catalog cost + margin
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_catalog uuid := '71000000-0000-0000-0000-000000000c19';
  v_cost int;
  v_bps int;
BEGIN
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

  PERFORM api.set_catalog_item_financials(
    v_catalog,
    '{"unit_cost_cents": 1200, "target_margin_bps": 5000}'::jsonb
  );

  SELECT unit_cost_cents, target_margin_bps INTO v_cost, v_bps
  FROM api.catalog_item_financials
  WHERE catalog_item_id = v_catalog;

  IF v_cost IS DISTINCT FROM 1200 OR v_bps IS DISTINCT FROM 5000 THEN
    RAISE EXCEPTION 'manager catalog financials mismatch: % / %', v_cost, v_bps;
  END IF;
END;
$$;

RESET ROLE;

-- Member cannot read/write catalog financials
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_catalog uuid := '71000000-0000-0000-0000-000000000c19';
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

  SELECT count(*) INTO v_count
  FROM api.catalog_item_financials
  WHERE catalog_item_id = v_catalog;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'member must not see catalog financials';
  END IF;

  BEGIN
    PERFORM api.set_catalog_item_financials(
      v_catalog, '{"unit_cost_cents": 1}'::jsonb
    );
    RAISE EXCEPTION 'member catalog cost write should have failed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%permission_denied:commercial.costs.view%' THEN
        RAISE;
      END IF;
  END;
END;
$$;

RESET ROLE;

-- Member apply_pricing_template copies cost; member cannot SELECT it; manager can
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000c19';
  v_template uuid := '72000000-0000-0000-0000-000000000c19';
  v_result jsonb;
  v_line uuid;
  v_count int;
  v_cost int;
  v_data_cost int;
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

  v_result := api.apply_pricing_template(
    v_project,
    v_template,
    '{}'::jsonb,
    NULL,
    'cf190000-0000-0000-0000-000000000001'::uuid
  );

  IF v_result ->> 'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'apply failed: %', v_result;
  END IF;

  v_line := (v_result -> 'line_ids' ->> 0)::uuid;
  IF v_line IS NULL THEN
    RAISE EXCEPTION 'apply returned no line';
  END IF;
  PERFORM set_config('test.cf19_line_id', v_line::text, true);

  SELECT count(*) INTO v_count
  FROM api.project_line_financials
  WHERE project_line_id = v_line;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'member must not see line financials via api';
  END IF;

  -- Prove row exists under table owner (bypass RLS for assertion only)
  RESET ROLE;
  SELECT unit_cost_cents INTO v_data_cost
  FROM data.project_line_financials
  WHERE project_line_id = v_line;
  IF v_data_cost IS DISTINCT FROM 1200 THEN
    RAISE EXCEPTION 'copy_catalog_cost_to_line missing/wrong cost: %', v_data_cost;
  END IF;

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

  SELECT unit_cost_cents INTO v_cost
  FROM api.project_line_financials
  WHERE project_line_id = v_line;
  IF v_cost IS DISTINCT FROM 1200 THEN
    RAISE EXCEPTION 'manager must see copied line cost: %', v_cost;
  END IF;
END;
$$;

RESET ROLE;

-- upsert INSERT copies; UPDATE does not overwrite cost
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000c19';
  v_catalog uuid := '71000000-0000-0000-0000-000000000c19';
  v_line uuid;
  v_cost int;
BEGIN
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

  v_line := api.upsert_project_line(
    v_project,
    NULL,
    v_catalog,
    'service',
    'CF19 upsert line',
    NULL,
    'u',
    1,
    25.50,
    0,
    21,
    10,
    NULL,
    'cf190000-0000-0000-0000-000000000002'::uuid
  );

  SELECT unit_cost_cents INTO v_cost
  FROM api.project_line_financials
  WHERE project_line_id = v_line;
  IF v_cost IS DISTINCT FROM 1200 THEN
    RAISE EXCEPTION 'upsert insert did not copy cost: %', v_cost;
  END IF;

  PERFORM api.set_project_line_financials(
    v_line, '{"unit_cost_cents": 9999}'::jsonb
  );

  PERFORM api.upsert_project_line(
    v_project,
    v_line,
    v_catalog,
    'service',
    'CF19 upsert line renamed',
    NULL,
    'u',
    2,
    25.50,
    0,
    21,
    10,
    NULL,
    NULL
  );

  SELECT unit_cost_cents INTO v_cost
  FROM api.project_line_financials
  WHERE project_line_id = v_line;
  IF v_cost IS DISTINCT FROM 9999 THEN
    RAISE EXCEPTION 'upsert update must not overwrite cost: %', v_cost;
  END IF;
END;
$$;

RESET ROLE;

-- Member upsert INSERT copies cost; member cannot SELECT it
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000c19';
  v_catalog uuid := '71000000-0000-0000-0000-000000000c19';
  v_line uuid;
  v_count int;
  v_data_cost int;
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

  v_line := api.upsert_project_line(
    v_project,
    NULL,
    v_catalog,
    'service',
    'CF19 member upsert',
    NULL,
    'u',
    1,
    25.50,
    0,
    21,
    20,
    NULL,
    'cf190000-0000-0000-0000-000000000003'::uuid
  );

  SELECT count(*) INTO v_count
  FROM api.project_line_financials
  WHERE project_line_id = v_line;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'member must not see upsert-copied line financials';
  END IF;

  RESET ROLE;
  SELECT unit_cost_cents INTO v_data_cost
  FROM data.project_line_financials
  WHERE project_line_id = v_line;
  IF v_data_cost IS DISTINCT FROM 1200 THEN
    RAISE EXCEPTION 'member upsert did not copy cost: %', v_data_cost;
  END IF;
END;
$$;

RESET ROLE;

-- Cross-tenant: other tenant manager cannot read/write financials
DO $$
DECLARE
  v_other uuid := '10000000-0000-0000-0000-000000000001';
  v_other_owner uuid := '20000000-0000-0000-0000-000000000001';
  v_catalog uuid := '71000000-0000-0000-0000-000000000c19';
  v_line uuid;
  v_count int;
BEGIN
  SELECT id INTO v_line
  FROM data.project_lines
  WHERE client_op_id = 'cf190000-0000-0000-0000-000000000003'::uuid
  LIMIT 1;

  PERFORM set_config('request.jwt.claim.sub', v_other_owner::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_other_owner,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_other::text,
          json_build_object('global_role', 'owner', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_other)::text,
    true
  );
  SET ROLE authenticated;

  SELECT count(*) INTO v_count
  FROM api.catalog_item_financials
  WHERE catalog_item_id = v_catalog;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'cross-tenant catalog financials leak';
  END IF;

  IF v_line IS NOT NULL THEN
    SELECT count(*) INTO v_count
    FROM api.project_line_financials
    WHERE project_line_id = v_line;
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'cross-tenant line financials leak';
    END IF;
  END IF;

  BEGIN
    PERFORM api.set_catalog_item_financials(
      v_catalog, '{"unit_cost_cents": 1}'::jsonb
    );
    RAISE EXCEPTION 'cross-tenant catalog write should fail';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%permission_denied:commercial.costs.view%'
         AND SQLERRM NOT LIKE '%catalog_item_not_found%' THEN
        RAISE;
      END IF;
  END;
END;
$$;

RESET ROLE;

-- apply_price_sheet copies catalog cost
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000c19';
  v_catalog uuid := '71000000-0000-0000-0000-000000000c19';
  v_result jsonb;
  v_line uuid;
  v_cost int;
BEGIN
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

  v_result := api.apply_price_sheet(
    v_project,
    jsonb_build_array(jsonb_build_object(
      'catalog_item_id', v_catalog,
      'quantity', 1
    )),
    'append',
    NULL,
    'cf190000-0000-0000-0000-000000000004'::uuid
  );

  IF v_result ->> 'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'apply_price_sheet failed: %', v_result;
  END IF;

  v_line := (v_result -> 'line_ids' ->> 0)::uuid;
  SELECT unit_cost_cents INTO v_cost
  FROM api.project_line_financials
  WHERE project_line_id = v_line;
  IF v_cost IS DISTINCT FROM 1200 THEN
    RAISE EXCEPTION 'apply_price_sheet did not copy cost: %', v_cost;
  END IF;
END;
$$;

RESET ROLE;

-- copy_project_lines prefers source line cost snapshot
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_source uuid := '51000000-0000-0000-0000-000000000c19';
  v_target uuid := '51000000-0000-0000-0000-000000000c1a';
  v_src_line uuid;
  v_result jsonb;
  v_new_line uuid;
  v_cost int;
BEGIN
  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_target, v_tenant, 'work_order', 'CF-19 copy target', 'disposable',
    'active', 'company', v_site, v_client, v_owner
  );

  SELECT pl.id INTO v_src_line
  FROM data.project_lines pl
  JOIN data.project_line_financials f ON f.project_line_id = pl.id
  WHERE pl.project_id = v_source
    AND f.unit_cost_cents = 9999
  LIMIT 1;

  IF v_src_line IS NULL THEN
    RAISE EXCEPTION 'missing source line with cost 9999 for copy test';
  END IF;

  -- Source line cost was forced to 9999 earlier; copy must keep that snapshot.
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

  v_result := api.copy_project_lines(
    v_source,
    v_target,
    'append',
    'cf190000-0000-0000-0000-000000000005'::uuid
  );

  IF v_result ->> 'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'copy_project_lines failed: %', v_result;
  END IF;

  -- copy_project_lines rewrites catalog line names from catalog; find by cost snapshot.
  SELECT pl.id, f.unit_cost_cents INTO v_new_line, v_cost
  FROM data.project_lines pl
  JOIN data.project_line_financials f ON f.project_line_id = pl.id
  WHERE pl.project_id = v_target
    AND f.unit_cost_cents = 9999
  LIMIT 1;

  IF v_new_line IS NULL OR v_cost IS DISTINCT FROM 9999 THEN
    RAISE EXCEPTION 'copy_project_lines must keep source cost snapshot: % / %', v_new_line, v_cost;
  END IF;
END;
$$;

RESET ROLE;

DO $$
BEGIN
  RAISE NOTICE 'PASS: CF-19 catalog/line financials';
END;
$$;

ROLLBACK;
