-- =============================================================================
-- Migration: 20260521000008_labor_calendar_multilevel_audit.sql
-- Purpose  : Add mandatory audit logs for labor calendar multilevel lifecycle
-- =============================================================================

-- =============================================================================
-- 1. Audit trigger: tenant_holiday_calendar_assignments
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_audit_tenant_holiday_calendar_assignments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      NULL,
      'TENANT_HOLIDAY_CALENDAR_ASSIGNED',
      'tenant_holiday_calendar_assignment',
      NEW.id,
      jsonb_build_object(
        'calendar_id', NEW.calendar_id,
        'priority', NEW.priority
      )
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      auth.uid(),
      NULL,
      'TENANT_HOLIDAY_CALENDAR_UNASSIGNED',
      'tenant_holiday_calendar_assignment',
      OLD.id,
      jsonb_build_object(
        'calendar_id', OLD.calendar_id,
        'priority', OLD.priority
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_tenant_holiday_calendar_assignments
  ON data.tenant_holiday_calendar_assignments;

CREATE TRIGGER trg_audit_tenant_holiday_calendar_assignments
  AFTER INSERT OR DELETE ON data.tenant_holiday_calendar_assignments
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_tenant_holiday_calendar_assignments();

-- =============================================================================
-- 2. Audit trigger: employee_day_overrides
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_audit_employee_day_overrides()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by),
      NULL,
      'EMPLOYEE_DAY_OVERRIDE_CREATED',
      'employee_day_override',
      NEW.id,
      jsonb_build_object(
        'employee_id', NEW.employee_id,
        'override_date', NEW.override_date,
        'override_type', NEW.override_type,
        'note', NEW.note
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by),
      NULL,
      'EMPLOYEE_DAY_OVERRIDE_UPDATED',
      'employee_day_override',
      NEW.id,
      jsonb_build_object(
        'old', jsonb_build_object(
          'override_date', OLD.override_date,
          'override_type', OLD.override_type,
          'note', OLD.note
        ),
        'new', jsonb_build_object(
          'override_date', NEW.override_date,
          'override_type', NEW.override_type,
          'note', NEW.note
        )
      )
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      COALESCE(auth.uid(), OLD.created_by),
      NULL,
      'EMPLOYEE_DAY_OVERRIDE_DELETED',
      'employee_day_override',
      OLD.id,
      jsonb_build_object(
        'employee_id', OLD.employee_id,
        'override_date', OLD.override_date,
        'override_type', OLD.override_type,
        'note', OLD.note
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_employee_day_overrides
  ON data.employee_day_overrides;

CREATE TRIGGER trg_audit_employee_day_overrides
  AFTER INSERT OR UPDATE OR DELETE ON data.employee_day_overrides
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_employee_day_overrides();
