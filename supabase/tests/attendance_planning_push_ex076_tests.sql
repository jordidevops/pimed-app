-- =============================================================================
-- attendance_planning_push_ex076_tests.sql
-- EX-07.6 — planning push enqueue + escalat urgent
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ex076_results (test_name text, status text, details text) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0760000-0000-0000-0000-000000000001', 'EX076 Tenant', 'ex076-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0760000-0000-0000-0000-000000000001', 'a0760000-0000-0000-0000-000000000001', 'EX076 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0760000-0000-0000-0000-000000000001',
  'a0760000-0000-0000-0000-000000000001',
  'b0760000-0000-0000-0000-000000000001',
  NULL, 'Emp EX076', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_portal_tokens (
  id, tenant_id, employee_id, token_hash, label, is_active
)
VALUES (
  'e0760000-0000-0000-0000-000000000001',
  'a0760000-0000-0000-0000-000000000001',
  'd0760000-0000-0000-0000-000000000001',
  decode('00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff', 'hex'),
  'EX076',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_portal_push_subscriptions (
  id, token_id, tenant_id, employee_id, endpoint, p256dh, auth
)
VALUES (
  'f0760000-0000-0000-0000-000000000001',
  'e0760000-0000-0000-0000-000000000001',
  'a0760000-0000-0000-0000-000000000001',
  'd0760000-0000-0000-0000-000000000001',
  'https://push.example/ex076',
  'p256dh-ex076',
  'auth-ex076'
)
ON CONFLICT (id) DO NOTHING;

-- Purge queue noise for this test (best-effort)
DO $$
BEGIN
  PERFORM pgmq.drop_queue('employee_portal_push_queue_ex076_tmp');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;

-- T1 enqueue single planning push
DO $$
DECLARE
  v_msg bigint;
  v_found boolean := false;
BEGIN
  -- Mid-day to avoid quiet hours (force urgent=true anyway)
  v_msg := data.enqueue_employee_portal_planning_push(
    'a0760000-0000-0000-0000-000000000001'::uuid,
    'd0760000-0000-0000-0000-000000000001'::uuid,
    'opening_published'::text,
    jsonb_build_object('entity_id', 't1', 'site_id', 'b0760000-0000-0000-0000-000000000001'),
    true,
    'b0760000-0000-0000-0000-000000000001'::uuid
  );

  SELECT EXISTS (
    SELECT 1
    FROM pgmq.q_employee_portal_push_queue q
    WHERE (q.message->>'task') = 'planning_push'
      AND (q.message->>'employee_id') = 'd0760000-0000-0000-0000-000000000001'
      AND (q.message->>'event') = 'opening_published'
  ) INTO v_found;

  IF v_msg IS NOT NULL AND v_found THEN
    INSERT INTO ex076_results VALUES ('T1 enqueue_planning_push', 'PASS', v_msg::text);
  ELSE
    INSERT INTO ex076_results VALUES ('T1 enqueue_planning_push', 'FAIL',
      format('msg=%s found=%s', v_msg, v_found));
  END IF;
END;
$$;

-- T2 fanout to site
DO $$
DECLARE
  v_count int;
BEGIN
  v_count := data.fanout_planning_push_to_site(
    'a0760000-0000-0000-0000-000000000001'::uuid,
    'b0760000-0000-0000-0000-000000000001'::uuid,
    'opening_urgent'::text,
    jsonb_build_object('entity_id', 't2', 'title', 'Urgent test'),
    true,
    NULL
  );

  IF v_count >= 1 THEN
    INSERT INTO ex076_results VALUES ('T2 fanout_site', 'PASS', v_count::text);
  ELSE
    INSERT INTO ex076_results VALUES ('T2 fanout_site', 'FAIL', v_count::text);
  END IF;
END;
$$;

-- T3 publish opening → trigger fanout + is_urgent from call_off notes
DO $$
DECLARE
  v_opening_id uuid;
  v_is_urgent boolean;
  v_found boolean;
BEGIN
  INSERT INTO data.shift_openings (
    id, tenant_id, site_id, opening_date, start_time, end_time,
    places_total, places_filled, claim_policy, status, title, notes, published_at
  ) VALUES (
    'c0760000-0000-0000-0000-000000000001',
    'a0760000-0000-0000-0000-000000000001',
    'b0760000-0000-0000-0000-000000000001',
    CURRENT_DATE + 1,
    '10:00', '14:00',
    1, 0, 'manager_approval', 'open',
    'EX076 vacant',
    'call_off:test',
    now()
  )
  ON CONFLICT (id) DO UPDATE
  SET status = 'open', notes = 'call_off:test', is_urgent = true
  RETURNING id, is_urgent INTO v_opening_id, v_is_urgent;

  SELECT EXISTS (
    SELECT 1 FROM pgmq.q_employee_portal_push_queue q
    WHERE (q.message->>'task') = 'planning_push'
      AND (q.message->>'event') IN ('opening_urgent', 'opening_published')
      AND (q.message->'payload'->>'entity_id') = v_opening_id::text
  ) INTO v_found;

  IF v_is_urgent AND v_found THEN
    INSERT INTO ex076_results VALUES ('T3 opening_trigger_urgent', 'PASS', v_opening_id::text);
  ELSE
    INSERT INTO ex076_results VALUES ('T3 opening_trigger_urgent', 'FAIL',
      format('urgent=%s found=%s', v_is_urgent, v_found));
  END IF;
END;
$$;

-- T4 claim reject → claim_rejected event
DO $$
DECLARE
  v_claim_id uuid;
  v_found boolean;
BEGIN
  INSERT INTO data.shift_opening_claims (
    id, tenant_id, opening_id, employee_id, status, notes
  ) VALUES (
    'c0760000-0000-0000-0000-000000000010',
    'a0760000-0000-0000-0000-000000000001',
    'c0760000-0000-0000-0000-000000000001',
    'd0760000-0000-0000-0000-000000000001',
    'pending',
    'test'
  )
  ON CONFLICT (id) DO UPDATE SET status = 'pending'
  RETURNING id INTO v_claim_id;

  UPDATE data.shift_opening_claims
  SET status = 'rejected', updated_at = now()
  WHERE id = v_claim_id;

  SELECT EXISTS (
    SELECT 1 FROM pgmq.q_employee_portal_push_queue q
    WHERE (q.message->>'event') = 'claim_rejected'
      AND (q.message->>'employee_id') = 'd0760000-0000-0000-0000-000000000001'
  ) INTO v_found;

  IF v_found THEN
    INSERT INTO ex076_results VALUES ('T4 claim_rejected_push', 'PASS', v_claim_id::text);
  ELSE
    INSERT INTO ex076_results VALUES ('T4 claim_rejected_push', 'FAIL', 'not found');
  END IF;
END;
$$;

-- T5 escalate updates last_escalated_at
DO $$
DECLARE
  v_res jsonb;
  v_last timestamptz;
BEGIN
  UPDATE data.shift_openings
  SET is_urgent = true,
      status = 'open',
      places_filled = 0,
      last_escalated_at = NULL,
      opening_date = CURRENT_DATE
  WHERE id = 'c0760000-0000-0000-0000-000000000001';

  v_res := api.escalate_urgent_shift_openings(clock_timestamp(), 2);

  SELECT last_escalated_at INTO v_last
  FROM data.shift_openings
  WHERE id = 'c0760000-0000-0000-0000-000000000001';

  IF (v_res->>'openings_escalated')::int >= 1 AND v_last IS NOT NULL THEN
    INSERT INTO ex076_results VALUES ('T5 escalate_urgent', 'PASS', v_res::text);
  ELSE
    INSERT INTO ex076_results VALUES ('T5 escalate_urgent', 'FAIL',
      jsonb_build_object('res', v_res, 'last', v_last)::text);
  END IF;
END;
$$;

SELECT test_name, status, details FROM ex076_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex076_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-07.6 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
