-- Quote composer RPCs: search, copy, save pack, apply_price_sheet.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_other_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_member uuid := '20000000-0000-0000-0000-000000000003';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_source uuid := '51000000-0000-0000-0000-00000000c241';
  v_target uuid := '51000000-0000-0000-0000-00000000c242';
  v_other uuid := '51000000-0000-0000-0000-00000000c243';
  v_catalog uuid := '44000000-0000-0000-0000-00000000c241';
  v_tpl uuid := 'a1000000-0000-0000-0000-00000000c241';
  v_ver uuid := 'a2000000-0000-0000-0000-00000000c241';
  v_pack uuid;
  v_result jsonb;
  v_found uuid;
  v_count int;
  v_price numeric;
  v_run uuid;
  v_denied boolean := false;
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
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim', true), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );

  INSERT INTO data.catalog_items (
    id, tenant_id, kind, name, unit, unit_price, tax_rate, is_active
  ) VALUES (
    v_catalog, v_tenant, 'service', 'QC Hora tècnic', 'h', 45.00, 21.00, true
  )
  ON CONFLICT (id) DO UPDATE SET
    unit_price = 45.00,
    is_active = true,
    name = EXCLUDED.name;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES
    (
      v_source, v_tenant, 'work_order', 'QC source avaria Meridian',
      'Disposable source', 'active', 'company', v_site, v_client, v_owner
    ),
    (
      v_target, v_tenant, 'work_order', 'QC target nova OS',
      'Disposable target', 'active', 'company', v_site, v_client, v_owner
    )
  ON CONFLICT (id) DO UPDATE SET
    status = 'active',
    client_id = EXCLUDED.client_id,
    name = EXCLUDED.name,
    updated_at = now();

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, created_by
  ) VALUES (
    v_other, v_other_tenant, 'work_order', 'QC other tenant',
    'Isolation', 'active', 'company', '30000000-0000-0000-0000-000000000001', v_owner
  )
  ON CONFLICT (id) DO UPDATE SET status = 'active';

  DELETE FROM data.price_sheet_ops WHERE project_id IN (v_source, v_target);
  DELETE FROM data.pricing_template_checklists
  WHERE template_id IN (
    SELECT id FROM data.pricing_templates WHERE tenant_id = v_tenant AND name LIKE 'QC pack%'
  );
  DELETE FROM data.pricing_template_items
  WHERE template_id IN (
    SELECT id FROM data.pricing_templates WHERE tenant_id = v_tenant AND name LIKE 'QC pack%'
  );
  DELETE FROM data.pricing_templates WHERE tenant_id = v_tenant AND name LIKE 'QC pack%';
  DELETE FROM data.checklist_run_items WHERE run_id IN (
    SELECT id FROM data.checklist_runs WHERE project_id IN (v_source, v_target)
  );
  DELETE FROM data.checklist_runs WHERE project_id IN (v_source, v_target);
  DELETE FROM data.project_lines WHERE project_id IN (v_source, v_target);
  DELETE FROM data.checklist_template_items WHERE version_id = v_ver;
  DELETE FROM data.checklist_template_versions WHERE id = v_ver;
  DELETE FROM data.checklist_templates WHERE id = v_tpl;

  INSERT INTO data.project_lines (
    tenant_id, project_id, catalog_item_id, kind, name, unit, quantity,
    unit_price, discount_pct, tax_rate, position
  ) VALUES (
    v_tenant, v_source, v_catalog, 'service', 'QC Hora tècnic', 'h', 2,
    99.00, 10, 21.00, 0
  );

  INSERT INTO data.project_lines (
    tenant_id, project_id, catalog_item_id, kind, name, unit, quantity,
    unit_price, discount_pct, tax_rate, position
  ) VALUES (
    v_tenant, v_source, NULL, 'service', 'QC línia lliure', 'u', 1,
    80.00, 0, 21.00, 1
  );

  INSERT INTO data.checklist_templates (
    id, tenant_id, name, kind, is_active, is_archived, created_by
  ) VALUES (
    v_tpl, v_tenant, 'QC visita', 'todo', true, false, v_owner
  )
  ON CONFLICT (id) DO UPDATE SET is_active = true, is_archived = false, tenant_id = v_tenant;

  INSERT INTO data.checklist_template_versions (
    id, template_id, version_number, status, created_by
  ) VALUES (
    v_ver, v_tpl, 1, 'draft', v_owner
  );

  INSERT INTO data.checklist_template_items (
    version_id, position, title, is_required, response_type
  )
  SELECT v_ver, 0, 'Comprovar tensió', true, 'checkbox'
  WHERE NOT EXISTS (
    SELECT 1 FROM data.checklist_template_items WHERE version_id = v_ver
  );

  UPDATE data.checklist_template_versions
  SET status = 'published', published_at = now(), published_by = v_owner
  WHERE id = v_ver AND status = 'draft';

  v_run := api.apply_checklist_to_project(v_source, v_tpl, NULL);

  -- Search finds jobs with lines, not only completed, excludes current.
  SELECT id INTO v_found
  FROM api.search_jobs_for_pricing('Meridian', NULL, v_target, false, NULL, NULL, 30)
  WHERE id = v_source;
  IF v_found IS NULL THEN
    RAISE EXCEPTION 'T1 search should find source OS with lines';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM api.search_jobs_for_pricing(NULL, NULL, v_source, false, NULL, NULL, 50)
  WHERE id = v_source;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'T2 search must exclude current project';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM api.search_jobs_for_pricing(NULL, NULL, v_target, true, NULL, NULL, 50)
  WHERE id = v_source;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'T3 completed_only must hide active source';
  END IF;

  -- Owner copy append: historical catalog price + free line.
  v_result := api.copy_project_lines(
    v_source, v_target, 'append', 'cf240000-0000-0000-0000-000000000001'::uuid
  );
  IF COALESCE((v_result->>'copied')::int, 0) <> 2 THEN
    RAISE EXCEPTION 'T4 owner copy should copy 2 lines: %', v_result;
  END IF;
  SELECT unit_price INTO v_price
  FROM data.project_lines
  WHERE project_id = v_target AND catalog_item_id = v_catalog;
  IF v_price IS DISTINCT FROM 99 THEN
    RAISE EXCEPTION 'T4 owner copy should keep historical catalog price %, got %', 99, v_price;
  END IF;

  -- Idempotency
  v_result := api.copy_project_lines(
    v_source, v_target, 'append', 'cf240000-0000-0000-0000-000000000001'::uuid
  );
  IF v_result->>'status' IS DISTINCT FROM 'duplicate' THEN
    RAISE EXCEPTION 'T5 copy client_op_id must be idempotent: %', v_result;
  END IF;

  -- Replace
  v_result := api.copy_project_lines(
    v_source, v_target, 'replace', 'cf240000-0000-0000-0000-000000000002'::uuid
  );
  SELECT COUNT(*) INTO v_count FROM data.project_lines WHERE project_id = v_target;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'T6 replace should leave 2 lines, got %', v_count;
  END IF;

  -- Tenant isolation
  BEGIN
    PERFORM api.copy_project_lines(
      v_other, v_target, 'append', 'cf240000-0000-0000-0000-000000000003'::uuid
    );
    RAISE EXCEPTION 'T7 copy from other tenant should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%T7 copy%' THEN RAISE; END IF;
  END;

  -- Member without pricing.edit: catalog PVP, skip free line, never 0€.
  DELETE FROM data.project_lines WHERE project_id = v_target;
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
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim', true), true);

  IF data.can_edit_commercial_pricing(v_tenant, v_site) THEN
    RAISE EXCEPTION 'T8 setup: member JWT must not edit pricing';
  END IF;

  v_result := api.copy_project_lines(
    v_source, v_target, 'append', 'cf240000-0000-0000-0000-000000000004'::uuid
  );
  IF COALESCE((v_result->>'copied')::int, 0) <> 1 THEN
    RAISE EXCEPTION 'T8 member copy should copy catalog only: %', v_result;
  END IF;
  IF jsonb_array_length(v_result->'skipped') < 1 THEN
    RAISE EXCEPTION 'T8 member must skip free line: %', v_result;
  END IF;
  SELECT unit_price INTO v_price
  FROM data.project_lines
  WHERE project_id = v_target AND catalog_item_id = v_catalog;
  IF v_price IS DISTINCT FROM 45 THEN
    RAISE EXCEPTION 'T8 member copy must use live catalog PVP 45, got %', v_price;
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM data.project_lines
  WHERE project_id = v_target AND catalog_item_id IS NULL;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'T8 member must not copy free lines';
  END IF;

  -- Member cannot create pack
  BEGIN
    PERFORM api.create_pricing_template_from_project(v_source, 'QC pack member', NULL, 'skip');
    RAISE EXCEPTION 'T9 member created a pack';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%T9 member%' THEN RAISE; END IF;
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'T9 member must not create pack';
  END IF;

  -- Member apply_price_sheet: skip free 0 and free priced; catalog uses PVP
  DELETE FROM data.project_lines WHERE project_id = v_target;
  v_result := api.apply_price_sheet(
    v_target,
    jsonb_build_array(
      jsonb_build_object(
        'catalog_item_id', v_catalog,
        'quantity', 3,
        'unit_price', 1,
        'discount_pct', 50
      ),
      jsonb_build_object('name', 'Línia lliure', 'quantity', 1, 'unit_price', 70, 'kind', 'service'),
      jsonb_build_object('name', 'Zero', 'quantity', 1, 'unit_price', 0, 'kind', 'service')
    ),
    'replace',
    NULL,
    'cf240000-0000-0000-0000-000000000005'::uuid
  );
  IF COALESCE((v_result->>'inserted')::int, 0) <> 1 THEN
    RAISE EXCEPTION 'T10 member apply should insert catalog only: %', v_result;
  END IF;
  SELECT unit_price, discount_pct INTO v_price, v_count
  FROM data.project_lines
  WHERE project_id = v_target AND catalog_item_id = v_catalog;
  IF v_price IS DISTINCT FROM 45 OR v_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'T10 member apply must ignore custom price/discount';
  END IF;

  -- Owner save pack + checklists of the OS
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
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim', true), true);

  v_result := api.create_pricing_template_from_project(
    v_source, 'QC pack from OS', 'avaries', 'skip'
  );
  v_pack := (v_result->>'template_id')::uuid;
  IF v_pack IS NULL THEN
    RAISE EXCEPTION 'T11 pack not created: %', v_result;
  END IF;
  IF COALESCE((v_result->>'item_count')::int, 0) < 1 THEN
    RAISE EXCEPTION 'T11 pack needs catalog items: %', v_result;
  END IF;
  IF jsonb_array_length(COALESCE(v_result->'checklist_template_ids', '[]'::jsonb)) < 1 THEN
    RAISE EXCEPTION 'T11 pack should copy OS checklist: %', v_result;
  END IF;

  -- Owner apply_price_sheet writes lines + checklist; zero free line skipped
  DELETE FROM data.project_lines WHERE project_id = v_target;
  DELETE FROM data.checklist_run_items WHERE run_id IN (
    SELECT id FROM data.checklist_runs WHERE project_id = v_target
  );
  DELETE FROM data.checklist_runs WHERE project_id = v_target;

  v_result := api.apply_price_sheet(
    v_target,
    jsonb_build_array(
      jsonb_build_object('catalog_item_id', v_catalog, 'quantity', 1),
      jsonb_build_object('name', 'Diagnosi extra', 'quantity', 1, 'unit_price', 120, 'kind', 'service'),
      jsonb_build_object('name', 'Gratis', 'quantity', 1, 'unit_price', 0, 'kind', 'service')
    ),
    'replace',
    v_tpl,
    'cf240000-0000-0000-0000-000000000006'::uuid
  );
  IF COALESCE((v_result->>'inserted')::int, 0) <> 2 THEN
    RAISE EXCEPTION 'T12 owner apply should insert 2 priced lines: %', v_result;
  END IF;
  IF jsonb_array_length(COALESCE(v_result->'checklist_run_ids', '[]'::jsonb)) < 1 THEN
    RAISE EXCEPTION 'T12 apply should create checklist run: %', v_result;
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM data.project_lines
  WHERE project_id = v_target AND COALESCE(unit_price, 0) = 0 AND catalog_item_id IS NULL;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'T12 must never insert 0€ free line';
  END IF;

  RAISE NOTICE 'quote_composer_price_sheet_rpcs_tests OK';
END;
$$;
