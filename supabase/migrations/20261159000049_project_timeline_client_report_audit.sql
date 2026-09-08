-- Project Activitat: mirror significant bulletin/CIR audits onto entity_type=project
-- so EntityTimeline on the OS shows publish / share / revoke / email / staff portal open.
-- CIR domain audits (non-project entity_type) are unchanged; dual-write via trigger.

-- ---------------------------------------------------------------------------
-- 1. Helper (same pattern as data.log_attendance_employee_audit)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.log_project_audit(
  p_tenant_id   uuid,
  p_user_id     uuid,
  p_site_id     uuid,
  p_project_id  uuid,
  p_action      text,
  p_payload     jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_project_id IS NULL OR p_tenant_id IS NULL OR COALESCE(p_action, '') = '' THEN
    RETURN;
  END IF;

  PERFORM data.log_audit_event(
    p_tenant_id,
    p_user_id,
    p_site_id,
    p_action,
    'project',
    p_project_id,
    COALESCE(p_payload, '{}'::jsonb) || jsonb_build_object('project_id', p_project_id),
    false
  );
END;
$$;

REVOKE ALL ON FUNCTION data.log_project_audit(uuid, uuid, uuid, uuid, text, jsonb) FROM PUBLIC;

COMMENT ON FUNCTION data.log_project_audit(uuid, uuid, uuid, uuid, text, jsonb) IS
  'Soft-writes an audit row pinned to entity_type=project for the OS Activitat timeline.';

-- ---------------------------------------------------------------------------
-- 2. Mirror CLIENT_REPORT_* audits onto the project timeline
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_mirror_client_report_audit_to_project()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_project_id uuid;
  v_payload jsonb;
  v_version_no int;
BEGIN
  IF NEW.entity_type IS NOT DISTINCT FROM 'project' THEN
    RETURN NEW;
  END IF;

  IF NEW.action NOT IN (
    'CLIENT_REPORT_PUBLISHED',
    'CLIENT_REPORT_VERSION_CREATED',
    'CLIENT_REPORT_SHARE_CREATED',
    'CLIENT_REPORT_SHARE_REVOKED',
    'CLIENT_REPORT_SHARE_EMAIL_ENQUEUED',
    'CLIENT_REPORT_STAFF_SESSION_CREATED'
  ) THEN
    RETURN NEW;
  END IF;

  v_payload := COALESCE(NEW.payload, '{}'::jsonb);
  BEGIN
    v_project_id := NULLIF(v_payload ->> 'project_id', '')::uuid;
  EXCEPTION
    WHEN OTHERS THEN
      v_project_id := NULL;
  END;

  IF v_project_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Enrich version_number when only report_version_id is present
  IF v_payload ->> 'version_number' IS NULL
     AND NULLIF(v_payload ->> 'report_version_id', '') IS NOT NULL THEN
    SELECT v.version_number
      INTO v_version_no
    FROM data.customer_intervention_report_versions v
    WHERE v.id = (v_payload ->> 'report_version_id')::uuid
    LIMIT 1;
    IF v_version_no IS NOT NULL THEN
      v_payload := v_payload || jsonb_build_object('version_number', v_version_no);
    END IF;
  END IF;

  IF NEW.action = 'CLIENT_REPORT_SHARE_EMAIL_ENQUEUED'
     AND v_payload ->> 'channel' IS NULL THEN
    v_payload := v_payload || jsonb_build_object('channel', 'email');
  END IF;

  PERFORM data.log_project_audit(
    NEW.tenant_id,
    NEW.user_id,
    NEW.site_id,
    v_project_id,
    NEW.action,
    v_payload
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_mirror_client_report_audit_to_project ON data.audit_logs;
CREATE TRIGGER trg_mirror_client_report_audit_to_project
  AFTER INSERT ON data.audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_mirror_client_report_audit_to_project();

-- ---------------------------------------------------------------------------
-- 3. Timeline message vars / keys for Activitat copy
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.timeline_audit_message_vars(
  p_action  text,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  CASE p_action
    WHEN 'EMPLOYEE_CREATED' THEN
      RETURN jsonb_build_object('name', coalesce(p_payload ->> 'full_name', p_payload ->> 'name'));
    WHEN 'EMPLOYEE_UPDATED' THEN
      IF p_payload ? 'changes' THEN
        RETURN jsonb_build_object(
          'changes', p_payload -> 'changes',
          'change_count', jsonb_array_length(p_payload -> 'changes')
        );
      END IF;
      RETURN jsonb_build_object('changes', '[]'::jsonb, 'change_count', 0);
    WHEN 'EMPLOYEE_TERMINATED' THEN
      RETURN jsonb_build_object(
        'name', coalesce(p_payload ->> 'full_name', p_payload ->> 'name'),
        'ends_on', p_payload ->> 'ends_on'
      );
    WHEN 'EMPLOYEE_PORTAL_TOKEN_CREATED' THEN
      RETURN jsonb_build_object(
        'label', coalesce(p_payload ->> 'label', '—'),
        'pin_required', coalesce(p_payload -> 'pin_required', 'false'::jsonb),
        'shared_device', coalesce(p_payload -> 'shared_device', 'false'::jsonb)
      );
    WHEN 'EMPLOYEE_PORTAL_TOKEN_REVOKED' THEN
      RETURN jsonb_build_object(
        'label', coalesce(p_payload ->> 'label', '—'),
        'revoke_reason', p_payload ->> 'revoke_reason',
        'compromised', coalesce(p_payload -> 'compromised', 'false'::jsonb)
      );
    WHEN 'EMPLOYEE_PORTAL_FIRST_ACCESS' THEN
      RETURN jsonb_build_object(
        'label', coalesce(p_payload ->> 'label', '—')
      );
    WHEN 'CONTACT_CREATED', 'CONTACT_ARCHIVED', 'CONTACT_UNARCHIVED' THEN
      RETURN jsonb_build_object('name', coalesce(p_payload ->> 'display_name', p_payload ->> 'name'));
    WHEN 'CONTACT_UPDATED' THEN
      IF p_payload ? 'changes' THEN
        RETURN jsonb_build_object(
          'changes', p_payload -> 'changes',
          'change_count', jsonb_array_length(p_payload -> 'changes')
        );
      END IF;
      RETURN jsonb_build_object('changes', '[]'::jsonb, 'change_count', 0);
    WHEN 'COMMENT_TASK_RESOLVED' THEN
      RETURN jsonb_build_object(
        'task_preview', p_payload ->> 'task_preview',
        'resolver_id', p_payload ->> 'resolved_by'
      );
    WHEN 'PROJECT_STATUS_CHANGED' THEN
      RETURN jsonb_build_object(
        'old', coalesce(p_payload ->> 'old_status', p_payload #>> '{old,status}'),
        'new', coalesce(p_payload ->> 'new_status', p_payload #>> '{new,status}')
      );
    WHEN 'CLIENT_REPORT_PUBLISHED',
         'CLIENT_REPORT_VERSION_CREATED',
         'CLIENT_REPORT_SHARE_CREATED',
         'CLIENT_REPORT_SHARE_REVOKED',
         'CLIENT_REPORT_SHARE_EMAIL_ENQUEUED',
         'CLIENT_REPORT_STAFF_SESSION_CREATED' THEN
      RETURN coalesce(p_payload, '{}'::jsonb);
    ELSE
      IF coalesce(p_action, '') LIKE 'ATTENDANCE\_%' ESCAPE '\' THEN
        RETURN coalesce(p_payload, '{}'::jsonb);
      END IF;
      RETURN jsonb_build_object('action', p_action);
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION data.timeline_audit_message_key(p_action text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_action
    WHEN 'EMPLOYEE_CREATED' THEN 'timeline.audit.EMPLOYEE_CREATED'
    WHEN 'EMPLOYEE_UPDATED' THEN 'timeline.audit.EMPLOYEE_UPDATED'
    WHEN 'EMPLOYEE_TERMINATED' THEN 'timeline.audit.EMPLOYEE_TERMINATED'
    WHEN 'EMPLOYEE_DELETED' THEN 'timeline.audit.EMPLOYEE_DELETED'
    WHEN 'EMPLOYEE_PORTAL_TOKEN_CREATED' THEN 'timeline.audit.EMPLOYEE_PORTAL_TOKEN_CREATED'
    WHEN 'EMPLOYEE_PORTAL_TOKEN_REVOKED' THEN 'timeline.audit.EMPLOYEE_PORTAL_TOKEN_REVOKED'
    WHEN 'EMPLOYEE_PORTAL_FIRST_ACCESS' THEN 'timeline.audit.EMPLOYEE_PORTAL_FIRST_ACCESS'
    WHEN 'CONTACT_CREATED' THEN 'timeline.audit.CONTACT_CREATED'
    WHEN 'CONTACT_UPDATED' THEN 'timeline.audit.CONTACT_UPDATED'
    WHEN 'CONTACT_ARCHIVED' THEN 'timeline.audit.CONTACT_ARCHIVED'
    WHEN 'CONTACT_UNARCHIVED' THEN 'timeline.audit.CONTACT_UNARCHIVED'
    WHEN 'COMMENT_TASK_RESOLVED' THEN 'timeline.audit.TASK_RESOLVED'
    WHEN 'PROJECT_STATUS_CHANGED' THEN 'timeline.audit.PROJECT_STATUS'
    WHEN 'CLIENT_REPORT_PUBLISHED' THEN 'timeline.audit.CLIENT_REPORT_PUBLISHED'
    WHEN 'CLIENT_REPORT_VERSION_CREATED' THEN 'timeline.audit.CLIENT_REPORT_VERSION_CREATED'
    WHEN 'CLIENT_REPORT_SHARE_CREATED' THEN 'timeline.audit.CLIENT_REPORT_SHARE_CREATED'
    WHEN 'CLIENT_REPORT_SHARE_REVOKED' THEN 'timeline.audit.CLIENT_REPORT_SHARE_REVOKED'
    WHEN 'CLIENT_REPORT_SHARE_EMAIL_ENQUEUED' THEN 'timeline.audit.CLIENT_REPORT_SHARE_EMAIL_ENQUEUED'
    WHEN 'CLIENT_REPORT_STAFF_SESSION_CREATED' THEN 'timeline.audit.CLIENT_REPORT_STAFF_SESSION_CREATED'
    ELSE 'timeline.audit.GENERIC'
  END;
$$;

NOTIFY pgrst, 'reload schema';
