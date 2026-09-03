-- =============================================================================
-- Migration: 20260527000002_signing_submissions_audit_log_url.sql
-- Purpose  : Adds audit_log_url column to data.signing_submissions.
--
--            DocuSeal sends audit_log_url at the top level of submission.completed
--            event data. We now capture it immediately when the webhook fires
--            (before attempting the Storage download), so:
--              · even if the download fails, the user can open the audit PDF via
--                the external DocuSeal URL
--              · the frontend shows fallback link using audit_log_url when
--                audit_trail_storage_path is not yet available
--
--            New column:
--              · audit_log_url text — raw DocuSeal URL for the audit certificate PDF
--
-- Pattern  : security_invoker = true, GRANTs re-issued after view recreation.
-- =============================================================================

ALTER TABLE data.signing_submissions
  ADD COLUMN IF NOT EXISTS audit_log_url text;

-- ---------------------------------------------------------------------------
-- Rebuild api.signing_submissions to expose the new column
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.signing_submissions;

CREATE VIEW api.signing_submissions WITH (security_invoker = true) AS
  SELECT
    ss.id,
    ss.tenant_id,
    ss.source_type,
    ss.source_document_id,
    ss.source_document_version_id,
    ss.source_template_locale_id,
    ss.result_document_version_id,
    rv.file_path_or_url     AS result_file_path_or_url,
    rv.storage_type         AS result_storage_type,
    ss.docuseal_submission_id,
    ss.external_id,
    ss.status,
    ss.status_reason,
    ss.error_message,
    ss.last_event_at,
    ss.signers,
    ss.docuseal_signing_url,
    ss.submitted_at,
    ss.completed_at,
    ss.document_title,
    -- Audit: storage path (if already downloaded) + raw DocuSeal URL (always captured)
    ss.audit_trail_storage_path,
    ss.audit_log_url,
    ss.initiated_by,
    ss.metadata,
    ss.created_at,
    ss.updated_at
  FROM data.signing_submissions ss
  LEFT JOIN data.document_versions rv ON rv.id = ss.result_document_version_id;

-- Re-issue GRANTs
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO service_role;
