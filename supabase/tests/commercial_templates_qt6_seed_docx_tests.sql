-- QT-6: 6 platform DOCX templates, 12 locales, token haystack, fallback intact.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_quote_count int;
  v_delivery_count int;
  v_locale_count int;
  v_rec record;
  v_resolved uuid;
  v_buyer text;
  v_tax_n int;
  v_got jsonb;
  v_mime text := 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
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
        )
      )
    )::text,
    true
  );

  SELECT count(*) INTO v_quote_count
  FROM data.document_templates
  WHERE id BETWEEN '74000000-0000-0000-0000-000000000001'
                AND '74000000-0000-0000-0000-000000000005'
    AND tenant_id IS NULL
    AND is_platform_default
    AND category = 'quote'
    AND template_type = 'docx'
    AND is_active;

  IF v_quote_count <> 5 THEN
    RAISE EXCEPTION 'QT-6 expected 5 quote DOCX templates, found %', v_quote_count;
  END IF;

  SELECT count(*) INTO v_delivery_count
  FROM data.document_templates
  WHERE id = '75000000-0000-0000-0000-000000000001'
    AND tenant_id IS NULL
    AND is_platform_default
    AND category = 'delivery_note'
    AND template_type = 'docx'
    AND is_active;

  IF v_delivery_count <> 1 THEN
    RAISE EXCEPTION 'QT-6 expected 1 delivery_note DOCX template';
  END IF;

  SELECT count(*) INTO v_locale_count
  FROM data.document_template_locales
  WHERE template_id IN (
    '74000000-0000-0000-0000-000000000001',
    '74000000-0000-0000-0000-000000000002',
    '74000000-0000-0000-0000-000000000003',
    '74000000-0000-0000-0000-000000000004',
    '74000000-0000-0000-0000-000000000005',
    '75000000-0000-0000-0000-000000000001'
  )
    AND is_active
    AND mime_type = v_mime
    AND locale IN ('ca', 'es')
    AND storage_path LIKE 'platform/docx/commercial/%';

  IF v_locale_count <> 12 THEN
    RAISE EXCEPTION 'QT-6 expected 12 DOCX locales, found %', v_locale_count;
  END IF;

  IF (SELECT target_archetypes FROM data.document_templates WHERE id = '74000000-0000-0000-0000-000000000001') IS NOT NULL THEN
    RAISE EXCEPTION 'generic quote DOCX must have NULL target_archetypes';
  END IF;

  IF (SELECT target_archetypes FROM data.document_templates WHERE id = '74000000-0000-0000-0000-000000000002')
       IS DISTINCT FROM ARRAY['field_service']::text[] THEN
    RAISE EXCEPTION 'field_service DOCX archetype mismatch';
  END IF;

  FOR v_rec IN
    SELECT t.category, l.locale, l.html_content, l.sample_values, l.storage_path, t.id
    FROM data.document_templates t
    JOIN data.document_template_locales l ON l.template_id = t.id
    WHERE t.id IN (
      '74000000-0000-0000-0000-000000000001',
      '74000000-0000-0000-0000-000000000002',
      '74000000-0000-0000-0000-000000000003',
      '74000000-0000-0000-0000-000000000004',
      '74000000-0000-0000-0000-000000000005',
      '75000000-0000-0000-0000-000000000001'
    )
  LOOP
    IF v_rec.html_content IS NOT NULL THEN
      RAISE EXCEPTION 'QT-6 DOCX locale must have NULL html_content';
    END IF;

    v_buyer := v_rec.sample_values #>> '{buyer,display_name}';
    IF v_buyer IS DISTINCT FROM 'Client Exemple SL' THEN
      RAISE EXCEPTION 'QT-6 sample_values buyer mismatch: %', v_buyer;
    END IF;

    SELECT count(*) INTO v_tax_n
    FROM jsonb_array_elements(v_rec.sample_values #> '{totals,tax_breakdown}') e;
    IF v_tax_n < 2 THEN
      RAISE EXCEPTION 'QT-6 sample_values need at least two tax rates';
    END IF;
  END LOOP;

  v_got := api.get_commercial_full_body_locale(
    v_tenant,
    '74000000-0000-0000-0000-000000000001',
    'ca'
  );
  IF v_got IS NULL OR (v_got->>'template_type') IS DISTINCT FROM 'docx' THEN
    RAISE EXCEPTION 'QT-6 locale RPC must return platform DOCX type';
  END IF;
  IF COALESCE(v_got->>'storage_path', '') NOT LIKE 'platform/docx/commercial/quote-generic-ca.docx' THEN
    RAISE EXCEPTION 'QT-6 locale RPC missing storage_path: %', v_got->>'storage_path';
  END IF;

  -- Platform seed must not auto-bind tenants (QT-D1 fallback).
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant, 'quote');
  IF v_resolved IS NOT NULL AND EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = v_resolved AND t.tenant_id IS NULL AND t.is_platform_default
  ) THEN
    RAISE EXCEPTION 'QT-6 must not auto-resolve platform quote DOCX, got %', v_resolved;
  END IF;

  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant, 'delivery_note');
  IF v_resolved IS NOT NULL AND EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = v_resolved AND t.tenant_id IS NULL AND t.is_platform_default
  ) THEN
    RAISE EXCEPTION 'QT-6 must not auto-resolve platform delivery DOCX, got %', v_resolved;
  END IF;

  RAISE NOTICE 'QT-6 seed DOCX tests PASS';
END $$;
