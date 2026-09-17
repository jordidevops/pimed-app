-- QT-1: resolver isolation, letterhead unchanged, legal validation + ack audit.
DO $$
DECLARE
  v_tenant_a uuid := '10000000-0000-0000-0000-000000000003';
  v_tenant_b uuid := '10000000-0000-0000-0000-000000000002';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-0000000000a1';
  v_tpl_a uuid := '76a10000-0000-0000-0000-000000000001';
  v_tpl_a2 uuid := '76a10000-0000-0000-0000-000000000002';
  v_tpl_b uuid := '76a20000-0000-0000-0000-000000000001';
  v_quote uuid;
  v_resolved uuid;
  v_letterhead uuid;
  v_missing text[];
  v_err text;
  v_audits int;
  v_full uuid;
  v_ok json;
  v_quote_html text :=
    '{% for line in lines %}{{ line.name }}{% endfor %}'
    || '{{ totals.total }}{{ document.doc_number }}{{ document.valid_until }}{{ totals.tax_breakdown }}'
    || '<signature-field role="client_accept"></signature-field>'
    || '<signature-field role="client_reject"></signature-field>';
  v_delivery_html text :=
    '{% for line in lines %}{{ line.name }}{% endfor %}'
    || '{{ document.doc_number }}'
    || '<signature-field role="client_delivery"></signature-field>';
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

  -- Cleanup previous runs
  DELETE FROM data.document_template_locales
  WHERE template_id IN (v_tpl_a, v_tpl_a2, v_tpl_b);
  DELETE FROM data.document_templates
  WHERE id IN (v_tpl_a, v_tpl_a2, v_tpl_b);
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb) - 'commercial'
      || jsonb_build_object(
        'commercial',
        COALESCE(settings -> 'commercial', '{}'::jsonb) - 'quote_template_id' - 'delivery_note_template_id'
      )
  WHERE id IN (v_tenant_a, v_tenant_b);

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant_a, 'work_order', 'QT-1 full body test',
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

  -- 1. Tenant without quote/delivery_note template: resolver NULL; letterhead unchanged
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote');
  IF v_resolved IS NOT NULL THEN
    RAISE EXCEPTION 'QT1 FAIL: expected NULL full-body resolver without quote template, got %', v_resolved;
  END IF;
  v_letterhead := data.resolve_commercial_document_template_id(v_tenant_a);

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Base QT-1', NULL, 'u',
    1, 40, 0, 21, 0, NULL,
    '0a100000-0000-0000-0000-000000000001'::uuid
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    '0a100000-0000-0000-0000-000000000002'::uuid,
    NULL
  );
  SELECT full_body_template_id, document_template_id
    INTO v_full, v_resolved
  FROM data.commercial_documents WHERE id = v_quote;
  IF v_full IS NOT NULL THEN
    RAISE EXCEPTION 'QT1 FAIL: issued quote without own template must keep full_body_template_id NULL';
  END IF;
  IF v_resolved IS DISTINCT FROM v_letterhead THEN
    RAISE EXCEPTION 'QT1 FAIL: letterhead document_template_id changed for tenant without full-body template';
  END IF;

  -- 2. validate_commercial_template_locale token sets
  v_missing := data.validate_commercial_template_locale('<p>buit</p>', 'text/html', 'quote');
  IF v_missing IS DISTINCT FROM ARRAY[
    'lines_loop', 'totals.total', 'document.doc_number', 'document.valid_until',
    'tax_breakdown', 'client_accept', 'client_reject'
  ] THEN
    RAISE EXCEPTION 'QT1 FAIL: quote missing tokens got %', v_missing;
  END IF;
  v_missing := data.validate_commercial_template_locale(v_quote_html, 'text/html', 'quote');
  IF COALESCE(array_length(v_missing, 1), 0) <> 0 THEN
    RAISE EXCEPTION 'QT1 FAIL: complete quote html should be valid, got %', v_missing;
  END IF;
  v_missing := data.validate_commercial_template_locale(v_quote_html, 'text/html', 'quote_amendment');
  IF COALESCE(array_length(v_missing, 1), 0) <> 0 THEN
    RAISE EXCEPTION 'QT1 FAIL: amendment should use quote token set';
  END IF;
  v_missing := data.validate_commercial_template_locale('<p>buit</p>', 'text/html', 'delivery_note');
  IF v_missing IS DISTINCT FROM ARRAY['lines_loop', 'document.doc_number', 'client_delivery'] THEN
    RAISE EXCEPTION 'QT1 FAIL: delivery_note missing tokens got %', v_missing;
  END IF;
  v_missing := data.validate_commercial_template_locale(v_delivery_html, 'text/html', 'delivery_note');
  IF COALESCE(array_length(v_missing, 1), 0) <> 0 THEN
    RAISE EXCEPTION 'QT1 FAIL: complete delivery html should be valid, got %', v_missing;
  END IF;
  v_missing := data.validate_commercial_template_locale(v_quote_html, NULL, 'quote');
  IF COALESCE(array_length(v_missing, 1), 0) <> 0 THEN
    RAISE EXCEPTION 'QT1 FAIL: NULL mime_type must return empty array';
  END IF;
  BEGIN
    PERFORM data.validate_commercial_template_locale('x', 'text/html', 'invoice');
    RAISE EXCEPTION 'QT1 FAIL: invalid_doc_type should raise';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%invalid_doc_type%' THEN
      RAISE;
    END IF;
  END;

  -- 3. Templates A (two quotes) + B (other tenant)
  INSERT INTO data.document_templates (
    id, tenant_id, name, category, template_type, is_platform_default, is_active, created_by, created_at
  ) VALUES
    (v_tpl_a, v_tenant_a, 'QT-1 quote A1', 'quote', 'html', false, true, v_owner, now() - interval '2 hours'),
    (v_tpl_a2, v_tenant_a, 'QT-1 quote A2', 'quote', 'html', false, true, v_owner, now() - interval '1 hour'),
    (v_tpl_b, v_tenant_b, 'QT-1 quote B', 'quote', 'html', false, true, v_owner, now());

  -- Draft (inactive) without legal tokens is allowed
  v_ok := api.upsert_document_template_locale(
    v_tpl_a, 'ca', 'text/html', NULL, '<p>esborrany</p>',
    '{}'::jsonb, '{}'::jsonb, NULL, false, NULL, false
  );
  IF v_ok IS NULL THEN
    RAISE EXCEPTION 'QT1 FAIL: inactive locale without tokens must save';
  END IF;

  -- Activate without tokens fails
  BEGIN
    PERFORM api.upsert_document_template_locale(
      v_tpl_a, 'ca', 'text/html', NULL, '<p>esborrany</p>',
      '{}'::jsonb, '{}'::jsonb, NULL, true, NULL, false
    );
    RAISE EXCEPTION 'QT1 FAIL: activate without tokens must fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%commercial_template_legal_gaps%' THEN
      RAISE;
    END IF;
  END;

  -- Activate with acknowledgement: allowed + audited
  PERFORM api.upsert_document_template_locale(
    v_tpl_a, 'ca', 'text/html', NULL, '<p>esborrany</p>',
    '{}'::jsonb, '{}'::jsonb, NULL, true, NULL, true
  );
  SELECT count(*) INTO v_audits
  FROM data.audit_logs
  WHERE tenant_id = v_tenant_a
    AND entity_id = v_tpl_a
    AND action = 'TEMPLATE_LEGAL_GAP_ACKNOWLEDGED';
  IF v_audits < 1 THEN
    RAISE EXCEPTION 'QT1 FAIL: expected TEMPLATE_LEGAL_GAP_ACKNOWLEDGED audit';
  END IF;

  -- Complete locales for resolver fallback
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

  -- Fallback: oldest tenant A quote (A1)
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote');
  IF v_resolved IS DISTINCT FROM v_tpl_a THEN
    RAISE EXCEPTION 'QT1 FAIL: fallback should be oldest tenant quote %, got %', v_tpl_a, v_resolved;
  END IF;

  -- Settings wins over fallback
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
    RAISE EXCEPTION 'QT1 FAIL: settings quote_template_id should win, got %', v_resolved;
  END IF;
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote_amendment');
  IF v_resolved IS DISTINCT FROM v_tpl_a2 THEN
    RAISE EXCEPTION 'QT1 FAIL: quote_amendment must reuse quote category';
  END IF;

  -- Isolation: pointing A at B's template must not resolve B
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings -> 'commercial', '{}'::jsonb)
        || jsonb_build_object('quote_template_id', v_tpl_b::text)
    )
  WHERE id = v_tenant_a;
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant_a, 'quote');
  IF v_resolved IS DISTINCT FROM v_tpl_a THEN
    RAISE EXCEPTION 'QT1 FAIL: must not resolve other tenant template (got %)', v_resolved;
  END IF;
  IF v_resolved = v_tpl_b THEN
    RAISE EXCEPTION 'QT1 FAIL: isolation breach — tenant B template resolved for A';
  END IF;

  -- Letterhead still ignores quote category
  v_letterhead := data.resolve_commercial_document_template_id(v_tenant_a);
  IF v_letterhead IN (v_tpl_a, v_tpl_a2, v_tpl_b) THEN
    RAISE EXCEPTION 'QT1 FAIL: letterhead resolver returned a quote full-body template';
  END IF;

  RAISE NOTICE 'QT-1 commercial templates tests PASS';
END $$;
