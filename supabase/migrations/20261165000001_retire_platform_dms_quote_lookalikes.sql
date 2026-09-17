-- Retire platform DMS templates that look like commercial-flow quotes.
-- HTML+DOCX "Pressupost d'obra o instal·lació" (022) and "Pressupost de reparació" (027).
-- Tenant clones stay. cloned_from_id / commercial_documents.document_template_id are ON DELETE SET NULL.

DO $$
DECLARE
  v_ids uuid[] := ARRAY[
    '70000000-0000-0000-0000-000000000022'::uuid,
    '70000000-0000-0000-0000-000000000027'::uuid,
    '72000000-0000-0000-0000-000000000022'::uuid,
    '72000000-0000-0000-0000-000000000027'::uuid
  ];
BEGIN
  UPDATE data.document_templates
  SET cloned_from_id = NULL
  WHERE cloned_from_id = ANY (v_ids);

  DELETE FROM data.document_template_locales
  WHERE template_id = ANY (v_ids);

  DELETE FROM data.document_templates
  WHERE id = ANY (v_ids)
    AND tenant_id IS NULL
    AND is_platform_default;
END $$;
