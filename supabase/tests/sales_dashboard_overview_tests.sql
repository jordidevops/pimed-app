-- get_sales_dashboard_overview smoke: shape, year on cash/series, agreements without year gate.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_ov jsonb;
  v_year int := EXTRACT(YEAR FROM CURRENT_DATE)::int;
  v_months jsonb;
  v_month jsonb;
  i int;
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

  v_ov := api.get_sales_dashboard_overview(v_year);

  IF v_ov->>'year' IS DISTINCT FROM v_year::text THEN
    RAISE EXCEPTION 'year mismatch: %', v_ov;
  END IF;

  IF (v_ov ? 'cash') IS NOT TRUE
     OR (v_ov->'cash' ? 'to_invoice_count') IS NOT TRUE
     OR (v_ov->'cash' ? 'to_invoice_cents') IS NOT TRUE
     OR (v_ov->'cash' ? 'pending_collection_cents') IS NOT TRUE
     OR (v_ov->'cash' ? 'pending_quotes_count') IS NOT TRUE THEN
    RAISE EXCEPTION 'missing cash keys: %', v_ov->'cash';
  END IF;

  IF (v_ov ? 'agreements') IS NOT TRUE
     OR (v_ov->'agreements' ? 'signature') IS NOT TRUE
     OR (v_ov->'agreements' ? 'lifecycle') IS NOT TRUE
     OR (v_ov->'agreements' ? 'needs_prepare_count') IS NOT TRUE
     OR (v_ov->'agreements' ? 'attention') IS NOT TRUE THEN
    RAISE EXCEPTION 'missing agreements keys: %', v_ov->'agreements';
  END IF;

  IF (v_ov->'agreements'->'signature' ? 'draft') IS NOT TRUE
     OR (v_ov->'agreements'->'signature' ? 'pending') IS NOT TRUE
     OR (v_ov->'agreements'->'signature' ? 'signed') IS NOT TRUE THEN
    RAISE EXCEPTION 'missing signature keys: %', v_ov->'agreements'->'signature';
  END IF;

  IF (v_ov->'agreements'->'lifecycle' ? 'active') IS NOT TRUE
     OR (v_ov->'agreements'->'lifecycle' ? 'expiring') IS NOT TRUE
     OR (v_ov->'agreements'->'lifecycle' ? 'suspended') IS NOT TRUE
     OR (v_ov->'agreements'->'lifecycle' ? 'finished') IS NOT TRUE THEN
    RAISE EXCEPTION 'missing lifecycle keys: %', v_ov->'agreements'->'lifecycle';
  END IF;

  v_months := v_ov->'series'->'months';
  IF jsonb_typeof(v_months) IS DISTINCT FROM 'array' OR jsonb_array_length(v_months) IS DISTINCT FROM 12 THEN
    RAISE EXCEPTION 'series.months must be 12 entries: %', v_months;
  END IF;

  FOR i IN 0..11 LOOP
    v_month := v_months->i;
    IF (v_month->>'month')::int IS DISTINCT FROM (i + 1)
       OR (v_month ? 'quotes_issued') IS NOT TRUE
       OR (v_month ? 'delivery_notes_issued') IS NOT TRUE
       OR (v_month ? 'invoiced_cents') IS NOT TRUE THEN
      RAISE EXCEPTION 'bad series month %: %', i + 1, v_month;
    END IF;
  END LOOP;

  RAISE NOTICE 'sales_dashboard_overview_tests ok';
END;
$$;

ROLLBACK;
