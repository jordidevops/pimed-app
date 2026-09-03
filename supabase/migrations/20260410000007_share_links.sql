-- =============================================================================
-- Migració 7: Share Links
-- =============================================================================
-- Suporta URLs compartides de llarga durada (> 7 dies) mitjançant tokens
-- persistents guardats a data.share_links.
--
-- Flux complet:
--   Client → POST get-file-url (expiry > 7 d) → INSERT share_links + retorna URL
--   Visitant → GET resolve-share?token=...    → 302 a signed URL fresca (5 min)
--
-- Per a expirys ≤ 7 dies, get-file-url retorna directament una signed URL
-- (Supabase Storage o S3 presigned URL) sense passar per aquesta taula.
-- =============================================================================


-- =============================================================================
-- 1. Taula data.share_links
-- =============================================================================

CREATE TABLE data.share_links (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- 64 caràcters hex = 32 bytes = 256 bits d'entropia. Generat per l'Edge Function.
  token       text        NOT NULL UNIQUE,
  node_id     uuid        NOT NULL REFERENCES data.file_nodes(id) ON DELETE CASCADE,
  created_by  uuid        NOT NULL REFERENCES data.profiles(id)   ON DELETE CASCADE,
  site_id     uuid        REFERENCES data.sites(id) ON DELETE SET NULL,  -- context del site per a filtres directes
  expires_at  timestamptz NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  -- Actualitzat en cada accés vàlid (per auditing i analytics futurs)
  accessed_at timestamptz
);

-- Índex de cerca de token: O(log n) en la resolució pública
CREATE INDEX idx_share_links_token   ON data.share_links (token);
-- Índex per netejar tokens expirats periòdicament (pg_cron)
CREATE INDEX idx_share_links_expires ON data.share_links (expires_at);
-- Útil per a una futura pantalla de gestió d'enllaços per fitxer
CREATE INDEX idx_share_links_node    ON data.share_links (node_id);


-- =============================================================================
-- 2. Row-Level Security
-- =============================================================================

ALTER TABLE data.share_links ENABLE ROW LEVEL SECURITY;

-- Els usuaris autenticats poden veure i esborrar els seus propis share links.
-- Els INSERTs estan reservats exclusivament a l'Edge Function via service_role.

CREATE POLICY "share_links: creator can select"
  ON data.share_links FOR SELECT
  TO authenticated
  USING (created_by = auth.uid());

CREATE POLICY "share_links: creator can delete"
  ON data.share_links FOR DELETE
  TO authenticated
  USING (created_by = auth.uid());

GRANT SELECT, DELETE ON data.share_links TO authenticated;


-- =============================================================================
-- 3. Vista api.share_links  —  accés de lectura per als creadors
-- =============================================================================
-- WITH (security_invoker = true): la vista executa amb els permisos del cridador,
-- no del creador de la vista. La condició WHERE created_by = auth.uid() és
-- redundant (i un smell) perquè la RLS de data.share_links ja la cobreix.
-- Eliminar-la aquí evita advertències "UNRESTRICTED" al Supabase Dashboard.
-- =============================================================================

CREATE VIEW api.share_links
  WITH (security_invoker = true) AS
  SELECT id, node_id, token, expires_at, created_at, accessed_at
  FROM data.share_links;

GRANT SELECT ON api.share_links TO authenticated;


-- =============================================================================
-- 4. api.create_share_link
-- Cridada exclusivament per l'Edge Function get-file-url amb service_role.
-- SECURITY DEFINER permet INSERT a data.share_links saltant-se RLS.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_share_link(
  p_node_id    uuid,
  p_created_by uuid,
  p_expires_at timestamptz,
  p_token      text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO data.share_links (token, node_id, created_by, expires_at)
  VALUES (p_token, p_node_id, p_created_by, p_expires_at)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Només l'Edge Function (service_role) pot crear share links
GRANT EXECUTE ON FUNCTION api.create_share_link(uuid, uuid, timestamptz, text)
  TO service_role;


-- =============================================================================
-- 5. api.resolve_share_link
-- Cridada per l'Edge Function resolve-share (accés públic, sense JWT).
-- Valida el token, actualitza accessed_at atòmicament i retorna la info del fitxer.
-- SECURITY DEFINER bypassa RLS per llegir data.share_links i data.file_nodes.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.resolve_share_link(
  p_token text
) RETURNS TABLE (
  node_id     uuid,
  storage_key text,
  file_name   text,
  mime_type   text,
  tenant_id   uuid,
  is_expired  boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
BEGIN
  -- Actualitzar accessed_at atòmicament (només si l'enllaç és vàlid)
  UPDATE data.share_links
  SET    accessed_at = now()
  WHERE  token = p_token
    AND  expires_at >= now();

  RETURN QUERY
  SELECT
    fn.id               AS node_id,
    fn.storage_key      AS storage_key,
    fn.name             AS file_name,
    fn.mime_type        AS mime_type,
    fn.tenant_id        AS tenant_id,
    (sl.expires_at < now()) AS is_expired
  FROM data.share_links sl
  JOIN data.file_nodes  fn ON fn.id = sl.node_id
  WHERE sl.token = p_token;
END;
$$;

-- anon: necessari per resolve-share (sense JWT)
-- service_role: per als adminClient calls
GRANT EXECUTE ON FUNCTION api.resolve_share_link(text)
  TO anon, service_role;
