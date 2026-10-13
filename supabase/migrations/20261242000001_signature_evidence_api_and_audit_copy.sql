-- Exposa document_signature_evidences via api.* (el PDF d'auditoria les llegia
-- amb el client PostgREST schema=api i sortia el registre d'events buit).
-- Enrich DOCUMENT_SIGNATURE_* audit payload amb signants.
-- Propaga title/signer a timeline_audit_message_vars.

CREATE OR REPLACE VIEW api.document_signature_evidences
WITH (security_invoker = true)
AS
SELECT
  id,
  session_id,
  event_type,
  created_at
  -- ip_address, user_agent, geolocation, metadata exclosos a l'API
FROM data.document_signature_evidences;

GRANT SELECT ON api.document_signature_evidences TO authenticated;
GRANT SELECT ON api.document_signature_evidences TO service_role;

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
    WHEN 'DOCUMENT_CREATED', 'DOCUMENT_UPDATED', 'DOCUMENT_DELETED' THEN
      RETURN jsonb_build_object(
        'title', coalesce(p_payload ->> 'title', p_payload ->> 'document_title')
      );
    WHEN 'DOCUMENT_SIGNATURE_ACCEPTED', 'DOCUMENT_SIGNATURE_REJECTED' THEN
      RETURN jsonb_build_object(
        'document_title', p_payload ->> 'document_title',
        'signer_name', coalesce(
          p_payload ->> 'signer_name',
          p_payload #>> '{signers,0,name}'
        ),
        'signer_role', coalesce(
          p_payload ->> 'signer_role',
          p_payload #>> '{signers,0,role}'
        ),
        'signers', coalesce(p_payload -> 'signers', '[]'::jsonb)
      );
    ELSE
      IF coalesce(p_action, '') LIKE 'ATTENDANCE\_%' ESCAPE '\' THEN
        RETURN coalesce(p_payload, '{}'::jsonb);
      END IF;
      RETURN jsonb_build_object('action', p_action);
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_signing_submission_automation_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_action text;
  v_auto   jsonb;
  v_signers jsonb;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' THEN
    v_action := 'DOCUMENT_SIGNATURE_ACCEPTED';
  ELSIF NEW.status = 'declined' THEN
    v_action := 'DOCUMENT_SIGNATURE_REJECTED';
  ELSE
    RETURN NEW;
  END IF;

  v_auto := COALESCE(NEW.metadata, '{}'::jsonb) -> 'automation';

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'name', s.signer_name,
        'role', s.signer_role,
        'email', s.signer_email,
        'signed_at', s.timestamps ->> 'signed_at'
      )
      ORDER BY s.signer_order
    ),
    '[]'::jsonb
  )
  INTO v_signers
  FROM data.document_signing_sessions s
  WHERE s.signing_group_id IS NOT NULL
    AND s.signing_group_id = NEW.native_group_id
    AND s.status = 'signed';

  PERFORM data.log_audit_event(
    NEW.tenant_id, NULL, NULL,
    v_action, 'document', NEW.source_document_id,
    jsonb_build_object(
      'submission_id',   NEW.id,
      'document_id',     NEW.source_document_id,
      'document_title',  NEW.document_title,
      'template_id',     NEW.source_template_locale_id,
      'workflow_run_id', v_auto->>'workflow_run_id',
      'step_run_id',     v_auto->>'step_run_id',
      'signer_name',     (v_signers -> 0) ->> 'name',
      'signer_role',     (v_signers -> 0) ->> 'role',
      'signers',         v_signers
    )
  );

  IF v_auto IS NOT NULL AND v_auto ? 'step_run_id' THEN
  BEGIN
    PERFORM api.automation_resume_step_service(
      (v_auto->>'step_run_id')::uuid,
      jsonb_build_object(
        'submission_id', NEW.id,
        'status',        NEW.status::text,
        'document_id',   NEW.source_document_id
      ),
      CASE WHEN v_action = 'DOCUMENT_SIGNATURE_REJECTED' THEN 'signature_rejected' ELSE NULL END
    );
  EXCEPTION WHEN others THEN
    RAISE WARNING '[automation] resume after signing: %', SQLERRM;
  END;
  END IF;

  RETURN NEW;
EXCEPTION WHEN others THEN
  RAISE WARNING '[automation] trg_signing_submission_automation_audit: %', SQLERRM;
  RETURN NEW;
END;
$$;

-- Backfill signer_name on existing DOCUMENT_SIGNATURE_* audit rows.
UPDATE data.audit_logs al
SET payload = al.payload || jsonb_build_object(
  'signer_name', s.signer_name,
  'signer_role', s.signer_role
)
FROM data.signing_submissions ss
JOIN LATERAL (
  SELECT signer_name, signer_role
  FROM data.document_signing_sessions sess
  WHERE sess.signing_group_id = ss.native_group_id
    AND sess.status = 'signed'
  ORDER BY sess.signer_order
  LIMIT 1
) s ON true
WHERE al.action IN ('DOCUMENT_SIGNATURE_ACCEPTED', 'DOCUMENT_SIGNATURE_REJECTED')
  AND al.entity_type = 'document'
  AND ss.id = (al.payload ->> 'submission_id')::uuid
  AND coalesce(al.payload ->> 'signer_name', '') = '';

-- Força regenerar certificats d'auditoria (events existents però PDF sense registre).
UPDATE data.signing_submissions ss
SET audit_trail_storage_path = NULL,
    updated_at = now()
WHERE ss.signing_provider = 'native'
  AND ss.status = 'completed'
  AND EXISTS (
    SELECT 1
    FROM data.document_signing_sessions s
    JOIN data.document_signature_evidences e ON e.session_id = s.id
    WHERE s.signing_group_id = ss.native_group_id
  );

UPDATE data.document_pdf_jobs j
SET
  status = 'queued',
  locked_at = NULL,
  locked_by = NULL,
  completed_at = NULL,
  updated_at = now(),
  metadata = (COALESCE(j.metadata, '{}'::jsonb) - 'audit_storage_path')
             || jsonb_build_object('type', 'audit_certificate')
WHERE j.idempotency_key LIKE 'audit-group-%'
  AND COALESCE(j.metadata->>'type', '') = 'audit_certificate'
  AND EXISTS (
    SELECT 1
    FROM data.signing_submissions ss
    WHERE ss.native_group_id::text = replace(j.idempotency_key, 'audit-group-', '')
      AND ss.signing_provider = 'native'
      AND ss.status = 'completed'
  );

NOTIFY pgrst, 'reload schema';
