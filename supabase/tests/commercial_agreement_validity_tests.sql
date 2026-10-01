-- CF-21-a: validity fields, recurring kind, re-prepare draft updates dates.
-- Uses fresh client_op_ids each run so leftover events from other suites cannot
-- short-circuit prepare via typed replay. Rolls back via ZZ001.
DO $$
DECLARE
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_quote uuid;
  v_agreement uuid;
  v_kind text;
  v_ends date;
  v_notice int;
  v_op_issue uuid := gen_random_uuid();
  v_op_accept uuid := gen_random_uuid();
  v_op_prep1 uuid := gen_random_uuid();
  v_op_prep2 uuid := gen_random_uuid();
  v_op_prep3 uuid := gen_random_uuid();
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

    v_quote := api.issue_commercial_document(
      v_project, 'quote', true,
      v_op_issue,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote,
      '{"method":"sql_test"}'::jsonb,
      v_op_accept
    );

    v_agreement := api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_prep1,
      'recurring',
      CURRENT_DATE,
      CURRENT_DATE + 30,
      14
    );

    SELECT a.kind, v.ends_on, v.notice_days
    INTO v_kind, v_ends, v_notice
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    WHERE a.id = v_agreement;

    IF v_kind <> 'recurring' OR v_ends IS DISTINCT FROM CURRENT_DATE + 30 OR v_notice <> 14 THEN
      RAISE EXCEPTION 'CF21a recurring prepare failed kind=% ends=% notice=%', v_kind, v_ends, v_notice;
    END IF;

    PERFORM api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      v_op_prep2,
      'specific',
      NULL,
      CURRENT_DATE + 60,
      7
    );

    SELECT a.kind, v.ends_on, v.notice_days
    INTO v_kind, v_ends, v_notice
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    WHERE a.id = v_agreement;

    IF v_kind <> 'specific' OR v_ends <> CURRENT_DATE + 60 OR v_notice <> 7 THEN
      RAISE EXCEPTION 'CF21a re-prepare draft failed kind=% ends=% notice=%', v_kind, v_ends, v_notice;
    END IF;

    BEGIN
      PERFORM api.prepare_agreement_from_quote(
        v_quote,
        '76100000-0000-0000-0000-000000000001'::uuid,
        'none',
        v_op_prep3,
        'recurring',
        NULL,
        NULL,
        NULL
      );
      RAISE EXCEPTION 'CF21a recurring without ends_on was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%recurring_ends_on_required%' THEN
        RAISE;
      END IF;
    END;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'CF-21-a validity tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'CF-21-a validity tests passed';
  END;
END;
$$;
