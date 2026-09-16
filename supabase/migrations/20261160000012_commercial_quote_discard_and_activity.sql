-- Commercial follow-up: discard issued quotes, project Activity projection
-- from commercial_document_events (canonical). Do not duplicate a second ledger.

CREATE OR REPLACE FUNCTION data.trg_commercial_document_event_project_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
BEGIN
  IF NEW.event_type NOT IN (
    'issued', 'sent', 'accepted', 'rejected', 'cancelled', 'superseded'
  ) THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = NEW.document_id;
  IF NOT FOUND OR v_doc.project_id IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM data.log_audit_event(
    NEW.tenant_id,
    NEW.actor_id,
    NULL,
    'PROJECT_COMMERCIAL_' || upper(NEW.event_type),
    'project',
    v_doc.project_id,
    jsonb_build_object(
      'doc_number', v_doc.doc_number,
      'doc_type', v_doc.doc_type,
      'event', NEW.event_type,
      'commercial_document_id', v_doc.id
    )
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_document_event_project_audit
  ON data.commercial_document_events;
CREATE TRIGGER trg_commercial_document_event_project_audit
  AFTER INSERT ON data.commercial_document_events
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_commercial_document_event_project_audit();

CREATE OR REPLACE FUNCTION api.cancel_commercial_document(
  p_document_id uuid,
  p_client_op_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN p_document_id;
  END IF;

  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'document_not_cancellable_type:%', v_doc.doc_type
      USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status <> 'issued' THEN
    RAISE EXCEPTION 'document_not_cancellable_state:%', v_doc.status
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET status = 'cancelled', updated_at = now()
  WHERE id = p_document_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id,
    p_document_id,
    'cancelled',
    v_uid,
    v_doc.content_hash,
    p_client_op_id,
    jsonb_build_object(
      'cancelled_content_hash', v_doc.content_hash,
      'reason', NULLIF(btrim(COALESCE(p_reason, '')), '')
    )
  );

  RETURN p_document_id;
END;
$$;

REVOKE ALL ON FUNCTION api.cancel_commercial_document(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.cancel_commercial_document(uuid, uuid, text)
  TO authenticated, service_role;

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
    WHEN 'PROJECT_COMMERCIAL_ISSUED',
         'PROJECT_COMMERCIAL_SENT',
         'PROJECT_COMMERCIAL_ACCEPTED',
         'PROJECT_COMMERCIAL_REJECTED',
         'PROJECT_COMMERCIAL_CANCELLED',
         'PROJECT_COMMERCIAL_SUPERSEDED' THEN
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
    WHEN 'PROJECT_COMMERCIAL_ISSUED' THEN 'timeline.audit.PROJECT_COMMERCIAL_ISSUED'
    WHEN 'PROJECT_COMMERCIAL_SENT' THEN 'timeline.audit.PROJECT_COMMERCIAL_SENT'
    WHEN 'PROJECT_COMMERCIAL_ACCEPTED' THEN 'timeline.audit.PROJECT_COMMERCIAL_ACCEPTED'
    WHEN 'PROJECT_COMMERCIAL_REJECTED' THEN 'timeline.audit.PROJECT_COMMERCIAL_REJECTED'
    WHEN 'PROJECT_COMMERCIAL_CANCELLED' THEN 'timeline.audit.PROJECT_COMMERCIAL_CANCELLED'
    WHEN 'PROJECT_COMMERCIAL_SUPERSEDED' THEN 'timeline.audit.PROJECT_COMMERCIAL_SUPERSEDED'
    ELSE 'timeline.audit.GENERIC'
  END;
$$;

NOTIFY pgrst, 'reload schema';
