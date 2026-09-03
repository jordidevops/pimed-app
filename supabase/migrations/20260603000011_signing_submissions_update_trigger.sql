-- Migration : 20260603000011_signing_submissions_update_trigger
-- Purpose   : Add INSTEAD OF UPDATE trigger to api.signing_submissions.
--
-- Root cause: The view has a LEFT JOIN (data.document_versions) which makes it
--             non-auto-updatable by PostgreSQL.  Without this trigger, every
--             .update() call on the view silently returns "cannot update view"
--             (sign-document-router, docuseal-webhook, signing-session-manager
--             all affected).
--
-- Security  : The view uses security_invoker=true.  PostgreSQL evaluates the
--             WHERE predicate with the calling role's RLS before firing the
--             trigger, so tenant isolation is enforced at the SELECT phase.
--             The trigger itself runs SECURITY DEFINER to reach data.* schema.

-- ============================================================================
-- INSTEAD OF UPDATE trigger function
-- Maps writable view columns → data.signing_submissions columns.
-- The JOIN columns (result_file_path_or_url, result_storage_type) are
-- read-only projections from document_versions and are never written back.
-- ============================================================================

CREATE OR REPLACE FUNCTION data.trg_api_signing_submissions_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.signing_submissions
  SET
    status                     = NEW.status,
    status_reason              = NEW.status_reason,
    error_message              = NEW.error_message,
    last_event_at              = NEW.last_event_at,
    updated_at                 = NEW.updated_at,
    docuseal_submission_id     = NEW.docuseal_submission_id,
    docuseal_signing_url       = NEW.docuseal_signing_url,
    signers                    = NEW.signers,
    result_document_version_id = NEW.result_document_version_id,
    audit_trail_storage_path   = NEW.audit_trail_storage_path,
    audit_log_url              = NEW.audit_log_url,
    notification_mode          = NEW.notification_mode,
    notification_enabled       = NEW.notification_enabled,
    next_signer_index          = NEW.next_signer_index,
    first_email_sent_at        = NEW.first_email_sent_at,
    last_notification_at       = NEW.last_notification_at,
    submitted_at               = NEW.submitted_at,
    completed_at               = NEW.completed_at,
    reviewed_at                = NEW.reviewed_at,
    reviewed_by                = NEW.reviewed_by,
    document_title             = NEW.document_title,
    initiated_by               = NEW.initiated_by,
    metadata                   = NEW.metadata
  WHERE id = NEW.id;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_api_signing_submissions_update
  INSTEAD OF UPDATE ON api.signing_submissions
  FOR EACH ROW EXECUTE FUNCTION data.trg_api_signing_submissions_update();
