-- =============================================================================
-- Migració: avatars — bucket, RPC i polítiques RLS
-- =============================================================================
--
-- BUCKET: avatars (públic)
--   Les URLs es poden mostrar a <img> sense JWT.
--   Mida màxima per fitxer: 2 MB.
--   Formats acceptats: JPEG, PNG, WebP.
--
-- PATH CONVENTION: {tenant_id}/{user_id}/avatar
--   Segment 1 → tenant_id  (uuid del tenant actiu de l'usuari)
--   Segment 2 → user_id    (= auth.uid())
--   Segment 3 → 'avatar'   (nom fix sense extensió → upsert sempre sobreescriu
--                            el mateix objecte i evita acumular duplicats)
--
-- RPC: api.update_my_avatar(p_avatar_url)
--   Actualitza data.profiles.avatar_url per a l'usuari autenticat.
--   Accessible des del tenant-portal (db.schema = 'api') via supabase.rpc().
--   Segueix el SECURITY DEFINER pattern de api.record_login().
--
-- RLS POLICIES:
--   SELECT  → públic (necessari per renderitzar <img> sense token)
--   INSERT  → authenticated + user_id del path = auth.uid()
--             + membre actiu del tenant del path (via data.my_role_in())
--   UPDATE  → ídem  (permet upsert: true des del client)
--   DELETE  → ídem
--
-- NOTE: Les polítiques usen SPLIT_PART + data.my_role_in() directament a la
-- clàusula de la policy (sense funció SECURITY DEFINER addicional) perquè
-- auth.uid() no es propaga correctament dins d'una nova funció SECURITY
-- DEFINER en el context d'Storage RLS del dev local de Supabase.
-- data.my_role_in() ja existeix com a SECURITY DEFINER al codebase i és
-- l'únic punt on s'accedeix a data.tenant_members sense recursió.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Bucket
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'avatars',
  'avatars',
  true,
  2097152,                                          -- 2 MB màxim per fitxer
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- RPC: api.update_my_avatar(p_avatar_url text)
-- Crida: supabase.rpc('update_my_avatar', { p_avatar_url: url | null })
-- Escriu a data.profiles (schema privat) usant SECURITY DEFINER.
-- Accepta NULL per esborrar l'avatar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_my_avatar(p_avatar_url text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, public
AS $$
  UPDATE data.profiles
  SET    avatar_url = p_avatar_url,
         updated_at = now()
  WHERE  id = auth.uid();
$$;

-- Només usuaris autenticats poden cridar-la (cap accés anon ni públic)
REVOKE EXECUTE ON FUNCTION api.update_my_avatar(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION api.update_my_avatar(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- RLS Policies
-- ---------------------------------------------------------------------------

-- SELECT: lectura pública — necessari per mostrar <img src="..."> sense JWT.
-- El bucket és marcat com a públic però les policies han d'existir igualment.
CREATE POLICY "avatars: accés públic de lectura"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'avatars');

-- INSERT: l'usuari autenticat pot pujar el seu propi avatar.
--   SPLIT_PART(name,'/',1)::uuid → tenant_id → data.my_role_in() comprova
--     que l'usuari és membre actiu del tenant (qualsevol rol és vàlid).
--   SPLIT_PART(name,'/',2) = auth.uid()::text → l'usuari només pot escriure
--     al seu propi path (no pot suplantar un altre usuari del mateix tenant).
CREATE POLICY "avatars: membre pot pujar el seu avatar"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'avatars'
    AND SPLIT_PART(name, '/', 2) = auth.uid()::text
    AND data.my_role_in(SPLIT_PART(name, '/', 1)::uuid) IS NOT NULL
  );

-- UPDATE: permet upsert:true des del client (sobreescriure l'avatar existent).
--   Mateixa lògica que INSERT; s'aplica tant a USING (fila existent) com a
--   WITH CHECK (nova fila resultant) per evitar que un usuari mogui un fitxer
--   d'un path a un altre.
CREATE POLICY "avatars: membre pot actualitzar el seu avatar"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'avatars'
    AND SPLIT_PART(name, '/', 2) = auth.uid()::text
    AND data.my_role_in(SPLIT_PART(name, '/', 1)::uuid) IS NOT NULL
  )
  WITH CHECK (
    bucket_id = 'avatars'
    AND SPLIT_PART(name, '/', 2) = auth.uid()::text
    AND data.my_role_in(SPLIT_PART(name, '/', 1)::uuid) IS NOT NULL
  );

-- DELETE: l'usuari pot esborrar el seu propi avatar.
CREATE POLICY "avatars: membre pot eliminar el seu avatar"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'avatars'
    AND SPLIT_PART(name, '/', 2) = auth.uid()::text
    AND data.my_role_in(SPLIT_PART(name, '/', 1)::uuid) IS NOT NULL
  );

