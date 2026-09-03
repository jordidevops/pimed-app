-- Exposar group_id i employee_id a la vista api.labor_calendar_overrides
-- (necessari per filtrar overrides per nivell de cascada via PostgREST).
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
  work_intervals,
  group_id,
  employee_id
FROM data.labor_calendar_overrides;

COMMENT ON VIEW api.labor_calendar_overrides IS
  'Labor calendar overrides (tenant/site/group/employee) with multi-slot work_intervals.';
