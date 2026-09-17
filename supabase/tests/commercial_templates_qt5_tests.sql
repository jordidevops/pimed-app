-- QT-5: §5 of docs/plans/commercial-templates/02-rendering-architecture.md
-- Fallback, resolver, isolation, legal validation, immutability.
-- HTML/PDF identity and signature markers are covered by vitest smoke (no Gotenberg here).
DO $$
DECLARE
  v_tenant_a uuid := '10000000-0000-0000-0000-000000000003';
  v_tenant_b uuid := '10000000-0000-0000-0000-000000000002';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-0000000000a5';
  v_tpl_a uuid := '76a50000-0000-0000-0000-000000000001';
  v_tpl_a2 uuid := '76a50000-0000-0000-0000-000000000002';
  v_tpl_b uuid := '76a50000-0000-0000-0000-000000000003';
  v_platform uuid := '76000000-0000-0000-0000-000000000001';
  v_quote_fb uuid;
  v_quote_own uuid;
  v_resolved uuid;
  v_letterhead uuid;
  v_letterhead_after uuid;
  v_missing text[];
  v_audits int;
  v_full uuid;
  v_ok json;
  v_quote_html text :=
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
        ),
        'user_permissions', json_build_object(
          v_tenant_a::text, json_build_object(
            'global_permissions', json_build_array('*'),
            'sites', json_build_object()
          ),
          v_tenant_b::text, json_build_object(
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
    json_build_object('x-tenant-id', v_tenant_a)::text,
    true
  );

  CREATE TEMP TABLE qt5_saved_settings ON COMMIT DROP AS
  SELECT id, settings FROM data.tenants WHERE id IN (v_tenant_a, v_tenant_b);

  CREATE TEMP TABLE qt5_saved_tpl ON COMMIT DROP AS
  SELECT id, is_active
  FROM data.document_templates
  WHERE tenant_id IN (v_tenant_a, v_tenant_b)
    AND lower(COALESCE(category, '')) IN ('quote', 'delivery_note');

  DELETE FROM data.document_template_locales
  WHERE template_id IN (v_tpl_a, v_tpl_a2, v_tpl_b);
  DELETE FROM data.document_templates
  WHERE id IN (v_tpl_a, v_tpl_a2, v_tpl_b);

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings -> 'commercial', '{}'::jsonb)
        - 'quote_template_id' - 'delivery_note_template_id'
    )
  WHERE id IN (v_tenant_a, v_tenant_b);

  UPDATE data.document_templates
  SET is_active = false
  WHERE tenant_id IN (v_tenant_a, v_tenant_b)
    AND lower(COALESCE(category, '')) IN ('quote', 'delivery_note');

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant_a, 'work_order', 'QT-5 commercial templates tests',
    'Disposable', 'active', 'company', v_site, v_client, v_owner
  )
  ON CONFLICT (id) DO UPDATE SET
    status = 'active',
    client_id = EXCLUDED.client_id,
    updated_at = now();

  ALTER TABLE data.commercial_document_events DISABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_lines DISABLE TRIGGER USER;
  ALTER TABLE data.commercial_documents DISABLE TRIGGER USER;
  DELETE FROM data.commercial_document_events
  WHERE document_id IN (SELECT id FROM data.commercial_documents WHERE project_id = v_project);
  DELETE FROM data.commercial_document_lines
  WHERE document_id IN (SELECT id FROM data.commercial_documents WHERE project_id = v_project);
  UPDATE data.commercial_documents
  SET rendered_document_id = NULL, pdf_job_id = NULL
  WHERE project_id = v_project;
  DELETE FROM data.commercial_documents WHERE project_id = v_project;
  ALTER TABLE data.commercial_documents ENABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_lines ENABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_events ENABLE TRIGGER USER;
  DELETE FROM data.project_lines WHERE project_id = v_project;

  -- ── 1. Fallback: no tenant quote/delivery_note → NULL; letterhead unchanged ─
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote');
  IF v_resolved IS NOT NULL THEN
    RAISE EXCEPTION 'QT5 FAIL fallback: quote resolver must be NULL without tenant template, got %', v_resolved;
  END IF;
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'delivery_note');
  IF v_resolved IS NOT NULL THEN
    RAISE EXCEPTION 'QT5 FAIL fallback: delivery_note resolver must be NULL, got %', v_resolved;
  END IF;
  IF data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote') IS NOT DISTINCT FROM v_platform THEN
    RAISE EXCEPTION 'QT5 FAIL fallback: must not auto-resolve platform seed';
  END IF;

  v_letterhead := data.resolve_commercial_document_template_id(v_tenant_a);

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Base QT-5', NULL, 'u',
    1, 40, 0, 21, 0, NULL,
    '0a500000-0000-0000-0000-000000000001'::uuid
  );
  v_quote_fb := api.issue_commercial_document(
    v_project, 'quote', true,
    '0a500000-0000-0000-0000-000000000002'::uuid,
    NULL
  );
  SELECT full_body_template_id, document_template_id
    INTO v_full, v_resolved
  FROM data.commercial_documents WHERE id = v_quote_fb;
  IF v_full IS NOT NULL THEN
    RAISE EXCEPTION 'QT5 FAIL fallback: issued quote without own template must keep full_body_template_id NULL';
  END IF;
  v_letterhead_after := data.resolve_commercial_document_template_id(v_tenant_a);
  IF v_resolved IS DISTINCT FROM v_letterhead
     OR v_letterhead_after IS DISTINCT FROM v_letterhead THEN
    RAISE EXCEPTION 'QT5 FAIL fallback: letterhead resolver changed';
  END IF;
  IF v_letterhead IS NOT NULL AND v_letterhead IN (v_tpl_a, v_tpl_a2, v_tpl_b, v_platform) THEN
    RAISE EXCEPTION 'QT5 FAIL fallback: letterhead must stay category=commercial';
  END IF;

  -- ── 4. Legal validation (draft ok; activate without tokens fails; ack audits) ─
  INSERT INTO data.document_templates (
    id, tenant_id, name, category, template_type, is_platform_default, is_active, created_by, created_at
  ) VALUES
    (v_tpl_a, v_tenant_a, 'QT-5 quote A1', 'quote', 'html', false, true, v_owner, now() - interval '2 hours'),
    (v_tpl_a2, v_tenant_a, 'QT-5 quote A2', 'quote', 'html', false, true, v_owner, now() - interval '1 hour'),
    (v_tpl_b, v_tenant_b, 'QT-5 quote B', 'quote', 'html', false, true, v_owner, now());

  v_ok := api.upsert_document_template_locale(
    v_tpl_a, 'ca', 'text/html', NULL, '<p>esborrany</p>',
    '{}'::jsonb, '{}'::jsonb, NULL, false, NULL, false
  );
  IF v_ok IS NULL THEN
    RAISE EXCEPTION 'QT5 FAIL legal: inactive locale without tokens must save';
  END IF;

  BEGIN
    PERFORM api.upsert_document_template_locale(
      v_tpl_a, 'ca', 'text/html', NULL, '<p>sense linies ni total</p>',
      '{}'::jsonb, '{}'::jsonb, NULL, true, NULL, false
    );
    RAISE EXCEPTION 'QT5 FAIL legal: activate without lines/total must fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%commercial_template_legal_gaps%' THEN
      RAISE;
    END IF;
  END;

  PERFORM api.upsert_document_template_locale(
    v_tpl_a, 'ca', 'text/html', NULL, '<p>sense linies ni total</p>',
    '{}'::jsonb, '{}'::jsonb, NULL, true, NULL, true
  );
  SELECT count(*) INTO v_audits
  FROM data.audit_logs
  WHERE tenant_id = v_tenant_a
    AND entity_id = v_tpl_a
    AND action = 'TEMPLATE_LEGAL_GAP_ACKNOWLEDGED';
  IF v_audits < 1 THEN
    RAISE EXCEPTION 'QT5 FAIL legal: expected TEMPLATE_LEGAL_GAP_ACKNOWLEDGED audit';
  END IF;

  v_missing := data.validate_commercial_template_locale('<p>buit</p>', 'text/html', 'quote');
  IF v_missing IS DISTINCT FROM ARRAY[
    'lines_loop', 'totals.total', 'document.doc_number', 'document.valid_until',
    'tax_breakdown', 'client_accept', 'client_reject'
  ] THEN
    RAISE EXCEPTION 'QT5 FAIL legal: quote missing tokens got %', v_missing;
  END IF;

  PERFORM api.upsert_document_template_locale(
    v_tpl_a, 'ca', 'text/html', NULL, v_quote_html,
    '{}'::jsonb, '{}'::jsonb, NULL, true, NULL, false
  );
  PERFORM api.upsert_document_template_locale(
    v_tpl_a2, 'ca', 'text/html', NULL, v_quote_html,
    '{}'::jsonb, '{}'::jsonb, NULL, true, NULL, false
  );
  PERFORM api.upsert_document_template_locale(
    v_tpl_b, 'ca', 'text/html', NULL, v_quote_html,
    '{}'::jsonb, '{}'::jsonb, NULL, true, NULL, false
  );

  -- ── 2. Resolver: oldest tenant template; settings wins ─────────────────────
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote');
  IF v_resolved IS DISTINCT FROM v_tpl_a THEN
    RAISE EXCEPTION 'QT5 FAIL resolver: oldest tenant quote should be %, got %', v_tpl_a, v_resolved;
  END IF;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings -> 'commercial', '{}'::jsonb)
        || jsonb_build_object('quote_template_id', v_tpl_a2::text)
    )
  WHERE id = v_tenant_a;
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote');
  IF v_resolved IS DISTINCT FROM v_tpl_a2 THEN
    RAISE EXCEPTION 'QT5 FAIL resolver: settings quote_template_id should win, got %', v_resolved;
  END IF;
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote_amendment');
  IF v_resolved IS DISTINCT FROM v_tpl_a2 THEN
    RAISE EXCEPTION 'QT5 FAIL resolver: quote_amendment must reuse quote settings';
  END IF;

  -- ── 3. Isolation: never resolve tenant B (settings, platform flag, tenant_id) ─
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings -> 'commercial', '{}'::jsonb)
        || jsonb_build_object('quote_template_id', v_tpl_b::text)
    )
  WHERE id = v_tenant_a;
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote');
  IF v_resolved = v_tpl_b THEN
    RAISE EXCEPTION 'QT5 FAIL isolation: tenant B template resolved for A via settings';
  END IF;
  IF v_resolved IS DISTINCT FROM v_tpl_a THEN
    RAISE EXCEPTION 'QT5 FAIL isolation: expected fallback to own oldest %, got %', v_tpl_a, v_resolved;
  END IF;

  BEGIN
    UPDATE data.document_templates
    SET is_platform_default = true
    WHERE id = v_tpl_b;
    RAISE EXCEPTION 'QT5 FAIL isolation: tenant template must not become is_platform_default';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  -- ── tenant_id moved to B must not resolve for A ────────────────────────────
  UPDATE data.document_templates
  SET tenant_id = v_tenant_b
  WHERE id = v_tpl_a2;
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings -> 'commercial', '{}'::jsonb)
        || jsonb_build_object('quote_template_id', v_tpl_a2::text)
    )
  WHERE id = v_tenant_a;
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote');
  IF v_resolved = v_tpl_a2 THEN
    RAISE EXCEPTION 'QT5 FAIL isolation: moving template tenant_id to B still resolved for A';
  END IF;
  UPDATE data.document_templates
  SET tenant_id = v_tenant_a
  WHERE id = v_tpl_a2;

  -- ── 5. Immutability: snapshot on issue; deactivate / settings must not rewrite ─
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings -> 'commercial', '{}'::jsonb)
        || jsonb_build_object('quote_template_id', v_tpl_a::text)
    )
  WHERE id = v_tenant_a;

  v_quote_own := api.issue_commercial_document(
    v_project, 'quote', true,
    '0a500000-0000-0000-0000-000000000003'::uuid,
    NULL
  );
  SELECT full_body_template_id INTO v_full
  FROM data.commercial_documents WHERE id = v_quote_own;
  IF v_full IS DISTINCT FROM v_tpl_a THEN
    RAISE EXCEPTION 'QT5 FAIL immutability: issued quote should snapshot %, got %', v_tpl_a, v_full;
  END IF;

  UPDATE data.document_templates SET is_active = false WHERE id = v_tpl_a;
  SELECT full_body_template_id INTO v_resolved
  FROM data.commercial_documents WHERE id = v_quote_own;
  IF v_resolved IS DISTINCT FROM v_tpl_a THEN
    RAISE EXCEPTION 'QT5 FAIL immutability: deactivating template changed issued full_body_template_id';
  END IF;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings -> 'commercial', '{}'::jsonb)
        || jsonb_build_object('quote_template_id', v_tpl_a2::text)
    )
  WHERE id = v_tenant_a;
  SELECT full_body_template_id INTO v_resolved
  FROM data.commercial_documents WHERE id = v_quote_own;
  IF v_resolved IS DISTINCT FROM v_tpl_a THEN
    RAISE EXCEPTION 'QT5 FAIL immutability: changing settings rewrote issued full_body_template_id';
  END IF;

  BEGIN
    UPDATE data.commercial_documents
    SET full_body_template_id = v_tpl_a2
    WHERE id = v_quote_own;
    RAISE EXCEPTION 'QT5 FAIL immutability: UPDATE full_body_template_id on issued doc must fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%commercial_document_immutable%' THEN
      RAISE;
    END IF;
  END;

  SELECT full_body_template_id INTO v_resolved
  FROM data.commercial_documents WHERE id = v_quote_own;
  IF v_resolved IS DISTINCT FROM v_tpl_a THEN
    RAISE EXCEPTION 'QT5 FAIL immutability: failed UPDATE still mutated the snapshot';
  END IF;

  -- Cleanup QT-5 fixtures; restore prior tenant templates/settings
  ALTER TABLE data.commercial_document_events DISABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_lines DISABLE TRIGGER USER;
  ALTER TABLE data.commercial_documents DISABLE TRIGGER USER;
  DELETE FROM data.commercial_document_events
  WHERE document_id IN (SELECT id FROM data.commercial_documents WHERE project_id = v_project);
  DELETE FROM data.commercial_document_lines
  WHERE document_id IN (SELECT id FROM data.commercial_documents WHERE project_id = v_project);
  UPDATE data.commercial_documents
  SET rendered_document_id = NULL, pdf_job_id = NULL
  WHERE project_id = v_project;
  DELETE FROM data.commercial_documents WHERE project_id = v_project;
  ALTER TABLE data.commercial_documents ENABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_lines ENABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_events ENABLE TRIGGER USER;
  DELETE FROM data.project_lines WHERE project_id = v_project;
  DELETE FROM data.projects WHERE id = v_project;

  DELETE FROM data.document_template_locales
  WHERE template_id IN (v_tpl_a, v_tpl_a2, v_tpl_b);
  DELETE FROM data.document_templates
  WHERE id IN (v_tpl_a, v_tpl_a2, v_tpl_b);

  UPDATE data.document_templates t
  SET is_active = s.is_active
  FROM qt5_saved_tpl s
  WHERE t.id = s.id;

  UPDATE data.tenants t
  SET settings = s.settings
  FROM qt5_saved_settings s
  WHERE t.id = s.id;

  RAISE NOTICE 'QT-5 commercial templates tests PASS';
END $$;
