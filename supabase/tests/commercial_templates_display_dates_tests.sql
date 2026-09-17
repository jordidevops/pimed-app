-- Isolation for api.get_commercial_display_formats + locale token replace
DO $$
DECLARE
  v_tenant_a uuid := '10000000-0000-0000-0000-000000000003';
  v_tenant_b uuid := '10000000-0000-0000-0000-000000000002';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_got jsonb;
  v_hit int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_owner,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant_a::text, json_build_object('global_role', 'owner', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );

  v_got := api.get_commercial_display_formats(v_tenant_a);
  IF v_got IS NULL OR (v_got->>'date_format') IS NULL OR (v_got->>'time_format') IS NULL THEN
    RAISE EXCEPTION 'display formats FAIL: expected formats for own tenant';
  END IF;

  BEGIN
    v_got := api.get_commercial_display_formats(v_tenant_b);
    RAISE EXCEPTION 'display formats FAIL: other tenant must be denied';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%access_denied%' THEN
        RAISE;
      END IF;
  END;

  SELECT count(*) INTO v_hit
  FROM data.document_template_locales l
  JOIN data.document_templates t ON t.id = l.template_id
  WHERE t.category IN ('quote', 'delivery_note')
    AND COALESCE(l.html_content, '') LIKE '%{{ document.issued_at }}%';
  IF v_hit <> 0 THEN
    RAISE EXCEPTION 'display formats FAIL: leftover raw issued_at tokens: %', v_hit;
  END IF;

  SELECT count(*) INTO v_hit
  FROM data.document_template_locales l
  JOIN data.document_templates t ON t.id = l.template_id
  WHERE t.category IN ('quote', 'delivery_note')
    AND COALESCE(l.html_content, '') LIKE '%{{ document.valid_until }}%'
    AND COALESCE(l.html_content, '') NOT LIKE '%{{ document.valid_until_display }}%';
  IF v_hit <> 0 THEN
    RAISE EXCEPTION 'display formats FAIL: leftover raw valid_until tokens: %', v_hit;
  END IF;

  RAISE NOTICE 'commercial display dates tests PASS';
END $$;
