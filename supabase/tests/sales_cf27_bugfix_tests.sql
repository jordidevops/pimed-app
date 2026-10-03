-- CF-27 bugfix (000011): atomic issue, orphan resume, empty lines,
-- export client_op_id (ready vs failed), member without invoices.edit.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf91';
  v_dn uuid;
  v_dn_empty uuid;
  v_draft uuid;
  v_invoice uuid;
  v_invoice2 uuid;
  v_op uuid := 'cf279100-0000-0000-0000-000000000001'::uuid;
  v_op2 uuid := 'cf279100-0000-0000-0000-000000000002'::uuid;
  v_op3 uuid := 'cf279100-0000-0000-0000-000000000003'::uuid;
  v_export_op uuid := 'cf279100-0000-0000-0000-0000000000e1'::uuid;
  v_export_op2 uuid := 'cf279100-0000-0000-0000-0000000000e2'::uuid;
  v_prep jsonb;
  v_prep2 jsonb;
  v_batch uuid;
  v_member_perms text[];
  v_err text;
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

  -- member must not inherit invoices.* from viewer (camp /sales gated)
  v_member_perms := data.get_role_permissions('member');
  IF EXISTS (
    SELECT 1 FROM unnest(v_member_perms) AS p WHERE p LIKE 'invoices.%'
  ) THEN
    RAISE EXCEPTION 'member base must not include invoices.* (got %)', v_member_perms;
  END IF;
  -- viewer keeps invoices.view for gestoria
  IF NOT ('invoices.view' = ANY (data.get_role_permissions('viewer'))) THEN
    RAISE EXCEPTION 'viewer must keep invoices.view';
  END IF;

  INSERT INTO data.document_number_counters (tenant_id, doc_type, year, last_value)
  SELECT v_tenant, d, EXTRACT(YEAR FROM CURRENT_DATE)::int, 9100
  FROM unnest(ARRAY['quote','quote_amendment','delivery_note','invoice']) AS d
  ON CONFLICT (tenant_id, doc_type, year) DO UPDATE
  SET last_value = GREATEST(data.document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.commercial_document_number_counters (tenant_id, series_id, period_key, last_value)
  SELECT v_tenant, s.id, EXTRACT(YEAR FROM CURRENT_DATE)::int::text, 9100
  FROM data.commercial_document_series s
  WHERE s.tenant_id = v_tenant AND s.active
  ON CONFLICT (tenant_id, series_id, period_key) DO UPDATE
  SET last_value = GREATEST(data.commercial_document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-27 bugfix', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Bugfix line', NULL, 'h',
    1, 100, 0, 21, 0, NULL,
    'cf279100-0000-0000-0000-000000000010'::uuid
  );
  PERFORM api.accept_commercial_document(
    api.issue_commercial_document(
      v_project, 'quote', true,
      'cf279100-0000-0000-0000-000000000011'::uuid, NULL
    ),
    '{"method":"sql_test"}'::jsonb,
    'cf279100-0000-0000-0000-000000000012'::uuid
  );
  UPDATE data.projects SET authorized_total = authorized_total + 1000 WHERE id = v_project;
  v_dn := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf279100-0000-0000-0000-000000000013'::uuid, NULL
  );

  -- Atomic issue + idempotent replay
  v_invoice := api.issue_invoice_from_delivery_notes(
    ARRAY[v_dn], v_op, CURRENT_DATE, NULL, NULL
  );
  IF (SELECT status FROM data.commercial_documents WHERE id = v_invoice) IS DISTINCT FROM 'issued' THEN
    RAISE EXCEPTION 'atomic issue should return issued';
  END IF;
  v_invoice2 := api.issue_invoice_from_delivery_notes(
    ARRAY[v_dn], v_op, CURRENT_DATE, NULL, NULL
  );
  IF v_invoice2 IS DISTINCT FROM v_invoice THEN
    RAISE EXCEPTION 'idempotent replay should return same invoice';
  END IF;

  -- Cancel so we can test orphan resume on a fresh DN
  PERFORM api.cancel_invoice(v_invoice, 'cf279100-0000-0000-0000-000000000020'::uuid);

  -- Replenish deliverable qty (first DN consumed the line)
  PERFORM api.upsert_project_line(
    v_project, (
      SELECT id FROM data.project_lines WHERE project_id = v_project LIMIT 1
    ), NULL, 'service', 'Bugfix line', NULL, 'h',
    2, 100, 0, 21, 0, NULL,
    'cf279100-0000-0000-0000-000000000021'::uuid
  );
  UPDATE data.projects SET authorized_total = authorized_total + 1000 WHERE id = v_project;

  v_dn := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf279100-0000-0000-0000-000000000022'::uuid, NULL
  );
  v_draft := api.create_invoice_draft_from_delivery_notes(
    ARRAY[v_dn],
    'cf279100-0000-0000-0000-000000000023'::uuid,
    CURRENT_DATE,
    NULL
  );
  -- Resume orphan draft with a NEW client_op_id (simulates retry after failed issue)
  v_invoice := api.issue_invoice_from_delivery_notes(
    ARRAY[v_dn], v_op2, CURRENT_DATE, NULL, 'ERP-RESUME'
  );
  IF v_invoice IS DISTINCT FROM v_draft THEN
    RAISE EXCEPTION 'resume should issue the orphan draft, got % expected %', v_invoice, v_draft;
  END IF;
  IF (SELECT status FROM data.commercial_documents WHERE id = v_invoice) IS DISTINCT FROM 'issued' THEN
    RAISE EXCEPTION 'resumed orphan should be issued';
  END IF;

  -- Empty-lines DN rejected (seed issued DN with no lines; mimics bad UAT fixtures)
  v_dn_empty := 'cf279100-0000-0000-0000-0000000000d0'::uuid;
  INSERT INTO data.commercial_documents (
    id, tenant_id, project_id, client_id, doc_type, status, currency,
    subtotal, tax_breakdown, total, created_by, issued_at, issued_on, doc_number
  ) VALUES (
    v_dn_empty,
    v_tenant, v_project, v_client, 'delivery_note', 'issued', 'EUR',
    0, '[]'::jsonb, 0, v_owner, now(), CURRENT_DATE, 'A-CF27-EMPTY'
  );
  BEGIN
    PERFORM api.issue_invoice_from_delivery_notes(
      ARRAY[v_dn_empty], v_op3, CURRENT_DATE, NULL, NULL
    );
    RAISE EXCEPTION 'empty-lines DN should fail';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'invoice_delivery_notes_empty_lines' THEN
        RAISE;
      END IF;
  END;

  -- Export client_op_id: reuse preparing/ready; failed does not block
  v_prep := api.prepare_commercial_export_batch(
    CURRENT_DATE - 30, CURRENT_DATE + 1, NULL, v_export_op
  );
  v_batch := (v_prep ->> 'batch_id')::uuid;
  v_prep2 := api.prepare_commercial_export_batch(
    CURRENT_DATE - 30, CURRENT_DATE + 1, NULL, v_export_op
  );
  IF (v_prep2 ->> 'batch_id')::uuid IS DISTINCT FROM v_batch THEN
    RAISE EXCEPTION 'prepare should reuse preparing/ready batch for same op id';
  END IF;

  -- Force a failed batch with a distinct op id, then reuse that op id
  UPDATE data.commercial_export_batches
  SET status = 'failed', row_count = 0, failed_count = 0, error_text = 'no_valid_documents',
      client_op_id = v_export_op2
  WHERE id = v_batch;
  -- Insert a fresh failed row if update cleared uniqueness oddly
  IF NOT FOUND THEN
    NULL;
  END IF;

  v_prep := api.prepare_commercial_export_batch(
    CURRENT_DATE - 30, CURRENT_DATE + 1, NULL, v_export_op2
  );
  IF (v_prep ->> 'batch_id')::uuid IS NOT DISTINCT FROM v_batch THEN
    RAISE EXCEPTION 'failed batch must not be reused; expected new batch';
  END IF;
  IF EXISTS (
    SELECT 1 FROM data.commercial_export_batches
    WHERE id = v_batch AND client_op_id = v_export_op2
  ) THEN
    RAISE EXCEPTION 'failed batch client_op_id should be cleared before reuse';
  END IF;

  RAISE NOTICE 'sales_cf27_bugfix_tests ok';
END;
$$;

ROLLBACK;
