-- =============================================================================
-- attendance_shift_publications_ex041_tests.sql
-- EX-04.1 — Lots versionats (shift_publications), publication_id, list/get
--
-- Executar:
--   Get-Content supabase/tests/attendance_shift_publications_ex041_tests.sql |
--     docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres -v ON_ERROR_STOP=0
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0410000-0000-0000-0000-000000000001', 'EX041 Tenant', 'ex041-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0410000-0000-0000-0000-000000000001', 'a0410000-0000-0000-0000-000000000001', 'EX041 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0410000-0000-0000-0000-000000000001', 'emp@ex041.test', 'authenticated', 'authenticated'),
  ('c0410000-0000-0000-0000-000000000002', 'mgr@ex041.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0410000-0000-0000-0000-000000000001', 'emp@ex041.test', 'Emp EX041'),
  ('c0410000-0000-0000-0000-000000000002', 'mgr@ex041.test', 'Mgr EX041')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0410000-0000-0000-0000-000000000001', 'c0410000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0410000-0000-0000-0000-000000000001', 'c0410000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0410000-0000-0000-0000-000000000001',
  'a0410000-0000-0000-0000-000000000001',
  'b0410000-0000-0000-0000-000000000001',
  'c0410000-0000-0000-0000-000000000001',
  'Emp EX041', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES (
  'e0410000-0000-0000-0000-000000000001',
  'a0410000-0000-0000-0000-000000000001',
  'b0410000-0000-0000-0000-000000000001',
  'Cuina EX041', 'zone', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_shifts (
  id, tenant_id, site_id, name, color, start_time, end_time, is_active, default_location_id
) VALUES (
  'f0410000-0000-0000-0000-000000000001',
  'a0410000-0000-0000-0000-000000000001',
  'b0410000-0000-0000-0000-000000000001',
  'Matí EX041', '#3b82f6', '09:00', '17:00', true,
  'e0410000-0000-0000-0000-000000000001'
)
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE ex041_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0410000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0410000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0410000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0410000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

-- T1: primera publicació → version=1 + publication_id als slots
DO $$
DECLARE
  v_asg jsonb;
  v_pub jsonb;
  v_slot_pub uuid;
  v_hash text;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_asg := api.assign_shift_slot(
    'd0410000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    'f0410000-0000-0000-0000-000000000001'::uuid
  );
  v_pub := api.publish_shifts(
    'b0410000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  SET LOCAL ROLE postgres;

  SELECT publication_id INTO v_slot_pub
  FROM data.shift_slots WHERE id = (v_asg->>'slot_id')::uuid;

  SELECT content_hash INTO v_hash
  FROM data.shift_publications WHERE id = (v_pub->>'publication_id')::uuid;

  IF (v_pub->>'published')::int = 1
     AND (v_pub->>'version')::int = 1
     AND v_pub->>'publication_id' IS NOT NULL
     AND v_slot_pub = (v_pub->>'publication_id')::uuid
     AND v_hash IS NOT NULL AND length(v_hash) = 64
  THEN
    INSERT INTO ex041_results VALUES ('T1 first publish v1', 'PASS',
      format('pub=%s hash_len=%s', v_pub->>'version', length(v_hash)));
  ELSE
    INSERT INTO ex041_results VALUES ('T1 first publish v1', 'FAIL',
      format('pub=%s slot_pub=%s hash=%s', v_pub, v_slot_pub, v_hash));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex041_results VALUES ('T1 first publish v1', 'ERROR', SQLERRM);
END;
$$;

-- T2: segona publicació → version=2 + lot v1 superseded
DO $$
DECLARE
  v_asg jsonb;
  v_pub jsonb;
  v_v1_status text;
  v_published_lots int;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_asg := api.assign_shift_slot(
    'd0410000-0000-0000-0000-000000000001'::uuid,
    '2026-07-14'::date,
    'f0410000-0000-0000-0000-000000000001'::uuid
  );
  v_pub := api.publish_shifts(
    'b0410000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  SET LOCAL ROLE postgres;

  SELECT status INTO v_v1_status
  FROM data.shift_publications
  WHERE site_id = 'b0410000-0000-0000-0000-000000000001'
    AND week_start = '2026-07-13'
    AND version = 1;

  SELECT count(*)::int INTO v_published_lots
  FROM data.shift_publications
  WHERE site_id = 'b0410000-0000-0000-0000-000000000001'
    AND week_start = '2026-07-13'
    AND status = 'published';

  IF (v_pub->>'version')::int = 2
     AND (v_pub->>'published')::int = 1
     AND v_v1_status = 'superseded'
     AND v_published_lots = 1
     AND v_asg->>'slot_id' IS NOT NULL
  THEN
    INSERT INTO ex041_results VALUES ('T2 version bump supersede', 'PASS',
      format('v2=%s v1=%s', v_pub->>'version', v_v1_status));
  ELSE
    INSERT INTO ex041_results VALUES ('T2 version bump supersede', 'FAIL',
      format('pub=%s v1=%s lots=%s', v_pub, v_v1_status, v_published_lots));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex041_results VALUES ('T2 version bump supersede', 'ERROR', SQLERRM);
END;
$$;

-- T3: slots v1 i v2 tenen publication_id diferents
DO $$
DECLARE
  v_v1 uuid;
  v_v2 uuid;
  v_slot1 uuid;
  v_slot2 uuid;
BEGIN
  SELECT id INTO v_v1 FROM data.shift_publications
  WHERE site_id = 'b0410000-0000-0000-0000-000000000001'
    AND week_start = '2026-07-13' AND version = 1;
  SELECT id INTO v_v2 FROM data.shift_publications
  WHERE site_id = 'b0410000-0000-0000-0000-000000000001'
    AND week_start = '2026-07-13' AND version = 2;

  SELECT id INTO v_slot1 FROM data.shift_slots
  WHERE publication_id = v_v1 LIMIT 1;
  SELECT id INTO v_slot2 FROM data.shift_slots
  WHERE publication_id = v_v2 LIMIT 1;

  IF v_v1 IS DISTINCT FROM v_v2
     AND v_slot1 IS NOT NULL AND v_slot2 IS NOT NULL
     AND v_slot1 IS DISTINCT FROM v_slot2
  THEN
    INSERT INTO ex041_results VALUES ('T3 slots per lot', 'PASS', 'ok');
  ELSE
    INSERT INTO ex041_results VALUES ('T3 slots per lot', 'FAIL',
      format('v1=%s v2=%s s1=%s s2=%s', v_v1, v_v2, v_slot1, v_slot2));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex041_results VALUES ('T3 slots per lot', 'ERROR', SQLERRM);
END;
$$;

-- T4: freeze location després de publish
DO $$
DECLARE
  v_slot uuid;
  v_ok boolean := false;
BEGIN
  SELECT id INTO v_slot FROM data.shift_slots
  WHERE employee_id = 'd0410000-0000-0000-0000-000000000001'
    AND status = 'published'
  LIMIT 1;

  BEGIN
    UPDATE data.shift_slots
    SET location_id = NULL
    WHERE id = v_slot;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%cannot mutate published%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO ex041_results VALUES ('T4 freeze published', 'PASS', 'ok');
  ELSE
    INSERT INTO ex041_results VALUES ('T4 freeze published', 'FAIL', 'no freeze');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex041_results VALUES ('T4 freeze published', 'ERROR', SQLERRM);
END;
$$;

-- T5: list_shift_publications
DO $$
DECLARE
  v_rows jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_rows := api.list_shift_publications(
    'b0410000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    10
  );
  SET LOCAL ROLE postgres;

  IF jsonb_array_length(v_rows) = 2
     AND (v_rows->0->>'version')::int = 2
     AND (v_rows->1->>'version')::int = 1
     AND v_rows->1->>'status' = 'superseded'
  THEN
    INSERT INTO ex041_results VALUES ('T5 list publications', 'PASS',
      format('n=%s', jsonb_array_length(v_rows)));
  ELSE
    INSERT INTO ex041_results VALUES ('T5 list publications', 'FAIL', v_rows::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex041_results VALUES ('T5 list publications', 'ERROR', SQLERRM);
END;
$$;

-- T6: get_shift_publication
DO $$
DECLARE
  v_pub_id uuid;
  v_detail jsonb;
BEGIN
  SELECT id INTO v_pub_id FROM data.shift_publications
  WHERE site_id = 'b0410000-0000-0000-0000-000000000001'
    AND week_start = '2026-07-13' AND version = 2;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_detail := api.get_shift_publication(v_pub_id);
  SET LOCAL ROLE postgres;

  IF v_detail->'publication'->>'version' = '2'
     AND jsonb_array_length(v_detail->'slots') = 1
  THEN
    INSERT INTO ex041_results VALUES ('T6 get publication', 'PASS',
      format('slots=%s', jsonb_array_length(v_detail->'slots')));
  ELSE
    INSERT INTO ex041_results VALUES ('T6 get publication', 'FAIL', v_detail::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex041_results VALUES ('T6 get publication', 'ERROR', SQLERRM);
END;
$$;

-- T7: empty publish no crea lot
DO $$
DECLARE
  v_pub jsonb;
  v_lots_before int;
  v_lots_after int;
BEGIN
  SELECT count(*)::int INTO v_lots_before
  FROM data.shift_publications
  WHERE site_id = 'b0410000-0000-0000-0000-000000000001'
    AND week_start = '2026-07-13';

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_pub := api.publish_shifts(
    'b0410000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );
  SET LOCAL ROLE postgres;

  SELECT count(*)::int INTO v_lots_after
  FROM data.shift_publications
  WHERE site_id = 'b0410000-0000-0000-0000-000000000001'
    AND week_start = '2026-07-13';

  IF (v_pub->>'published')::int = 0
     AND v_pub->>'publication_id' IS NULL
     AND v_lots_before = v_lots_after
  THEN
    INSERT INTO ex041_results VALUES ('T7 empty publish', 'PASS', 'ok');
  ELSE
    INSERT INTO ex041_results VALUES ('T7 empty publish', 'FAIL',
      format('pub=%s before=%s after=%s', v_pub, v_lots_before, v_lots_after));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex041_results VALUES ('T7 empty publish', 'ERROR', SQLERRM);
END;
$$;

-- T8: Monday guard
DO $$
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  PERFORM api.publish_shifts(
    'b0410000-0000-0000-0000-000000000001'::uuid,
    '2026-07-14'::date
  );
  SET LOCAL ROLE postgres;
  INSERT INTO ex041_results VALUES ('T8 monday guard', 'FAIL', 'expected exception');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  IF SQLERRM ILIKE '%invalid_week_start%' THEN
    INSERT INTO ex041_results VALUES ('T8 monday guard', 'PASS', SQLERRM);
  ELSE
    INSERT INTO ex041_results VALUES ('T8 monday guard', 'ERROR', SQLERRM);
  END IF;
END;
$$;

-- T9: calendar_events després de publish
DO $$
DECLARE
  v_events int;
  v_slots int;
BEGIN
  SELECT count(*)::int INTO v_slots
  FROM data.shift_slots
  WHERE site_id = 'b0410000-0000-0000-0000-000000000001'
    AND slot_date BETWEEN '2026-07-13' AND '2026-07-19'
    AND status = 'published';

  SELECT count(*)::int INTO v_events
  FROM data.calendar_events ce
  WHERE ce.entity_type = 'shift_slot'
    AND ce.entity_id IN (
      SELECT id FROM data.shift_slots
      WHERE site_id = 'b0410000-0000-0000-0000-000000000001'
        AND slot_date BETWEEN '2026-07-13' AND '2026-07-19'
        AND status = 'published'
    );

  IF v_events = v_slots AND v_slots >= 2 THEN
    INSERT INTO ex041_results VALUES ('T9 calendar events', 'PASS',
      format('events=%s slots=%s', v_events, v_slots));
  ELSE
    INSERT INTO ex041_results VALUES ('T9 calendar events', 'FAIL',
      format('events=%s slots=%s', v_events, v_slots));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex041_results VALUES ('T9 calendar events', 'ERROR', SQLERRM);
END;
$$;

SELECT * FROM ex041_results ORDER BY test_name;

SELECT
  count(*) FILTER (WHERE status = 'PASS') AS passed,
  count(*) FILTER (WHERE status = 'FAIL') AS failed,
  count(*) FILTER (WHERE status = 'ERROR') AS errors,
  count(*) AS total
FROM ex041_results;

ROLLBACK;
