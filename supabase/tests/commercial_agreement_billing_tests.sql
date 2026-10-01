-- CF-21-g: billing rule + period generation + external invoice mark.
DO $$
DECLARE
  v_op_1 uuid := gen_random_uuid();
  v_op_2 uuid := gen_random_uuid();
  v_op_3 uuid := gen_random_uuid();
  v_op_4 uuid := gen_random_uuid();
  v_op_5 uuid := gen_random_uuid();
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_client uuid;
  v_quote uuid;
  v_agreement uuid;
  v_version uuid;
  v_period uuid;
  v_cents int;
  v_cadence text;
  v_next date;
  v_result jsonb;
  v_status text;
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

    -- cadence without amount must fail
    BEGIN
      PERFORM api.prepare_agreement_from_quote(
        v_quote,
        '76100000-0000-0000-0000-000000000002'::uuid,
        'none',
        v_op_3,
        'recurring',
        CURRENT_DATE,
        CURRENT_DATE + 400,
        30,
        false,
        NULL, NULL, NULL,
        'monthly',
        NULL,
        'EUR',
        1
      );
      RAISE EXCEPTION 'CF21g expected billing_amount_required';
    EXCEPTION
      WHEN SQLSTATE 'P0001' THEN
        IF position('billing_amount_required' in SQLERRM) = 0 THEN
          RAISE;
        END IF;
    END;

    v_agreement := api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000002'::uuid,
      'none',
      v_op_4,
      'recurring',
      CURRENT_DATE,
      CURRENT_DATE + 400,
      30,
      false,
      4, 24, '8-18',
      'monthly',
      12100,
      'EUR',
      1
    );

    SELECT active_version_id INTO v_version
    FROM data.commercial_agreements WHERE id = v_agreement;

    SELECT billing_cadence, billing_amount_cents, next_billing_on
    INTO v_cadence, v_cents, v_next
    FROM data.commercial_agreement_versions WHERE id = v_version;

    IF v_cadence IS DISTINCT FROM 'monthly' OR v_cents IS DISTINCT FROM 12100 THEN
      RAISE EXCEPTION 'CF21g unexpected billing rule % %', v_cadence, v_cents;
    END IF;
    IF v_next IS DISTINCT FROM CURRENT_DATE THEN
      RAISE EXCEPTION 'CF21g next_billing_on expected today, got %', v_next;
    END IF;

    -- CF-21-h2: finalize is internal; draft -> pending_signature, then signed with a PDF.
    INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
    VALUES (v_tenant, 'CF21g signed stub', 'commercial', '{}', v_owner)
    RETURNING id INTO v_doc;
    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature' WHERE id = v_version;
    PERFORM data.finalize_commercial_agreement_version(v_version, v_doc, v_owner, CURRENT_DATE);
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_agreement;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21g expected active, got %', v_status;
    END IF;

    v_result := api.generate_due_agreement_billing_periods(CURRENT_DATE, 50);
    IF COALESCE((v_result->>'generated')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21g expected generated period, got %', v_result;
    END IF;

    SELECT id INTO v_period
    FROM data.commercial_agreement_billing_periods
    WHERE agreement_id = v_agreement AND status = 'due'
    ORDER BY due_on
    LIMIT 1;
    IF v_period IS NULL THEN
      RAISE EXCEPTION 'CF21g missing due period';
    END IF;

    PERFORM api.mark_agreement_billing_period_invoiced(
      v_period, 'HOLD-TEST-001', v_op_5
    );
    SELECT status, external_invoice_ref INTO v_status, v_cadence
    FROM data.commercial_agreement_billing_periods WHERE id = v_period;
    IF v_status IS DISTINCT FROM 'invoiced' OR v_cadence IS DISTINCT FROM 'HOLD-TEST-001' THEN
      RAISE EXCEPTION 'CF21g mark invoiced failed';
    END IF;

    -- Idempotent client_op
    PERFORM api.mark_agreement_billing_period_invoiced(
      v_period, 'HOLD-TEST-001', v_op_5
    );

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'CF-21-g billing tests PASS';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN
      RAISE NOTICE 'CF-21-g billing tests PASS';
    WHEN OTHERS THEN
      RAISE EXCEPTION 'CF-21-g billing tests FAIL: %', SQLERRM;
  END;
END;
$$;
