-- QT-8: authorship of signature fields on the 6 platform templates (HTML + DOCX).
-- HTML locales must pass validate_commercial_template_locale without ack and
-- include equal 220×70 <signature-field> boxes (01 §3/§4).
-- DOCX stores html_content NULL; we check signing_roles_schema instead.
-- Fallback QT-D1: platform templates must not auto-resolve.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_rec record;
  v_missing text[];
  v_roles jsonb;
  v_resolved uuid;
  v_html_n int;
  v_docx_n int;
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

  SELECT count(*) INTO v_html_n
  FROM data.document_templates t
  JOIN data.document_template_locales l ON l.template_id = t.id
  WHERE t.tenant_id IS NULL AND t.is_platform_default AND t.is_active
    AND t.template_type = 'html'
    AND t.category IN ('quote', 'delivery_note')
    AND l.locale IN ('ca', 'es')
    AND l.is_active;

  IF v_html_n <> 12 THEN
    RAISE EXCEPTION 'QT-8 expected 12 HTML locales, found %', v_html_n;
  END IF;

  FOR v_rec IN
    SELECT t.category, l.locale, l.html_content, l.signing_roles_schema, t.id, t.template_type
    FROM data.document_templates t
    JOIN data.document_template_locales l ON l.template_id = t.id
    WHERE t.tenant_id IS NULL AND t.is_platform_default AND t.is_active
      AND t.template_type = 'html'
      AND t.category IN ('quote', 'delivery_note')
      AND l.locale IN ('ca', 'es')
      AND l.is_active
  LOOP
    v_missing := data.validate_commercial_template_locale(
      v_rec.html_content,
      'text/html',
      CASE WHEN v_rec.category = 'delivery_note' THEN 'delivery_note' ELSE 'quote' END
    );
    IF v_missing <> '{}'::text[] THEN
      RAISE EXCEPTION 'QT-8 HTML %/% missing tokens: %', v_rec.category, v_rec.locale, v_missing;
    END IF;

    IF v_rec.category = 'delivery_note' THEN
      IF position('role="client_delivery"' IN v_rec.html_content) = 0 THEN
        RAISE EXCEPTION 'QT-8 HTML delivery missing client_delivery';
      END IF;
      IF v_rec.html_content !~ 'role="client_delivery"[^>]*width:220px' THEN
        RAISE EXCEPTION 'QT-8 HTML delivery signature box is not 220px';
      END IF;
    ELSE
      IF position('role="client_accept"' IN v_rec.html_content) = 0
         OR position('role="client_reject"' IN v_rec.html_content) = 0 THEN
        RAISE EXCEPTION 'QT-8 HTML quote missing accept/reject';
      END IF;
      IF v_rec.html_content !~ 'role="client_accept"[^>]*width:220px'
         OR v_rec.html_content !~ 'role="client_reject"[^>]*width:220px' THEN
        RAISE EXCEPTION 'QT-8 HTML quote signature boxes are not equal 220px';
      END IF;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_docx_n
  FROM data.document_templates t
  JOIN data.document_template_locales l ON l.template_id = t.id
  WHERE t.tenant_id IS NULL AND t.is_platform_default AND t.is_active
    AND t.template_type = 'docx'
    AND t.category IN ('quote', 'delivery_note')
    AND l.locale IN ('ca', 'es')
    AND l.is_active;

  IF v_docx_n <> 12 THEN
    RAISE EXCEPTION 'QT-8 expected 12 DOCX locales, found %', v_docx_n;
  END IF;

  FOR v_rec IN
    SELECT t.category, l.locale, l.signing_roles_schema, l.html_content
    FROM data.document_templates t
    JOIN data.document_template_locales l ON l.template_id = t.id
    WHERE t.tenant_id IS NULL AND t.is_platform_default AND t.is_active
      AND t.template_type = 'docx'
      AND t.category IN ('quote', 'delivery_note')
      AND l.locale IN ('ca', 'es')
      AND l.is_active
  LOOP
    IF v_rec.html_content IS NOT NULL THEN
      RAISE EXCEPTION 'QT-8 DOCX locale must keep html_content NULL';
    END IF;
    v_roles := COALESCE(v_rec.signing_roles_schema, '{}'::jsonb);
    IF v_rec.category = 'delivery_note' THEN
      IF NOT (v_roles ? 'client_delivery') THEN
        RAISE EXCEPTION 'QT-8 DOCX delivery missing client_delivery role';
      END IF;
    ELSE
      IF NOT (v_roles ? 'client_accept') OR NOT (v_roles ? 'client_reject') THEN
        RAISE EXCEPTION 'QT-8 DOCX quote missing accept/reject roles';
      END IF;
    END IF;
  END LOOP;

  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant, 'quote');
  IF v_resolved IS NOT NULL AND EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = v_resolved AND t.tenant_id IS NULL AND t.is_platform_default
  ) THEN
    RAISE EXCEPTION 'QT-8 must not auto-resolve platform quote template';
  END IF;

  RAISE NOTICE 'QT-8 signature field authorship tests passed';
END;
$$;
