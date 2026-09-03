-- Track G6 Lot 3 — bulk publish + auto onboarding
BEGIN;

CREATE TEMP TABLE g6_lot3_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION g6_lot3_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO g6_lot3_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

DO $$
DECLARE
  v_tenant_id uuid := '10000000-0000-0000-0000-000000000001';
  v_emp_id    uuid := '40000000-0000-0000-0000-000000000001';
  v_job_id    uuid;
  v_item_id   uuid;
  v_lacks     boolean;
  v_payload   jsonb;
BEGIN
  PERFORM g6_lot3_assert(
    EXISTS (SELECT 1 FROM data.employees WHERE id = v_emp_id AND tenant_id = v_tenant_id),
    'fixture employee exists'
  );

  v_lacks := data.employee_lacks_attendance_protocol(v_emp_id, v_tenant_id);
  PERFORM g6_lot3_assert(v_lacks IS NOT NULL, 'employee_lacks_attendance_protocol callable');

  INSERT INTO data.attendance_protocol_bulk_jobs (tenant_id, scope, total_count)
  VALUES (v_tenant_id, 'all_active', 1)
  RETURNING id INTO v_job_id;

  INSERT INTO data.attendance_protocol_bulk_job_items (job_id, tenant_id, employee_id, source)
  VALUES (v_job_id, v_tenant_id, v_emp_id, 'onboarding')
  RETURNING id INTO v_item_id;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  v_payload := data.service_get_protocol_publish_payload(v_item_id);
  PERFORM g6_lot3_assert((v_payload->>'employee_id')::uuid = v_emp_id, 'payload resolves employee');
  PERFORM g6_lot3_assert(v_payload->>'template_locale_id' IS NOT NULL, 'payload has template');
  PERFORM g6_lot3_assert(v_payload->>'initiated_by_user_id' IS NOT NULL, 'payload has initiator fallback');

  PERFORM data.service_complete_protocol_publish_item(v_item_id, 'skipped', NULL, 'test');
  PERFORM g6_lot3_assert(
    EXISTS (
      SELECT 1 FROM data.attendance_protocol_bulk_jobs j
      WHERE j.id = v_job_id AND j.skipped_count = 1 AND j.status = 'completed'
    ),
    'complete item updates job counters and status'
  );
END;
$$;

SELECT msg FROM g6_lot3_test_log ORDER BY id;

ROLLBACK;
