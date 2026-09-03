-- =============================================================================
-- Migració 6: File Management System
-- =============================================================================
-- Sistema complet de gestió de fitxers amb:
--   - Filesystem virtual (file_nodes) amb carpetes i fitxers
--   - Materialitzed path + ancestor_paths (GIN) per rendiment
--   - Namespace (repository/system) per protegir nodes del sistema
--   - ACL jeràrquic amb efecte "candau" (node visible, contingut ocult)
--   - BYOS (Bring Your Own Storage) via storage_providers + Vault
--   - Quota de dos fases (committed_bytes + reserved_bytes)
--   - Kill Switch per bloquejar storage a nivell de tenant
--   - Papelera (soft delete) amb 30 dies de retenció
--   - Esborrat definitiu via pgmq (Supabase Queues) + Edge Functions
--   - Favorits, Recents, Els meus fitxers, Cerca (pg_trgm)
--   - Regles de processament per path/MIME
--   - Context de site (site_id NULL = global tenant; site_id NOT NULL = recurs de site)
--
-- Autorització:
--   · Aquesta migració defineix RLS pròpia de file_nodes/storage_providers/etc.
--   · El model de permisos (JWT claims + fallback cache) es defineix a la migració 3.
--   · La select de file_nodes es refina més endavant a la migració ACL (20260413000010).
--
-- Ordre d'execució:
--   0. Extensions + cua pgmq
--   1. ALTER taules existents (kill switch, storage_usage)
--   2. DROP infraestructura antiga (data.files)
--   3. CREATE noves taules
--   4. Migrar dades data.files → data.file_nodes
--   5. DROP data.files
--   6. CREATE funcions helper
--   7. CREATE triggers
--   8. CREATE índexs
--   9. ENABLE RLS + polítiques
--  10. GRANTs
--  11. Vistes api.* + regles
--  12. Funcions RPC (search, trash, restore)
--  13. pg_cron schedules (condicional)
-- =============================================================================


-- =============================================================================
-- 0. EXTENSIONS + CUA PGMQ
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgmq;

-- Cua de missatges per a esborrat físic de fitxers a Storage/S3.
-- Consumida per l'Edge Function 'process-deletion-queue'.
-- Payload: { file_node_id, tenant_id, storage_provider_id, storage_key }
SELECT pgmq.create('trash_deletion_queue');


-- =============================================================================
-- 1. ALTER TAULES EXISTENTS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1a. Kill Switch a data.tenants
-- Permet bloquejar l'storage d'un tenant immediatament.
-- ---------------------------------------------------------------------------
ALTER TABLE data.tenants
  ADD COLUMN storage_blocked         boolean     NOT NULL DEFAULT false,
  ADD COLUMN storage_blocked_reason  text,
  ADD COLUMN storage_blocked_at      timestamptz,
  ADD COLUMN storage_blocked_by      uuid        REFERENCES data.profiles(id);

-- ---------------------------------------------------------------------------
-- 1b. Transformar data.storage_usage: total_bytes → committed_bytes + reserved_bytes
-- El model de dos fases separa bytes confirmats (fitxers pujats) dels reservats
-- (uploads pendents en curs).
-- ---------------------------------------------------------------------------

-- Primer eliminem la vista dependent
DROP VIEW IF EXISTS api.storage_usage;

ALTER TABLE data.storage_usage
  ADD COLUMN committed_bytes bigint NOT NULL DEFAULT 0,
  ADD COLUMN reserved_bytes  bigint NOT NULL DEFAULT 0;

-- Migrar dades existents
UPDATE data.storage_usage SET committed_bytes = total_bytes;

ALTER TABLE data.storage_usage DROP COLUMN total_bytes;


-- =============================================================================
-- 2. DROP INFRAESTRUCTURA ANTIGA (data.files)
-- =============================================================================
-- L'ordre importa: vista → polítiques → trigger → índex

DROP VIEW IF EXISTS api.files CASCADE;

DROP POLICY IF EXISTS "files: veure fitxers dels teus tenants"         ON data.files;
DROP POLICY IF EXISTS "files: owner/manager/member poden pujar"        ON data.files;
DROP POLICY IF EXISTS "files: uploader o owner/manager pot eliminar"   ON data.files;

ALTER TABLE data.files DISABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_files_storage_usage ON data.files;

DROP INDEX IF EXISTS data.idx_files_tenant;


-- =============================================================================
-- 3. CREATE NOVES TAULES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 3a. data.storage_providers — configuració BYOS per tenant
-- Cada tenant pot opcionalment connectar el seu propi bucket S3/R2/GCS.
-- Si storage_provider_id és NULL a file_nodes → Supabase Storage per defecte.
-- secret_key_id referencia vault.secrets.id (MAI exposat via api.*).
-- ---------------------------------------------------------------------------
CREATE TABLE data.storage_providers (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL UNIQUE REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider_type   text        NOT NULL DEFAULT 'supabase'
                              CHECK (provider_type IN ('supabase', 's3', 'r2', 'gcs')),
  endpoint_url    text,
  bucket_name     text,
  access_key      text,           -- clau pública, segur d'emmagatzemar
  secret_key_id   uuid,           -- → vault.secrets.id (només via Edge Function)
  region          text,
  is_verified     boolean     NOT NULL DEFAULT false,
  is_active       boolean     NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 3b. data.file_nodes — filesystem virtual
-- Substitueix data.files. Cada fila és un fitxer o carpeta.
-- path: path materialitzat del directori pare (ex: '/docs/contracts/')
-- ancestor_paths: array computat per trigger amb tots els paths ancestrals (GIN)
-- namespace: 'repository' (editable per usuaris) o 'system' (protegit)
-- ---------------------------------------------------------------------------
CREATE TABLE data.file_nodes (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  parent_id           uuid        REFERENCES data.file_nodes(id) ON DELETE CASCADE,
  created_by          uuid        NOT NULL REFERENCES data.profiles(id),
  node_type           text        NOT NULL
                                  CHECK (node_type IN ('file', 'folder')),
  name                text        NOT NULL,
  path                text        NOT NULL DEFAULT '/',
  ancestor_paths      text[]      NOT NULL DEFAULT ARRAY['/'],
  namespace           text        NOT NULL DEFAULT 'repository'
                                  CHECK (namespace IN ('repository', 'system')),

  -- Camps d'storage (només per fitxers, NULL per carpetes)
  storage_provider_id uuid        REFERENCES data.storage_providers(id),
  storage_key         text,
  mime_type           text,
  size_bytes          bigint      NOT NULL DEFAULT 0,
  checksum            text,

  -- Processament
  processing_status   text        NOT NULL DEFAULT 'none'
                                  CHECK (processing_status IN ('none','pending','processing','done','error')),
  processing_error    text,
  metadata            jsonb,

  -- Cicle de vida d'upload
  upload_expires_at   timestamptz,

  -- Soft delete (papelera)
  is_deleted          boolean     NOT NULL DEFAULT false,
  deleted_at          timestamptz,
  deleted_by          uuid        REFERENCES data.profiles(id),

  -- Contexte de site (NULL = node global del Tenant)
  site_id             uuid        REFERENCES data.sites(id) ON DELETE SET NULL,

  -- Timestamps
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  -- Constraint: carpetes no poden tenir camps d'storage
  CHECK (
    (node_type = 'folder' AND storage_key IS NULL AND mime_type IS NULL AND size_bytes = 0)
    OR node_type = 'file'
  )
);

-- ---------------------------------------------------------------------------
-- 3c. data.storage_path_usage — ús granular per path
-- Permet veure quant ocupa cada subcarpeta sense agregar tot file_nodes.
-- ---------------------------------------------------------------------------
CREATE TABLE data.storage_path_usage (
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  path        text        NOT NULL,
  file_count  integer     NOT NULL DEFAULT 0,
  total_bytes bigint      NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, path)
);

-- ---------------------------------------------------------------------------
-- 3d. data.storage_processing_rules — regles per path/MIME
-- tenant_id NULL = regla global. actions és un array JSON d'accions a aplicar.
-- ---------------------------------------------------------------------------
CREATE TABLE data.storage_processing_rules (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        REFERENCES data.tenants(id) ON DELETE CASCADE,
  path_pattern  text,
  mime_pattern  text,
  actions       jsonb       NOT NULL DEFAULT '[]',
  priority      integer     NOT NULL DEFAULT 0,
  is_active     boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 3e. data.node_acl — marca un node com a restringit (candau)
-- Un node amb ACL és VISIBLE però el seu contingut és OCULT per defecte.
-- Els grants (node_acl_grants) determinen qui pot veure-hi dins.
-- node_path es sincronitza automàticament via trigger.
-- ---------------------------------------------------------------------------
CREATE TABLE data.node_acl (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  node_id     uuid        NOT NULL UNIQUE REFERENCES data.file_nodes(id) ON DELETE CASCADE,
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  node_path   text        NOT NULL,
  created_by  uuid        NOT NULL REFERENCES data.profiles(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 3f. data.node_acl_grants — qui pot accedir a un node restringit
-- Cada grant dona accés per user_id o per rol (o ambdós).
-- ---------------------------------------------------------------------------
CREATE TABLE data.node_acl_grants (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  acl_id          uuid        NOT NULL REFERENCES data.node_acl(id) ON DELETE CASCADE,
  grantee_user_id uuid        REFERENCES data.profiles(id) ON DELETE CASCADE,
  grantee_role    text        CHECK (grantee_role IS NULL OR grantee_role IN ('owner','manager','member','viewer')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- Almenys un dels dos ha d'estar informat
  CHECK (grantee_user_id IS NOT NULL OR grantee_role IS NOT NULL)
);

-- ---------------------------------------------------------------------------
-- 3g. data.node_favorites — favorits per usuari
-- ---------------------------------------------------------------------------
CREATE TABLE data.node_favorites (
  user_id     uuid        NOT NULL REFERENCES data.profiles(id) ON DELETE CASCADE,
  node_id     uuid        NOT NULL REFERENCES data.file_nodes(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, node_id)
);


-- =============================================================================
-- 4. MIGRAR DADES data.files → data.file_nodes
-- =============================================================================
-- Migrem ABANS de crear triggers per evitar doble comptabilitat a storage_usage.
-- Tots els fitxers existents van a l'arrel ('/'), status 'done', namespace 'repository'.
-- =============================================================================
INSERT INTO data.file_nodes (
  id, tenant_id, parent_id, created_by, node_type, name, path,
  ancestor_paths, namespace, storage_key, mime_type, size_bytes,
  metadata, processing_status, created_at, updated_at
)
SELECT
  id,
  tenant_id,
  NULL,
  uploaded_by,
  'file',
  file_name,
  '/',
  ARRAY['/'],
  'repository',
  storage_path,
  mime_type,
  size_bytes,
  metadata,
  'done',
  created_at,
  created_at
FROM data.files
ON CONFLICT DO NOTHING;


-- =============================================================================
-- 5. DROP data.files
-- =============================================================================
DROP TABLE data.files CASCADE;


-- =============================================================================
-- 6. FUNCIONS HELPER
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 6a. compute_ancestor_paths(p_path) → text[]
-- Donat un path materialitzat, retorna tots els paths ancestrals.
-- Ex: '/docs/contracts/' → ['/', '/docs/', '/docs/contracts/']
-- Ex: '/' → ['/']
-- IMMUTABLE: no depèn de dades, mateixa entrada sempre = mateixa sortida.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.compute_ancestor_paths(p_path text)
RETURNS text[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_paths text[] := ARRAY['/'];
  v_parts text[];
  v_current text := '/';
  i integer;
BEGIN
  IF p_path IS NULL OR p_path = '/' THEN
    RETURN ARRAY['/'];
  END IF;

  v_parts := string_to_array(trim(both '/' from p_path), '/');

  FOR i IN 1..array_length(v_parts, 1) LOOP
    v_current := v_current || v_parts[i] || '/';
    v_paths := v_paths || v_current;
  END LOOP;

  RETURN v_paths;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6b. compute_node_path() — trigger BEFORE INSERT/UPDATE OF parent_id
-- Calcula el path materialitzat a partir de parent_id.
-- Si parent_id IS NULL → path = '/' (arrel).
-- Si parent_id existeix → path = parent.path || parent.name || '/'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.compute_node_path()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_parent_path text;
  v_parent_name text;
BEGIN
  IF NEW.parent_id IS NULL THEN
    NEW.path := '/';
  ELSE
    SELECT path, name INTO v_parent_path, v_parent_name
    FROM data.file_nodes
    WHERE id = NEW.parent_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'parent_not_found'
        USING HINT = 'El parent_id referenciat no existeix';
    END IF;

    NEW.path := v_parent_path || v_parent_name || '/';
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6c. sync_ancestor_paths() — trigger BEFORE INSERT/UPDATE OF path
-- Computa ancestor_paths a partir del path materialitzat.
-- S'executa DESPRÉS de compute_node_path (ordre alfabètic dels triggers).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.sync_ancestor_paths()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.ancestor_paths := data.compute_ancestor_paths(NEW.path);
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6d. cascade_path_update() — trigger AFTER UPDATE on file_nodes
-- Quan una carpeta canvia de path o nom, propaga el canvi als descendents.
-- Cada descendent actualitzat dispara sync_ancestor_paths automàticament.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.cascade_path_update()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_old_prefix text;
  v_new_prefix text;
BEGIN
  IF NEW.node_type != 'folder' THEN RETURN NULL; END IF;

  v_old_prefix := OLD.path || OLD.name || '/';
  v_new_prefix := NEW.path || NEW.name || '/';

  UPDATE data.file_nodes
  SET path = v_new_prefix || substring(path FROM length(v_old_prefix) + 1)
  WHERE tenant_id = NEW.tenant_id
    AND path LIKE v_old_prefix || '%'
    AND id != NEW.id;

  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6e. sync_acl_node_path() — trigger en node_acl
-- Calcula node_path (path complet del node restringit) quan es crea un ACL.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.sync_acl_node_path()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_node record;
BEGIN
  SELECT node_type, path, name INTO v_node
  FROM data.file_nodes WHERE id = NEW.node_id;

  IF v_node.node_type = 'folder' THEN
    NEW.node_path := v_node.path || v_node.name || '/';
  ELSE
    NEW.node_path := v_node.path || v_node.name;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6f. sync_acl_paths_on_node_change() — trigger AFTER UPDATE en file_nodes
-- Quan el path o nom d'un node canvia, sincronitza el node_path a node_acl.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.sync_acl_paths_on_node_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.node_type = 'folder' THEN
    UPDATE data.node_acl
    SET node_path = NEW.path || NEW.name || '/'
    WHERE node_id = NEW.id;
  ELSE
    UPDATE data.node_acl
    SET node_path = NEW.path || NEW.name
    WHERE node_id = NEW.id;
  END IF;
  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6g. has_no_blocked_ancestor(ancestor_paths, tenant_id) → boolean
-- Retorna TRUE si cap ancestre del node està bloquejat per ACL sense grant
-- per l'usuari actual. Usat a la política RLS de file_nodes.
--
-- SECURITY DEFINER: ha de llegir node_acl i node_acl_grants sense RLS.
-- STABLE: pot ser cachejat dins una mateixa query.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.has_no_blocked_ancestor(
  p_ancestor_paths text[],
  p_tenant_id uuid
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM data.node_acl a
    WHERE a.tenant_id = p_tenant_id
      AND a.node_path = ANY(p_ancestor_paths)
      AND NOT EXISTS (
        SELECT 1 FROM data.node_acl_grants g
        WHERE g.acl_id = a.id
          AND (
            g.grantee_user_id = auth.uid()
            OR g.grantee_role = data.my_role_in(p_tenant_id)
          )
      )
  );
$$;

-- ---------------------------------------------------------------------------
-- 6h. update_file_nodes_storage_usage() — trigger AFTER INSERT/UPDATE/DELETE
-- Manté data.storage_usage amb el model de dos fases:
--   INSERT pending  → reserved_bytes += size
--   INSERT done     → committed_bytes += size, file_count += 1
--   UPDATE pending→done → move reserved → committed, file_count += 1
--   UPDATE done→done (size change) → committed += (new - old)
--   DELETE pending  → reserved_bytes -= size
--   DELETE done     → committed_bytes -= size, file_count -= 1
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.update_file_nodes_storage_usage()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.node_type = 'file' THEN
    IF NEW.processing_status = 'pending' THEN
      INSERT INTO data.storage_usage (tenant_id, file_count, committed_bytes, reserved_bytes)
      VALUES (NEW.tenant_id, 0, 0, NEW.size_bytes)
      ON CONFLICT (tenant_id) DO UPDATE
        SET reserved_bytes = data.storage_usage.reserved_bytes + NEW.size_bytes,
            updated_at     = now();
    ELSE
      INSERT INTO data.storage_usage (tenant_id, file_count, committed_bytes, reserved_bytes)
      VALUES (NEW.tenant_id, 1, NEW.size_bytes, 0)
      ON CONFLICT (tenant_id) DO UPDATE
        SET file_count      = data.storage_usage.file_count + 1,
            committed_bytes = data.storage_usage.committed_bytes + NEW.size_bytes,
            updated_at      = now();
    END IF;

  ELSIF TG_OP = 'UPDATE' AND NEW.node_type = 'file' THEN
    -- Transició pending → confirmat: moure reserved → committed
    IF OLD.processing_status = 'pending' AND NEW.processing_status IN ('done', 'none') THEN
      UPDATE data.storage_usage
      SET file_count      = file_count + 1,
          committed_bytes = committed_bytes + NEW.size_bytes,
          reserved_bytes  = GREATEST(reserved_bytes - OLD.size_bytes, 0),
          updated_at      = now()
      WHERE tenant_id = NEW.tenant_id;

    -- Nova versió del fitxer: size_bytes canvia però l'status es manté no-pending
    ELSIF OLD.processing_status != 'pending' AND NEW.processing_status != 'pending'
      AND OLD.size_bytes IS DISTINCT FROM NEW.size_bytes THEN
      UPDATE data.storage_usage
      SET committed_bytes = committed_bytes + (NEW.size_bytes - OLD.size_bytes),
          updated_at      = now()
      WHERE tenant_id = NEW.tenant_id;
    END IF;

  ELSIF TG_OP = 'DELETE' AND OLD.node_type = 'file' THEN
    IF OLD.processing_status = 'pending' THEN
      UPDATE data.storage_usage
      SET reserved_bytes = GREATEST(reserved_bytes - OLD.size_bytes, 0),
          updated_at     = now()
      WHERE tenant_id = OLD.tenant_id;
    ELSE
      UPDATE data.storage_usage
      SET file_count      = GREATEST(file_count - 1, 0),
          committed_bytes = GREATEST(committed_bytes - OLD.size_bytes, 0),
          updated_at      = now()
      WHERE tenant_id = OLD.tenant_id;
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6i. check_pending_upload_limit() — trigger BEFORE INSERT
-- Limita a 50 uploads pendents per tenant per evitar abús de quota.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.check_pending_upload_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_pending_count integer;
BEGIN
  IF NEW.processing_status = 'pending' THEN
    SELECT count(*) INTO v_pending_count
    FROM data.file_nodes
    WHERE tenant_id = NEW.tenant_id
      AND processing_status = 'pending';

    IF v_pending_count >= 50 THEN
      RAISE EXCEPTION 'pending_upload_limit_exceeded'
        USING HINT = 'Màxim 50 uploads pendents per tenant';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6j. hard_delete_node(node_id, tenant_id) → integer
-- SECURITY DEFINER — només accessible via Edge Functions (service_role).
-- 1. Envia missatges a pgmq per neteja d'Storage
-- 2. DELETE del node (CASCADE elimina descendents)
-- 3. El trigger de storage_usage allibera la quota a l'instant
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.hard_delete_node(p_node_id uuid, p_tenant_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_node record;
  v_node_path text;
  v_count integer;
  v_file record;
BEGIN
  SELECT * INTO v_node FROM data.file_nodes
  WHERE id = p_node_id AND tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'node_not_found';
  END IF;

  IF v_node.namespace = 'system' THEN
    RAISE EXCEPTION 'system_node_protected';
  END IF;

  -- Calcular prefix de descendents per carpetes
  IF v_node.node_type = 'folder' THEN
    v_node_path := v_node.path || v_node.name || '/';
  END IF;

  -- Encuar fitxers per a esborrat físic d'Storage via pgmq
  FOR v_file IN
    SELECT fn.id, fn.tenant_id, fn.storage_provider_id, fn.storage_key
    FROM data.file_nodes fn
    WHERE fn.tenant_id = p_tenant_id
      AND fn.node_type = 'file'
      AND fn.storage_key IS NOT NULL
      AND (
        fn.id = p_node_id
        OR (v_node_path IS NOT NULL AND v_node_path = ANY(fn.ancestor_paths))
      )
  LOOP
    PERFORM pgmq.send('trash_deletion_queue', jsonb_build_object(
      'file_node_id',        v_file.id,
      'tenant_id',           v_file.tenant_id,
      'storage_provider_id', v_file.storage_provider_id,
      'storage_key',         v_file.storage_key
    ));
  END LOOP;

  -- Comptar nodes afectats ABANS del DELETE
  IF v_node.node_type = 'folder' THEN
    SELECT count(*) INTO v_count FROM data.file_nodes
    WHERE tenant_id = p_tenant_id
      AND (id = p_node_id OR v_node_path = ANY(ancestor_paths));
  ELSE
    v_count := 1;
  END IF;

  -- Eliminar node (ON DELETE CASCADE propaga als descendents)
  -- El trigger trg_file_nodes_storage_usage allibera la quota per cada fila eliminada
  DELETE FROM data.file_nodes WHERE id = p_node_id;

  RETURN v_count;
END;
$$;

-- Restringir accés: només service_role (Edge Functions)
REVOKE ALL ON FUNCTION data.hard_delete_node(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.hard_delete_node(uuid, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION data.hard_delete_node(uuid, uuid) FROM anon;

-- ---------------------------------------------------------------------------
-- 6k. process_expired_trash() — helper per pg_cron
-- Encua fitxers de la papelera expirada (> 30 dies) a pgmq,
-- després els elimina de file_nodes (trigger actualitza quota).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.process_expired_trash()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_file record;
BEGIN
  -- Encuar fitxers amb storage_key per a esborrat físic
  FOR v_file IN
    SELECT fn.id, fn.tenant_id, fn.storage_provider_id, fn.storage_key
    FROM data.file_nodes fn
    WHERE fn.is_deleted = true
      AND fn.deleted_at < now() - interval '30 days'
      AND fn.node_type = 'file'
      AND fn.storage_key IS NOT NULL
  LOOP
    PERFORM pgmq.send('trash_deletion_queue', jsonb_build_object(
      'file_node_id',        v_file.id,
      'tenant_id',           v_file.tenant_id,
      'storage_provider_id', v_file.storage_provider_id,
      'storage_key',         v_file.storage_key
    ));
  END LOOP;

  -- Eliminar nodes expirats (trigger actualitza quota)
  DELETE FROM data.file_nodes
  WHERE is_deleted = true
    AND deleted_at < now() - interval '30 days';
END;
$$;

REVOKE ALL ON FUNCTION data.process_expired_trash() FROM PUBLIC;
REVOKE ALL ON FUNCTION data.process_expired_trash() FROM authenticated;
REVOKE ALL ON FUNCTION data.process_expired_trash() FROM anon;

-- ---------------------------------------------------------------------------
-- 6l. cleanup_pending_uploads() — helper per pg_cron
-- Neteja uploads pendents expirats. Encua els que tenen storage_key per
-- esborrar el fitxer real que ja s'havia pujat però no confirmat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.cleanup_pending_uploads()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_file record;
BEGIN
  FOR v_file IN
    SELECT fn.id, fn.tenant_id, fn.storage_provider_id, fn.storage_key
    FROM data.file_nodes fn
    WHERE fn.processing_status = 'pending'
      AND fn.upload_expires_at < now()
      AND fn.storage_key IS NOT NULL
  LOOP
    PERFORM pgmq.send('trash_deletion_queue', jsonb_build_object(
      'file_node_id',        v_file.id,
      'tenant_id',           v_file.tenant_id,
      'storage_provider_id', v_file.storage_provider_id,
      'storage_key',         v_file.storage_key
    ));
  END LOOP;

  DELETE FROM data.file_nodes
  WHERE processing_status = 'pending'
    AND upload_expires_at < now();
END;
$$;

REVOKE ALL ON FUNCTION data.cleanup_pending_uploads() FROM PUBLIC;
REVOKE ALL ON FUNCTION data.cleanup_pending_uploads() FROM authenticated;
REVOKE ALL ON FUNCTION data.cleanup_pending_uploads() FROM anon;


-- =============================================================================
-- 7. TRIGGERS
-- =============================================================================

-- updated_at (reutilitza data.set_updated_at() de migració 2)
CREATE TRIGGER trg_file_nodes_updated_at
  BEFORE UPDATE ON data.file_nodes
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_storage_providers_updated_at
  BEFORE UPDATE ON data.storage_providers
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_storage_processing_rules_updated_at
  BEFORE UPDATE ON data.storage_processing_rules
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- Path computation: ordre alfabètic garanteix a→b
-- trg_a: calcula path des de parent_id
CREATE TRIGGER trg_a_file_nodes_compute_path
  BEFORE INSERT OR UPDATE OF parent_id ON data.file_nodes
  FOR EACH ROW EXECUTE FUNCTION data.compute_node_path();

-- trg_b: calcula ancestor_paths des de path (s'executa DESPRÉS de trg_a)
CREATE TRIGGER trg_b_file_nodes_sync_ancestors
  BEFORE INSERT OR UPDATE OF path ON data.file_nodes
  FOR EACH ROW EXECUTE FUNCTION data.sync_ancestor_paths();

-- Propagar canvis de path als descendents
CREATE TRIGGER trg_c_file_nodes_cascade_paths
  AFTER UPDATE ON data.file_nodes
  FOR EACH ROW
  WHEN (OLD.path IS DISTINCT FROM NEW.path OR OLD.name IS DISTINCT FROM NEW.name)
  EXECUTE FUNCTION data.cascade_path_update();

-- Sincronitzar node_path a node_acl quan canvia path/name
CREATE TRIGGER trg_d_file_nodes_sync_acl_paths
  AFTER UPDATE ON data.file_nodes
  FOR EACH ROW
  WHEN (OLD.path IS DISTINCT FROM NEW.path OR OLD.name IS DISTINCT FROM NEW.name)
  EXECUTE FUNCTION data.sync_acl_paths_on_node_change();

-- Calcular node_path en inserir ACL
CREATE TRIGGER trg_node_acl_sync_path
  BEFORE INSERT OR UPDATE OF node_id ON data.node_acl
  FOR EACH ROW EXECUTE FUNCTION data.sync_acl_node_path();

-- Storage usage (dos fases)
CREATE TRIGGER trg_file_nodes_storage_usage
  AFTER INSERT OR UPDATE OR DELETE ON data.file_nodes
  FOR EACH ROW EXECUTE FUNCTION data.update_file_nodes_storage_usage();

-- Límit d'uploads pendents
CREATE TRIGGER trg_file_nodes_pending_limit
  BEFORE INSERT ON data.file_nodes
  FOR EACH ROW EXECUTE FUNCTION data.check_pending_upload_limit();


-- =============================================================================
-- 8. ÍNDEXS
-- =============================================================================

-- Noms únics per carpeta (parcial: only non-deleted, handles NULL parent_id)
CREATE UNIQUE INDEX idx_file_nodes_unique_name
  ON data.file_nodes (tenant_id, COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), name)
  WHERE is_deleted = false;

-- Lookups bàsics
CREATE INDEX idx_file_nodes_tenant     ON data.file_nodes (tenant_id);
CREATE INDEX idx_file_nodes_parent     ON data.file_nodes (parent_id);
CREATE INDEX idx_file_nodes_created_by ON data.file_nodes (created_by);

-- GIN: ancestor_paths per ACL checks i cascades
CREATE INDEX idx_file_nodes_ancestor_paths ON data.file_nodes USING GIN (ancestor_paths);

-- GIN: trigram per cerca aproximada de noms
CREATE INDEX idx_file_nodes_name_trgm ON data.file_nodes USING GIN (name gin_trgm_ops);

-- GIN: metadata JSONB
CREATE INDEX idx_file_nodes_metadata ON data.file_nodes USING GIN (metadata jsonb_path_ops);

-- Recent files (parcial: només fitxers no esborrats i processats)
CREATE INDEX idx_file_nodes_recent
  ON data.file_nodes (tenant_id, updated_at DESC)
  WHERE is_deleted = false AND node_type = 'file' AND processing_status IN ('none', 'done');

-- Pending uploads (per cleanup cron)
CREATE INDEX idx_file_nodes_pending
  ON data.file_nodes (upload_expires_at)
  WHERE processing_status = 'pending';

-- Soft-deleted nodes (per trash cron)
CREATE INDEX idx_file_nodes_deleted
  ON data.file_nodes (deleted_at)
  WHERE is_deleted = true;

-- Favorits per usuari
CREATE INDEX idx_node_favorites_user ON data.node_favorites (user_id, created_at DESC);

-- ACL lookups
CREATE INDEX idx_node_acl_tenant    ON data.node_acl (tenant_id);
CREATE INDEX idx_node_acl_node_path ON data.node_acl (node_path);

-- ACL grants per acl_id
CREATE INDEX idx_node_acl_grants_acl ON data.node_acl_grants (acl_id);


-- =============================================================================
-- 9. RLS — ENABLE + POLÍTIQUES
-- =============================================================================

ALTER TABLE data.file_nodes              ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.storage_providers       ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.storage_path_usage      ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.storage_processing_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.node_acl                ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.node_acl_grants         ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.node_favorites          ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- file_nodes
-- ---------------------------------------------------------------------------

-- SELECT: l'usuari veu nodes dels seus tenants.
-- Nodes NO esborrats: filtra per processing_status i ACL (efecte candau).
-- Nodes esborrats: visibles sense ACL (per a la vista trash).
CREATE POLICY "file_nodes: veure nodes dels teus tenants"
  ON data.file_nodes FOR SELECT
  TO authenticated
  USING (
    tenant_id = ANY(data.my_tenant_ids())
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      -- Nodes actius: status vàlid + ACL check
      (
        is_deleted = false
        AND (
          processing_status IN ('none', 'done', 'processing', 'error')
          OR (processing_status = 'pending' AND created_by = auth.uid())
        )
        AND data.has_no_blocked_ancestor(ancestor_paths, tenant_id)
      )
      OR
      -- Nodes esborrats: visibles per a la vista trash (sense ACL)
      is_deleted = true
    )
  );

-- INSERT: owner/manager/member global, o rol d'escriptura en el site destí
CREATE POLICY "file_nodes: owner/manager/member poden crear"
  ON data.file_nodes FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND created_by = auth.uid()
    AND namespace = 'repository'
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager', 'member')
      OR
      (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text)
              IN ('owner', 'manager', 'member')
      )
    )
  );

-- UPDATE: l'autor o owner/manager globals, namespace 'repository'
CREATE POLICY "file_nodes: actualitzar nodes del repositori"
  ON data.file_nodes FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND namespace = 'repository'
    AND (
      created_by = auth.uid()
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    namespace = 'repository'
  );

-- DELETE: prohibit per authenticated. Només via funcions SECURITY DEFINER (service_role).
CREATE POLICY "file_nodes: no delete directe"
  ON data.file_nodes FOR DELETE
  TO authenticated
  USING (false);

-- ---------------------------------------------------------------------------
-- storage_providers
-- ---------------------------------------------------------------------------
CREATE POLICY "storage_providers: owner/manager veuen"
  ON data.storage_providers FOR SELECT
  TO authenticated
  USING (
    tenant_id = ANY(data.my_tenant_ids())
    AND data.my_role_in(tenant_id) IN ('owner', 'manager')
  );

-- INSERT: owner pot configurar, secret_key_id ha de ser NULL (Vault via Edge Function)
CREATE POLICY "storage_providers: owner pot configurar"
  ON data.storage_providers FOR INSERT
  TO authenticated
  WITH CHECK (
    data.my_role_in(tenant_id) = 'owner'
    AND secret_key_id IS NULL
  );

CREATE POLICY "storage_providers: owner pot actualitzar"
  ON data.storage_providers FOR UPDATE
  TO authenticated
  USING  (data.my_role_in(tenant_id) = 'owner')
  WITH CHECK (data.my_role_in(tenant_id) = 'owner');

-- ---------------------------------------------------------------------------
-- storage_path_usage
-- ---------------------------------------------------------------------------
CREATE POLICY "storage_path_usage: owner/manager veuen"
  ON data.storage_path_usage FOR SELECT
  TO authenticated
  USING (
    tenant_id = ANY(data.my_tenant_ids())
    AND data.my_role_in(tenant_id) IN ('owner', 'manager')
  );

-- ---------------------------------------------------------------------------
-- storage_processing_rules
-- ---------------------------------------------------------------------------
CREATE POLICY "storage_processing_rules: veuen regles"
  ON data.storage_processing_rules FOR SELECT
  TO authenticated
  USING (
    tenant_id IS NULL
    OR (
      tenant_id = ANY(data.my_tenant_ids())
      AND data.my_role_in(tenant_id) IN ('owner', 'manager')
    )
  );

-- ---------------------------------------------------------------------------
-- node_acl
-- ---------------------------------------------------------------------------
CREATE POLICY "node_acl: membres veuen ACL"
  ON data.node_acl FOR SELECT
  TO authenticated
  USING (tenant_id = ANY(data.my_tenant_ids()));

CREATE POLICY "node_acl: owner/manager poden crear"
  ON data.node_acl FOR INSERT
  TO authenticated
  WITH CHECK (
    data.my_role_in(tenant_id) IN ('owner', 'manager')
    AND created_by = auth.uid()
  );

CREATE POLICY "node_acl: owner/manager poden eliminar"
  ON data.node_acl FOR DELETE
  TO authenticated
  USING (data.my_role_in(tenant_id) IN ('owner', 'manager'));

-- ---------------------------------------------------------------------------
-- node_acl_grants
-- ---------------------------------------------------------------------------
CREATE POLICY "node_acl_grants: veuen grants"
  ON data.node_acl_grants FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.node_acl a
      WHERE a.id = acl_id AND a.tenant_id = ANY(data.my_tenant_ids())
    )
  );

CREATE POLICY "node_acl_grants: owner/manager gestionen"
  ON data.node_acl_grants FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.node_acl a
      WHERE a.id = acl_id AND data.my_role_in(a.tenant_id) IN ('owner', 'manager')
    )
  );

CREATE POLICY "node_acl_grants: owner/manager eliminen"
  ON data.node_acl_grants FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.node_acl a
      WHERE a.id = acl_id AND data.my_role_in(a.tenant_id) IN ('owner', 'manager')
    )
  );

-- ---------------------------------------------------------------------------
-- node_favorites
-- ---------------------------------------------------------------------------
CREATE POLICY "node_favorites: veure pròpies"
  ON data.node_favorites FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "node_favorites: crear"
  ON data.node_favorites FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "node_favorites: eliminar"
  ON data.node_favorites FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- storage_usage — actualitzar política per nous camps
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "storage_usage: owner/manager veuen l'ús" ON data.storage_usage;

CREATE POLICY "storage_usage: owner/manager veuen l'ús"
  ON data.storage_usage FOR SELECT
  TO authenticated
  USING (
    tenant_id = ANY(data.my_tenant_ids())
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.my_role_in(tenant_id) IN ('owner', 'manager')
  );


-- =============================================================================
-- 10. GRANTS
-- =============================================================================
GRANT SELECT, INSERT, UPDATE   ON data.file_nodes               TO authenticated;
GRANT SELECT, INSERT, UPDATE   ON data.storage_providers         TO authenticated;
GRANT SELECT                   ON data.storage_path_usage        TO authenticated;
GRANT SELECT                   ON data.storage_processing_rules  TO authenticated;
GRANT SELECT, INSERT, DELETE   ON data.node_acl                  TO authenticated;
GRANT SELECT, INSERT, DELETE   ON data.node_acl_grants           TO authenticated;
GRANT SELECT, INSERT, DELETE   ON data.node_favorites            TO authenticated;


-- =============================================================================
-- 11. VISTES api.*
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 11a. api.file_nodes — navegador de fitxers
-- Mostra nodes actius (no esborrats) amb indicadors ACL.
-- is_restricted: el node té un ACL (candau visible)
-- can_access_for_me: l'usuari té grant per veure-hi dins
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.file_nodes
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
    -- Efecte candau: indicadors per al frontend
    EXISTS (
      SELECT 1 FROM data.node_acl a WHERE a.node_id = fn.id
    ) AS is_restricted,
    CASE
      WHEN EXISTS (SELECT 1 FROM data.node_acl a WHERE a.node_id = fn.id)
      THEN EXISTS (
        SELECT 1 FROM data.node_acl a
        JOIN data.node_acl_grants g ON g.acl_id = a.id
        WHERE a.node_id = fn.id
          AND (
            g.grantee_user_id = auth.uid()
            OR g.grantee_role = data.my_role_in(fn.tenant_id)
          )
      )
      ELSE true
    END AS can_access_for_me
  FROM data.file_nodes fn
  WHERE fn.is_deleted = false;

GRANT SELECT, INSERT, UPDATE ON api.file_nodes TO authenticated;

-- Regles per fer la vista writable via PostgREST
CREATE RULE "api_file_nodes_insert" AS ON INSERT TO api.file_nodes
  DO INSTEAD
  INSERT INTO data.file_nodes (
    tenant_id, parent_id, created_by, node_type, name,
    namespace, mime_type, size_bytes, metadata
  )
  VALUES (
    NEW.tenant_id, NEW.parent_id, auth.uid(), NEW.node_type, NEW.name,
    COALESCE(NEW.namespace, 'repository'), NEW.mime_type, COALESCE(NEW.size_bytes, 0), NEW.metadata
  )
  RETURNING
    id, tenant_id, parent_id, created_by, node_type, name, path,
    namespace, mime_type, size_bytes, checksum, processing_status,
    metadata, created_at, updated_at, storage_key,
    false AS is_restricted,
    true  AS can_access_for_me;

CREATE RULE "api_file_nodes_update" AS ON UPDATE TO api.file_nodes
  DO INSTEAD
  UPDATE data.file_nodes
  SET name     = COALESCE(NEW.name, OLD.name),
      metadata = COALESCE(NEW.metadata, OLD.metadata)
  WHERE id = OLD.id
  RETURNING
    id, tenant_id, parent_id, created_by, node_type, name, path,
    namespace, mime_type, size_bytes, checksum, processing_status,
    metadata, created_at, updated_at, storage_key,
    false AS is_restricted,
    true  AS can_access_for_me;

-- ---------------------------------------------------------------------------
-- 11b. api.trash — papelera
-- Només nodes de primer nivell esborrats (no fills en cascada).
-- Un node és "top-level" si el seu pare no existeix o no està esborrat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.trash
  WITH (security_invoker = true) AS
  SELECT
    fn.id,
    fn.tenant_id,
    fn.parent_id,
    fn.storage_provider_id,
    fn.node_type,
    fn.name,
    fn.path,
    fn.mime_type,
    fn.size_bytes,
    fn.deleted_at,
    fn.deleted_by,
    fn.created_at
  FROM data.file_nodes fn
  WHERE fn.is_deleted = true
    AND (
      fn.parent_id IS NULL
      OR NOT EXISTS (
        SELECT 1 FROM data.file_nodes p
        WHERE p.id = fn.parent_id AND p.is_deleted = true
      )
    );

GRANT SELECT ON api.trash TO authenticated;

-- ---------------------------------------------------------------------------
-- 11c. api.starred_files — fitxers favorits de l'usuari
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.starred_files
  WITH (security_invoker = true) AS
  SELECT
    fn.id,
    fn.tenant_id,
    fn.parent_id,
    fn.storage_provider_id,
    fn.node_type,
    fn.name,
    fn.path,
    fn.mime_type,
    fn.size_bytes,
    fn.created_at,
    fn.updated_at,
    nf.created_at AS starred_at,
    fn.storage_key
  FROM data.node_favorites nf
  JOIN data.file_nodes fn ON fn.id = nf.node_id
  WHERE nf.user_id = auth.uid()
    AND fn.is_deleted = false;

GRANT SELECT ON api.starred_files TO authenticated;

-- ---------------------------------------------------------------------------
-- 11d. api.node_favorites — CRUD de favorits
-- Vista simple per INSERT/DELETE des de PostgREST.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.node_favorites
  WITH (security_invoker = true) AS
  SELECT node_id, created_at
  FROM data.node_favorites;

GRANT SELECT, INSERT, DELETE ON api.node_favorites TO authenticated;

CREATE RULE "api_node_favorites_insert" AS ON INSERT TO api.node_favorites
  DO INSTEAD
  INSERT INTO data.node_favorites (user_id, node_id)
  VALUES (auth.uid(), NEW.node_id)
  ON CONFLICT (user_id, node_id) DO NOTHING;

CREATE RULE "api_node_favorites_delete" AS ON DELETE TO api.node_favorites
  DO INSTEAD
  DELETE FROM data.node_favorites
  WHERE user_id = auth.uid() AND node_id = OLD.node_id;

CREATE OR REPLACE FUNCTION api.star_node(p_node_id uuid)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS 'INSERT INTO data.node_favorites (user_id, node_id)
    VALUES (auth.uid(), p_node_id)
    ON CONFLICT (user_id, node_id) DO NOTHING;';

CREATE OR REPLACE FUNCTION api.unstar_node(p_node_id uuid)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS 'DELETE FROM data.node_favorites
    WHERE user_id = auth.uid()
      AND node_id = p_node_id;';

GRANT EXECUTE ON FUNCTION api.star_node(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.unstar_node(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 11e. api.recent_files — fitxers recents
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.recent_files
  WITH (security_invoker = true) AS
  SELECT
    fn.id,
    fn.tenant_id,
    fn.parent_id,
    fn.node_type,
    fn.name,
    fn.path,
    fn.mime_type,
    fn.size_bytes,
    fn.created_at,
    fn.updated_at
  FROM data.file_nodes fn
  WHERE fn.is_deleted = false
    AND fn.node_type = 'file'
    AND fn.processing_status IN ('none', 'done')
  ORDER BY fn.updated_at DESC;

GRANT SELECT ON api.recent_files TO authenticated;

-- ---------------------------------------------------------------------------
-- 11f. api.my_files — els meus fitxers (amb nom del tenant)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.my_files
  WITH (security_invoker = true) AS
  SELECT
    fn.id,
    fn.tenant_id,
    fn.node_type,
    fn.name,
    fn.path,
    fn.mime_type,
    fn.size_bytes,
    fn.created_at,
    fn.updated_at,
    t.name AS tenant_name,
    t.slug AS tenant_slug
  FROM data.file_nodes fn
  JOIN data.tenants t ON t.id = fn.tenant_id
  WHERE fn.created_by = auth.uid()
    AND fn.is_deleted = false
    AND fn.processing_status IN ('none', 'done');

GRANT SELECT ON api.my_files TO authenticated;

-- ---------------------------------------------------------------------------
-- 11g. api.storage_provider — configuració BYOS (sense secret_key_id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.storage_provider
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    provider_type,
    endpoint_url,
    bucket_name,
    region,
    is_verified,
    is_active,
    created_at,
    updated_at
    -- secret_key_id MAI exposat
  FROM data.storage_providers;

GRANT SELECT, INSERT, UPDATE ON api.storage_provider TO authenticated;

CREATE RULE "api_storage_provider_insert" AS ON INSERT TO api.storage_provider
  DO INSTEAD
  INSERT INTO data.storage_providers (
    tenant_id, provider_type, endpoint_url, bucket_name, access_key, region
  )
  VALUES (
    NEW.tenant_id, COALESCE(NEW.provider_type, 'supabase'),
    NEW.endpoint_url, NEW.bucket_name, NULL, NEW.region
  );

CREATE RULE "api_storage_provider_update" AS ON UPDATE TO api.storage_provider
  DO INSTEAD
  UPDATE data.storage_providers
  SET provider_type = COALESCE(NEW.provider_type, OLD.provider_type),
      endpoint_url  = NEW.endpoint_url,
      bucket_name   = NEW.bucket_name,
      region        = NEW.region
  WHERE id = OLD.id;

-- ---------------------------------------------------------------------------
-- 11h. api.storage_usage — ús de storage (recreada amb nous camps)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.storage_usage
  WITH (security_invoker = true) AS
  SELECT
    tenant_id,
    file_count,
    committed_bytes,
    reserved_bytes,
    committed_bytes + reserved_bytes AS total_bytes,
    round((committed_bytes + reserved_bytes)::numeric / 1048576, 2) AS total_mb,
    updated_at
  FROM data.storage_usage;

GRANT SELECT ON api.storage_usage TO authenticated;


-- =============================================================================
-- 12. FUNCIONS RPC (exposades via PostgREST)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 12a. api.search_files — cerca per nom amb pg_trgm
-- Retorna fins a 50 resultats ordenats per rellevància (similarity).
-- El GIN index gin_trgm_ops suporta ILIKE '%query%' eficientment.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.search_files(p_query text, p_tenant_id uuid)
RETURNS TABLE (
  id uuid,
  tenant_id uuid,
  parent_id uuid,
  node_type text,
  name text,
  path text,
  mime_type text,
  size_bytes bigint,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql STABLE SECURITY INVOKER AS $$
  SELECT
    fn.id, fn.tenant_id, fn.parent_id, fn.node_type,
    fn.name, fn.path, fn.mime_type, fn.size_bytes,
    fn.created_at, fn.updated_at
  FROM data.file_nodes fn
  WHERE fn.tenant_id = p_tenant_id
    AND fn.is_deleted = false
    AND fn.processing_status IN ('none', 'done')
    AND fn.name ILIKE '%' || p_query || '%'
  ORDER BY similarity(fn.name, p_query) DESC
  LIMIT 50;
$$;

GRANT EXECUTE ON FUNCTION api.search_files(text, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 12b. api.trash_node — moure a papelera o eliminar definitivament
-- SECURITY DEFINER per poder fer UPDATE/DELETE malgrat les polítiques RLS.
-- Comprova permisos: owner/manager qualsevol, member només el propi.
--
-- force_permanent = false (defecte): soft delete (papelera amb 30 dies)
-- force_permanent = true: hard delete immediat + encua a pgmq per cleanup Storage
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.trash_node(
  p_node_id uuid,
  force_permanent boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_node record;
  v_role text;
  v_node_path text;
  v_count integer := 0;
  v_descendants integer;
  v_file record;
BEGIN
  -- Obtenir el node
  SELECT * INTO v_node FROM data.file_nodes
  WHERE id = p_node_id AND is_deleted = false;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'node_not_found'
      USING HINT = 'El node no existeix o ja està a la papelera';
  END IF;

  -- Comprovar permisos
  v_role := data.my_role_in(v_node.tenant_id);
  IF v_role IS NULL OR v_role = 'viewer' THEN
    RAISE EXCEPTION 'forbidden'
      USING HINT = 'No tens permisos per esborrar aquest node';
  END IF;

  -- Members només poden esborrar els seus propis nodes
  IF v_role = 'member' AND v_node.created_by != auth.uid() THEN
    RAISE EXCEPTION 'forbidden'
      USING HINT = 'Els membres només poden esborrar els seus propis fitxers';
  END IF;

  -- Nodes del sistema protegits
  IF v_node.namespace = 'system' THEN
    RAISE EXCEPTION 'system_node_protected'
      USING HINT = 'Els nodes del sistema no es poden esborrar';
  END IF;

  -- Calcular prefix de descendents per carpetes
  IF v_node.node_type = 'folder' THEN
    v_node_path := v_node.path || v_node.name || '/';
  END IF;

  -- ===== MODE PERMANENT =====
  IF force_permanent THEN
    -- Comptar nodes afectats ABANS del DELETE
    IF v_node.node_type = 'folder' THEN
      SELECT count(*) INTO v_count FROM data.file_nodes
      WHERE tenant_id = v_node.tenant_id
        AND (id = p_node_id OR v_node_path = ANY(ancestor_paths));
    ELSE
      v_count := 1;
    END IF;

    -- Encuar fitxers per a esborrat físic d'Storage via pgmq
    FOR v_file IN
      SELECT fn.id, fn.tenant_id, fn.storage_provider_id, fn.storage_key
      FROM data.file_nodes fn
      WHERE fn.tenant_id = v_node.tenant_id
        AND fn.node_type = 'file'
        AND fn.storage_key IS NOT NULL
        AND (
          fn.id = p_node_id
          OR (v_node_path IS NOT NULL AND v_node_path = ANY(fn.ancestor_paths))
        )
    LOOP
      PERFORM pgmq.send('trash_deletion_queue', jsonb_build_object(
        'file_node_id',        v_file.id,
        'tenant_id',           v_file.tenant_id,
        'storage_provider_id', v_file.storage_provider_id,
        'storage_key',         v_file.storage_key
      ));
    END LOOP;

    -- Eliminar node (ON DELETE CASCADE propaga als descendents)
    -- El trigger trg_file_nodes_storage_usage allibera la quota a l'instant
    DELETE FROM data.file_nodes WHERE id = p_node_id;

    RETURN v_count;
  END IF;

  -- ===== MODE PAPELERA (soft delete) =====
  UPDATE data.file_nodes
  SET is_deleted = true, deleted_at = now(), deleted_by = auth.uid()
  WHERE id = p_node_id;
  v_count := 1;

  -- Cascada als descendents si és carpeta
  IF v_node.node_type = 'folder' THEN
    WITH deleted AS (
      UPDATE data.file_nodes
      SET is_deleted = true, deleted_at = now(), deleted_by = auth.uid()
      WHERE tenant_id = v_node.tenant_id
        AND is_deleted = false
        AND v_node_path = ANY(ancestor_paths)
      RETURNING 1
    )
    SELECT count(*) INTO v_descendants FROM deleted;
    v_count := v_count + v_descendants;
  END IF;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.trash_node(uuid, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- 12c. api.restore_node — restaurar un node des de la papelera
-- SECURITY DEFINER per poder fer UPDATE de is_deleted.
-- Comprova que el pare no estigui a la papelera (si ho està → excepció).
-- Cascada: si és carpeta, restaura descendents via ancestor_paths GIN.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.restore_node(p_node_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_node record;
  v_parent record;
  v_role text;
  v_node_path text;
  v_count integer := 0;
  v_descendants integer;
BEGIN
  -- Obtenir el node esborrat
  SELECT * INTO v_node FROM data.file_nodes
  WHERE id = p_node_id AND is_deleted = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'node_not_found'
      USING HINT = 'El node no existeix o no està a la papelera';
  END IF;

  -- Comprovar permisos
  v_role := data.my_role_in(v_node.tenant_id);
  IF v_role IS NULL OR v_role = 'viewer' THEN
    RAISE EXCEPTION 'forbidden'
      USING HINT = 'No tens permisos per restaurar aquest node';
  END IF;

  -- Comprovar que el pare no estigui a la papelera
  IF v_node.parent_id IS NOT NULL THEN
    SELECT * INTO v_parent FROM data.file_nodes
    WHERE id = v_node.parent_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'parent_not_found'
        USING HINT = 'La carpeta pare ja no existeix. El node no es pot restaurar.';
    END IF;

    IF v_parent.is_deleted THEN
      RAISE EXCEPTION 'parent_still_deleted'
        USING HINT = format(
          'No es pot restaurar: la carpeta pare "%s" encara està a la papelera. Restaura-la primer.',
          v_parent.name
        );
    END IF;
  END IF;

  -- Restaurar el node
  UPDATE data.file_nodes
  SET is_deleted = false, deleted_at = NULL, deleted_by = NULL
  WHERE id = p_node_id;
  v_count := 1;

  -- Cascada als descendents si és carpeta
  IF v_node.node_type = 'folder' THEN
    v_node_path := v_node.path || v_node.name || '/';
    WITH restored AS (
      UPDATE data.file_nodes
      SET is_deleted = false, deleted_at = NULL, deleted_by = NULL
      WHERE tenant_id = v_node.tenant_id
        AND is_deleted = true
        AND v_node_path = ANY(ancestor_paths)
      RETURNING 1
    )
    SELECT count(*) INTO v_descendants FROM restored;
    v_count := v_count + v_descendants;
  END IF;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.restore_node(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 12d. api.check_upload_eligibility — Kill Switch + Quota en 1 sola query
-- SECURITY DEFINER per llegir tenants, plans i storage_usage sense RLS.
-- Usada per l'Edge Function request-upload via adminClient.rpc().
-- Només service_role pot cridar-la (REVOKE de authenticated/anon).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.check_upload_eligibility(
  p_tenant_id uuid,
  p_size_bytes bigint
)
RETURNS TABLE (
  storage_blocked boolean,
  storage_blocked_reason text,
  quota_exceeded boolean,
  current_bytes bigint,
  max_bytes bigint
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT
    t.storage_blocked,
    t.storage_blocked_reason,
    CASE
      WHEN p.max_storage_mb IS NULL THEN false
      ELSE (COALESCE(su.committed_bytes, 0) + COALESCE(su.reserved_bytes, 0) + p_size_bytes)
           > (p.max_storage_mb::bigint * 1024 * 1024)
    END AS quota_exceeded,
    COALESCE(su.committed_bytes, 0) + COALESCE(su.reserved_bytes, 0) AS current_bytes,
    COALESCE(p.max_storage_mb::bigint * 1024 * 1024, 0) AS max_bytes
  FROM data.tenants t
  LEFT JOIN data.plans p ON p.id = t.plan_id
  LEFT JOIN data.storage_usage su ON su.tenant_id = t.id
  WHERE t.id = p_tenant_id;
$$;

-- Només service_role (Edge Functions) pot cridar-la
REVOKE ALL ON FUNCTION api.check_upload_eligibility(uuid, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.check_upload_eligibility(uuid, bigint) FROM authenticated;
REVOKE ALL ON FUNCTION api.check_upload_eligibility(uuid, bigint) FROM anon;
GRANT EXECUTE ON FUNCTION api.check_upload_eligibility(uuid, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 12e. api.create_pending_upload — INSERT a data.file_nodes amb tots els camps
-- SECURITY DEFINER per poder escriure directament a data.file_nodes (no via la vista).
-- Només service_role pot cridar-la.
-- Retorna el node_id creat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_pending_upload(
  p_id uuid,
  p_tenant_id uuid,
  p_parent_id uuid,
  p_created_by uuid,
  p_name text,
  p_storage_provider_id uuid,
  p_storage_key text,
  p_mime_type text,
  p_size_bytes bigint,
  p_upload_expires_at timestamptz,
  p_metadata jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
BEGIN
  -- Remove any orphaned pending node with the same name in the same folder.
  -- These are artifacts of upload attempts that never reached confirm-upload
  -- (network failure, CORS error, browser tab closed mid-upload, etc.).
  -- Safe to hard-delete: pending nodes have no confirmed storage object, no
  -- child nodes and no share references.
  DELETE FROM data.file_nodes
  WHERE tenant_id = p_tenant_id
    AND COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid)
        = COALESCE(p_parent_id, '00000000-0000-0000-0000-000000000000'::uuid)
    AND name = p_name
    AND is_deleted = false
    AND processing_status = 'pending';

  INSERT INTO data.file_nodes (
    id, tenant_id, parent_id, created_by, node_type, name,
    namespace, storage_provider_id, storage_key, mime_type, size_bytes,
    processing_status, upload_expires_at, metadata
  ) VALUES (
    p_id, p_tenant_id, p_parent_id, p_created_by, 'file', p_name,
    'repository', p_storage_provider_id, p_storage_key, p_mime_type, p_size_bytes,
    'pending', p_upload_expires_at, p_metadata
  );
  RETURN p_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_pending_upload(uuid, uuid, uuid, uuid, text, uuid, text, text, bigint, timestamptz, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.create_pending_upload(uuid, uuid, uuid, uuid, text, uuid, text, text, bigint, timestamptz, jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION api.create_pending_upload(uuid, uuid, uuid, uuid, text, uuid, text, text, bigint, timestamptz, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION api.create_pending_upload(uuid, uuid, uuid, uuid, text, uuid, text, text, bigint, timestamptz, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 12f. api.get_storage_provider_with_secret — retorna provider BYOS actiu + secret
-- SECURITY DEFINER per accedir a data.storage_providers i vault.
-- Només service_role pot cridar-la.
-- Retorna NULL si el tenant no té BYOS configurat/actiu/verificat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_storage_provider_with_secret(p_tenant_id uuid)
RETURNS TABLE (
  id uuid,
  provider_type text,
  endpoint_url text,
  bucket_name text,
  access_key text,
  secret_key text,
  region text
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    sp.id,
    sp.provider_type,
    sp.endpoint_url,
    sp.bucket_name,
    sp.access_key,
    vs.decrypted_secret AS secret_key,
    sp.region
  FROM data.storage_providers sp
  LEFT JOIN vault.decrypted_secrets vs ON vs.id = sp.secret_key_id
  WHERE sp.tenant_id = p_tenant_id
    AND sp.is_active = true
    AND sp.is_verified = true;
$$;

REVOKE ALL ON FUNCTION api.get_storage_provider_with_secret(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_storage_provider_with_secret(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_storage_provider_with_secret(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_storage_provider_with_secret(uuid) TO service_role;


-- =============================================================================
-- 13. pg_cron SCHEDULES (condicional — pg_cron pot no estar disponible en local)
-- =============================================================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN

    -- Cada 30 minuts: netejar uploads pendents expirats
    PERFORM cron.schedule(
      'cleanup-pending-uploads',
      '*/30 * * * *',
      'SELECT data.cleanup_pending_uploads()'
    );

    -- Cada dia a les 3:00 UTC: processar papelera expirada (> 30 dies)
    PERFORM cron.schedule(
      'queue-expired-trash',
      '0 3 * * *',
      'SELECT data.process_expired_trash()'
    );

  END IF;
END;
$$;
