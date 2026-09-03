-- Drop legacy RPC overloads (without p_work_intervals) so PostgREST always
-- invokes the version that persists the full work_intervals JSONB array.

DROP FUNCTION IF EXISTS api.upsert_labor_calendar_days(
  date[], text, text, time without time zone, time without time zone, uuid
);

DROP FUNCTION IF EXISTS api.apply_weekly_pattern_to_calendar(
  integer, integer[], text, text, time without time zone, time without time zone, uuid
);

-- Backfill: rows saved via the legacy RPC may have work_start/work_end but empty work_intervals.
UPDATE data.labor_calendar_overrides
SET work_intervals = jsonb_build_array(
  jsonb_build_object(
    'start', to_char(work_start, 'HH24:MI'),
    'end',   to_char(work_end, 'HH24:MI')
  )
)
WHERE day_type = 'work'
  AND work_start IS NOT NULL
  AND work_end IS NOT NULL
  AND (
    work_intervals IS NULL
    OR work_intervals = '[]'::jsonb
    OR jsonb_array_length(work_intervals) = 0
  );
