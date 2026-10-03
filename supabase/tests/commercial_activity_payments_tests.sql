-- Activity projection: invoice_cancelled + payment_recorded narrative events.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cfa1';
  v_project2 uuid := '51000000-0000-0000-0000-00000000cfa2';
  v_dn uuid;
  v_dn2 uuid;
  v_dn3 uuid;
  v_draft uuid;
  v_invoice uuid;
  v_payment_id uuid;
  v_pay jsonb;
  v_pay2 jsonb;
  v_event_count int;
  v_audit_count int;
  v_op uuid;
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

  INSERT INTO data.document_number_counters (tenant_id, doc_type, year, last_value)
  SELECT v_tenant, d, EXTRACT(YEAR FROM CURRENT_DATE)::int, 9200
  FROM unnest(ARRAY['quote','quote_amendment','delivery_note','invoice']) AS d
  ON CONFLICT (tenant_id, doc_type, year) DO UPDATE
  SET last_value = GREATEST(data.document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.commercial_document_number_counters (tenant_id, series_id, period_key, last_value)
  SELECT v_tenant, s.id, EXTRACT(YEAR FROM CURRENT_DATE)::int::text, 9200
  FROM data.commercial_document_series s
  WHERE s.tenant_id = v_tenant AND s.active
  ON CONFLICT (tenant_id, series_id, period_key) DO UPDATE
  SET last_value = GREATEST(data.commercial_document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF activity pay A', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Activity line', NULL, 'h',
    1, 100, 0, 21, 0, NULL,
    'cfa10000-0000-0000-0000-000000000001'::uuid
  );
  PERFORM api.accept_commercial_document(
    api.issue_commercial_document(
      v_project, 'quote', true,
      'cfa10000-0000-0000-0000-000000000002'::uuid, NULL
    ),
    '{"method":"sql_test"}'::jsonb,
    'cfa10000-0000-0000-0000-000000000003'::uuid
  );
  UPDATE data.projects SET authorized_total = authorized_total + 5000 WHERE id = v_project;
  v_dn := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cfa10000-0000-0000-0000-000000000004'::uuid, NULL
  );

  -- 1) DN payment → payment_recorded + PROJECT_COMMERCIAL_PAYMENT_RECORDED
  v_payment_id := api.record_payment(
    v_dn, 1000, 'cash',
    'cfa10000-0000-0000-0000-000000000010'::uuid, NULL, now()
  );
  SELECT COUNT(*) INTO v_event_count
  FROM data.commercial_document_events
  WHERE document_id = v_dn
    AND event_type = 'payment_recorded'
    AND client_op_id = 'cfa10000-0000-0000-0000-000000000010'::uuid;
  IF v_event_count <> 1 THEN
    RAISE EXCEPTION 'expected 1 payment_recorded on DN, got %', v_event_count;
  END IF;
  SELECT COUNT(*) INTO v_audit_count
  FROM data.audit_logs
  WHERE tenant_id = v_tenant
    AND action = 'PROJECT_COMMERCIAL_PAYMENT_RECORDED'
    AND entity_id = v_project
    AND payload ->> 'commercial_document_id' = v_dn::text;
  IF v_audit_count < 1 THEN
    RAISE EXCEPTION 'expected PROJECT_COMMERCIAL_PAYMENT_RECORDED for DN payment';
  END IF;

  -- Idempotent replay must not duplicate event
  PERFORM api.record_payment(
    v_dn, 1000, 'cash',
    'cfa10000-0000-0000-0000-000000000010'::uuid, NULL, now()
  );
  SELECT COUNT(*) INTO v_event_count
  FROM data.commercial_document_events
  WHERE document_id = v_dn
    AND event_type = 'payment_recorded'
    AND client_op_id = 'cfa10000-0000-0000-0000-000000000010'::uuid;
  IF v_event_count <> 1 THEN
    RAISE EXCEPTION 'idempotent DN payment duplicated events: %', v_event_count;
  END IF;

  -- 2) Single-OS invoice cancel → invoice_cancelled + audit
  PERFORM api.upsert_project_line(
    v_project, (
      SELECT id FROM data.project_lines WHERE project_id = v_project LIMIT 1
    ), NULL, 'service', 'Activity line', NULL, 'h',
    2, 100, 0, 21, 0, NULL,
    'cfa10000-0000-0000-0000-000000000011'::uuid
  );
  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cfa10000-0000-0000-0000-000000000012'::uuid, NULL
  );
  v_draft := api.create_invoice_draft_from_delivery_notes(
    ARRAY[v_dn2],
    'cfa10000-0000-0000-0000-000000000013'::uuid,
    CURRENT_DATE, NULL
  );
  v_invoice := api.issue_invoice(
    v_draft,
    'cfa10000-0000-0000-0000-000000000014'::uuid,
    CURRENT_DATE, NULL, NULL
  );
  IF (SELECT project_id FROM data.commercial_documents WHERE id = v_invoice) IS DISTINCT FROM v_project THEN
    RAISE EXCEPTION 'single-OS invoice should keep project_id';
  END IF;

  PERFORM api.cancel_invoice(v_invoice, 'cfa10000-0000-0000-0000-000000000015'::uuid);
  SELECT COUNT(*) INTO v_event_count
  FROM data.commercial_document_events
  WHERE document_id = v_invoice AND event_type = 'invoice_cancelled';
  IF v_event_count <> 1 THEN
    RAISE EXCEPTION 'expected invoice_cancelled event';
  END IF;
  -- Links must be released (E1 preconditions)
  IF EXISTS (
    SELECT 1 FROM data.invoice_delivery_notes
    WHERE invoice_id = v_invoice AND released_at IS NULL
  ) THEN
    RAISE EXCEPTION 'cancel should release DN links before/with event';
  END IF;
  SELECT COUNT(*) INTO v_audit_count
  FROM data.audit_logs
  WHERE tenant_id = v_tenant
    AND action = 'PROJECT_COMMERCIAL_INVOICE_CANCELLED'
    AND entity_id = v_project
    AND payload ->> 'commercial_document_id' = v_invoice::text;
  IF v_audit_count < 1 THEN
    RAISE EXCEPTION 'single-OS cancel should project Activity after link release';
  END IF;

  -- 3) Multi-OS invoice cancel fan-out (project_id NULL, ignore released_at)
  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_project2, v_tenant, 'work_order', 'CF activity pay B', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );
  PERFORM api.upsert_project_line(
    v_project, (
      SELECT id FROM data.project_lines WHERE project_id = v_project LIMIT 1
    ), NULL, 'service', 'Activity line', NULL, 'h',
    3, 100, 0, 21, 0, NULL,
    'cfa10000-0000-0000-0000-000000000020'::uuid
  );
  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cfa10000-0000-0000-0000-000000000021'::uuid, NULL
  );
  PERFORM api.upsert_project_line(
    v_project2, NULL, NULL, 'service', 'Activity line B', NULL, 'h',
    1, 50, 0, 21, 0, NULL,
    'cfa10000-0000-0000-0000-000000000022'::uuid
  );
  PERFORM api.accept_commercial_document(
    api.issue_commercial_document(
      v_project2, 'quote', true,
      'cfa10000-0000-0000-0000-000000000023'::uuid, NULL
    ),
    '{"method":"sql_test"}'::jsonb,
    'cfa10000-0000-0000-0000-000000000024'::uuid
  );
  UPDATE data.projects SET authorized_total = authorized_total + 1000 WHERE id = v_project2;
  v_dn3 := api.issue_commercial_document(
    v_project2, 'delivery_note', true,
    'cfa10000-0000-0000-0000-000000000025'::uuid, NULL
  );

  v_draft := api.create_invoice_draft_from_delivery_notes(
    ARRAY[v_dn2, v_dn3],
    'cfa10000-0000-0000-0000-000000000026'::uuid,
    CURRENT_DATE, NULL
  );
  v_invoice := api.issue_invoice(
    v_draft,
    'cfa10000-0000-0000-0000-000000000027'::uuid,
    CURRENT_DATE, NULL, NULL
  );
  IF (SELECT project_id FROM data.commercial_documents WHERE id = v_invoice) IS NOT NULL THEN
    RAISE EXCEPTION 'multi-OS invoice should have NULL project_id';
  END IF;

  PERFORM api.cancel_invoice(v_invoice, 'cfa10000-0000-0000-0000-000000000028'::uuid);
  SELECT COUNT(DISTINCT entity_id) INTO v_audit_count
  FROM data.audit_logs
  WHERE tenant_id = v_tenant
    AND action = 'PROJECT_COMMERCIAL_INVOICE_CANCELLED'
    AND payload ->> 'commercial_document_id' = v_invoice::text
    AND entity_id IN (v_project, v_project2);
  IF v_audit_count < 2 THEN
    RAISE EXCEPTION 'multi-OS cancel fan-out expected 2 projects, got %', v_audit_count;
  END IF;

  -- 4) Invoice payment event + idempotent
  PERFORM api.upsert_project_line(
    v_project, (
      SELECT id FROM data.project_lines WHERE project_id = v_project LIMIT 1
    ), NULL, 'service', 'Activity line', NULL, 'h',
    4, 100, 0, 21, 0, NULL,
    'cfa10000-0000-0000-0000-000000000030'::uuid
  );
  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cfa10000-0000-0000-0000-000000000031'::uuid, NULL
  );
  v_draft := api.create_invoice_draft_from_delivery_notes(
    ARRAY[v_dn2],
    'cfa10000-0000-0000-0000-000000000032'::uuid,
    CURRENT_DATE, NULL
  );
  v_invoice := api.issue_invoice(
    v_draft,
    'cfa10000-0000-0000-0000-000000000033'::uuid,
    CURRENT_DATE, NULL, NULL
  );

  v_pay := api.record_invoice_payment(
    v_invoice, 5000, 'transfer', 'REF-ACT',
    'cfa10000-0000-0000-0000-000000000034'::uuid, now()
  );
  IF (v_pay ->> 'idempotent')::boolean THEN
    RAISE EXCEPTION 'first invoice payment should not be idempotent';
  END IF;
  SELECT COUNT(*) INTO v_event_count
  FROM data.commercial_document_events
  WHERE document_id = v_invoice
    AND event_type = 'payment_recorded'
    AND client_op_id = 'cfa10000-0000-0000-0000-000000000034'::uuid;
  IF v_event_count <> 1 THEN
    RAISE EXCEPTION 'expected 1 payment_recorded on invoice';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.commercial_document_events
    WHERE document_id = v_invoice
      AND event_type = 'payment_recorded'
      AND payload ? 'allocations'
      AND jsonb_array_length(payload -> 'allocations') >= 1
  ) THEN
    RAISE EXCEPTION 'invoice payment_recorded should include allocations';
  END IF;

  v_pay2 := api.record_invoice_payment(
    v_invoice, 5000, 'transfer', 'REF-ACT',
    'cfa10000-0000-0000-0000-000000000034'::uuid, now()
  );
  IF NOT (v_pay2 ->> 'idempotent')::boolean THEN
    RAISE EXCEPTION 'replay should be idempotent';
  END IF;
  SELECT COUNT(*) INTO v_event_count
  FROM data.commercial_document_events
  WHERE document_id = v_invoice
    AND event_type = 'payment_recorded'
    AND client_op_id = 'cfa10000-0000-0000-0000-000000000034'::uuid;
  IF v_event_count <> 1 THEN
    RAISE EXCEPTION 'idempotent invoice payment duplicated events';
  END IF;

  -- 5) Repair: payment row without event → retry creates event
  v_op := 'cfa10000-0000-0000-0000-000000000040'::uuid;
  INSERT INTO data.payments (
    tenant_id, document_id, amount_cents, method, reference,
    collected_by, occurred_at, client_op_id
  ) VALUES (
    v_tenant, v_dn, 100, 'cash', NULL, v_owner, now(), v_op
  ) RETURNING id INTO v_payment_id;
  IF EXISTS (
    SELECT 1 FROM data.commercial_document_events
    WHERE tenant_id = v_tenant AND client_op_id = v_op
  ) THEN
    RAISE EXCEPTION 'repair fixture must not have event yet';
  END IF;
  PERFORM api.record_payment(v_dn, 100, 'cash', v_op, NULL, now());
  IF NOT EXISTS (
    SELECT 1 FROM data.commercial_document_events
    WHERE tenant_id = v_tenant
      AND client_op_id = v_op
      AND event_type = 'payment_recorded'
      AND (payload ->> 'payment_id')::uuid = v_payment_id
  ) THEN
    RAISE EXCEPTION 'idempotent path should repair missing payment_recorded';
  END IF;

  RAISE NOTICE 'commercial_activity_payments_tests ok';
END;
$$;

ROLLBACK;
