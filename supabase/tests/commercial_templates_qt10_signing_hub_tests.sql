-- QT-10: commercial native intents appear on api.commercial_signing_hub
-- so the Signing Centre can resolve quote/delivery_note links.
-- submission_id has no FK; the hub LEFT JOINs signing_submissions.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := gen_random_uuid();
  v_quote uuid;
  v_submission uuid := gen_random_uuid();
  v_session uuid := gen_random_uuid();
  v_hub_doc uuid;
  v_hub_type text;
  v_hub_num text;
  v_other_tenant uuid := '10000000-0000-0000-0000-000000000099';
  v_leaked int;
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

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'QT-10 hub', 'Disposable',
    'active', 'company', v_site, v_client, v_owner
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'QT-10 line', NULL, 'u',
    1, 50, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );

  INSERT INTO data.commercial_signing_intents (
    tenant_id, document_id, submission_id, session_id, action, client_op_id, created_by
  ) VALUES (
    v_tenant, v_quote, v_submission, v_session, 'accept', gen_random_uuid(), v_owner
  );

  SELECT commercial_document_id, doc_type, doc_number
    INTO v_hub_doc, v_hub_type, v_hub_num
  FROM api.commercial_signing_hub
  WHERE submission_id = v_submission;

  IF v_hub_doc IS DISTINCT FROM v_quote THEN
    RAISE EXCEPTION 'QT-10 hub did not resolve commercial document: % vs %', v_hub_doc, v_quote;
  END IF;
  IF v_hub_type IS DISTINCT FROM 'quote' THEN
    RAISE EXCEPTION 'QT-10 hub doc_type expected quote, got %', v_hub_type;
  END IF;
  IF v_hub_num IS NULL OR btrim(v_hub_num) = '' THEN
    RAISE EXCEPTION 'QT-10 hub missing doc_number';
  END IF;

  -- Isolation: another tenant id must not leak this row through the view filter.
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_owner,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_other_tenant::text, json_build_object('global_role', 'owner', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );

  SELECT count(*) INTO v_leaked
  FROM api.commercial_signing_hub
  WHERE submission_id = v_submission;

  IF v_leaked <> 0 THEN
    RAISE EXCEPTION 'QT-10 hub leaked commercial signing row to another tenant: %', v_leaked;
  END IF;

  RAISE NOTICE 'QT-10 commercial signing hub PASS';
END $$;
