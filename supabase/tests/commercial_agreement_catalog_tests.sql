-- CT-5: catalog tokens, visita sample intact, reissue does not keep the old quote as source.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_source uuid := '51000000-0000-0000-0000-000000000101';
  v_project uuid := '52000000-0000-0000-0000-000000000501';
  v_site uuid;
  v_client uuid;
  v_html text;
  v_sample text;
  v_quote uuid;
  v_reissued uuid;
  v_before integer;
  v_hash text;
  v_hash_new text;
  v_mode text;
  v_accept text;
BEGIN
  BEGIN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.id = '78100000-0000-0000-0000-000000000011';
    IF v_html IS NULL
       OR position('source_quote.doc_number' IN v_html) = 0
       OR position('source_quote.content_hash' IN v_html) = 0
       OR position('{% for line in lines %}' IN v_html) = 0
       OR position('totals.total' IN v_html) = 0
       OR position('role="client"' IN v_html) = 0
       OR position('client_accept' IN v_html) > 0
       OR position('client_reject' IN v_html) > 0 THEN
      RAISE EXCEPTION 'CT5 ca agreement template is incomplete';
    END IF;

    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.id = '79100000-0000-0000-0000-000000000011';
    IF v_html IS NULL
       OR position('source_quote.doc_number' IN v_html) = 0
       OR position('role="client"' IN v_html) = 0
       OR position('client_accept' IN v_html) > 0 THEN
      RAISE EXCEPTION 'CT5 es agreement template is incomplete';
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
      RAISE EXCEPTION 'CT5 Visita tècnica sample was removed';
    END IF;

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
            v_tenant::text, json_build_object('global_permissions', json_build_array('*'), 'sites', json_build_object())
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

    SELECT site_id, client_id INTO v_site, v_client FROM data.projects WHERE id = v_source;
    INSERT INTO data.projects (
      id, tenant_id, type, name, status, visibility, site_id, client_id,
      created_by, commercial_regime, service_mode
    ) VALUES (
      v_project, v_tenant, 'work_order', 'CT5 reissue', 'active', 'company',
      v_site, v_client, v_owner, 'consumer', 'execute'
    );
    PERFORM api.upsert_project_line(
      v_project, NULL, NULL, 'service', 'CT5', NULL, 'u',
      1, 10, 0, 21, 0, NULL, '91000000-0000-0000-0000-0000000005a1'::uuid
    );

    v_quote := api.issue_commercial_document(
      v_project, 'quote', true,
      '91000000-0000-0000-0000-0000000005a2'::uuid,
      NULL, 'separate_agreement', NULL
    );
    SELECT content_hash INTO v_hash FROM data.commercial_documents WHERE id = v_quote;
    PERFORM api.reject_commercial_document(
      v_quote, '{"method":"sql_test"}'::jsonb,
      '91000000-0000-0000-0000-0000000005a3'::uuid
    );
    BEGIN
      PERFORM api.prepare_agreement_from_quote(
        v_quote,
        '76100000-0000-0000-0000-000000000001'::uuid,
        'none',
        '91000000-0000-0000-0000-0000000005a4'::uuid
      );
      RAISE EXCEPTION 'CT5 rejected quote was prepared';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%quote_not_accepted%' THEN
        RAISE;
      END IF;
    END;

    v_reissued := api.reissue_commercial_quote(
      v_quote,
      '91000000-0000-0000-0000-0000000005a5'::uuid
    );
    SELECT content_hash, formalization_mode INTO v_hash_new, v_mode
    FROM data.commercial_documents WHERE id = v_reissued;
    IF v_reissued = v_quote OR v_hash_new IS NOT DISTINCT FROM v_hash OR v_mode <> 'separate_agreement' THEN
      RAISE EXCEPTION 'CT5 reissue did not create a new snapshot: old=% new=% mode=%', v_hash, v_hash_new, v_mode;
    END IF;

    SELECT count(*) INTO v_before FROM data.commercial_agreements WHERE source_quote_id IN (v_quote, v_reissued);
    PERFORM api.accept_commercial_document(
      v_reissued, '{"method":"sql_test"}'::jsonb,
      '91000000-0000-0000-0000-0000000005a6'::uuid
    );
    IF (SELECT count(*) FROM data.commercial_agreements WHERE source_quote_id IN (v_quote, v_reissued)) <> v_before THEN
      RAISE EXCEPTION 'CT5 accept of reissue created an agreement';
    END IF;
    IF (SELECT commercial_regime FROM data.projects WHERE id = v_project) IS DISTINCT FROM 'consumer' THEN
      RAISE EXCEPTION 'CT5 regime changed';
    END IF;

    SELECT string_agg(pg_get_functiondef(p.oid), E'\n') INTO v_accept
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'accept_commercial_document';
    IF v_accept ILIKE '%prepare_agreement_from_quote%' THEN
      RAISE EXCEPTION 'CT5 accept calls prepare';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'catalog tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: agreement catalog, visita sample, reissue snapshot';
  END;
END;
$$;
