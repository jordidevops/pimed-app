-- Signing centre: expose agreement_id on api.commercial_signing_hub.
-- Intent rows join the decision request (native path). DocuSeal stores
-- decision_request_id on submission metadata and does not create an intent,
-- so those agreement submissions are UNIONed when no intent exists yet.

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
  ss.signing_provider,
  ss.source_document_id,
  ss.result_document_version_id,
  rv.document_id AS result_document_id,
  r.agreement_version_id,
  av.agreement_id
FROM data.commercial_signing_intents i
JOIN data.commercial_documents cd
  ON cd.id = i.document_id
LEFT JOIN data.signing_submissions ss
  ON ss.id = i.submission_id
LEFT JOIN data.document_versions rv
  ON rv.id = ss.result_document_version_id
LEFT JOIN data.commercial_decision_requests r
  ON r.id = i.decision_request_id
LEFT JOIN data.commercial_agreement_versions av
  ON av.id = r.agreement_version_id
WHERE i.submission_id IS NOT NULL
  AND data.jwt_user_tenants() ? i.tenant_id::text

UNION ALL

SELECT
  ss.tenant_id,
  NULL::uuid AS intent_id,
  ss.id AS submission_id,
  NULL::uuid AS session_id,
  av.source_quote_id AS commercial_document_id,
  NULL::text AS action,
  NULL::timestamptz AS applied_at,
  ss.created_at,
  cd.doc_type,
  cd.doc_number,
  cd.project_id,
  cd.status AS commercial_status,
  ss.status AS signing_status,
  ss.signing_provider,
  ss.source_document_id,
  ss.result_document_version_id,
  rv.document_id AS result_document_id,
  r.agreement_version_id,
  av.agreement_id
FROM data.signing_submissions ss
JOIN data.commercial_decision_requests r
  ON r.agreement_version_id IS NOT NULL
 AND r.tenant_id = ss.tenant_id
 AND r.id::text = ss.metadata->>'decision_request_id'
JOIN data.commercial_agreement_versions av
  ON av.id = r.agreement_version_id
LEFT JOIN data.commercial_documents cd
  ON cd.id = av.source_quote_id
LEFT JOIN data.document_versions rv
  ON rv.id = ss.result_document_version_id
WHERE ss.signing_provider = 'docuseal'
  AND data.jwt_user_tenants() ? ss.tenant_id::text
  AND NOT EXISTS (
    SELECT 1
    FROM data.commercial_signing_intents i
    WHERE i.submission_id = ss.id
  );

COMMENT ON VIEW api.commercial_signing_hub IS
  'Maps signing submissions to commercial documents and, when the decision request is an agreement version, to commercial_agreements. DocuSeal agreement submissions are included from metadata when no intent exists.';

GRANT SELECT ON api.commercial_signing_hub TO authenticated;
GRANT SELECT ON api.commercial_signing_hub TO service_role;
