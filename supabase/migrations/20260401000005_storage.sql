-- =============================================================================
-- Migració 5: Supabase Storage — buckets i policies
-- =============================================================================
-- Bucket: tenant-files
--   Privat (no públic). Cada tenant accedeix NOMÉS al seu path: {tenant_id}/*
--   Quota de fitxers controlada via data.storage_usage i el límit del pla.
-- =============================================================================

-- Crear bucket privat per a fitxers de tenants
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'tenant-files',
  'tenant-files',
  false,                              -- privat: cal JWT per accedir
  52428800,                           -- 50 MB màxim per fitxer
  ARRAY[
    'image/jpeg', 'image/png', 'image/gif', 'image/webp',
    'application/pdf',
    'text/plain', 'text/csv',
    'application/json',
    'application/zip',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- =============================================================================
-- Storage RLS policies
-- Path convention: {tenant_id}/{subcarpeta}/{fitxer}
-- L'usuari ha de ser membre actiu del tenant per accedir al seu path.
-- =============================================================================

-- Funció helper: extreu el tenant_id del path de storage
CREATE OR REPLACE FUNCTION data.storage_path_tenant_id(object_name text)
RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT SPLIT_PART(object_name, '/', 1)::uuid;
$$;

-- Funció helper: comprova si l'usuari és membre actiu del tenant d'un path
CREATE OR REPLACE FUNCTION data.can_access_tenant_storage(object_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE user_id   = auth.uid()
      AND tenant_id = data.storage_path_tenant_id(object_name)
      AND is_active = true
  );
$$;

-- SELECT (descarregar/veure fitxers)
CREATE POLICY "storage: membres poden llegir fitxers del tenant"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'tenant-files'
    AND data.can_access_tenant_storage(name)
  );

-- INSERT (pujar fitxers)
CREATE POLICY "storage: membres poden pujar fitxers al tenant"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'tenant-files'
    AND data.can_access_tenant_storage(name)
    AND data.my_role_in(data.storage_path_tenant_id(name)) IN ('owner', 'manager', 'member')
  );

-- DELETE (eliminar fitxers — l'autor o owner/manager)
CREATE POLICY "storage: autor o owner/manager pot eliminar fitxers"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'tenant-files'
    AND data.can_access_tenant_storage(name)
    AND (
      owner = auth.uid()
      OR data.my_role_in(data.storage_path_tenant_id(name)) IN ('owner', 'manager')
    )
  );
