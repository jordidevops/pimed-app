-- Smoke test: api.get_attendance_queue_health (requereix migració 20260806000001)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_health jsonb;
  v_len    int;
BEGIN
  v_health := api.get_attendance_queue_health();
  v_len    := COALESCE((v_health->>'queue_length')::int, -1);

  IF v_health ? 'queue_name' AND v_len >= 0 THEN
    RAISE NOTICE 'PASS: get_attendance_queue_health queue_length=%', v_len;
  ELSE
    RAISE EXCEPTION 'FAIL: resposta health inesperada: %', v_health;
  END IF;
END;
$$;
