-- Employee Portal — timeline d'empleat (create/revoke/first access) + primer accés per token

-- -----------------------------------------------------------------------------
-- 1. first_accessed_at per token
-- -----------------------------------------------------------------------------
ALTER TABLE data.employee_portal_tokens
  ADD COLUMN IF NOT EXISTS first_accessed_at timestamptz;

COMMENT ON COLUMN data.employee_portal_tokens.first_accessed_at IS
  'Primera sessió exitosa amb aquest enllaç (session_create).';

-- Backfill des d''access_logs existents
UPDATE data.employee_portal_tokens t
SET
  first_accessed_at = COALESCE(t.first_accessed_at, sub.first_at),
  last_accessed_at = COALESCE(t.last_accessed_at, sub.last_at)
FROM (
  SELECT
    l.token_id,
    MIN(l.accessed_at) AS first_at,
    MAX(l.accessed_at) AS last_at
  FROM data.employee_portal_access_logs l
  WHERE l.http_status IS NULL OR l.http_status < 400
  GROUP BY l.token_id
) sub
WHERE t.id = sub.token_id;

DROP VIEW IF EXISTS api.employee_portal_tokens;

CREATE VIEW api.employee_portal_tokens
  WITH (security_invoker = true)
AS
  SELECT
    id,
    tenant_id,
    employee_id,
    (pin_hash IS NOT NULL) AS pin_required,
    pin_attempts,
    pin_locked_until,
    session_version,
    compromised,
    expires_at,
    is_active,
    label,
    shared_device,
    first_accessed_at,
    last_accessed_at,
    created_by_user_id,
    created_at,
    revoked_at,
    revoke_reason
  FROM data.employee_portal_tokens;

GRANT SELECT ON api.employee_portal_tokens TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Audit a la timeline de l''empleat (entity_type = employee)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_employee_portal_tokens()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_site_id uuid;
BEGIN
  SELECT e.site_id INTO v_site_id
  FROM data.employees e
  WHERE e.id = COALESCE(NEW.employee_id, OLD.employee_id);

  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by_user_id),
      v_site_id,
      'EMPLOYEE_PORTAL_TOKEN_CREATED',
      'employee',
      NEW.employee_id,
      jsonb_build_object(
        'token_id', NEW.id,
        'employee_id', NEW.employee_id,
        'label', NEW.label,
        'shared_device', NEW.shared_device,
        'expires_at', NEW.expires_at,
        'pin_required', (NEW.pin_hash IS NOT NULL)
      )
    );
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.revoked_at IS NULL
     AND NEW.revoked_at IS NOT NULL THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      v_site_id,
      'EMPLOYEE_PORTAL_TOKEN_REVOKED',
      'employee',
      NEW.employee_id,
      jsonb_build_object(
        'token_id', NEW.id,
        'employee_id', NEW.employee_id,
        'label', NEW.label,
        'revoke_reason', NEW.revoke_reason,
        'compromised', NEW.compromised,
        'session_version', NEW.session_version
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Events antics (abans d''aquest canvi) → timeline de l''empleat
UPDATE data.audit_logs al
SET
  entity_type = 'employee',
  entity_id = (al.payload ->> 'employee_id')::uuid
WHERE al.action IN ('EMPLOYEE_PORTAL_TOKEN_CREATED', 'EMPLOYEE_PORTAL_TOKEN_REVOKED')
  AND al.entity_type = 'employee_portal_token'
  AND al.payload ? 'employee_id'
  AND (al.payload ->> 'employee_id') ~ '^[0-9a-f-]{36}$';

-- -----------------------------------------------------------------------------
-- 3. log_employee_portal_access_event — primer/últim accés + audit primer ús
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.log_employee_portal_access_event(
  p_token_id       uuid,
  p_employee_id    uuid,
  p_tenant_id      uuid,
  p_action         text,
  p_http_status    smallint DEFAULT NULL,
  p_failure_reason text DEFAULT NULL,
  p_ip_address     inet DEFAULT NULL,
  p_user_agent     text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_site_id uuid;
  v_success boolean;
  v_is_first_employee_access boolean;
  v_token_label text;
BEGIN
  v_success := (p_http_status IS NULL OR p_http_status < 400);

  v_is_first_employee_access := (
    v_success
    AND p_action = 'session_create'
    AND NOT EXISTS (
      SELECT 1
      FROM data.employee_portal_access_logs l
      WHERE l.employee_id = p_employee_id
        AND l.action = 'session_create'
        AND (l.http_status IS NULL OR l.http_status < 400)
    )
  );

  INSERT INTO data.employee_portal_access_logs (
    token_id,
    employee_id,
    tenant_id,
    action,
    http_status,
    failure_reason,
    ip_address,
    user_agent
  ) VALUES (
    p_token_id,
    p_employee_id,
    p_tenant_id,
    p_action,
    p_http_status,
    NULLIF(btrim(p_failure_reason), ''),
    p_ip_address,
    NULLIF(btrim(p_user_agent), '')
  );

  IF v_success THEN
    UPDATE data.employee_portal_tokens
    SET
      last_accessed_at = now(),
      first_accessed_at = COALESCE(first_accessed_at, now())
    WHERE id = p_token_id;

    IF v_is_first_employee_access THEN
      SELECT e.site_id INTO v_site_id
      FROM data.employees e
      WHERE e.id = p_employee_id;

      SELECT t.label INTO v_token_label
      FROM data.employee_portal_tokens t
      WHERE t.id = p_token_id;

      PERFORM data.log_audit_event(
        p_tenant_id,
        NULL,
        v_site_id,
        'EMPLOYEE_PORTAL_FIRST_ACCESS',
        'employee',
        p_employee_id,
        jsonb_build_object(
          'token_id', p_token_id,
          'label', v_token_label
        )
      );
    END IF;
  END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. Timeline message vars (UI + notificacions)
-- -----------------------------------------------------------------------------
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
    ELSE 'timeline.audit.GENERIC'
  END;
$$;

NOTIFY pgrst, 'reload schema';
