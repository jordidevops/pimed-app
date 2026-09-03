/*
  Fix: permisos base per llegir data.document_content_blocks via api.document_content_blocks

  Causa:
  - api.document_content_blocks és una vista WITH (security_invoker = true)
  - Amb security_invoker, el rol cridador (authenticated) necessita permisos SELECT
    sobre la taula base data.document_content_blocks.
  - Sense aquest GRANT, Postgres retorna 42501 abans d'aplicar RLS.
*/

GRANT SELECT ON data.document_content_blocks TO authenticated;
GRANT SELECT ON data.document_content_blocks TO service_role;
