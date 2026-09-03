-- =============================================================================
-- Employee audit: 1 event per operació amb payload.changes[] (D9)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.build_audit_changes(
  p_old jsonb,
  p_new jsonb,
  p_fields text[]
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_field text;
  v_changes jsonb := '[]'::jsonb;
BEGIN
  FOREACH v_field IN ARRAY p_fields LOOP
    IF (p_old ->> v_field) IS DISTINCT FROM (p_new ->> v_field) THEN
      v_changes := v_changes || jsonb_build_array(jsonb_build_object(
        'field', v_field,
        'old', p_old -> v_field,
        'new', p_new -> v_field
      ));
    END IF;
  END LOOP;
  RETURN v_changes;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_audit_employees()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_changes jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.user_id),
      NEW.site_id,
      'EMPLOYEE_CREATED',
      'employee',
      NEW.id,
      jsonb_build_object(
        'id',            NEW.id,
        'full_name',     NEW.full_name,
        'status',        NEW.status,
        'job_title',     NEW.job_title,
        'department_id', NEW.department_id,
        'starts_on',     NEW.starts_on
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'terminated' THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        auth.uid(),
        NEW.site_id,
        'EMPLOYEE_TERMINATED',
        'employee',
        NEW.id,
        jsonb_build_object(
          'id',         NEW.id,
          'full_name',  NEW.full_name,
          'status',     NEW.status,
          'old_status', OLD.status,
          'ends_on',    NEW.ends_on
        )
      );
    ELSE
      v_changes := data.build_audit_changes(
        jsonb_build_object(
          'full_name',     OLD.full_name,
          'status',        OLD.status,
          'job_title',     OLD.job_title,
          'department_id', OLD.department_id,
          'site_id',       OLD.site_id,
          'weekly_hours',  OLD.weekly_hours,
          'email',         OLD.email,
          'phone',         OLD.phone,
          'document_id',   OLD.document_id,
          'starts_on',     OLD.starts_on,
          'ends_on',       OLD.ends_on
        ),
        jsonb_build_object(
          'full_name',     NEW.full_name,
          'status',        NEW.status,
          'job_title',     NEW.job_title,
          'department_id', NEW.department_id,
          'site_id',       NEW.site_id,
          'weekly_hours',  NEW.weekly_hours,
          'email',         NEW.email,
          'phone',         NEW.phone,
          'document_id',   NEW.document_id,
          'starts_on',     NEW.starts_on,
          'ends_on',       NEW.ends_on
        ),
        ARRAY[
          'full_name', 'status', 'job_title', 'department_id', 'site_id',
          'weekly_hours', 'email', 'phone', 'document_id', 'starts_on', 'ends_on'
        ]
      );

      IF jsonb_array_length(v_changes) > 0 THEN
        PERFORM data.log_audit_event(
          NEW.tenant_id,
          auth.uid(),
          NEW.site_id,
          'EMPLOYEE_UPDATED',
          'employee',
          NEW.id,
          jsonb_build_object(
            'id',        NEW.id,
            'full_name', NEW.full_name,
            'changes',   v_changes
          )
        );
      END IF;
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      auth.uid(),
      OLD.site_id,
      'EMPLOYEE_DELETED',
      'employee',
      OLD.id,
      jsonb_build_object(
        'id',        OLD.id,
        'full_name', OLD.full_name,
        'status',    OLD.status,
        'ends_on',   OLD.ends_on
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;
