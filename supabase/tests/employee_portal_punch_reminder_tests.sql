-- =============================================================================
-- employee_portal_punch_reminder_tests.sql — WS-B1
-- =============================================================================

BEGIN;

CREATE TEMP TABLE pr_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active, settings)
VALUES (
  'b1000000-0000-0000-0000-000000000001',
  'PR Test Tenant',
  'pr-test',
  true,
  '{"attendance":{"punch_reminders":{"enabled":true,"delay_minutes":0,"max_per_day":4}},"attendance_punch_reminders":{"enabled":true,"delay_minutes":0,"max_per_day":4}}'::jsonb
)
ON CONFLICT (id) DO UPDATE
SET settings = EXCLUDED.settings;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'PR Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'b5000000-0000-0000-0000-000000000001',
  'b1000000-0000-0000-0000-000000000001',
  'b2000000-0000-0000-0000-000000000001',
  NULL,
  'PR Employee',
  'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_portal_tokens (
  id, tenant_id, employee_id, token_hash, label, is_active
)
VALUES (
  'b5500000-0000-0000-0000-000000000001',
  'b1000000-0000-0000-0000-000000000001',
  'b5000000-0000-0000-0000-000000000001',
  decode('aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899', 'hex'),
  'PR Test',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_portal_push_subscriptions (
  id, token_id, tenant_id, employee_id, endpoint, p256dh, auth
)
VALUES (
  'b6000000-0000-0000-0000-000000000001',
  'b5500000-0000-0000-0000-000000000001',
  'b1000000-0000-0000-0000-000000000001',
  'b5000000-0000-0000-0000-000000000001',
  'https://push.example/test-endpoint',
  'p256dh-test',
  'auth-test'
)
ON CONFLICT (id) DO NOTHING;

-- PR-T1: claim idempotent
DO $$
DECLARE
  v_first boolean;
  v_second boolean;
BEGIN
  v_first := api.try_claim_employee_portal_punch_reminder(
    'b1000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001',
    CURRENT_DATE,
    'missing_entry',
    4
  );

  v_second := api.try_claim_employee_portal_punch_reminder(
    'b1000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001',
    CURRENT_DATE,
    'missing_entry',
    4
  );

  IF v_first IS TRUE AND v_second IS FALSE THEN
    INSERT INTO pr_test_results VALUES ('PR-T1 claim idempotent', 'PASS', NULL);
  ELSE
    INSERT INTO pr_test_results VALUES (
      'PR-T1 claim idempotent',
      'FAIL',
      format('first=%s second=%s', v_first, v_second)
    );
  END IF;
END;
$$;

-- PR-T2: enqueue punch_reminder
DO $$
DECLARE
  v_msg_id bigint;
BEGIN
  PERFORM api.release_employee_portal_punch_reminder_claim(
    'b5000000-0000-0000-0000-000000000001',
    CURRENT_DATE,
    'missing_exit'
  );

  PERFORM api.try_claim_employee_portal_punch_reminder(
    'b1000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001',
    CURRENT_DATE,
    'missing_exit',
    4
  );

  v_msg_id := api.enqueue_employee_portal_punch_reminder(
    'b1000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001',
    CURRENT_DATE,
    'missing_exit'
  );

  IF v_msg_id IS NOT NULL THEN
    INSERT INTO pr_test_results VALUES ('PR-T2 enqueue punch_reminder', 'PASS', NULL);
  ELSE
    INSERT INTO pr_test_results VALUES (
      'PR-T2 enqueue punch_reminder',
      'FAIL',
      format('msg_id=%s', v_msg_id)
    );
  END IF;
END;
$$;

-- PR-T3: candidates include employee with subscription
DO $$
DECLARE
  v_rows jsonb;
  v_found boolean := false;
  v_row jsonb;
BEGIN
  v_rows := api.list_employee_portal_punch_reminder_candidates();

  FOR v_row IN SELECT * FROM jsonb_array_elements(v_rows)
  LOOP
    IF (v_row ->> 'employee_id')::uuid = 'b5000000-0000-0000-0000-000000000001' THEN
      v_found := true;
      EXIT;
    END IF;
  END LOOP;

  IF v_found THEN
    INSERT INTO pr_test_results VALUES ('PR-T3 list candidates', 'PASS', NULL);
  ELSE
    INSERT INTO pr_test_results VALUES ('PR-T3 list candidates', 'FAIL', 'employee not listed');
  END IF;
END;
$$;

SELECT * FROM pr_test_results ORDER BY test_name;

ROLLBACK;
