-- CF-28 F3: commercial.decision_request template + enqueue delivery email.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := gen_random_uuid();
  v_quote uuid;
  v_render uuid;
  v_req uuid;
  v_delivery uuid;
  v_result jsonb;
  v_status text;
  v_masked text;
  v_log uuid;
  v_meta jsonb;
  v_token_hits int;
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

  IF NOT EXISTS (
    SELECT 1 FROM data.email_templates
    WHERE event_type = 'commercial.decision_request'
      AND is_platform_default
      AND is_active
  ) THEN
    RAISE EXCEPTION 'commercial.decision_request template missing';
  END IF;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings->'commercial', '{}'::jsonb)
        || jsonb_build_object('decision_requests_enabled', true)
    )
  WHERE id = v_tenant;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF28-email', 'Disposable', 'active', 'company',
    v_site, v_client, v_owner
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'CF28 email line', NULL, 'u',
    1, 120, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );

  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (v_tenant, 'CF28 email render', 'commercial', '{}', v_owner)
  RETURNING id INTO v_render;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, created_by
  ) VALUES (
    v_render, 1, 'native', 'cf28/email-test.pdf', 'application/pdf', v_owner
  );

  -- rendered_document_id is mutable post-issue; buyer/content_hash are not.
  UPDATE data.commercial_documents
  SET rendered_document_id = COALESCE(rendered_document_id, v_render)
  WHERE id = v_quote;

  IF (
    SELECT content_hash IS NULL OR btrim(content_hash) = ''
    FROM data.commercial_documents WHERE id = v_quote
  ) THEN
    RAISE EXCEPTION 'issued quote missing content_hash';
  END IF;

  v_req := api.create_commercial_decision_request(
    'commercial_document', v_quote, now() + interval '7 days', gen_random_uuid()
  );

  v_delivery := (
    api.create_commercial_decision_delivery(
      v_req, 'email', NULL, 'ca', gen_random_uuid()
    )->>'delivery_id'
  )::uuid;

  v_result := api.enqueue_commercial_decision_delivery_email(
    v_delivery,
    'client@example.test',
    'https://app.example.test/sign/tok-demo',
    'Client Prova',
    'ca',
    NULL
  );

  IF (v_result->>'status') IS DISTINCT FROM 'queued' THEN
    RAISE EXCEPTION 'expected queued, got %', v_result;
  END IF;
  v_log := (v_result->>'email_log_id')::uuid;
  IF v_log IS NULL THEN
    RAISE EXCEPTION 'email_log_id missing';
  END IF;

  SELECT status, recipient_masked INTO v_status, v_masked
  FROM data.commercial_decision_deliveries
  WHERE id = v_delivery;
  IF v_status IS DISTINCT FROM 'queued' THEN
    RAISE EXCEPTION 'delivery not queued: %', v_status;
  END IF;
  IF v_masked IS DISTINCT FROM 'c***@example.test' THEN
    RAISE EXCEPTION 'recipient_masked unexpected: %', v_masked;
  END IF;

  SELECT metadata INTO v_meta FROM data.email_logs WHERE id = v_log;
  IF v_meta ? 'raw_token' OR (v_meta::text ILIKE '%tok-demo%' AND v_meta ? 'token') THEN
    RAISE EXCEPTION 'raw token leaked into email metadata';
  END IF;
  IF (v_meta->>'request_id') IS DISTINCT FROM v_req::text THEN
    RAISE EXCEPTION 'metadata request_id missing';
  END IF;

  -- Idempotent re-enqueue
  v_result := api.enqueue_commercial_decision_delivery_email(
    v_delivery,
    'client@example.test',
    'https://app.example.test/sign/tok-demo',
    'Client Prova',
    'ca',
    NULL
  );
  IF (v_result->>'already_queued')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'expected already_queued';
  END IF;

  SELECT count(*) INTO v_token_hits
  FROM data.commercial_decision_access_tokens t
  WHERE t.request_id = v_req
    AND t.token_hash = 'tok-demo';
  IF v_token_hits > 0 THEN
    RAISE EXCEPTION 'decision_url must not be stored as token_hash';
  END IF;

  RAISE NOTICE 'CF-28 F3 commercial_decision_email_tests OK';
END;
$$;

ROLLBACK;
