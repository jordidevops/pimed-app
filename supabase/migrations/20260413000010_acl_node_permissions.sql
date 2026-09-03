-- =============================================================================
-- Migració 10: Sistema ACL amb node_permissions i herència per ancestor_paths
-- =============================================================================
-- Aquesta migració amplia el model de permisos de fitxers amb ACL per node.
-- Conviu amb RLS basada en JWT claims (migració 3) i afegeix control fi
-- sobre file_nodes via can_access_via_permissions().
--
-- Estat actual:
--   · SELECT de file_nodes combina ACL + context tenant actiu + context de site.
--   · Usuari amb rol global: accés a tots els sites del tenant (subjecte a ACL).
--   · Usuari site-only: accés només al seu site (subjecte a ACL).
--
-- ARQUITECTURA D'ACCÉS (4 condicions, la primera TRUE guanya):
--
--   1. L'usuari és el CREADOR del node (created_by = auth.uid())
--   2. L'usuari té un PERMÍS DIRECTE en data.node_permissions per a aquest node
--   3. L'usuari té un PERMÍS HERETAT: entrada a node_permissions per qualsevol
--      carpeta ancestral (permís a '/projects/' → accés a tot el contingut)
--   4. NODE PÚBLIC: is_restricted = false I cap ancestre té is_restricted = true
--
-- RESOLUCIÓ DE CONFLICTES PARE/FILL:
--   • Cada node té el seu propi flag is_restricted (independent).
--   • Un PERMÍS en un ancestre PROPAGA accés a tots els descendents,
--     fins i tot als que tenen is_restricted = true.
--     Exemple: permís a '/projects/' cobreix '/projects/confidential/' (restringit).
--   • Un FILL restringit dins un PARE públic:
--     → exigeix permís directe o heretat al fill (o al seu ancestre)
--   • Un FILL públic dins un PARE restringit:
--     → bloquejat si l'usuari no té permís al pare o superior.
--     El is_restricted = false del fill NOMÉS significa "sense restricció addicional".
--   • En crear un node, hereta is_restricted del pare via trigger (si pare=true).
--
-- CANVIS RESPECTE AL SISTEMA LEGACY (node_acl + node_acl_grants):
--   • Afegim la columna is_restricted directament a data.file_nodes.
--   • Migrem nodes amb node_acl → is_restricted = true.
--   • Migrem grants per user → node_permissions (access_level 'viewer' per defecte).
--   • La vista api.file_nodes usa is_restricted (columna) i can_access_via_permissions().
--   • El sistema legacy node_acl es manté sense canvis (backward compat) però
--     la nova funció can_access_via_permissions() és l'autoritat per al RLS.
-- =============================================================================


-- =============================================================================
-- 1. COLUMNA is_restricted a data.file_nodes
-- =============================================================================

ALTER TABLE data.file_nodes
  ADD COLUMN IF NOT EXISTS is_restricted boolean NOT NULL DEFAULT false;

-- Sincronitzar amb el sistema legacy: nodes amb node_acl → is_restricted = true
UPDATE data.file_nodes fn
   SET is_restricted = true
 WHERE EXISTS (
     SELECT 1 FROM data.node_acl a WHERE a.node_id = fn.id
 );

-- Índex parcial per a queries de nodes restringits (usats a can_access_via_permissions)
CREATE INDEX IF NOT EXISTS idx_file_nodes_restricted
  ON data.file_nodes (tenant_id, id)
  WHERE is_restricted = true;


-- =============================================================================
-- 2. TAULA data.node_permissions
-- =============================================================================

CREATE TABLE data.node_permissions (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  node_id      uuid        NOT NULL REFERENCES data.file_nodes(id) ON DELETE CASCADE,
  user_id      uuid        NOT NULL REFERENCES data.profiles(id)   ON DELETE CASCADE,
  access_level text        NOT NULL
                           CHECK (access_level IN ('viewer', 'editor', 'owner')),
  granted_by   uuid        NOT NULL REFERENCES data.profiles(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (node_id, user_id)
);

-- Índexs principals per al check de permisos
CREATE INDEX idx_node_permissions_node    ON data.node_permissions (node_id);
CREATE INDEX idx_node_permissions_user    ON data.node_permissions (user_id);

-- Migrar permisos existents: node_acl_grants (per user_id) → node_permissions
-- Usem 'viewer' com a access_level conservador per als grants migrats.
INSERT INTO data.node_permissions (node_id, user_id, access_level, granted_by)
SELECT
  a.node_id,
  g.grantee_user_id,
  'viewer'     AS access_level,
  a.created_by AS granted_by
FROM data.node_acl a
JOIN data.node_acl_grants g ON g.acl_id = a.id
WHERE g.grantee_user_id IS NOT NULL
ON CONFLICT (node_id, user_id) DO NOTHING;


-- =============================================================================
-- 3. RLS per a data.node_permissions
-- =============================================================================

ALTER TABLE data.node_permissions ENABLE ROW LEVEL SECURITY;

-- Lectura: l'usuari veu els seus propis permisos O tots si és owner/manager
CREATE POLICY "node_permissions: lectura"
  ON data.node_permissions FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM data.file_nodes fn
      WHERE fn.id = node_id
        AND data.my_role_in(fn.tenant_id) IN ('owner', 'manager')
    )
  );

-- Inserció: el cridador ha de ser owner/manager del tenant i el granted_by = auth.uid()
CREATE POLICY "node_permissions: inserció"
  ON data.node_permissions FOR INSERT
  TO authenticated
  WITH CHECK (
    granted_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM data.file_nodes fn
      WHERE fn.id = node_id
        AND data.my_role_in(fn.tenant_id) IN ('owner', 'manager')
    )
  );

-- Eliminació: owner/manager del tenant
CREATE POLICY "node_permissions: eliminació"
  ON data.node_permissions FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.file_nodes fn
      WHERE fn.id = node_id
        AND data.my_role_in(fn.tenant_id) IN ('owner', 'manager')
    )
  );

GRANT SELECT, INSERT, DELETE ON data.node_permissions TO authenticated;


-- =============================================================================
-- 4. TRIGGER: herència de is_restricted del pare
-- =============================================================================
-- Si el pare és restringit, el fill hereta la restricció en crear-se.
-- Nom "trg_e_" per garantir execució DARRERE dels triggers trg_a..d (ordre alfabètic).
-- =============================================================================

CREATE OR REPLACE FUNCTION data.inherit_parent_restriction()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_parent_restricted boolean;
BEGIN
  IF NEW.parent_id IS NOT NULL THEN
    SELECT is_restricted
      INTO v_parent_restricted
      FROM data.file_nodes
     WHERE id = NEW.parent_id;

    -- Si el pare és restringit i el fill no ho és explícitament, propagar
    IF FOUND AND v_parent_restricted AND NOT NEW.is_restricted THEN
      NEW.is_restricted := true;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_e_file_nodes_inherit_restriction
  BEFORE INSERT ON data.file_nodes
  FOR EACH ROW EXECUTE FUNCTION data.inherit_parent_restriction();


-- =============================================================================
-- 5. FUNCIÓ SECURITY DEFINER: can_access_via_permissions
-- =============================================================================
-- Retorna TRUE si auth.uid() pot accedir al node amb els paràmetres donats.
-- Usada tant al USING del RLS com al SELECT de la vista api.file_nodes,
-- per garantir coherència absoluta entre visibilitat RLS i indicadors del frontend.
--
-- SECURITY DEFINER: necessari per llegir data.node_permissions i data.file_nodes
--   sense que el RLS del cridador interfereixi (la funció executa com postgres).
-- STABLE: PostgreSQL pot cachejar el resultat per query; no fa escriptures.
-- SET search_path = data: prevenció d'injection via search_path manipulation.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.can_access_via_permissions(
  p_node_id        uuid,
  p_is_restricted  boolean,
  p_created_by     uuid,
  p_ancestor_paths text[],
  p_tenant_id      uuid
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT
    -- 1. El creador sempre té accés al seu propi contingut
    p_created_by = auth.uid()

    OR

    -- 2. Permís directe: entrada a node_permissions per a aquest node
    EXISTS (
      SELECT 1
        FROM data.node_permissions
       WHERE node_id = p_node_id
         AND user_id = auth.uid()
    )

    OR

    -- 3. Permís heretat: l'usuari té permís en qualsevol carpeta ancestral.
    --    (anc.path || anc.name || '/') = path complet de la carpeta ancestre.
    --    Ex: path='/', name='projects' → '/projects/' (present a ancestor_paths dels fills)
    EXISTS (
      SELECT 1
        FROM data.node_permissions np
        JOIN data.file_nodes anc ON anc.id = np.node_id
       WHERE np.user_id  = auth.uid()
         AND anc.tenant_id = p_tenant_id
         AND (anc.path || anc.name || '/') = ANY(p_ancestor_paths)
    )

    OR

    -- 4. Subtree completament públic: el node no és restringit I cap ancestre ho és.
    (
      NOT p_is_restricted
      AND NOT EXISTS (
        SELECT 1
          FROM data.file_nodes anc
         WHERE anc.tenant_id  = p_tenant_id
           AND anc.is_restricted = true
           AND (anc.path || anc.name || '/') = ANY(p_ancestor_paths)
      )
    )
$$;

GRANT EXECUTE ON FUNCTION data.can_access_via_permissions(uuid, boolean, uuid, text[], uuid)
  TO authenticated;


-- =============================================================================
-- 6. ACTUALITZAR RLS de data.file_nodes (substituir has_no_blocked_ancestor)
-- =============================================================================

DROP POLICY IF EXISTS "file_nodes: veure nodes dels teus tenants" ON data.file_nodes;

CREATE POLICY "file_nodes: veure nodes dels teus tenants"
  ON data.file_nodes FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      -- Nodes esborrats: visibles a la vista trash sense filtre de site
      is_deleted = true
      OR (
        is_deleted = false
        AND (
          processing_status IN ('none', 'done', 'processing', 'error')
          OR (processing_status = 'pending' AND created_by = auth.uid())
        )
        AND data.can_access_via_permissions(
          id, is_restricted, created_by, ancestor_paths, tenant_id
        )
        AND (
          -- Node global del Tenant: visible per a tots els membres
          site_id IS NULL
          OR
          -- Rol global: accés a tots els sites del Tenant
          (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IS NOT NULL
          OR
          -- Accés específic al site del node
          (data.jwt_user_tenants() -> tenant_id::text -> 'sites') ? site_id::text
        )
      )
    )
  );


-- =============================================================================
-- 7. ACTUALITZAR api.file_nodes: is_restricted com a columna + can_access_for_me
-- =============================================================================
-- DROP CASCADE elimina les regles INSERT/UPDATE definides en la migració anterior.
-- És necessari perquè s'afegeix una columna nova (storage_provider_id) i
-- CREATE OR REPLACE VIEW no permet canviar l'ordre de columnes existents.
-- =============================================================================

DROP VIEW IF EXISTS api.file_nodes CASCADE;

CREATE VIEW api.file_nodes
  WITH (security_invoker = true) AS
  SELECT
    fn.id,
    fn.tenant_id,
    fn.parent_id,
    fn.created_by,
    fn.node_type,
    fn.name,
    fn.path,
    fn.namespace,
    fn.mime_type,
    fn.size_bytes,
    fn.checksum,
    fn.processing_status,
    fn.metadata,
    fn.created_at,
    fn.updated_at,
    fn.storage_key,
    fn.storage_provider_id,
    -- Columna real (no computada de node_acl): font de veritat per a RLS i UI
    fn.is_restricted,
    -- Indica si l'usuari actual té accés efectiu (heretant de pares si cal)
    data.can_access_via_permissions(
      fn.id,
      fn.is_restricted,
      fn.created_by,
      fn.ancestor_paths,
      fn.tenant_id
    ) AS can_access_for_me
  FROM data.file_nodes fn
  WHERE fn.is_deleted = false;

GRANT SELECT, INSERT, UPDATE ON api.file_nodes TO authenticated;


-- =============================================================================
-- 8. REGLES INSERT i UPDATE (actualitzades per incloure is_restricted)
-- =============================================================================
-- La regla INSERT passa is_restricted al INSERT perquè el trigger
-- trg_e_file_nodes_inherit_restriction pugui sobreescriure'l si el pare és restringit.
-- (Les regles anteriors les ha eliminat el DROP CASCADE de la secció 7.)
-- =============================================================================

CREATE RULE "api_file_nodes_insert" AS ON INSERT TO api.file_nodes
  DO INSTEAD
  INSERT INTO data.file_nodes (
    tenant_id, parent_id, created_by, node_type, name,
    namespace, mime_type, size_bytes, metadata, is_restricted
  )
  VALUES (
    NEW.tenant_id,
    NEW.parent_id,
    auth.uid(),
    NEW.node_type,
    NEW.name,
    COALESCE(NEW.namespace, 'repository'),
    NEW.mime_type,
    COALESCE(NEW.size_bytes, 0),
    NEW.metadata,
    COALESCE(NEW.is_restricted, false)
  )
  RETURNING
    id, tenant_id, parent_id, created_by, node_type, name, path,
    namespace, mime_type, size_bytes, checksum, processing_status,
    metadata, created_at, updated_at, storage_key,
    storage_provider_id,
    is_restricted,
    true AS can_access_for_me;

CREATE RULE "api_file_nodes_update" AS ON UPDATE TO api.file_nodes
  DO INSTEAD
  UPDATE data.file_nodes
     SET name         = COALESCE(NEW.name, OLD.name),
         metadata     = COALESCE(NEW.metadata, OLD.metadata),
         is_restricted = COALESCE(NEW.is_restricted, OLD.is_restricted)
   WHERE id = OLD.id
  RETURNING
    id, tenant_id, parent_id, created_by, node_type, name, path,
    namespace, mime_type, size_bytes, checksum, processing_status,
    metadata, created_at, updated_at, storage_key,
    storage_provider_id,
    is_restricted,
    true AS can_access_for_me;


-- =============================================================================
-- 9. VISTA api.node_permissions — lectura de permisos amb dades de perfil
-- =============================================================================

CREATE OR REPLACE VIEW api.node_permissions
  WITH (security_invoker = true) AS
  SELECT
    np.id,
    np.node_id,
    np.user_id,
    np.access_level,
    np.granted_by,
    np.created_at,
    p.email,
    p.full_name,
    p.avatar_url
  FROM data.node_permissions np
  JOIN data.profiles p ON p.id = np.user_id;

GRANT SELECT ON api.node_permissions TO authenticated;


-- =============================================================================
-- 10. RPC api.update_node_permissions — gestió atòmica de l'ACL d'un node
-- =============================================================================
-- • Canvia is_restricted del node.
-- • Reemplaça tots els permisos d'usuari del node (DELETE + INSERT).
-- • Valida que cada user_id és membre actiu del tenant.
-- • SECURITY DEFINER per operar atòmicament sense restriccions RLS.
-- • Seguretat explícita: comprova que el cridador és owner/manager.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.update_node_permissions(
  p_node_id          uuid,
  p_is_restricted    boolean,
  p_permissions_json jsonb  -- [{"user_id":"uuid","access_level":"viewer|editor|owner"}, ...]
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_node    record;
  v_role    text;
  v_perm    jsonb;
  v_uid     uuid;
  v_level   text;
BEGIN
  -- Obtenir el node (ha d'existir i no estar a la paperera)
  SELECT * INTO v_node
    FROM data.file_nodes
   WHERE id = p_node_id AND is_deleted = false;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'node_not_found'
      USING HINT = 'El node no existeix o està a la paperera';
  END IF;

  -- Verificar que el cridador és owner o manager del tenant
  v_role := data.my_role_in(v_node.tenant_id);
  IF v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'insufficient_permissions'
      USING HINT = 'Necessites ser owner o manager per gestionar permisos';
  END IF;

  -- Actualitzar is_restricted en el node
  UPDATE data.file_nodes
     SET is_restricted = p_is_restricted,
         updated_at    = now()
   WHERE id = p_node_id;

  -- Reemplaçar tots els permisos del node
  DELETE FROM data.node_permissions WHERE node_id = p_node_id;

  IF p_permissions_json IS NOT NULL AND jsonb_array_length(p_permissions_json) > 0 THEN
    FOR v_perm IN SELECT * FROM jsonb_array_elements(p_permissions_json)
    LOOP
      v_uid   := (v_perm->>'user_id')::uuid;
      v_level := v_perm->>'access_level';

      -- Validar access_level
      IF v_level NOT IN ('viewer', 'editor', 'owner') THEN
        RAISE EXCEPTION 'invalid_access_level'
          USING HINT = 'access_level ha de ser viewer, editor o owner';
      END IF;

      -- Validar que l'usuari és membre actiu del tenant
      IF NOT EXISTS (
        SELECT 1 FROM data.tenant_members
        WHERE user_id   = v_uid
          AND tenant_id = v_node.tenant_id
          AND is_active = true
      ) THEN
        RAISE EXCEPTION 'user_not_tenant_member'
          USING HINT = 'L''usuari no és membre actiu del tenant';
      END IF;

      INSERT INTO data.node_permissions (node_id, user_id, access_level, granted_by)
      VALUES (p_node_id, v_uid, v_level, auth.uid())
      ON CONFLICT (node_id, user_id) DO UPDATE
        SET access_level = EXCLUDED.access_level,
            granted_by   = EXCLUDED.granted_by;
    END LOOP;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_node_permissions(uuid, boolean, jsonb) TO authenticated;
