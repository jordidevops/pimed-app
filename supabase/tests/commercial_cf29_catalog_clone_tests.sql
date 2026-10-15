-- CF-29: catàleg ready (amb preus il·lustratius) + clone aïllat per tenant.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_uid uuid := '20000000-0000-0000-0000-000000000002';
  v_cat_id uuid;
  v_clone_a uuid;
  v_clone_b uuid;
  v_catalog_count_before int;
  v_catalog_count_after int;
  v_ready_count int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}},"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}},"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  SELECT COUNT(*) INTO v_catalog_count_before FROM data.calculator_catalog;

  SELECT COUNT(*) INTO v_ready_count
  FROM data.calculator_catalog
  WHERE default_case IS NOT NULL
    AND definition->'constants' IS NOT NULL;
  IF v_ready_count < 2 THEN
    RAISE EXCEPTION 'cf29_catalog_tests: expected ready catalog rows with default_case';
  END IF;

  -- Overturn D12: el catàleg ready pot (i ha de) tenir preus numèrics il·lustratius.
  IF NOT EXISTS (
    SELECT 1
    FROM data.calculator_catalog c,
    LATERAL jsonb_array_elements(COALESCE(c.definition->'constants', '[]'::jsonb)) const
    WHERE jsonb_typeof(const->'value') = 'number'
  ) THEN
    RAISE EXCEPTION 'cf29_catalog_tests: expected at least one numeric example price in catalog';
  END IF;

  SELECT id INTO v_cat_id
  FROM data.calculator_catalog
  WHERE slug = 'electrician_travel_labor'
  LIMIT 1;
  IF v_cat_id IS NULL THEN
    RAISE EXCEPTION 'cf29_catalog_tests: missing electrician catalog row';
  END IF;

  v_clone_a := api.clone_calculator_from_catalog(v_cat_id, 'Clone A');
  IF NOT EXISTS (
    SELECT 1 FROM data.calculator_definitions
    WHERE id = v_clone_a AND tenant_id = v_tenant AND status = 'incomplete'
      AND cloned_from_catalog_id = v_cat_id
  ) THEN
    RAISE EXCEPTION 'cf29_catalog_tests: clone A missing';
  END IF;

  SELECT COUNT(*) INTO v_catalog_count_after FROM data.calculator_catalog;
  IF v_catalog_count_after <> v_catalog_count_before THEN
    RAISE EXCEPTION 'cf29_catalog_tests: clone wrote to calculator_catalog';
  END IF;

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  IF EXISTS (
    SELECT 1 FROM api.calculator_definitions WHERE id = v_clone_a
  ) THEN
    RAISE EXCEPTION 'cf29_catalog_tests: tenant B can see clone A';
  END IF;

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);
  v_clone_b := api.clone_calculator_from_catalog(v_cat_id, 'Clone A2');
  IF v_clone_b = v_clone_a THEN
    RAISE EXCEPTION 'cf29_catalog_tests: second clone reused first id';
  END IF;

  DELETE FROM data.calculator_definitions WHERE id IN (v_clone_a, v_clone_b);

  RAISE NOTICE 'CF-29 catalog clone tests PASS';
END;
$$;
