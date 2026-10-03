-- CF-27: preview_next_document_number must not return NULL without a counter row.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_preview text;
  v_series uuid;
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

  SELECT id INTO v_series
  FROM data.commercial_document_series
  WHERE tenant_id = v_tenant AND doc_type = 'invoice' AND active
  ORDER BY code
  LIMIT 1;

  IF v_series IS NULL THEN
    RAISE EXCEPTION 'TEST SETUP: missing invoice series for Volt';
  END IF;

  -- Ensure no counter for a disposable period key path: delete 2099 if any, then preview with that year.
  DELETE FROM data.commercial_document_number_counters
  WHERE tenant_id = v_tenant
    AND series_id = v_series
    AND period_key = '2099';

  v_preview := api.preview_next_document_number('invoice', NULL, '2099-06-15'::date);
  IF v_preview IS NULL OR btrim(v_preview) = '' THEN
    RAISE EXCEPTION 'FAIL: preview returned empty without counter (got %)', v_preview;
  END IF;
  IF v_preview IS DISTINCT FROM 'F-2099-0001' THEN
    RAISE EXCEPTION 'FAIL: expected F-2099-0001 got %', v_preview;
  END IF;

  INSERT INTO data.commercial_document_number_counters (tenant_id, series_id, period_key, last_value)
  VALUES (v_tenant, v_series, '2099', 7);

  v_preview := api.preview_next_document_number('invoice', NULL, '2099-06-15'::date);
  IF v_preview IS DISTINCT FROM 'F-2099-0008' THEN
    RAISE EXCEPTION 'FAIL: expected F-2099-0008 got %', v_preview;
  END IF;

  RAISE NOTICE 'PASS sales_preview_number_tests';
END;
$$;

ROLLBACK;
