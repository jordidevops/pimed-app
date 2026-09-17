-- Site-scoped commercial.pricing.edit for apply_pricing_template discounts.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_other_site uuid := '30000000-0000-0000-0000-000000000099';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_ok boolean;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_member,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text, json_build_object(
            'global_role', 'member',
            'sites', json_build_object(
              v_site::text, 'manager'
            )
          )
        )
      )
    )::text,
    true
  );

  v_ok := data.can_edit_commercial_pricing(v_tenant, NULL);
  IF v_ok IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'T0 member global must not edit pricing: %', v_ok;
  END IF;

  v_ok := data.can_edit_commercial_pricing(v_tenant, v_site);
  IF v_ok IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T1 site manager must edit pricing on assigned site: %', v_ok;
  END IF;

  v_ok := data.can_edit_commercial_pricing(v_tenant, v_other_site);
  IF v_ok IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'T2 site manager must not edit pricing on other site: %', v_ok;
  END IF;

  RAISE NOTICE 'commercial_flow_pricing_edit_site_scope_tests OK';
END;
$$;
