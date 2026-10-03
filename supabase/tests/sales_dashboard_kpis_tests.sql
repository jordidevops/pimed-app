-- CF-27: get_sales_dashboard_kpis smoke (shape + year scope).
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_kpis jsonb;
  v_year int := EXTRACT(YEAR FROM CURRENT_DATE)::int;
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

  v_kpis := api.get_sales_dashboard_kpis(v_year);

  IF v_kpis->>'year' IS DISTINCT FROM v_year::text THEN
    RAISE EXCEPTION 'year mismatch: %', v_kpis;
  END IF;
  IF (v_kpis ? 'to_invoice_count') IS NOT TRUE
     OR (v_kpis ? 'to_invoice_cents') IS NOT TRUE
     OR (v_kpis ? 'pending_collection_cents') IS NOT TRUE
     OR (v_kpis ? 'pending_quotes_count') IS NOT TRUE THEN
    RAISE EXCEPTION 'missing kpi keys: %', v_kpis;
  END IF;

  RAISE NOTICE 'sales_dashboard_kpis_tests ok: %', v_kpis;
END;
$$;

ROLLBACK;
