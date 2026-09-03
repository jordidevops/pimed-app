-- Permet actualitzar staging_storage_path des de la vista api.signing_submissions

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
    staging_storage_path       = NEW.staging_storage_path,
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
    metadata                   = NEW.metadata,
    signing_provider           = NEW.signing_provider,
    native_group_id            = NEW.native_group_id
  WHERE id = NEW.id;

  RETURN NEW;
END;
$$;
