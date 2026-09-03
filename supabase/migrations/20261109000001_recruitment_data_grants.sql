-- =============================================================================
-- REC-1 follow-up — GRANTs on data.* for authenticated (security_invoker views)
-- =============================================================================

GRANT SELECT, UPDATE ON data.recruitment_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.job_postings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.job_posting_public_sites TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.job_posting_templates TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.pipeline_stages TO authenticated;
GRANT SELECT, INSERT, UPDATE ON data.applicants TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.applications TO authenticated;
GRANT SELECT ON data.applicant_consent_events TO authenticated;
GRANT SELECT ON data.applicant_erasure_log TO authenticated;
