-- La migració phase_b va reemplaçar la CONSTRAINT per un UNIQUE INDEX amb el mateix nom.
-- Les RPCs fan ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique, que només
-- funciona amb constraints reals — no amb índexos únics.
DROP INDEX IF EXISTS data.labor_calendar_overrides_unique;

ALTER TABLE data.labor_calendar_overrides
  ADD CONSTRAINT labor_calendar_overrides_unique
  UNIQUE NULLS NOT DISTINCT (tenant_id, site_id, group_id, employee_id, calendar_date);
