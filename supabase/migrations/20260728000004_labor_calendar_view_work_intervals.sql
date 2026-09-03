-- Add work_intervals to the api.labor_calendar_overrides view.
-- The view was created before this column was added to data.labor_calendar_overrides,
-- so PostgREST was returning rows without work_intervals, causing only the
-- first interval to be visible (falling back to work_start/work_end).

-- CREATE OR REPLACE VIEW cannot insert columns in the middle; work_intervals must
-- come after the columns that already exist in the view (at the end).
CREATE OR REPLACE VIEW api.labor_calendar_overrides AS
SELECT
  id,
  tenant_id,
  site_id,
  calendar_date,
  day_type,
  day_name,
  work_start,
  work_end,
  created_at,
  updated_at,
  work_intervals
FROM data.labor_calendar_overrides;

COMMENT ON VIEW api.labor_calendar_overrides IS
  'Tenant/site labor calendar day overrides, including multi-slot work_intervals.';
