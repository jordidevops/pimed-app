-- =============================================================================
-- Migration: 20260526000001_signing_doc_and_audit.sql
-- Purpose  : Adds three new fields to data.signing_submissions:
--              · source_document_id       — FK snapshot per a navegació al document pare
--              · document_title           — snapshot del títol en el moment de la signatura
--              · audit_trail_storage_path — path al PDF d'auditoria un cop completa
--            Rebuilds api.signing_submissions view to expose the new columns.
--            All existing GRANTs are re-issued after view recreation.
-- Pattern  : RLS no canvia (security_invoker = true, polítiques ja a data.*)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Noves columnes a data.signing_submissions
-- ---------------------------------------------------------------------------

ALTER TABLE data.signing_submissions
  ADD COLUMN IF NOT EXISTS source_document_id       uuid
    REFERENCES data.documents(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS document_title           text,
  ADD COLUMN IF NOT EXISTS audit_trail_storage_path text;

-- ---------------------------------------------------------------------------
-- 2. Index per a navegació eficient document → submissions
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_signing_submissions_doc
  ON data.signing_submissions (source_document_id)
  WHERE source_document_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Reconstruir api.signing_submissions per exposar els camps nous
--    Hem de DROP + CREATE perquè OR REPLACE no pot afegir columnes en vistes
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.signing_submissions;

CREATE VIEW api.signing_submissions WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    source_type,
    source_document_id,
    source_document_version_id,
    source_template_locale_id,
    result_document_version_id,
    docuseal_submission_id,
    external_id,
    status,
    status_reason,
    error_message,
    last_event_at,
    signers,
    docuseal_signing_url,
    submitted_at,
    completed_at,
    document_title,
    audit_trail_storage_path,
    initiated_by,
    metadata,
    created_at,
    updated_at
  FROM data.signing_submissions;

-- ---------------------------------------------------------------------------
-- 4. Re-emetre GRANTs (la recreació de la vista els esborra)
-- ---------------------------------------------------------------------------

GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO service_role;
