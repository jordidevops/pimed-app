-- QT-10: commercial signed documents in the existing Signing Centre.
-- Additive only: index + view joining native intents to commercial docs and
-- signing_submissions. Does not alter sign-document-router / stamp / field-map.

CREATE INDEX IF NOT EXISTS idx_commercial_signing_intents_submission
  ON data.commercial_signing_intents (submission_id)
  WHERE submission_id IS NOT NULL;

CREATE OR REPLACE VIEW api.commercial_signing_hub
WITH (security_invoker = true) AS
SELECT
  i.tenant_id,
  i.id AS intent_id,
  i.submission_id,
  i.session_id,
  i.document_id AS commercial_document_id,
  i.action,
  i.applied_at,
  i.created_at,
  cd.doc_type,
  cd.doc_number,
  cd.project_id,
  cd.status AS commercial_status,
  ss.status AS signing_status,
  ss.signing_provider
FROM data.commercial_signing_intents i
JOIN data.commercial_documents cd
  ON cd.id = i.document_id
LEFT JOIN data.signing_submissions ss
  ON ss.id = i.submission_id
WHERE i.submission_id IS NOT NULL
  AND data.jwt_user_tenants() ? i.tenant_id::text;

COMMENT ON VIEW api.commercial_signing_hub IS
  'QT-10: maps native signing_submissions to commercial_documents for the Signing Centre.';

GRANT SELECT ON api.commercial_signing_hub TO authenticated;
GRANT SELECT ON api.commercial_signing_hub TO service_role;
