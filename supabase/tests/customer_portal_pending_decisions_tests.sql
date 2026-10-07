-- CF-28 F7: portal pending list/get + portal decline receipt.
BEGIN;

DO $$
DECLARE
  v_tenant_a uuid := '10000000-0000-0000-0000-000000000004';
  v_tenant_b uuid := '10000000-0000-0000-0000-000000000003';
  v_client_a uuid := '80000000-0000-0000-0000-000000000201';
  v_quote uuid := '52000000-0000-0000-0000-000000000902';
  v_req_id uuid := 'a1000000-0000-4000-8000-000000000901';
  v_rendered uuid;
  v_version uuid;
  v_list jsonb;
  v_detail jsonb;
  v_count integer;
  v_found boolean;
  v_hash text;
  v_apply jsonb;
BEGIN
  UPDATE data.tenants
  SET settings = jsonb_set(
    COALESCE(settings, '{}'::jsonb),
    '{commercial,decision_requests_enabled}',
    'true'::jsonb,
    true
  )
  WHERE id = v_tenant_a;

  PERFORM data.ensure_customer_portal_tenant_state(v_tenant_a);
  UPDATE data.customer_portal_tenant_state
  SET commercial_quotes_agreements_enabled = true,
      commercial_delivery_notes_enabled = true
  WHERE tenant_id = v_tenant_a;

  SELECT rendered_document_id, content_hash
    INTO v_rendered, v_hash
  FROM data.commercial_documents
  WHERE id = v_quote AND tenant_id = v_tenant_a;

  IF v_rendered IS NULL THEN
    RAISE EXCEPTION 'FAIL fixture quote missing rendered_document_id';
  END IF;

  SELECT id INTO v_version
  FROM data.document_versions
  WHERE document_id = v_rendered
  ORDER BY version_number DESC
  LIMIT 1;

  IF v_version IS NULL THEN
    RAISE EXCEPTION 'FAIL fixture quote missing document version';
  END IF;

  -- Ensure quote is issued for visibility / apply.
  UPDATE data.commercial_documents
  SET status = 'issued'
  WHERE id = v_quote AND status IS DISTINCT FROM 'issued';

  INSERT INTO data.commercial_decision_requests (
    id, tenant_id, client_account_contact_id, commercial_document_id,
    purpose, status, active_provider, snapshot_json, content_hash,
    rendered_document_id, document_version_id, expires_at, client_op_id
  ) VALUES (
    v_req_id,
    v_tenant_a,
    v_client_a,
    v_quote,
    'acceptance',
    'open',
    'native',
    jsonb_build_object(
      'kind', 'commercial_document',
      'doc_type', 'quote',
      'doc_number', 'P-2026-9002',
      'total', 120.5,
      'currency', 'EUR',
      'show_prices', true
    ),
    COALESCE(v_hash, 'test-hash-f7-pending'),
    v_rendered,
    v_version,
    now() + interval '7 days',
    'b1000000-0000-4000-8000-000000000901'
  );

  -- Cross-tenant empty
  v_list := data.list_customer_portal_pending_decisions(
    v_tenant_b, v_client_a, true, true, 20
  );
  IF jsonb_array_length(v_list) <> 0 THEN
    RAISE EXCEPTION 'FAIL cross-tenant pending list leaked';
  END IF;

  v_detail := data.get_customer_portal_pending_decision(
    v_tenant_b, v_client_a, v_req_id, true, true
  );
  IF v_detail IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL cross-tenant pending detail leaked';
  END IF;

  -- Happy path list/get
  v_list := data.list_customer_portal_pending_decisions(
    v_tenant_a, v_client_a, true, true, 20
  );
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list) e
    WHERE e->>'request_id' = v_req_id::text
      AND e->>'label' = 'P-2026-9002'
  ) INTO v_found;
  IF NOT v_found THEN
    RAISE EXCEPTION 'FAIL owned open request missing from pending list';
  END IF;

  v_count := data.count_customer_portal_pending_decisions(
    v_tenant_a, v_client_a, true, true
  );
  IF v_count < 1 THEN
    RAISE EXCEPTION 'FAIL pending count expected >= 1';
  END IF;

  v_detail := data.get_customer_portal_pending_decision(
    v_tenant_a, v_client_a, v_req_id, true, true
  );
  IF v_detail IS NULL OR v_detail->>'label' IS DISTINCT FROM 'P-2026-9002' THEN
    RAISE EXCEPTION 'FAIL pending detail missing';
  END IF;
  IF v_detail ? 'created_by' OR v_detail ? 'commercial_document_id' THEN
    RAISE EXCEPTION 'FAIL pending detail leaked internal fields';
  END IF;
  IF (v_detail->>'decline_available')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL native open request should allow decline';
  END IF;
  -- Without a linked native signing session, accept stays unavailable.
  IF (v_detail->>'accept_available')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL accept_available true without native session';
  END IF;

  IF data.customer_portal_pending_native_session_ready(v_req_id) THEN
    RAISE EXCEPTION 'FAIL native session ready unexpectedly before fixture';
  END IF;

  -- Module off hides quote pending
  v_list := data.list_customer_portal_pending_decisions(
    v_tenant_a, v_client_a, false, true, 20
  );
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list) e
    WHERE e->>'request_id' = v_req_id::text
  ) INTO v_found;
  IF v_found THEN
    RAISE EXCEPTION 'FAIL quotes module off still listed quote pending';
  END IF;

  -- Portal decline via apply
  v_apply := data.apply_commercial_decision_request(
    v_req_id,
    'declined',
    'portal',
    jsonb_build_object(
      'signer_name', 'Test Client',
      'reason', 'no thanks',
      'principal_kind', 'named_person'
    ),
    'c1000000-0000-4000-8000-000000000901',
    NULL
  );
  IF COALESCE((v_apply->>'applied')::boolean, false) IS NOT TRUE
     AND COALESCE((v_apply->>'already_decided')::boolean, false) IS NOT TRUE
  THEN
    RAISE EXCEPTION 'FAIL portal decline apply did not apply: %', v_apply;
  END IF;

  v_detail := data.get_customer_portal_pending_decision(
    v_tenant_a, v_client_a, v_req_id, true, true
  );
  IF v_detail IS NULL OR v_detail->>'status' IS DISTINCT FROM 'declined' THEN
    RAISE EXCEPTION 'FAIL declined request not readable as receipt';
  END IF;
  IF v_detail->'receipt'->>'outcome' IS DISTINCT FROM 'declined' THEN
    RAISE EXCEPTION 'FAIL receipt missing after portal decline';
  END IF;

  v_list := data.list_customer_portal_pending_decisions(
    v_tenant_a, v_client_a, true, true, 20
  );
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list) e
    WHERE e->>'request_id' = v_req_id::text
  ) INTO v_found;
  IF v_found THEN
    RAISE EXCEPTION 'FAIL declined request still in pending list';
  END IF;

  -- Expired open request excluded (use DN fixture; leave quote alone)
  DECLARE
    v_dn uuid;
    v_dn_rendered uuid;
    v_dn_version uuid;
    v_dn_hash text;
    v_req_exp uuid := 'a1000000-0000-4000-8000-000000000903';
  BEGIN
    SELECT id, rendered_document_id, content_hash
      INTO v_dn, v_dn_rendered, v_dn_hash
    FROM data.commercial_documents
    WHERE tenant_id = v_tenant_a
      AND client_id = v_client_a
      AND doc_type = 'delivery_note'
      AND status = 'issued'
      AND doc_number IS DISTINCT FROM 'A-2026-0002'
    LIMIT 1;

    IF v_dn IS NOT NULL AND v_dn_rendered IS NOT NULL THEN
      SELECT id INTO v_dn_version
      FROM data.document_versions
      WHERE document_id = v_dn_rendered
      ORDER BY version_number DESC
      LIMIT 1;

      IF v_dn_version IS NOT NULL THEN
        INSERT INTO data.commercial_decision_requests (
          id, tenant_id, client_account_contact_id, commercial_document_id,
          purpose, status, active_provider, snapshot_json, content_hash,
          rendered_document_id, document_version_id, expires_at, client_op_id
        ) VALUES (
          v_req_exp, v_tenant_a, v_client_a, v_dn, 'delivery_confirmation',
          'open', 'native',
          jsonb_build_object(
            'kind', 'commercial_document',
            'doc_type', 'delivery_note',
            'doc_number', 'DN-EXP',
            'total', 1,
            'currency', 'EUR'
          ),
          COALESCE(v_dn_hash, 'dn-hash'),
          v_dn_rendered, v_dn_version,
          now() - interval '1 hour',
          'b1000000-0000-4000-8000-000000000903'
        );

        v_list := data.list_customer_portal_pending_decisions(
          v_tenant_a, v_client_a, true, true, 20
        );
        SELECT EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_list) e
          WHERE e->>'request_id' = v_req_exp::text
        ) INTO v_found;
        IF v_found THEN
          RAISE EXCEPTION 'FAIL expired open request still listed';
        END IF;
      END IF;
    END IF;
  END;

  RAISE NOTICE 'PASS customer_portal_pending_decisions_tests';
END;
$$;

ROLLBACK;
