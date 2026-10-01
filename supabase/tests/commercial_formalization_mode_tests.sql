-- CT-1: formalization_mode default, override, immutability, clause and template.
-- One statement so `supabase db query --file` rolls the fixture back.
DO $$
DECLARE
  v_op_1 uuid := gen_random_uuid();
  v_op_2 uuid := gen_random_uuid();
  v_op_3 uuid := gen_random_uuid();
  v_op_4 uuid := gen_random_uuid();
  v_op_5 uuid := gen_random_uuid();
  v_op_6 uuid := gen_random_uuid();
  v_op_7 uuid := gen_random_uuid();
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_default uuid;
  v_override uuid;
  v_reissued uuid;
  v_mode text;
  v_status text;
  v_payload text;
  v_html text;
  v_sample text;
  v_accept_def text;
  v_agreements_before integer;
BEGIN
  BEGIN
    PERFORM set_config(
      'request.jwt.claim.sub',
      '20000000-0000-0000-0000-000000000002',
      true
    );
    PERFORM set_config(
      'request.jwt.claim',
      '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
      true
    );
    PERFORM set_config(
      'request.headers',
      '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}',
      true
    );

    SELECT count(*) INTO v_agreements_before FROM data.commercial_agreements;

    UPDATE data.tenants
    SET settings = COALESCE(settings, '{}'::jsonb)
      || jsonb_build_object(
        'commercial',
        COALESCE(settings -> 'commercial', '{}'::jsonb)
          || jsonb_build_object('formalization_mode_default', 'separate_agreement')
      )
    WHERE id = v_tenant;

    v_default := api.issue_commercial_document(
      v_project, 'quote', true,
      v_op_1,
      NULL, NULL, NULL
    );

    SELECT formalization_mode INTO v_mode
    FROM data.commercial_documents WHERE id = v_default;
    SELECT payload ->> 'formalization_mode' INTO v_payload
    FROM data.commercial_document_events
    WHERE document_id = v_default AND event_type = 'issued';
    IF v_mode <> 'separate_agreement' OR v_payload <> 'separate_agreement' THEN
      RAISE EXCEPTION 'CT1 tenant default failed: mode=% payload=%', v_mode, v_payload;
    END IF;
    IF (SELECT count(*) FROM data.commercial_agreements) <> v_agreements_before THEN
      RAISE EXCEPTION 'CT1 issue created an agreement';
    END IF;

    v_override := api.issue_commercial_document(
      v_project, 'quote', true,
      v_op_2,
      NULL, 'signed_quote',
      '76000000-0000-0000-0000-000000000006'::uuid
    );
    SELECT formalization_mode, full_body_template_id::text
    INTO v_mode, v_payload
    FROM data.commercial_documents WHERE id = v_override;
    IF v_mode <> 'signed_quote'
       OR v_payload <> '76000000-0000-0000-0000-000000000006' THEN
      RAISE EXCEPTION 'CT1 override failed: mode=% template=%', v_mode, v_payload;
    END IF;

    BEGIN
      UPDATE data.commercial_documents
      SET formalization_mode = 'separate_agreement'
      WHERE id = v_override;
      RAISE EXCEPTION 'CT1 issued mode update was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%commercial_document_immutable%' THEN
        RAISE;
      END IF;
    END;

    UPDATE data.commercial_documents
    SET status = 'draft'
    WHERE id = v_override;
    PERFORM api.set_quote_formalization(
      v_override,
      'separate_agreement',
      v_op_3
    );
    SELECT status, formalization_mode INTO v_status, v_mode
    FROM data.commercial_documents WHERE id = v_override;
    IF v_status <> 'draft' OR v_mode <> 'separate_agreement' THEN
      RAISE EXCEPTION 'CT1 draft update failed: status=% mode=%', v_status, v_mode;
    END IF;

    BEGIN
      PERFORM api.set_quote_formalization(
        v_override, 'nope', v_op_4
      );
      RAISE EXCEPTION 'CT1 invalid mode was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%invalid_formalization_mode%' THEN
        RAISE;
      END IF;
    END;

    UPDATE data.commercial_documents
    SET status = 'issued'
    WHERE id = v_override;

    BEGIN
      PERFORM api.set_quote_formalization(
        v_override,
        'signed_quote',
        v_op_5
      );
      RAISE EXCEPTION 'CT1 issued set_quote_formalization was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%commercial_document_immutable%' THEN
        RAISE;
      END IF;
    END;

    UPDATE data.commercial_documents
    SET status = 'cancelled'
    WHERE project_id = v_project
      AND tenant_id = v_tenant
      AND doc_type = 'quote'
      AND id <> v_override
      AND status = 'issued';

    PERFORM api.reject_commercial_document(
      v_override,
      '{"method":"sql_test"}'::jsonb,
      v_op_6
    );
    v_reissued := api.reissue_commercial_quote(
      v_override,
      v_op_7
    );
    SELECT formalization_mode, full_body_template_id::text
    INTO v_mode, v_payload
    FROM data.commercial_documents WHERE id = v_reissued;
    IF v_mode <> 'separate_agreement'
       OR v_payload <> '76000000-0000-0000-0000-000000000006' THEN
      RAISE EXCEPTION 'CT1 reissue did not keep mode/template: mode=% template=%', v_mode, v_payload;
    END IF;

    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    JOIN data.document_templates t ON t.id = l.template_id
    WHERE t.id = '76000000-0000-0000-0000-000000000001'
      AND l.locale = 'ca';
    IF v_html IS NULL OR v_html NOT LIKE '%constitueix el contracte%' THEN
      RAISE EXCEPTION 'CT1 ca clause missing';
    END IF;

    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = '76000000-0000-0000-0000-000000000006'
      AND l.locale = 'es';
    IF v_html IS NULL
       OR v_html NOT LIKE '%Presupuesto y contrato de servicios n.º%'
       OR v_html NOT LIKE '%constituye el contrato%' THEN
      RAISE EXCEPTION 'CT1 quote-contract template missing';
    END IF;

    SELECT l.sample_values::text INTO v_sample
    FROM data.document_template_locales l
    JOIN data.document_templates t ON t.id = l.template_id
    WHERE t.tenant_id IS NULL
      AND t.category = 'quote'
      AND l.locale = 'ca'
      AND l.sample_values::text LIKE '%Visita tècnica%'
    LIMIT 1;
    IF v_sample IS NULL THEN
      RAISE EXCEPTION 'CT1 Visita tècnica sample was removed';
    END IF;

    SELECT string_agg(pg_get_functiondef(p.oid), E'\n')
    INTO v_accept_def
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api'
      AND p.proname = 'accept_commercial_document';
    IF v_accept_def ILIKE '%prepare_agreement%'
       OR v_accept_def ILIKE '%commercial_agreements%' THEN
      RAISE EXCEPTION 'CT1 accept must not create an agreement';
    END IF;

    RAISE EXCEPTION USING
      ERRCODE = 'ZZ001',
      MESSAGE = 'formalization mode tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: default, override, draft, issued lock, clause, template';
  END;
END;
$$;
