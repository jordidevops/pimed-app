-- =============================================================================
-- M-ES-03 — Trigger single-writer de lifecycle_state + auditoria
-- =============================================================================

CREATE OR REPLACE FUNCTION data.sync_employee_lifecycle_state()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.effective_on <= CURRENT_DATE THEN
    PERFORM set_config('data.lifecycle_state_write', '1', true);

    UPDATE data.employees
    SET lifecycle_state = NEW.to_state,
        lifecycle_since = NEW.effective_on,
        lifecycle_updated_at = now()
    WHERE id = NEW.employee_id;

    PERFORM data.log_audit_event(
      NEW.tenant_id,
      NEW.triggered_by,
      NULL,
      'EMPLOYEE_LIFECYCLE_CHANGED',
      'employee',
      NEW.employee_id,
      jsonb_build_object(
        'from', NEW.from_state,
        'to', NEW.to_state,
        'reason_code', NEW.reason_code,
        'event_id', NEW.id
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_employee_lifecycle_state ON data.employee_lifecycle_events;
CREATE TRIGGER trg_sync_employee_lifecycle_state
  AFTER INSERT ON data.employee_lifecycle_events
  FOR EACH ROW
  EXECUTE FUNCTION data.sync_employee_lifecycle_state();

-- Reconciliar backfill: events inserits abans del trigger existeixin sense sync
SELECT set_config('data.lifecycle_state_write', '1', true);

UPDATE data.employees e
SET
  lifecycle_since = COALESCE(e.lifecycle_since, COALESCE(e.starts_on, CURRENT_DATE)),
  lifecycle_updated_at = COALESCE(e.lifecycle_updated_at, now())
WHERE e.lifecycle_since IS NULL;

NOTIFY pgrst, 'reload schema';
