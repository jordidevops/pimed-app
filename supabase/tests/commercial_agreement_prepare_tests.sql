-- CT-3: prepare is explicit, idempotent, and copies the quote hash. Accept does not prepare.
DO $$
DECLARE
  v_op_1 uuid := gen_random_uuid();
  v_op_2 uuid := gen_random_uuid();
  v_op_3 uuid := gen_random_uuid();
  v_op_4 uuid := gen_random_uuid();
  v_op_5 uuid := gen_random_uuid();
  v_op_6 uuid := gen_random_uuid();
  v_op_7 uuid := gen_random_uuid();
  v_op_8 uuid := gen_random_uuid();
  v_op_9 uuid := gen_random_uuid();
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_quote uuid;
  v_signed uuid;
  v_agreement uuid;
  v_retry uuid;
  v_again uuid;
  v_hash text;
  v_quote_hash text;
  v_count integer;
  v_before integer;
  v_accept text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
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

    SELECT count(*) INTO v_before FROM data.commercial_agreements;

    v_quote := api.issue_commercial_document(
      v_project, 'quote', true,
      v_op_1,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote,
      '{"method":"sql_test"}'::jsonb,
      v_op_2
    );
    IF (SELECT count(*) FROM data.commercial_agreements) <> v_before THEN
      RAISE EXCEPTION 'CT3 accept created an agreement';
    END IF;

    SELECT content_hash INTO v_quote_hash FROM data.commercial_documents WHERE id = v_quote;

    v_agreement := api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_3
    );
    v_retry := api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_3
    );
    IF v_agreement IS DISTINCT FROM v_retry THEN
      RAISE EXCEPTION 'CT3 client_op was not idempotent';
    END IF;

    SELECT count(*) INTO v_count
    FROM data.commercial_agreements
    WHERE source_quote_id = v_quote;
    SELECT v.source_quote_content_hash INTO v_hash
    FROM data.commercial_agreement_versions v
    WHERE v.agreement_id = v_agreement;
    IF v_count <> 1 OR v_hash IS DISTINCT FROM v_quote_hash THEN
      RAISE EXCEPTION 'CT3 hash/count failed count=% hash=% quote=%', v_count, v_hash, v_quote_hash;
    END IF;

    v_again := api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_4
    );
    SELECT count(*) INTO v_count
    FROM data.commercial_agreements WHERE source_quote_id = v_quote;
    IF v_again IS DISTINCT FROM v_agreement OR v_count <> 1 THEN
      RAISE EXCEPTION 'CT3 second prepare duplicated the agreement';
    END IF;

    BEGIN
      PERFORM api.mark_agreement_sent_for_signature(
        (SELECT id FROM data.commercial_agreement_versions WHERE agreement_id = v_agreement),
        NULL,
        'client_accept',
        v_op_5
      );
      RAISE EXCEPTION 'CT3 client_accept role was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_signer_role_invalid%' THEN
        RAISE;
      END IF;
    END;

    v_signed := api.issue_commercial_document(
      v_project, 'quote', true,
      v_op_6,
      NULL, 'signed_quote', NULL
    );
    PERFORM api.accept_commercial_document(
      v_signed,
      '{"method":"sql_test"}'::jsonb,
      v_op_7
    );
    BEGIN
      PERFORM api.prepare_agreement_from_quote(
        v_signed,
        '76100000-0000-0000-0000-000000000001'::uuid,
        'none',
        v_op_8
      );
      RAISE EXCEPTION 'CT3 signed_quote prepare was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%quote_not_separate_agreement%' THEN
        RAISE;
      END IF;
    END;

    UPDATE data.tenant_members
    SET role = 'member'
    WHERE tenant_id = v_tenant
      AND user_id = v_member
      AND site_id IS NULL;
    INSERT INTO data.tenant_members (tenant_id, user_id, role)
    VALUES (v_tenant, v_member, 'member')
    ON CONFLICT (tenant_id, user_id) WHERE site_id IS NULL DO NOTHING;

    PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
    PERFORM set_config(
      'request.jwt.claim',
      json_build_object(
        'sub', v_member,
        'role', 'authenticated',
        'app_metadata', json_build_object(
          'user_tenants', json_build_object(
            v_tenant::text, json_build_object('global_role', 'member', 'sites', json_build_object())
          )
        )
      )::text,
      true
    );
    BEGIN
      PERFORM api.prepare_agreement_from_quote(
        v_quote,
        '76100000-0000-0000-0000-000000000001'::uuid,
        'none',
        v_op_9
      );
      RAISE EXCEPTION 'CT3 member prepare was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%permission_denied%' THEN
        RAISE;
      END IF;
    END;

    SELECT string_agg(pg_get_functiondef(p.oid), E'\n') INTO v_accept
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'accept_commercial_document';
    IF v_accept ILIKE '%prepare_agreement_from_quote%' THEN
      RAISE EXCEPTION 'CT3 accept calls prepare';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'prepare agreement tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: explicit prepare, hash, idempotency, role client';
  END;
END;
$$;
