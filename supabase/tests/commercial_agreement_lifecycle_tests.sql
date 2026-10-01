-- CF-21-e: finalize / activate by starts_on / expire or renew.
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
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_client uuid;
  v_quote uuid;
  v_agreement uuid;
  v_version uuid;
  v_status text;
  v_starts date;
  v_ends date;
  v_result jsonb;
  v_doc uuid;
BEGIN
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

    SELECT client_id INTO v_client FROM data.projects WHERE id = v_project;

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

    -- Future start: finalize keeps pending_start
    v_agreement := api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_3,
      'recurring',
      CURRENT_DATE + 10,
      CURRENT_DATE + 375,
      30,
      true
    );
    SELECT active_version_id INTO v_version
    FROM data.commercial_agreements WHERE id = v_agreement;

    -- CF-21-h2: finalize is internal; draft -> pending_signature, then signed with a PDF.
    INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
    VALUES (v_tenant, 'CF21e signed stub', 'commercial', '{}', v_owner)
    RETURNING id INTO v_doc;
    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature' WHERE id = v_version;
    PERFORM data.finalize_commercial_agreement_version(v_version, v_doc, v_owner, CURRENT_DATE);
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_agreement;
    IF v_status IS DISTINCT FROM 'pending_start' THEN
      RAISE EXCEPTION 'CF21e expected pending_start for future starts_on, got %', v_status;
    END IF;
    SELECT status INTO v_status FROM data.commercial_agreement_versions WHERE id = v_version;
    IF v_status IS DISTINCT FROM 'signed' THEN
      RAISE EXCEPTION 'CF21e version should be signed';
    END IF;

    -- Activate due when as_of reaches starts_on
    v_result := api.activate_due_commercial_agreements(CURRENT_DATE + 10, 50);
    IF COALESCE((v_result->>'activated')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21e activate_due did not activate: %', v_result;
    END IF;
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_agreement;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21e expected active after activate_due';
    END IF;

    -- Immediate activate when starts_on is today/null
    v_quote := api.issue_commercial_document(
      v_project, 'quote', true,
      v_op_4,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote,
      '{"method":"sql_test"}'::jsonb,
      v_op_5
    );
    -- Need a fresh quote without existing agreement — use amendment path via new project client quote
    -- Force new agreement by using framework create instead
    v_agreement := api.create_framework_agreement(
      v_tenant, v_client,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_6,
      CURRENT_DATE - 5,
      CURRENT_DATE - 1,
      15,
      'ca',
      false
    );
    SELECT active_version_id INTO v_version
    FROM data.commercial_agreements WHERE id = v_agreement;
    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature' WHERE id = v_version;
    PERFORM data.finalize_commercial_agreement_version(v_version, v_doc, v_owner, CURRENT_DATE);
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_agreement;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21e expected immediate active, got %', v_status;
    END IF;

    -- Expire without renew → finished
    v_result := api.expire_or_renew_commercial_agreements(CURRENT_DATE, 50);
    IF COALESCE((v_result->>'finished')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21e expire did not finish: %', v_result;
    END IF;
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_agreement;
    IF v_status IS DISTINCT FROM 'finished' THEN
      RAISE EXCEPTION 'CF21e expected finished, got %', v_status;
    END IF;

    -- Renew path
    v_agreement := api.create_framework_agreement(
      v_tenant, v_client,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_7,
      CURRENT_DATE - 40,
      CURRENT_DATE - 1,
      7,
      'ca',
      true
    );
    SELECT active_version_id INTO v_version
    FROM data.commercial_agreements WHERE id = v_agreement;
    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature' WHERE id = v_version;
    PERFORM data.finalize_commercial_agreement_version(v_version, v_doc, v_owner, CURRENT_DATE);
    v_result := api.expire_or_renew_commercial_agreements(CURRENT_DATE, 50);
    IF COALESCE((v_result->>'renewed')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21e renew did not run: %', v_result;
    END IF;
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_agreement;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21e renewed agreement should stay active';
    END IF;
    -- CF-21-h3: renewal moves the ACTIVE CYCLE; the signed version dates never change.
    SELECT c.starts_on, c.ends_on INTO v_starts, v_ends
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
    WHERE a.id = v_agreement;
    IF v_ends IS NULL OR v_ends <= CURRENT_DATE - 1 THEN
      RAISE EXCEPTION 'CF21e renew did not extend the active cycle: % / %', v_starts, v_ends;
    END IF;
    SELECT starts_on, ends_on INTO v_starts, v_ends
    FROM data.commercial_agreement_versions WHERE id = v_version;
    IF v_starts IS DISTINCT FROM CURRENT_DATE - 40 OR v_ends IS DISTINCT FROM CURRENT_DATE - 1 THEN
      RAISE EXCEPTION 'CF21e renew mutated the signed version dates: % / %', v_starts, v_ends;
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'commercial_agreement_lifecycle_tests OK';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN
      RAISE NOTICE 'commercial_agreement_lifecycle_tests OK';
    WHEN OTHERS THEN
      RAISE EXCEPTION 'commercial_agreement_lifecycle_tests FAILED: %', SQLERRM;
  END;
END;
$$;
