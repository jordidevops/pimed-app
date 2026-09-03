-- ---------------------------------------------------------------------------
-- 1. Afegir intermediate_path i intermediate_size_bytes a la vista api.document_pdf_jobs
--    (eren absents; el worker fallava amb "intermediate_path is NULL")
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.document_pdf_jobs CASCADE;

CREATE VIEW api.document_pdf_jobs
WITH (security_invoker = true)
AS
SELECT
  id, tenant_id, status, source_type, source_ref_id, template_type, document_title,
  intermediate_path, intermediate_size_bytes,
  result_document_id, result_version_id, output_profile,
  priority, attempt_count, max_retries, next_retry_at, is_dead_letter,
  last_error_code, last_error_message, duration_ms,
  size_input_bytes, size_output_bytes,
  locked_at, locked_by,
  created_by, folder_id, metadata, idempotency_key,
  created_at, updated_at, completed_at
FROM data.document_pdf_jobs;

GRANT SELECT, INSERT, UPDATE ON api.document_pdf_jobs TO service_role;
GRANT SELECT                 ON api.document_pdf_jobs TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Grants api.* per a Edge Functions (PostgREST només exposa schema api)
-- ---------------------------------------------------------------------------

GRANT SELECT ON api.document_versions TO service_role;
GRANT SELECT ON api.documents         TO service_role;
GRANT SELECT, INSERT, UPDATE ON api.document_signing_sessions  TO service_role;
GRANT SELECT, INSERT, UPDATE ON api.document_signatures_audit  TO service_role;
