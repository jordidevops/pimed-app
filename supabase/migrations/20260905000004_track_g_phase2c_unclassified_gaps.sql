-- Track G Phase 2c: UNCLASSIFIED_GAP helper (D-INT-7)

CREATE OR REPLACE FUNCTION data.collect_unclassified_gaps(
  p_employee_id uuid,
  p_work_date   date,
  p_threshold   int DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_gap   record;
  v_items jsonb := '[]'::jsonb;
BEGIN
  FOR v_gap IN
    SELECT g.id, g.started_at, g.ended_at,
           ROUND(EXTRACT(EPOCH FROM (g.ended_at - g.started_at)) / 60)::int AS minutes
    FROM data.work_log_field_gaps g
    WHERE g.employee_id = p_employee_id
      AND g.work_date = p_work_date
      AND g.gap_kind = 'UNCLASSIFIED'
  LOOP
    IF v_gap.minutes > p_threshold THEN
      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'gap_id', v_gap.id,
        'started_at', v_gap.started_at,
        'ended_at', v_gap.ended_at,
        'minutes', v_gap.minutes,
        'kind', 'UNCLASSIFIED'
      ));
    END IF;
  END LOOP;

  RETURN v_items;
END;
$$;

REVOKE ALL ON FUNCTION data.collect_unclassified_gaps(uuid, date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.collect_unclassified_gaps(uuid, date, int) TO service_role;
