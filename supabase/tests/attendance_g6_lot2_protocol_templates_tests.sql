-- Track G6 Lot 2 — protocol template resolution
BEGIN;

CREATE TEMP TABLE g6_lot2_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION g6_lot2_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO g6_lot2_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

DO $$
DECLARE
  v_settings jsonb;
  v_id uuid;
BEGIN
  v_settings := jsonb_build_object(
    'attendance_protocol_template_locale_id', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'attendance_protocol_template_by_profile', jsonb_build_object(
      'mobile_peripatetic', '71000000-0000-0000-0000-000000000031'
    )
  );

  v_id := data.resolve_attendance_protocol_template_locale(v_settings, 'fixed_site');
  PERFORM g6_lot2_assert(
    v_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
    'fixed_site uses tenant default'
  );

  v_id := data.resolve_attendance_protocol_template_locale(v_settings, 'mobile_peripatetic');
  PERFORM g6_lot2_assert(
    v_id = '71000000-0000-0000-0000-000000000031'::uuid,
    'mobile uses profile override'
  );

  v_settings := '{}'::jsonb;
  v_id := data.resolve_attendance_protocol_template_locale(v_settings, 'hybrid');
  PERFORM g6_lot2_assert(
    v_id = '71000000-0000-0000-0000-000000000030'::uuid,
    'empty settings fall back to platform default'
  );
END;
$$;

SELECT msg FROM g6_lot2_test_log ORDER BY id;

ROLLBACK;
