-- Repara firmes natives que van crear un document DMS germà en lloc d'afegir
-- una versió al rendered_document_id del pressupost/albarà.
-- Mou la versió firmada al document canònic, reapontà sessions/submissions/auditoria
-- i arxiva el document duplicat.

DO $$
DECLARE
  r record;
  v_signed data.document_versions%ROWTYPE;
  v_base_version_id uuid;
  v_new_version_id uuid;
  v_next_num int;
BEGIN
  FOR r IN
    SELECT
      cd.id AS commercial_id,
      cd.rendered_document_id AS canonical_doc_id,
      ss.id AS submission_id,
      ss.source_document_id AS orphan_doc_id,
      ss.result_document_version_id AS signed_version_id,
      ss.native_group_id
    FROM data.commercial_documents cd
    JOIN data.signing_submissions ss
      ON ss.source_document_id IS NOT NULL
     AND ss.result_document_version_id IS NOT NULL
     AND ss.signing_provider = 'native'
     AND ss.status = 'completed'
     AND EXISTS (
       SELECT 1
       FROM data.commercial_signing_intents i
       WHERE i.document_id = cd.id
         AND i.session_id IN (
           SELECT s.id FROM data.document_signing_sessions s
           WHERE s.signing_group_id = ss.native_group_id
         )
     )
    WHERE cd.rendered_document_id IS NOT NULL
      AND ss.source_document_id IS DISTINCT FROM cd.rendered_document_id
  LOOP
    SELECT * INTO v_signed
    FROM data.document_versions
    WHERE id = r.signed_version_id;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    -- Base (sense firma) al canònic: darrera versió abans d'afegir la firmada.
    SELECT dv.id INTO v_base_version_id
    FROM data.document_versions dv
    WHERE dv.document_id = r.canonical_doc_id
    ORDER BY dv.version_number DESC
    LIMIT 1;

    SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_next_num
    FROM data.document_versions
    WHERE document_id = r.canonical_doc_id;

    INSERT INTO data.document_versions (
      document_id, version_number, file_path_or_url, mime_type, size_bytes, storage_type, created_by
    ) VALUES (
      r.canonical_doc_id,
      v_next_num,
      v_signed.file_path_or_url,
      v_signed.mime_type,
      v_signed.size_bytes,
      v_signed.storage_type,
      v_signed.created_by
    )
    RETURNING id INTO v_new_version_id;

    UPDATE data.document_signing_sessions s
    SET
      document_version_id = COALESCE(v_base_version_id, s.document_version_id),
      result_version_id = v_new_version_id,
      updated_at = now()
    WHERE s.signing_group_id = r.native_group_id;

    UPDATE data.signing_submissions
    SET
      source_document_id = r.canonical_doc_id,
      result_document_version_id = v_new_version_id,
      updated_at = now()
    WHERE id = r.submission_id;

    UPDATE data.document_signatures_audit
    SET document_id = r.canonical_doc_id
    WHERE session_id IN (
      SELECT s.id FROM data.document_signing_sessions s
      WHERE s.signing_group_id = r.native_group_id
    );

    UPDATE data.documents
    SET is_archived = true, updated_at = now()
    WHERE id = r.orphan_doc_id
      AND is_archived = false;
  END LOOP;
END;
$$;
