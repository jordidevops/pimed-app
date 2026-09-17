-- QT-3: 6 platform HTML templates, 12 locales, token validation, fallback intact.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_quote_count int;
  v_delivery_count int;
  v_locale_count int;
  v_missing text[];
  v_rec record;
  v_resolved uuid;
  v_buyer text;
  v_tax_n int;
BEGIN
  SELECT count(*) INTO v_quote_count
  FROM data.document_templates
  WHERE id BETWEEN '76000000-0000-0000-0000-000000000001'
                AND '76000000-0000-0000-0000-000000000005'
    AND tenant_id IS NULL
    AND is_platform_default
    AND category = 'quote'
    AND template_type = 'html'
    AND is_active;

  IF v_quote_count <> 5 THEN
    RAISE EXCEPTION 'QT-3 expected 5 quote templates, found %', v_quote_count;
  END IF;

  SELECT count(*) INTO v_delivery_count
  FROM data.document_templates
  WHERE id = '77000000-0000-0000-0000-000000000001'
    AND tenant_id IS NULL
    AND is_platform_default
    AND category = 'delivery_note'
    AND template_type = 'html'
    AND is_active;

  IF v_delivery_count <> 1 THEN
    RAISE EXCEPTION 'QT-3 expected 1 delivery_note template';
  END IF;

  SELECT count(*) INTO v_locale_count
  FROM data.document_template_locales
  WHERE template_id IN (
    '76000000-0000-0000-0000-000000000001',
    '76000000-0000-0000-0000-000000000002',
    '76000000-0000-0000-0000-000000000003',
    '76000000-0000-0000-0000-000000000004',
    '76000000-0000-0000-0000-000000000005',
    '77000000-0000-0000-0000-000000000001'
  )
    AND is_active
    AND mime_type = 'text/html'
    AND locale IN ('ca', 'es');

  IF v_locale_count <> 12 THEN
    RAISE EXCEPTION 'QT-3 expected 12 locales, found %', v_locale_count;
  END IF;

  IF (SELECT target_archetypes FROM data.document_templates WHERE id = '76000000-0000-0000-0000-000000000001') IS NOT NULL THEN
    RAISE EXCEPTION 'generic quote must have NULL target_archetypes';
  END IF;

  IF (SELECT target_archetypes FROM data.document_templates WHERE id = '76000000-0000-0000-0000-000000000002')
       IS DISTINCT FROM ARRAY['field_service']::text[] THEN
    RAISE EXCEPTION 'field_service archetype mismatch';
  END IF;

  FOR v_rec IN
    SELECT t.category, l.locale, l.html_content, l.sample_values
    FROM data.document_templates t
    JOIN data.document_template_locales l ON l.template_id = t.id
    WHERE t.id IN (
      '76000000-0000-0000-0000-000000000001',
      '76000000-0000-0000-0000-000000000002',
      '76000000-0000-0000-0000-000000000003',
      '76000000-0000-0000-0000-000000000004',
      '76000000-0000-0000-0000-000000000005',
      '77000000-0000-0000-0000-000000000001'
    )
  LOOP
    v_missing := data.validate_commercial_template_locale(
      v_rec.html_content,
      'text/html',
      CASE WHEN v_rec.category = 'delivery_note' THEN 'delivery_note' ELSE 'quote' END
    );
    IF v_missing <> '{}'::text[] THEN
      RAISE EXCEPTION 'QT-3 locale %/% missing tokens: %', v_rec.category, v_rec.locale, v_missing;
    END IF;

    v_buyer := v_rec.sample_values #>> '{buyer,display_name}';
    IF v_buyer IS DISTINCT FROM 'Client Exemple SL' THEN
      RAISE EXCEPTION 'QT-3 sample_values buyer mismatch: %', v_buyer;
    END IF;

    SELECT count(*) INTO v_tax_n
    FROM jsonb_array_elements(v_rec.sample_values #> '{totals,tax_breakdown}') e;
    IF v_tax_n < 2 THEN
      RAISE EXCEPTION 'QT-3 sample_values need at least two tax rates';
    END IF;
  END LOOP;

  -- Platform seed must not auto-bind tenants (QT-D1 fallback).
  -- A tenant may already have a *tenant* template from other tests; that is fine.
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant, 'quote');
  IF v_resolved IS NOT NULL AND EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = v_resolved AND t.tenant_id IS NULL AND t.is_platform_default
  ) THEN
    RAISE EXCEPTION 'QT-3 must not auto-resolve platform quote template, got %', v_resolved;
  END IF;

  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant, 'delivery_note');
  IF v_resolved IS NOT NULL AND EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = v_resolved AND t.tenant_id IS NULL AND t.is_platform_default
  ) THEN
    RAISE EXCEPTION 'QT-3 must not auto-resolve platform delivery template, got %', v_resolved;
  END IF;

  RAISE NOTICE 'QT-3 seed HTML tests PASS';
END $$;
