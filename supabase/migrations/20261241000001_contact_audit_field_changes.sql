-- CONTACT_UPDATED: payload.changes[] amb camps concrets (com EMPLOYEE_UPDATED).
-- timeline_audit_message_vars: deriva changes des d'old/new per esdeveniments antics.

CREATE OR REPLACE FUNCTION data.trg_audit_contacts()
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
      COALESCE(auth.uid(), NEW.created_by),
      NEW.site_id,
      'CONTACT_CREATED',
      'contact',
      NEW.id,
      jsonb_build_object(
        'display_name', NEW.display_name,
        'kind',         NEW.kind,
        'email',        NEW.email
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.is_archived IS DISTINCT FROM NEW.is_archived THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        CASE WHEN NEW.is_archived THEN 'CONTACT_ARCHIVED' ELSE 'CONTACT_UNARCHIVED' END,
        'contact', NEW.id,
        jsonb_build_object(
          'display_name', NEW.display_name,
          'kind',         NEW.kind,
          'email',        NEW.email
        )
      );
    ELSE
      v_changes := data.build_audit_changes(
        jsonb_build_object(
          'display_name',      OLD.display_name,
          'kind',              OLD.kind,
          'given_name',        OLD.given_name,
          'family_name',       OLD.family_name,
          'legal_name',        OLD.legal_name,
          'tax_id',            OLD.tax_id,
          'email',             OLD.email,
          'phone',             OLD.phone,
          'phone_alt',         OLD.phone_alt,
          'preferred_channel', OLD.preferred_channel,
          'source',            OLD.source
        ),
        jsonb_build_object(
          'display_name',      NEW.display_name,
          'kind',              NEW.kind,
          'given_name',        NEW.given_name,
          'family_name',       NEW.family_name,
          'legal_name',        NEW.legal_name,
          'tax_id',            NEW.tax_id,
          'email',             NEW.email,
          'phone',             NEW.phone,
          'phone_alt',         NEW.phone_alt,
          'preferred_channel', NEW.preferred_channel,
          'source',            NEW.source
        ),
        ARRAY[
          'display_name', 'kind', 'given_name', 'family_name', 'legal_name',
          'tax_id', 'email', 'phone', 'phone_alt', 'preferred_channel', 'source'
        ]
      );

      IF jsonb_array_length(v_changes) > 0 THEN
        PERFORM data.log_audit_event(
          NEW.tenant_id,
          auth.uid(),
          NEW.site_id,
          'CONTACT_UPDATED',
          'contact',
          NEW.id,
          jsonb_build_object(
            'display_name', NEW.display_name,
            'changes',      v_changes
          )
        );
      END IF;
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      CASE
        WHEN EXISTS (SELECT 1 FROM data.tenants t WHERE t.id = OLD.tenant_id) THEN OLD.tenant_id
        ELSE NULL
      END,
      auth.uid(),
      OLD.site_id,
      'CONTACT_DELETED',
      'contact',
      OLD.id,
      jsonb_build_object(
        'display_name', OLD.display_name,
        'kind',         OLD.kind,
        'email',        OLD.email
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION data.timeline_audit_message_vars(
  p_action  text,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_changes jsonb;
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
      IF p_payload ? 'changes'
         AND jsonb_typeof(p_payload -> 'changes') = 'array'
         AND jsonb_array_length(p_payload -> 'changes') > 0 THEN
        RETURN jsonb_build_object(
          'changes', p_payload -> 'changes',
          'change_count', jsonb_array_length(p_payload -> 'changes'),
          'name', coalesce(p_payload ->> 'display_name', p_payload #>> '{new,display_name}')
        );
      END IF;
      -- Esdeveniments antics: només old/new (sense changes[])
      IF p_payload ? 'old' AND p_payload ? 'new' THEN
        v_changes := data.build_audit_changes(
          p_payload -> 'old',
          p_payload -> 'new',
          ARRAY['display_name', 'kind', 'email', 'phone', 'phone_alt', 'legal_name', 'tax_id']
        );
        RETURN jsonb_build_object(
          'changes', v_changes,
          'change_count', jsonb_array_length(v_changes),
          'name', coalesce(p_payload #>> '{new,display_name}', p_payload ->> 'display_name')
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
         'PROJECT_COMMERCIAL_SUPERSEDED',
         'PROJECT_COMMERCIAL_INVOICE_CANCELLED',
         'PROJECT_COMMERCIAL_PAYMENT_RECORDED' THEN
      RETURN coalesce(p_payload, '{}'::jsonb);
    ELSE
      IF coalesce(p_action, '') LIKE 'ATTENDANCE\_%' ESCAPE '\' THEN
        RETURN coalesce(p_payload, '{}'::jsonb);
      END IF;
      RETURN jsonb_build_object('action', p_action);
  END CASE;
END;
$$;
