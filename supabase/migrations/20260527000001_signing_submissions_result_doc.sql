-- =============================================================================
-- Migration: 20260527000001_signing_submissions_result_doc.sql
-- Purpose  : Extends api.signing_submissions view to expose the signed document's
--            file path and storage type so the frontend can generate signed URLs
--            directly without an extra query.
--
--            New columns added via LEFT JOIN with data.document_versions:
--              · result_file_path_or_url  — storage path or external URL of the signed PDF
--              · result_storage_type      — 'native' | 'external_link'
--
-- Pattern  : security_invoker = true (RLS enforced on data.document_versions)
--            GRANTs re-issued after view recreation.
-- =============================================================================

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
    -- Signed document file info (available once submission.completed webhook fires)
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
    ss.audit_trail_storage_path,
    ss.initiated_by,
    ss.metadata,
    ss.created_at,
    ss.updated_at
  FROM data.signing_submissions ss
  LEFT JOIN data.document_versions rv ON rv.id = ss.result_document_version_id;

-- Re-issue GRANTs (view recreation drops them)
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO service_role;
