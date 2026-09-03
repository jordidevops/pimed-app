-- Track G6 Lot 4 — republicació, PDF async staging, orphan cleanup
BEGIN;

CREATE TEMP TABLE g6_lot4_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION g6_lot4_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO g6_lot4_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

DO $$
DECLARE
  v_tenant    uuid := '10000000-0000-0000-0000-000000000001';
  v_employee  uuid := '40000000-0000-0000-0000-000000000001';
  v_manager   uuid := '20000000-0000-0000-0000-000000000004';
  v_doc_ver   uuid;
  v_assign1   uuid;
  v_superseded int;
  v_version   int;
  v_pending_id uuid;
  v_pdf_job   uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    format(
      '{"sub":"%s","app_metadata":{"user_tenants":{"%s":{"global_role":"manager","sites":{}}},"user_permissions":{"%s":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
      v_manager, v_tenant, v_tenant
    ),
    true
  );

  SELECT dv.id INTO v_doc_ver
  FROM data.document_versions dv
  JOIN data.documents d ON d.id = dv.document_id
  WHERE d.tenant_id = v_tenant
  LIMIT 1;

  PERFORM g6_lot4_assert(v_doc_ver IS NOT NULL, 'fixture document version exists');

  v_assign1 := api.create_attendance_protocol_assignment(v_employee, v_doc_ver, NULL);
  PERFORM g6_lot4_assert(v_assign1 IS NOT NULL, 'assignment created');

  SELECT protocol_version INTO v_version
  FROM data.employee_portal_document_assignments WHERE id = v_assign1;
  PERFORM g6_lot4_assert(v_version = 1, 'first assignment version is 1');

  v_superseded := data.supersede_pending_attendance_protocols(v_employee, v_tenant, v_manager);
  PERFORM g6_lot4_assert(v_superseded >= 1, 'supersede marks pending assignment');

  PERFORM g6_lot4_assert(
    EXISTS (
      SELECT 1 FROM data.employee_portal_document_assignments
      WHERE id = v_assign1 AND superseded_at IS NOT NULL
    ),
    'assignment has superseded_at'
  );

  PERFORM g6_lot4_assert(
    data.next_attendance_protocol_version(v_employee, v_tenant) = 2,
    'next version increments'
  );

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  INSERT INTO data.document_pdf_jobs (
    tenant_id, status, source_type, template_type, document_title, idempotency_key
  )
  VALUES (v_tenant, 'queued', 'template_locale', 'html', 'Protocol test PDF', 'test-pdf-' || gen_random_uuid()::text)
  RETURNING id INTO v_pdf_job;

  v_pending_id := data.stage_attendance_protocol_publish_pending(
    v_tenant, v_employee, v_pdf_job, NULL, v_manager, false, NULL, 'Test Empleat'
  );
  PERFORM g6_lot4_assert(v_pending_id IS NOT NULL, 'stage pending for async PDF');

  UPDATE data.document_pdf_jobs
  SET status = 'completed',
      result_version_id = v_doc_ver,
      completed_at = now()
  WHERE id = v_pdf_job;

  PERFORM g6_lot4_assert(
    data.service_mark_protocol_publish_pending_ready(v_pdf_job) = v_pending_id,
    'mark pending ready after pdf job completes'
  );

  PERFORM g6_lot4_assert(
    (data.cleanup_orphan_attendance_protocol_documents(0, 10)->>'deleted') IS NOT NULL,
    'orphan cleanup callable'
  );
END;
$$;

SELECT msg FROM g6_lot4_test_log ORDER BY id;

ROLLBACK;
