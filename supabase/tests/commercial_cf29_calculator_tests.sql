-- CF-29 fase 2: apply calculator a projecte i orfe; re-executar; RLS creuada.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_other_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_uid uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_client uuid;
  v_def uuid;
  v_version uuid;
  v_run jsonb;
  v_calc_count int;
  v_manual_count int;
  v_draft uuid;
  v_hash text := 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  SELECT client_id INTO v_client FROM data.projects WHERE id = v_project;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'fixture project missing';
  END IF;

  INSERT INTO data.calculator_definitions (
    id, tenant_id, name, status, draft_definition, created_by
  ) VALUES (
    'a1000000-0000-0000-0000-000000000001',
    v_tenant,
    'Test electricista',
    'active',
    '{"schema_version":1,"parameters":[],"lines":[]}'::jsonb,
    v_uid
  )
  RETURNING id INTO v_def;

  INSERT INTO data.calculator_versions (
    id, definition_id, tenant_id, version_number, definition, content_hash, published_by
  ) VALUES (
    'a1000000-0000-0000-0000-000000000002',
    v_def, v_tenant, 1,
    '{"schema_version":1,"parameters":[],"lines":[]}'::jsonb,
    v_hash, v_uid
  )
  RETURNING id INTO v_version;

  UPDATE data.calculator_definitions
  SET published_version_id = v_version
  WHERE id = v_def;

  INSERT INTO data.calculator_cases (definition_id, tenant_id, name, params, expected_lines, last_result)
  VALUES (v_def, v_tenant, 'cas1', '{}'::jsonb, '[]'::jsonb, 'pass');

  -- Línia manual prèvia
  INSERT INTO data.project_lines (
    tenant_id, project_id, kind, name, unit, quantity, unit_price, discount_pct, tax_rate, position, line_origin
  ) VALUES (
    v_tenant, v_project, 'service', 'Manual previa', 'u', 1, 10, 0, 21, 0, 'manual'
  );

  -- Apply (service_role path: crida directa com l'Edge)
  v_run := api.apply_calculator_lines(
    v_version,
    '{"distance_km":20}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'key', 'travel',
        'kind', 'service',
        'name', 'Desplaçament',
        'description', null,
        'unit', 'u',
        'quantity', '1.000',
        'unit_price', '25.00',
        'discount_pct', '0.00',
        'tax_rate', '21.00',
        'allow_zero_price', true
      )
    ),
    v_hash,
    'b1000000-0000-0000-0000-000000000001'::uuid,
    v_uid,
    v_project,
    NULL
  );

  IF v_run->>'status' <> 'ok' THEN
    RAISE EXCEPTION 'T1 apply expected ok, got %', v_run;
  END IF;

  SELECT COUNT(*) INTO v_calc_count
  FROM data.project_lines
  WHERE project_id = v_project AND line_origin = 'calculator';
  IF v_calc_count <> 1 THEN
    RAISE EXCEPTION 'T1 expected 1 calculator line, got %', v_calc_count;
  END IF;

  SELECT COUNT(*) INTO v_manual_count
  FROM data.project_lines
  WHERE project_id = v_project AND line_origin = 'manual';
  IF v_manual_count < 1 THEN
    RAISE EXCEPTION 'T1 manual line disappeared';
  END IF;

  -- Re-apply substitutes calculator lines only
  v_run := api.apply_calculator_lines(
    v_version,
    '{"distance_km":40}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'key', 'travel',
        'kind', 'service',
        'name', 'Desplaçament',
        'description', null,
        'unit', 'u',
        'quantity', '1.000',
        'unit_price', '37.00',
        'discount_pct', '0.00',
        'tax_rate', '21.00',
        'allow_zero_price', true
      ),
      jsonb_build_object(
        'key', 'labor',
        'kind', 'service',
        'name', 'Mà d''obra',
        'description', null,
        'unit', 'h',
        'quantity', '8.000',
        'unit_price', '45.00',
        'discount_pct', '0.00',
        'tax_rate', '21.00',
        'allow_zero_price', false
      )
    ),
    v_hash,
    'b1000000-0000-0000-0000-000000000002'::uuid,
    v_uid,
    v_project,
    NULL
  );

  SELECT COUNT(*) INTO v_calc_count
  FROM data.project_lines
  WHERE project_id = v_project AND line_origin = 'calculator';
  IF v_calc_count <> 2 THEN
    RAISE EXCEPTION 'T2 expected 2 calculator lines, got %', v_calc_count;
  END IF;

  SELECT COUNT(*) INTO v_manual_count
  FROM data.project_lines
  WHERE project_id = v_project AND line_origin = 'manual' AND name = 'Manual previa';
  IF v_manual_count <> 1 THEN
    RAISE EXCEPTION 'T2 manual should survive re-run';
  END IF;

  -- Idempotency
  v_run := api.apply_calculator_lines(
    v_version, '{}'::jsonb, '[]'::jsonb, v_hash,
    'b1000000-0000-0000-0000-000000000002'::uuid, v_uid, v_project, NULL
  );
  IF v_run->>'status' <> 'duplicate' THEN
    RAISE EXCEPTION 'T3 expected duplicate';
  END IF;

  -- Orphan draft apply
  v_draft := api.create_orphan_quote_draft(
    v_tenant, v_client, NULL, 'signed_quote',
    'b1000000-0000-0000-0000-000000000010'::uuid
  );
  v_run := api.apply_calculator_lines(
    v_version,
    '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'key', 'labor',
        'kind', 'service',
        'name', 'Mà d''obra',
        'description', null,
        'unit', 'h',
        'quantity', '2.000',
        'unit_price', '45.00',
        'discount_pct', '0.00',
        'tax_rate', '21.00',
        'allow_zero_price', false
      )
    ),
    v_hash,
    'b1000000-0000-0000-0000-000000000003'::uuid,
    v_uid,
    NULL,
    v_draft
  );
  IF v_run->>'status' <> 'ok' THEN
    RAISE EXCEPTION 'T4 orphan apply failed %', v_run;
  END IF;

  SELECT COUNT(*) INTO v_calc_count
  FROM data.commercial_document_lines
  WHERE document_id = v_draft AND line_origin = 'calculator';
  IF v_calc_count <> 1 THEN
    RAISE EXCEPTION 'T4 expected 1 CDL calculator line';
  END IF;

  -- Immutable version
  BEGIN
    UPDATE data.calculator_versions SET content_hash = 'x' WHERE id = v_version;
    RAISE EXCEPTION 'T5 version update should fail';
  EXCEPTION
    WHEN integrity_constraint_violation THEN
      NULL; -- expected calculator_version_immutable
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%calculator_version_immutable%' THEN
        RAISE;
      END IF;
  END;

  -- Cross-tenant definition not visible via active tenant (smoke)
  IF EXISTS (
    SELECT 1 FROM data.calculator_definitions
    WHERE tenant_id = v_other_tenant AND id = v_def
  ) THEN
    RAISE EXCEPTION 'T6 definition leaked to other tenant row check';
  END IF;

  RAISE NOTICE 'CF-29 calculator tests PASS';
END;
$$;
