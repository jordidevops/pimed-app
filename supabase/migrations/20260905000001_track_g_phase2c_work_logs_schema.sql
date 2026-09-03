-- Track G Phase 2c: work_logs entry_mode + field gap declarations (D-INT-2, D-INT-7)

ALTER TABLE data.work_logs
  ADD COLUMN IF NOT EXISTS entry_mode text NOT NULL DEFAULT 'timer'
    CHECK (entry_mode IN ('field_punch', 'timer', 'manual'));

ALTER TABLE data.work_logs
  ADD COLUMN IF NOT EXISTS time_punch_in_id uuid REFERENCES data.time_punches(id) ON DELETE SET NULL;

ALTER TABLE data.work_logs
  ADD COLUMN IF NOT EXISTS time_punch_out_id uuid REFERENCES data.time_punches(id) ON DELETE SET NULL;

ALTER TABLE data.work_logs
  ADD COLUMN IF NOT EXISTS employee_id uuid REFERENCES data.employees(id) ON DELETE SET NULL;

COMMENT ON COLUMN data.work_logs.entry_mode IS
  'field_punch = camp+legal vinculat a time_punches; timer/manual no alimenten segments (D-INT-3).';

CREATE INDEX IF NOT EXISTS idx_work_logs_entry_mode
  ON data.work_logs (tenant_id, entry_mode, check_in DESC);

CREATE INDEX IF NOT EXISTS idx_work_logs_employee_date
  ON data.work_logs (employee_id, check_in DESC)
  WHERE employee_id IS NOT NULL;

-- Gaps declarats entre field_punch (switch_work_log / field_punch_stop — D-INT-7)
CREATE TABLE IF NOT EXISTS data.work_log_field_gaps (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id      uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  work_date        date NOT NULL,
  started_at       timestamptz NOT NULL,
  ended_at         timestamptz NOT NULL,
  gap_kind         text NOT NULL CHECK (gap_kind IN (
    'TRAVEL', 'BREAK_UNPAID', 'BREAK_PAID', 'OFF_DUTY', 'UNCLASSIFIED'
  )),
  prev_work_log_id uuid REFERENCES data.work_logs(id) ON DELETE SET NULL,
  next_work_log_id uuid REFERENCES data.work_logs(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (ended_at > started_at)
);

CREATE INDEX IF NOT EXISTS idx_work_log_field_gaps_employee_date
  ON data.work_log_field_gaps (employee_id, work_date, started_at);

ALTER TABLE data.work_log_field_gaps ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "wlfg: tenant read" ON data.work_log_field_gaps;
CREATE POLICY "wlfg: tenant read"
  ON data.work_log_field_gaps FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

GRANT SELECT ON data.work_log_field_gaps TO authenticated;
GRANT ALL ON data.work_log_field_gaps TO service_role;

CREATE OR REPLACE FUNCTION data.normalize_field_gap_kind(p_gap_kind text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(trim(COALESCE(p_gap_kind, '')))
    WHEN 'travel' THEN 'TRAVEL'
    WHEN 'break_unpaid' THEN 'BREAK_UNPAID'
    WHEN 'break_paid' THEN 'BREAK_PAID'
    WHEN 'day_end' THEN 'TRAVEL'
    WHEN 'off_duty' THEN 'OFF_DUTY'
    WHEN 'unclassified' THEN 'UNCLASSIFIED'
    WHEN '' THEN 'UNCLASSIFIED'
    ELSE CASE
      WHEN upper(trim(p_gap_kind)) IN (
        'TRAVEL', 'BREAK_UNPAID', 'BREAK_PAID', 'OFF_DUTY', 'UNCLASSIFIED'
      ) THEN upper(trim(p_gap_kind))
      ELSE 'UNCLASSIFIED'
    END
  END;
$$;

REVOKE ALL ON FUNCTION data.normalize_field_gap_kind(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.normalize_field_gap_kind(text) TO service_role;

-- Backfill employee_id on existing rows where worker maps to employee
UPDATE data.work_logs wl
SET employee_id = e.id
FROM data.employees e
WHERE wl.employee_id IS NULL
  AND e.user_id = wl.worker_id
  AND e.tenant_id = wl.tenant_id;
