-- Price sheet technician UX: lock, SET NULL, waiver gate, member default, backfill.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := gen_random_uuid();
  v_source uuid := gen_random_uuid();
  v_line uuid;
  v_quote uuid;
  v_cdl uuid;
  v_src_before uuid;
  v_member_perms text[];
  v_defaults jsonb;
  v_meta jsonb;
  v_catalog uuid := gen_random_uuid();
  v_tpl uuid := gen_random_uuid();
  v_tpl_item uuid;
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

  -- Member default includes commercial.pricing.edit
  v_member_perms := data.get_role_permissions('member', NULL);
  IF NOT ('commercial.pricing.edit' = ANY (v_member_perms)) THEN
    RAISE EXCEPTION 'price_sheet_ux: member default missing commercial.pricing.edit';
  END IF;

  -- get_tenant_role_permissions defaults.member includes the key
  v_defaults := api.get_tenant_role_permissions(v_tenant) -> 'defaults' -> 'member';
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(v_defaults) AS p(val)
    WHERE p.val = 'commercial.pricing.edit'
  ) THEN
    RAISE EXCEPTION 'price_sheet_ux: get_tenant_role_permissions defaults.member missing key: %',
      v_defaults;
  END IF;

  -- Backfill expression: custom member matrix without the key → append
  UPDATE data.tenants
  SET metadata = jsonb_set(
    COALESCE(metadata, '{}'::jsonb),
    '{role_permissions,member}',
    '["storage.upload","calendar.edit"]'::jsonb,
    true
  )
  WHERE id = v_tenant;

  UPDATE data.tenants t
  SET metadata = jsonb_set(
    COALESCE(t.metadata, '{}'::jsonb),
    '{role_permissions,member}',
    COALESCE(t.metadata -> 'role_permissions' -> 'member', '[]'::jsonb)
      || '["commercial.pricing.edit"]'::jsonb,
    true
  )
  WHERE t.id = v_tenant
    AND t.metadata ? 'role_permissions'
    AND t.metadata -> 'role_permissions' ? 'member'
    AND jsonb_typeof(t.metadata -> 'role_permissions' -> 'member') = 'array'
    AND NOT (
      EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(t.metadata -> 'role_permissions' -> 'member') AS p(val)
        WHERE p.val = 'commercial.pricing.edit'
      )
    );

  SELECT metadata INTO v_meta FROM data.tenants WHERE id = v_tenant;
  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text(v_meta -> 'role_permissions' -> 'member') AS p(val)
    WHERE p.val = 'commercial.pricing.edit'
  ) THEN
    RAISE EXCEPTION 'price_sheet_ux: backfill did not append commercial.pricing.edit';
  END IF;

  -- Restore empty customization so later get_role_permissions uses defaults
  UPDATE data.tenants
  SET metadata = COALESCE(metadata, '{}'::jsonb) - 'role_permissions'
  WHERE id = v_tenant;

  INSERT INTO data.catalog_items (
    id, tenant_id, kind, name, unit, unit_price, tax_rate, is_active
  ) VALUES (
    v_catalog, v_tenant, 'service', 'PSUX Hora', 'h', 40.00, 21.00, true
  );

  INSERT INTO data.pricing_templates (
    id, tenant_id, name, is_active
  ) VALUES (
    v_tpl, v_tenant, 'PSUX pack', true
  );

  INSERT INTO data.pricing_template_items (
    id, tenant_id, template_id, catalog_item_id, default_quantity, position
  ) VALUES (
    gen_random_uuid(), v_tenant, v_tpl, v_catalog, 1, 0
  )
  RETURNING id INTO v_tpl_item;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES
    (
      v_project, v_tenant, 'work_order', 'Price sheet UX test', NULL, 'active', 'company',
      v_site, v_client, v_owner
    ),
    (
      v_source, v_tenant, 'work_order', 'Price sheet UX source', NULL, 'active', 'company',
      v_site, v_client, v_owner
    );

  PERFORM api.upsert_project_line(
    v_source, NULL, v_catalog, 'service', 'PSUX Hora', NULL, 'h',
    1, 40, 0, 21, 0, NULL, gen_random_uuid()
  );

  v_line := api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores tècnic', NULL, 'h',
    2, 45, 0, 21, 0, NULL, gen_random_uuid()
  );

  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );

  -- Lock: upsert while issued
  BEGIN
    PERFORM api.upsert_project_line(
      v_project, v_line, NULL, 'service', 'Hores tècnic', NULL, 'h',
      3, 45, 0, 21, 0, NULL, NULL
    );
    RAISE EXCEPTION 'price_sheet_ux: expected lock on upsert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%price_sheet_locked:quote_in_progress%' THEN
      RAISE;
    END IF;
  END;

  -- Lock: delete while issued
  BEGIN
    PERFORM api.delete_project_line(v_line);
    RAISE EXCEPTION 'price_sheet_ux: expected lock on delete';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%price_sheet_locked:quote_in_progress%' THEN
      RAISE;
    END IF;
  END;

  -- Lock: apply_pricing_template while issued
  BEGIN
    PERFORM api.apply_pricing_template(
      v_project, v_tpl, '{}'::jsonb, NULL, gen_random_uuid()
    );
    RAISE EXCEPTION 'price_sheet_ux: expected lock on apply_pricing_template';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%price_sheet_locked:quote_in_progress%' THEN
      RAISE;
    END IF;
  END;

  -- Lock: copy_project_lines while issued
  BEGIN
    PERFORM api.copy_project_lines(
      v_source, v_project, 'append', gen_random_uuid()
    );
    RAISE EXCEPTION 'price_sheet_ux: expected lock on copy_project_lines';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%price_sheet_locked:quote_in_progress%' THEN
      RAISE;
    END IF;
  END;

  -- Lock: apply_price_sheet while issued
  BEGIN
    PERFORM api.apply_price_sheet(
      v_project,
      jsonb_build_array(
        jsonb_build_object(
          'catalog_item_id', v_catalog,
          'quantity', 1
        )
      ),
      'append',
      NULL,
      gen_random_uuid()
    );
    RAISE EXCEPTION 'price_sheet_ux: expected lock on apply_price_sheet';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%price_sheet_locked:quote_in_progress%' THEN
      RAISE;
    END IF;
  END;

  -- Waiver blocked while issued (before accept)
  BEGIN
    PERFORM api.create_quote_waiver(
      v_project,
      'Legal text',
      'Work description',
      jsonb_build_object('method', 'sql_test'),
      gen_random_uuid(),
      NULL
    );
    RAISE EXCEPTION 'price_sheet_ux: expected waiver_blocked while issued';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%waiver_blocked:quote_active%' THEN
      RAISE;
    END IF;
  END;

  -- Actuals still allowed while issued
  PERFORM data.apply_project_line_actual(
    v_project, v_line, 'h', 2.5, gen_random_uuid()
  );

  -- Expired issued unlocks structure mutations
  -- valid_until is immutable after issue; disable trigger only for this fixture.
  ALTER TABLE data.commercial_documents
    DISABLE TRIGGER trg_commercial_documents_immutable;
  UPDATE data.commercial_documents
  SET valid_until = now() - interval '1 day'
  WHERE id = v_quote;
  ALTER TABLE data.commercial_documents
    ENABLE TRIGGER trg_commercial_documents_immutable;

  PERFORM api.upsert_project_line(
    v_project, v_line, NULL, 'service', 'Hores tècnic', NULL, 'h',
    3, 45, 0, 21, 0, NULL, NULL
  );

  -- Cancel expired-but-still-issued row, then re-issue for SET NULL coverage
  PERFORM api.cancel_commercial_document(v_quote, gen_random_uuid(), 'expired_cleanup');

  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );
  PERFORM api.cancel_commercial_document(v_quote, gen_random_uuid(), 'test');

  SELECT id, source_project_line_id INTO v_cdl, v_src_before
  FROM data.commercial_document_lines
  WHERE document_id = v_quote AND source_project_line_id = v_line
  LIMIT 1;

  IF v_cdl IS NULL THEN
    RAISE EXCEPTION 'price_sheet_ux: missing commercial_document_lines snapshot';
  END IF;

  PERFORM api.delete_project_line(v_line);

  SELECT source_project_line_id INTO v_src_before
  FROM data.commercial_document_lines WHERE id = v_cdl;
  IF v_src_before IS NOT NULL THEN
    RAISE EXCEPTION 'price_sheet_ux: source_project_line_id not SET NULL';
  END IF;

  BEGIN
    UPDATE data.commercial_document_lines
    SET unit_price = unit_price + 1
    WHERE id = v_cdl;
    RAISE EXCEPTION 'price_sheet_ux: expected immutable unit_price';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%commercial_document_lines_immutable%' THEN
      RAISE;
    END IF;
  END;

  -- Waiver blocked while accepted quote exists
  v_line := api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Material', NULL, 'u',
    1, 10, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote,
    jsonb_build_object('method', 'sql_test', 'note', 'price_sheet_ux'),
    gen_random_uuid()
  );

  BEGIN
    PERFORM api.create_quote_waiver(
      v_project,
      'Legal text',
      'Work description',
      jsonb_build_object('method', 'sql_test'),
      gen_random_uuid(),
      NULL
    );
    RAISE EXCEPTION 'price_sheet_ux: expected waiver_blocked after accept';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%waiver_blocked:quote_active%' THEN
      RAISE;
    END IF;
  END;

  -- Cleanup disposable fixtures
  DELETE FROM data.pricing_template_items WHERE template_id = v_tpl;
  DELETE FROM data.pricing_templates WHERE id = v_tpl;
  DELETE FROM data.catalog_items WHERE id = v_catalog;

  RAISE NOTICE 'price_sheet_technician_ux_tests OK';
END $$;
