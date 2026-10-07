-- CF-28 F3/F4: smoke for three decision targets (quote, DN, agreement_version).
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := gen_random_uuid();
  v_quote uuid;
  v_dn uuid;
  v_render uuid;
  v_req uuid;
  v_delivery_json jsonb;
  v_raw text;
  v_resolve jsonb;
  v_agreement uuid;
  v_version uuid;
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
    v_project, v_tenant, 'work_order', 'CF28-3T', 'Disposable', 'active', 'company',
    v_site, v_client, v_owner
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'CF28 3T', NULL, 'u',
    1, 50, 0, 21, 0, NULL, gen_random_uuid()
  );

  -- Shared render document
  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (v_tenant, 'CF28 3T render', 'commercial', '{}', v_owner)
  RETURNING id INTO v_render;
  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, created_by
  ) VALUES (
    v_render, 1, 'native', 'cf28/3t.pdf', 'application/pdf', v_owner
  );

  -- 1) Quote signed_quote
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );
  UPDATE data.commercial_documents
  SET rendered_document_id = v_render,
      content_hash = COALESCE(NULLIF(btrim(content_hash), ''), 'cf28-3t-quote')
  WHERE id = v_quote;

  v_req := api.create_commercial_decision_request(
    'commercial_document', v_quote, now() + interval '5 days', gen_random_uuid()
  );
  v_delivery_json := api.create_commercial_decision_delivery(
    v_req, 'email', NULL, 'ca', gen_random_uuid()
  );
  IF v_delivery_json->>'raw_token' IS NOT NULL THEN
    RAISE EXCEPTION 'CS-D58: authenticated must not receive raw_token';
  END IF;
  SELECT o.raw_token INTO v_raw
  FROM data.commercial_decision_token_once o
  WHERE o.delivery_id = (v_delivery_json->>'delivery_id')::uuid;
  v_resolve := api.resolve_commercial_decision_token(v_raw, false);
  IF v_resolve->>'kind' IS DISTINCT FROM 'commercial_decision'
     OR (v_resolve->>'can_decide')::boolean IS NOT TRUE
     OR v_resolve->>'purpose' IS DISTINCT FROM 'acceptance'
  THEN
    RAISE EXCEPTION 'quote target resolve failed: %', v_resolve;
  END IF;
  PERFORM api.revoke_commercial_decision_request(v_req, gen_random_uuid());

  -- 2) Delivery note
  v_dn := api.issue_commercial_document(
    v_project, 'delivery_note', true, gen_random_uuid(), v_quote
  );
  UPDATE data.commercial_documents
  SET rendered_document_id = v_render,
      content_hash = COALESCE(NULLIF(btrim(content_hash), ''), 'cf28-3t-dn')
  WHERE id = v_dn;

  v_req := api.create_commercial_decision_request(
    'commercial_document', v_dn, now() + interval '5 days', gen_random_uuid()
  );
  v_delivery_json := api.create_commercial_decision_delivery(
    v_req, 'email', NULL, 'ca', gen_random_uuid()
  );
  SELECT o.raw_token INTO v_raw
  FROM data.commercial_decision_token_once o
  WHERE o.delivery_id = (v_delivery_json->>'delivery_id')::uuid;
  v_resolve := api.resolve_commercial_decision_token(v_raw, false);
  IF v_resolve->>'purpose' IS DISTINCT FROM 'delivery_confirmation'
     OR (v_resolve->>'can_decide')::boolean IS NOT TRUE
  THEN
    RAISE EXCEPTION 'DN target resolve failed: %', v_resolve;
  END IF;
  PERFORM api.revoke_commercial_decision_request(v_req, gen_random_uuid());

  -- 3) Agreement version (separate_agreement path)
  -- Use a fresh quote so formalization_mode can be set at draft time via issue defaults,
  -- or attach agreement to the existing issued quote (CS-D8 allows prepare from issued).
  INSERT INTO data.commercial_agreements (
    tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by
  ) VALUES (
    v_tenant, v_client, 'specific', 'pending_start', v_quote, 'none', v_owner
  ) RETURNING id INTO v_agreement;

  INSERT INTO data.commercial_agreement_versions (
    tenant_id, agreement_id, version_no, status,
    source_quote_id, source_quote_content_hash, content_hash,
    rendered_document_id
  ) VALUES (
    v_tenant, v_agreement, 1, 'draft',
    v_quote,
    COALESCE((SELECT content_hash FROM data.commercial_documents WHERE id = v_quote), 'cf28-3t-quote'),
    'cf28-3t-agreement',
    v_render
  ) RETURNING id INTO v_version;

  UPDATE data.commercial_agreements
  SET active_version_id = v_version
  WHERE id = v_agreement;

  UPDATE data.commercial_agreement_versions
  SET status = 'pending_signature'
  WHERE id = v_version;

  v_req := api.create_commercial_decision_request(
    'agreement_version', v_version, now() + interval '5 days', gen_random_uuid()
  );
  v_delivery_json := api.create_commercial_decision_delivery(
    v_req, 'email', NULL, 'ca', gen_random_uuid()
  );
  SELECT o.raw_token INTO v_raw
  FROM data.commercial_decision_token_once o
  WHERE o.delivery_id = (v_delivery_json->>'delivery_id')::uuid;
  v_resolve := api.resolve_commercial_decision_token(v_raw, false);
  IF v_resolve->>'kind' IS DISTINCT FROM 'commercial_decision'
     OR (v_resolve->>'can_decide')::boolean IS NOT TRUE
     OR v_resolve->'snapshot'->>'kind' IS DISTINCT FROM 'agreement_version'
  THEN
    RAISE EXCEPTION 'agreement_version target resolve failed: %', v_resolve;
  END IF;

  -- Open lookup from quote id finds agreement request
  IF api.get_open_commercial_decision_request(v_quote, NULL) IS NULL THEN
    RAISE EXCEPTION 'get_open via quote should find agreement request';
  END IF;

  RAISE NOTICE 'CF-28 three targets smoke OK';
END;
$$;

ROLLBACK;
