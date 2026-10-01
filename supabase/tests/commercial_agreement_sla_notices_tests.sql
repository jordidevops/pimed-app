-- CF-21-f: SLA columns, maintenance template, expiry notices.
DO $$
DECLARE
  v_op_1 uuid := gen_random_uuid();
  v_op_2 uuid := gen_random_uuid();
  v_op_3 uuid := gen_random_uuid();
  v_op_4 uuid := gen_random_uuid();
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_client uuid;
  v_quote uuid;
  v_agreement uuid;
  v_version uuid;
  v_hours int;
  v_notes text;
  v_tpl uuid;
  v_status text;
  v_result jsonb;
  v_evt int;
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

    SELECT id INTO v_tpl
    FROM data.document_templates
    WHERE id = '76100000-0000-0000-0000-000000000002'
      AND category = 'commercial_agreement'
      AND is_platform_default
      AND is_active;
    IF v_tpl IS NULL THEN
      RAISE EXCEPTION 'CF21f maintenance template missing';
    END IF;

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

    -- ends_on within notice window so notify can fire after activate
    v_agreement := api.prepare_agreement_from_quote(
      v_quote,
      v_tpl,
      'none',
      v_op_3,
      'recurring',
      CURRENT_DATE,
      CURRENT_DATE + 10,
      30,
      false,
      4,
      24,
      'laborables 8-18'
    );

    SELECT active_version_id INTO v_version
    FROM data.commercial_agreements WHERE id = v_agreement;

    SELECT sla_response_hours, sla_coverage_notes
    INTO v_hours, v_notes
    FROM data.commercial_agreement_versions WHERE id = v_version;

    IF v_hours IS DISTINCT FROM 4 THEN
      RAISE EXCEPTION 'CF21f expected sla_response_hours=4, got %', v_hours;
    END IF;
    IF v_notes IS DISTINCT FROM 'laborables 8-18' THEN
      RAISE EXCEPTION 'CF21f unexpected coverage notes: %', v_notes;
    END IF;

    -- CF-21-h2: finalize is internal; draft -> pending_signature, then signed with a PDF.
    INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
    VALUES (v_tenant, 'CF21f signed stub', 'commercial', '{}', v_owner)
    RETURNING id INTO v_doc;
    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature' WHERE id = v_version;
    PERFORM data.finalize_commercial_agreement_version(v_version, v_doc, v_owner, CURRENT_DATE);
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_agreement;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21f expected active after finalize, got %', v_status;
    END IF;

    v_result := api.notify_expiring_commercial_agreements(CURRENT_DATE, 50);
    -- notified if owners have email; skipped if none — either proves the job ran
    IF COALESCE((v_result->>'notified')::int, 0) + COALESCE((v_result->>'skipped')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21f notify expected notified or skipped, got %', v_result;
    END IF;

    PERFORM api.notify_expiring_commercial_agreements(CURRENT_DATE, 50);
    SELECT count(*) INTO v_evt
    FROM data.commercial_agreement_events
    WHERE agreement_id = v_agreement AND event_type = 'expiry_notice_sent';
    IF COALESCE((v_result->>'notified')::int, 0) >= 1 AND v_evt <> 1 THEN
      RAISE EXCEPTION 'CF21f expected exactly one expiry_notice_sent after notify, got %', v_evt;
    END IF;

    -- Framework with SLA
    v_agreement := api.create_framework_agreement(
      v_tenant,
      v_client,
      v_tpl,
      'none',
      v_op_4,
      CURRENT_DATE,
      CURRENT_DATE + 365,
      45,
      'ca',
      true,
      8,
      48,
      '24/7'
    );
    SELECT v.sla_resolution_hours INTO v_hours
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    WHERE a.id = v_agreement;
    IF v_hours IS DISTINCT FROM 48 THEN
      RAISE EXCEPTION 'CF21f framework sla_resolution_hours expected 48, got %', v_hours;
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'CF-21-f SLA/notices tests PASS';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN
      RAISE NOTICE 'CF-21-f SLA/notices tests PASS';
    WHEN OTHERS THEN
      RAISE EXCEPTION 'CF-21-f SLA/notices tests FAIL: %', SQLERRM;
  END;
END;
$$;
