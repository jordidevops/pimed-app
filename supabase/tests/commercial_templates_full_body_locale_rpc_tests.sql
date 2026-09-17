-- Isolation + locale load for api.get_commercial_full_body_locale
DO $$
DECLARE
  v_tenant_a uuid := '10000000-0000-0000-0000-000000000003';
  v_tenant_b uuid := '10000000-0000-0000-0000-000000000002';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_tpl_a uuid := '76a60000-0000-0000-0000-000000000001';
  v_tpl_b uuid := '76a60000-0000-0000-0000-000000000002';
  v_got jsonb;
  v_html text :=
    '{% for line in lines %}{{ line.name }}{% endfor %}'
    || '{{ totals.total }}{{ document.doc_number }}{{ document.valid_until }}{{ totals.tax_breakdown }}'
    || '<signature-field role="client_accept"></signature-field>'
    || '<signature-field role="client_reject"></signature-field>';
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_owner,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant_a::text, json_build_object('global_role', 'owner', 'sites', json_build_object()),
          v_tenant_b::text, json_build_object('global_role', 'owner', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );

  DELETE FROM data.document_template_locales WHERE template_id IN (v_tpl_a, v_tpl_b);
  DELETE FROM data.document_templates WHERE id IN (v_tpl_a, v_tpl_b);

  INSERT INTO data.document_templates (
    id, tenant_id, name, category, template_type, is_platform_default, is_active, created_by
  ) VALUES
    (v_tpl_a, v_tenant_a, 'QT locale A', 'quote', 'html', false, true, v_owner),
    (v_tpl_b, v_tenant_b, 'QT locale B', 'quote', 'html', false, true, v_owner);

  INSERT INTO data.document_template_locales (
    template_id, locale, mime_type, html_content, is_active
  ) VALUES
    (v_tpl_a, 'ca', 'text/html', v_html, true),
    (v_tpl_b, 'ca', 'text/html', v_html, true);

  v_got := api.get_commercial_full_body_locale(v_tenant_a, v_tpl_a, 'ca');
  IF v_got IS NULL OR (v_got->>'html_content') IS DISTINCT FROM v_html THEN
    RAISE EXCEPTION 'locale RPC FAIL: expected html for own template';
  END IF;
  IF (v_got->>'template_type') IS DISTINCT FROM 'html' THEN
    RAISE EXCEPTION 'locale RPC FAIL: template_type';
  END IF;

  v_got := api.get_commercial_full_body_locale(v_tenant_a, v_tpl_b, 'ca');
  IF v_got IS NOT NULL THEN
    RAISE EXCEPTION 'locale RPC FAIL: must not return other tenant template';
  END IF;

  v_got := api.get_commercial_full_body_locale(v_tenant_a, v_tpl_a, 'es');
  IF (v_got->>'html_content') IS DISTINCT FROM v_html THEN
    RAISE EXCEPTION 'locale RPC FAIL: missing locale should fall back to ca';
  END IF;

  DELETE FROM data.document_template_locales WHERE template_id IN (v_tpl_a, v_tpl_b);
  DELETE FROM data.document_templates WHERE id IN (v_tpl_a, v_tpl_b);

  RAISE NOTICE 'get_commercial_full_body_locale tests PASS';
END $$;
