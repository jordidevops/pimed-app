-- ============================================================================
-- Migració: 20260530000003_fix_document_templates_storage_policy
-- Motiu: La política de lectura del bucket "document-templates" comprova
--        jwt_user_tenants() ? (foldername)[1], cosa que bloqueja els fitxers
--        de plantilles de plataforma (prefix "platform/") perquè "platform" no
--        és un tenant_id vàlid. Qualsevol usuari autenticat ha de poder llegir
--        les plantilles de plataforma.
-- Patró: SELECT permet si (a) primer folder = 'platform' (plantilla del sistema),
--                          o (b) primer folder és un tenant_id del jwt de l'usuari.
-- ============================================================================

DROP POLICY IF EXISTS "document-templates bucket: tenant members can read" ON storage.objects;

CREATE POLICY "document-templates bucket: tenant members can read"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'document-templates'
    AND (
      -- Plantilles de plataforma: accessible per qualsevol usuari autenticat
      (storage.foldername(name))[1]::text = 'platform'
      -- Plantilles de tenant: l'usuari ha de ser membre del tenant
      OR data.jwt_user_tenants() ? (storage.foldername(name))[1]::text
    )
  );
