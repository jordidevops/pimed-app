-- Review follow-up: sentinel Cap, hub result_*, trigger re-raise, office gate on apply.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_tpl uuid := '76a10000-0000-0000-0000-0000000000f1';
  v_project uuid := gen_random_uuid();
  v_project_b uuid := gen_random_uuid();
  v_quote uuid;
  v_amend uuid;
  v_quote2 uuid;
  v_session uuid := gen_random_uuid();
  v_session2 uuid := gen_random_uuid();
  v_submission uuid := gen_random_uuid();
  v_version uuid := gen_random_uuid();
  v_dms_doc uuid := gen_random_uuid();
  v_resolved uuid;
  v_status text;
  v_session_status text;
  v_hub_result uuid;
  v_prev_settings jsonb;
  v_applied timestamptz;
  v_quote_html text :=
    '{% for line in lines %}{{ line.name }}{% endfor %}'
    || '{{ totals.total }}{{ document.doc_number }}{{ document.valid_until }}{{ totals.tax_breakdown }}'
    || '<signature-field role="client_accept"></signature-field>'
    || '<signature-field role="client_reject"></signature-field>';
BEGIN
  INSERT INTO data.tenant_members (tenant_id, user_id, role)
  VALUES (v_tenant, v_member, 'member')
  ON CONFLICT (tenant_id, user_id) WHERE site_id IS NULL DO NOTHING;

  SELECT settings INTO v_prev_settings FROM data.tenants WHERE id = v_tenant;

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

  DELETE FROM data.document_template_locales WHERE template_id = v_tpl;
  DELETE FROM data.document_templates WHERE id = v_tpl;

  INSERT INTO data.document_templates (
    id, tenant_id, name, category, template_type, is_platform_default, is_active, created_by
  ) VALUES (
    v_tpl, v_tenant, 'Review quote', 'quote', 'html', false, true, v_owner
  );
  PERFORM api.upsert_document_template_locale(
    v_tpl, 'ca', 'text/html', NULL, v_quote_html,
    '{}'::jsonb, '{}'::jsonb, NULL, true, NULL, false
  );

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings -> 'commercial', '{}'::jsonb)
        || jsonb_build_object('quote_template_id', 'none')
    )
  WHERE id = v_tenant;

  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant, 'quote');
  IF v_resolved IS NOT NULL THEN
    RAISE EXCEPTION 'review FAIL sentinel: expected NULL with Cap=none, got %', v_resolved;
  END IF;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings -> 'commercial', '{}'::jsonb) - 'quote_template_id'
    )
  WHERE id = v_tenant;
  v_resolved := data.resolve_commercial_full_body_template_id(v_tenant, 'quote');
  IF v_resolved IS NULL THEN
    RAISE EXCEPTION 'review FAIL auto-pick: expected a tenant clone after clearing Cap';
  END IF;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES
    (v_project, v_tenant, 'work_order', 'Review A', 'Disposable', 'active', 'company', v_site, v_client, v_owner),
    (v_project_b, v_tenant, 'work_order', 'Review B', 'Disposable', 'active', 'company', v_site, v_client, v_owner);

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Review A line', NULL, 'u',
    1, 40, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb, gen_random_uuid()
  );

  INSERT INTO data.documents (
    id, tenant_id, title, entity_type, entity_id, category, required_permissions, created_by
  ) VALUES (
    v_dms_doc, v_tenant, 'Signed copy', 'commercial_document', v_quote, 'commercial', '{}', v_owner
  );
  INSERT INTO data.document_versions (
    id, document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes, created_by
  ) VALUES (
    v_version, v_dms_doc, 1, 'native', v_tenant::text || '/review-signed.pdf', 'application/pdf', 12, v_owner
  );

  INSERT INTO data.signing_submissions (
    id, tenant_id, source_type, source_document_id, source_document_version_id,
    result_document_version_id, status, signing_provider, document_title, initiated_by, signers
  ) VALUES (
    v_submission, v_tenant, 'document_existing', v_dms_doc, v_version,
    v_version, 'completed', 'native', 'Review signed', v_owner, '[]'::jsonb
  );

  INSERT INTO data.commercial_signing_intents (
    tenant_id, document_id, submission_id, session_id, action, client_op_id, created_by
  ) VALUES (
    v_tenant, v_quote, v_submission, gen_random_uuid(), 'accept', gen_random_uuid(), v_owner
  );

  SELECT result_document_id INTO v_hub_result
  FROM api.commercial_signing_hub
  WHERE submission_id = v_submission;
  IF v_hub_result IS DISTINCT FROM v_dms_doc THEN
    RAISE EXCEPTION 'review FAIL hub result_document_id: expected %, got %', v_dms_doc, v_hub_result;
  END IF;

  -- Trigger must not swallow apply errors (already accepted).
  PERFORM api.upsert_project_line(
    v_project_b, NULL, NULL, 'service', 'Review B line', NULL, 'u',
    1, 50, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote2 := api.issue_commercial_document(
    v_project_b, 'quote', true, gen_random_uuid(), NULL
  );
  INSERT INTO data.document_signing_sessions (
    id, tenant_id, document_version_id, signing_token, signing_type, status,
    signer_name, signer_role, operator_user_id, expires_at
  ) VALUES (
    v_session, v_tenant, gen_random_uuid(),
    'revtoken' || replace(gen_random_uuid()::text, '-', ''),
    'remote', 'pending', 'Client Review', 'client_accept', v_owner, now() + interval '7 days'
  );
  PERFORM api.register_commercial_signing_intent(
    v_quote2, v_session, 'accept', gen_random_uuid(), gen_random_uuid()
  );
  PERFORM api.accept_commercial_document(
    v_quote2, '{"method":"sql_test"}'::jsonb, gen_random_uuid()
  );

  BEGIN
    UPDATE data.document_signing_sessions
    SET status = 'signed'
    WHERE id = v_session;
    RAISE EXCEPTION 'review FAIL trigger: expected apply error to abort session update';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%review FAIL trigger%' THEN
      RAISE;
    END IF;
  END;

  SELECT status INTO v_session_status FROM data.document_signing_sessions WHERE id = v_session;
  IF v_session_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'review FAIL trigger: session should stay pending, got %', v_session_status;
  END IF;

  -- Amendment: member intent + live overage must fail at apply (not only at register).
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb) || jsonb_build_object(
    'commercial', jsonb_build_object('deviation_approval_threshold_eur', 10)
  )
  WHERE id = v_tenant;

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Review extra', NULL, 'u',
    1, 5, 0, 21, 1, NULL, gen_random_uuid()
  );
  v_amend := api.issue_commercial_document(
    v_project, 'quote_amendment', true, gen_random_uuid(), v_quote
  );

  INSERT INTO data.document_signing_sessions (
    id, tenant_id, document_version_id, signing_token, signing_type, status,
    signer_name, signer_role, operator_user_id, expires_at
  ) VALUES (
    v_session2, v_tenant, gen_random_uuid(),
    'rev2token' || replace(gen_random_uuid()::text, '-', ''),
    'remote', 'pending', 'Client Amend', 'client_accept', v_member, now() + interval '7 days'
  );
  INSERT INTO data.commercial_signing_intents (
    tenant_id, document_id, submission_id, session_id, action, client_op_id, created_by
  ) VALUES (
    v_tenant, v_amend, gen_random_uuid(), v_session2, 'accept', gen_random_uuid(), v_member
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Review blow threshold', NULL, 'u',
    1, 80, 0, 21, 2, NULL, gen_random_uuid()
  );
  UPDATE data.projects SET authorized_total = 0 WHERE id = v_project;

  BEGIN
    PERFORM data.commercial_accept_office_gate_for_actor(v_amend, v_member);
    RAISE EXCEPTION 'review FAIL office gate fn: expected office_approval_required';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%office_approval_required%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    UPDATE data.document_signing_sessions
    SET status = 'signed'
    WHERE id = v_session2;
    RAISE EXCEPTION 'review FAIL office gate trigger: expected office_approval_required';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%office_approval_required%' THEN
      RAISE;
    END IF;
  END;

  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_amend;
  SELECT applied_at INTO v_applied
  FROM data.commercial_signing_intents
  WHERE session_id = v_session2;
  IF v_status IS DISTINCT FROM 'issued' THEN
    RAISE EXCEPTION 'review FAIL office gate: amendment should stay issued, got % applied=%', v_status, v_applied;
  END IF;
  IF v_applied IS NOT NULL THEN
    RAISE EXCEPTION 'review FAIL office gate: intent should not be applied';
  END IF;
  SELECT status INTO v_session_status FROM data.document_signing_sessions WHERE id = v_session2;
  IF v_session_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'review FAIL office gate: session should stay pending, got %', v_session_status;
  END IF;

  UPDATE data.tenants SET settings = COALESCE(v_prev_settings, '{}'::jsonb) WHERE id = v_tenant;
  DELETE FROM data.document_template_locales WHERE template_id = v_tpl;
  DELETE FROM data.document_templates WHERE id = v_tpl;

  RAISE NOTICE 'commercial templates review follow-up tests PASS';
END $$;
