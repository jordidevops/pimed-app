-- =============================================================================
-- Migració 4: Vistes api.* (Patró A — schema api com a pont)
-- =============================================================================
-- Cada vista exposa columnes seleccionades de data.*.
-- security_invoker = true: el RLS de les taules base s'aplica tal qual.
-- PostgREST exposa NOMÉS aquest schema (configurat a config.toml).
--
-- Consumidors:
--   · tenant-portal (supabase-js): accés via PostgREST sobre api.* amb JWT user.
--   · admin-portal NO usa aquestes vistes per a backoffice sensible:
--     treballa amb Prisma/service role (bypass RLS) a data.*.
--
-- Notes:
--   · api.notes és updatable via RULES i propaga site_id.
--   · api.sites és el punt d'entrada per gestionar locals des del tenant-portal.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- api.plans — plans de subscripció disponibles (lectura pública per al tenant)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.plans
  WITH (security_invoker = true) AS
  SELECT
    id,
    name,
    display_name,
    max_members,
    max_storage_mb,
    price_monthly
  FROM data.plans
  WHERE is_active = true;

GRANT SELECT ON api.plans TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- api.my_tenant — el tenant de l'usuari autenticat
-- Inclou dades del pla: max_members, max_storage_mb, max_sites per al frontend.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.my_tenant
  WITH (security_invoker = true) AS
  SELECT
    t.id,
    t.name,
    t.slug,
    t.is_active,
    t.created_at,
    t.plan_id,
    p.name         AS plan_name,
    p.display_name AS plan_display_name,
    p.max_members,
    p.max_storage_mb,
    p.max_sites
  FROM data.tenants t
  LEFT JOIN data.plans p ON p.id = t.plan_id;

GRANT SELECT ON api.my_tenant TO authenticated;

-- ---------------------------------------------------------------------------
-- api.my_profile — perfil de l'usuari autenticat
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.my_profile
  WITH (security_invoker = true) AS
  SELECT
    id,
    email,
    full_name,
    avatar_url,
    created_at,
    updated_at
  FROM data.profiles;

GRANT SELECT, UPDATE ON api.my_profile TO authenticated;

-- ---------------------------------------------------------------------------
-- api.tenant_members — membres del tenant de l'usuari autenticat
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.tenant_members
  WITH (security_invoker = true) AS
  SELECT
    tm.id,
    tm.tenant_id,
    tm.user_id,
    tm.role,
    tm.is_active,
    tm.joined_at,
    p.email,
    p.full_name,
    p.avatar_url
  FROM data.tenant_members tm
  JOIN data.profiles p ON p.id = tm.user_id;

GRANT SELECT ON api.tenant_members TO authenticated;

-- ---------------------------------------------------------------------------
-- api.notes — CRUD de notes del tenant (globals i per site)
-- site_id = NULL → nota global; site_id NOT NULL → nota d'un site concret.
-- Per a INSERT/UPDATE/DELETE des de PostgREST, la vista és updatable via regles.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.notes
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    site_id,
    created_by,
    title,
    content,
    is_pinned,
    created_at,
    updated_at
  FROM data.notes;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.notes TO authenticated;

-- INSERT: propaga site_id (pot ser NULL per notes globals)
CREATE RULE "api_notes_insert" AS ON INSERT TO api.notes
  DO INSTEAD
  INSERT INTO data.notes (tenant_id, site_id, created_by, title, content, is_pinned, metadata)
  VALUES (NEW.tenant_id, NEW.site_id, NEW.created_by, NEW.title, NEW.content, COALESCE(NEW.is_pinned, false), NULL);

-- UPDATE: propaga site_id i els camps editables
CREATE RULE "api_notes_update" AS ON UPDATE TO api.notes
  DO INSTEAD
  UPDATE data.notes
  SET title      = NEW.title,
      content    = NEW.content,
      is_pinned  = NEW.is_pinned,
      site_id    = NEW.site_id,
      updated_at = now()
  WHERE id = OLD.id;

CREATE RULE "api_notes_delete" AS ON DELETE TO api.notes
  DO INSTEAD
  DELETE FROM data.notes WHERE id = OLD.id;

-- ---------------------------------------------------------------------------
-- api.sites — seus/locals d'un tenant
-- RLS de data.sites aplicat automàticament (security_invoker = true).
-- El frontend consulta aquesta vista via supabase.from('sites').
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.sites
  WITH (security_invoker = true) AS
  SELECT
    s.id,
    s.tenant_id,
    s.name,
    s.address,
    s.is_active,
    s.metadata,
    s.created_at,
    s.updated_at
  FROM data.sites s;

GRANT SELECT, INSERT, UPDATE ON api.sites TO authenticated;

-- ---------------------------------------------------------------------------
-- api.files — registre de fitxers del tenant
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.files
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    uploaded_by,
    bucket_id,
    storage_path,
    file_name,
    mime_type,
    size_bytes,
    created_at
  FROM data.files;

GRANT SELECT, INSERT, DELETE ON api.files TO authenticated;

CREATE RULE "api_files_insert" AS ON INSERT TO api.files
  DO INSTEAD
  INSERT INTO data.files (tenant_id, uploaded_by, bucket_id, storage_path, file_name, mime_type, size_bytes)
  VALUES (NEW.tenant_id, NEW.uploaded_by, NEW.bucket_id, NEW.storage_path, NEW.file_name, NEW.mime_type, COALESCE(NEW.size_bytes, 0));

CREATE RULE "api_files_delete" AS ON DELETE TO api.files
  DO INSTEAD
  DELETE FROM data.files WHERE id = OLD.id;

-- ---------------------------------------------------------------------------
-- api.storage_usage — ús de storage del tenant
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.storage_usage
  WITH (security_invoker = true) AS
  SELECT
    tenant_id,
    file_count,
    total_bytes,
    round(total_bytes::numeric / 1048576, 2) AS total_mb,
    updated_at
  FROM data.storage_usage;

GRANT SELECT ON api.storage_usage TO authenticated;

-- ---------------------------------------------------------------------------
-- api.audit_logs — log d'accions del tenant (lectura admin)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.audit_logs
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    user_id,
    action,
    entity_type,
    entity_id,
    created_at
  FROM data.audit_logs;

GRANT SELECT ON api.audit_logs TO authenticated;
