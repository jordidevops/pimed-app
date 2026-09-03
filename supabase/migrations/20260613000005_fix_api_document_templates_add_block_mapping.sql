/*
  Fix: afegir default_block_mapping a api.document_templates

  La vista api.document_templates no exposava la columna default_block_mapping
  afegida a data.document_templates per la migració 20260613000001.
  Sense aquesta columna, el frontend sempre llegia '{}' i el mapeig guardat
  es perdia en recarregar la pàgina.

  Actualitza la vista per incloure la nova columna (última versió completa).
*/

CREATE OR REPLACE VIEW api.document_templates
  WITH (security_invoker = true)
AS
SELECT
  t.id,
  t.tenant_id,
  t.name,
  t.description,
  t.category,
  t.is_platform_default,
  t.cloned_from_id,
  t.is_active,
  t.created_by,
  t.created_at,
  t.updated_at,
  t.template_type,
  t.target_archetypes,
  t.target_verticals,
  t.default_block_mapping
FROM data.document_templates t;

-- Mantenim els mateixos grants que la versió anterior
GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_templates TO authenticated;
GRANT SELECT ON api.document_templates TO service_role;
