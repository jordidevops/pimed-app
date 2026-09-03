-- =============================================================================
-- Migració 2: Taules core SaaS multitenant (schema: data)
-- =============================================================================
-- Totes les taules viuen a l'schema "data" (privat).
-- Cap taula s'exposa directament via PostgREST: el frontend entra per vistes api.*.
--
-- Aquesta migració és la base estructural del model multi-tenant + multi-site:
--   · Plans/Tenants/Sites/Membresies (tenant_members amb rol global o de site)
--   · user_permissions_cache (fallback del sistema dual JWT claims)
--   · Notes i audit amb site_id (recurs global vs recurs de site)
--   · enforce_site_quota() (límit max_sites per pla)
--   · provision_tenant() (onboarding atòmic tenant + site inicial)
--
-- IMPORTANT:
--   · Les polítiques RLS i Custom JWT Claims es defineixen a la migració 3.
--   · Les vistes api.* es defineixen a la migració 4.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Plans de subscripció
-- ---------------------------------------------------------------------------
CREATE TABLE data.plans (
  id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text          NOT NULL UNIQUE,        -- 'free', 'pro', 'enterprise'
  display_name  text          NOT NULL,
  max_members   integer       NOT NULL DEFAULT 5,     -- membres per tenant
  max_storage_mb integer      NOT NULL DEFAULT 100,   -- MB de storage per tenant
  max_sites     integer       NOT NULL DEFAULT 1,     -- màxim de sites (locals) per tenant; 0 = sense límit
  price_monthly numeric(10,2) NOT NULL DEFAULT 0,
  is_active     boolean       NOT NULL DEFAULT true,
  metadata      jsonb,
  created_at    timestamptz   NOT NULL DEFAULT now(),
  updated_at    timestamptz   NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Tenants (organitzacions/empreses)
-- ---------------------------------------------------------------------------
CREATE TABLE data.tenants (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL,
  slug        text        UNIQUE NOT NULL,
  plan_id     uuid        REFERENCES data.plans(id) ON DELETE SET NULL,
  metadata    jsonb,
  is_active   boolean     NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Sites (seus/locals físics d'un Tenant)
--   Un Tenant (franquícia/organització) pot tenir N sites (restaurants/locals).
--   Cada site pertany exclusivament a un Tenant.
--   site_id IS NULL en altres taules → recurs global del Tenant.
--   site_id IS NOT NULL              → recurs d'un site concret.
-- ---------------------------------------------------------------------------
CREATE TABLE data.sites (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name        text        NOT NULL,
  address     text,
  is_active   boolean     NOT NULL DEFAULT true,
  metadata    jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sites_tenant_id ON data.sites (tenant_id);

COMMENT ON TABLE data.sites
  IS 'Seus/locals fisics d''un Tenant. Un Tenant (franquicia) pot tenir N sites (restaurants).';

-- ---------------------------------------------------------------------------
-- Perfils d'usuari (extensió 1:1 de auth.users)
-- ---------------------------------------------------------------------------
CREATE TABLE data.profiles (
  id          uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email       text        NOT NULL,
  full_name   text,
  avatar_url  text,
  metadata    jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Cache de permisos per usuari (mantenida per trigger sobre tenant_members)
--   Mateixa estructura JSON que el JWT claim app_metadata.user_tenants.
--   Usada com a fallback si el hook JWT no és actiu (tokens antics, etc.).
-- ---------------------------------------------------------------------------
CREATE TABLE data.user_permissions_cache (
  user_id     uuid        PRIMARY KEY REFERENCES data.profiles(id) ON DELETE CASCADE,
  tenant_data jsonb       NOT NULL DEFAULT '{}',
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.user_permissions_cache
  IS 'Cache de permisos per usuari. Mateixa estructura que app_metadata.user_tenants del JWT. '
     'Mantinguda per trigger sobre tenant_members. Usada com a fallback si el hook JWT no esta actiu.';

GRANT SELECT ON data.user_permissions_cache TO authenticated;
GRANT SELECT ON data.user_permissions_cache TO supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- Membres d'un tenant (relació usuari ↔ tenant amb rol)
-- Rols possibles:
--   owner   → propietari (ex: franquiciat). Accés a TOTS els seus tenants. Control total.
--   manager → administratiu corporatiu. Accés a tots els tenants assignats. No pot eliminar tenant ni canviar pla.
--   member  → gerent del local. Veu i edita les dades del seu tenant. No pot convidar.
--   viewer  → lectura del seu tenant. No pot escriure res.
--
-- site_id:
--   NULL     → rol global al Tenant (owner/manager corporatiu, etc.)
--   NOT NULL → rol limitat a un site concret (gerent del local Gràcia, etc.)
--
-- NOTA: no usem UNIQUE(tenant_id, user_id, site_id) perquè PostgreSQL tracta
-- NULL ≠ NULL en índexs únics compostos. Usem dos índexs parcials en comptes.
-- ---------------------------------------------------------------------------
CREATE TABLE data.tenant_members (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  user_id     uuid        NOT NULL REFERENCES data.profiles(id) ON DELETE CASCADE,
  site_id     uuid        REFERENCES data.sites(id) ON DELETE CASCADE,
  role        text        NOT NULL DEFAULT 'member'
                          CHECK (role IN ('owner', 'manager', 'member', 'viewer')),
  is_active   boolean     NOT NULL DEFAULT true,
  invited_by  uuid        REFERENCES data.profiles(id),
  joined_at   timestamptz NOT NULL DEFAULT now()
);

-- Rol global únic per usuari i tenant (site_id IS NULL)
CREATE UNIQUE INDEX uq_tenant_members_global
  ON data.tenant_members (tenant_id, user_id)
  WHERE site_id IS NULL;

-- Rol de site únic per usuari, tenant i site (site_id IS NOT NULL)
CREATE UNIQUE INDEX uq_tenant_members_site
  ON data.tenant_members (tenant_id, user_id, site_id)
  WHERE site_id IS NOT NULL;

COMMENT ON COLUMN data.tenant_members.site_id
  IS 'NULL = rol global al Tenant. NOT NULL = rol limitat al site indicat.';

-- ---------------------------------------------------------------------------
-- Subscripcions (historial de plans per tenant)
-- ---------------------------------------------------------------------------
CREATE TABLE data.subscriptions (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  plan_id         uuid        NOT NULL REFERENCES data.plans(id),
  status          text        NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active', 'cancelled', 'expired', 'trial')),
  started_at      timestamptz NOT NULL DEFAULT now(),
  ends_at         timestamptz,
  cancelled_at    timestamptz,
  metadata        jsonb,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Notes — taula genèrica per provar CRUD multitenant aïllat
-- Representa qualsevol entitat de dades pròpia del tenant.
-- ---------------------------------------------------------------------------
CREATE TABLE data.notes (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id     uuid        REFERENCES data.sites(id) ON DELETE SET NULL, -- NULL = nota global del tenant
  created_by  uuid        NOT NULL REFERENCES data.profiles(id),
  title       text        NOT NULL,
  content     text,
  is_pinned   boolean     NOT NULL DEFAULT false,
  metadata    jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Storage: registre de fitxers pujats per tenant
-- El fitxer real viu al bucket de Supabase Storage.
-- Aquí guardem el registre per poder fer tracking d'ús.
-- ---------------------------------------------------------------------------
CREATE TABLE data.files (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  uploaded_by   uuid        NOT NULL REFERENCES data.profiles(id),
  bucket_id     text        NOT NULL,   -- nom del bucket de Supabase Storage
  storage_path  text        NOT NULL,   -- path dins el bucket (ex: tenant-id/files/uuid.pdf)
  file_name     text        NOT NULL,
  mime_type     text,
  size_bytes    bigint      NOT NULL DEFAULT 0,
  metadata      jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (bucket_id, storage_path)
);

-- ---------------------------------------------------------------------------
-- Ús de storage per tenant (agregat, actualitzat via trigger)
-- Permet consultar ràpidament l'ús sense agregar data.files cada cop.
-- ---------------------------------------------------------------------------
CREATE TABLE data.storage_usage (
  tenant_id     uuid        PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  file_count    integer     NOT NULL DEFAULT 0,
  total_bytes   bigint      NOT NULL DEFAULT 0,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Audit log
-- Registra accions importants (qui, a quin tenant, sobre quina entitat).
-- ---------------------------------------------------------------------------
CREATE TABLE data.audit_logs (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        REFERENCES data.tenants(id) ON DELETE SET NULL,
  user_id       uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  site_id       uuid        REFERENCES data.sites(id) ON DELETE SET NULL,   -- context del site on va passar
  action        text        NOT NULL,  -- 'create', 'update', 'delete', 'upload', 'login'...
  entity_type   text,                  -- 'note', 'file', 'tenant_member'...
  entity_id     uuid,
  payload       jsonb,                 -- dades addicionals del context
  ip_address    inet,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- =============================================================================
-- Triggers de timestamps updated_at
-- =============================================================================
CREATE OR REPLACE FUNCTION data.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_plans_updated_at
  BEFORE UPDATE ON data.plans
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_tenants_updated_at
  BEFORE UPDATE ON data.tenants
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON data.profiles
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_notes_updated_at
  BEFORE UPDATE ON data.notes
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_sites_updated_at
  BEFORE UPDATE ON data.sites
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- =============================================================================
-- Trigger: storage_usage s'actualitza automàticament quan s'insereix/elimina un fitxer
-- =============================================================================
CREATE OR REPLACE FUNCTION data.update_storage_usage()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO data.storage_usage (tenant_id, file_count, total_bytes)
    VALUES (NEW.tenant_id, 1, NEW.size_bytes)
    ON CONFLICT (tenant_id) DO UPDATE
      SET file_count  = data.storage_usage.file_count + 1,
          total_bytes = data.storage_usage.total_bytes + NEW.size_bytes,
          updated_at  = now();

  ELSIF TG_OP = 'DELETE' THEN
    UPDATE data.storage_usage
    SET file_count  = GREATEST(file_count - 1, 0),
        total_bytes = GREATEST(total_bytes - OLD.size_bytes, 0),
        updated_at  = now()
    WHERE tenant_id = OLD.tenant_id;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_files_storage_usage
  AFTER INSERT OR DELETE ON data.files
  FOR EACH ROW EXECUTE FUNCTION data.update_storage_usage();

-- =============================================================================
-- Trigger: crea profile automàticament quan es registra un usuari a auth.users
-- =============================================================================
CREATE OR REPLACE FUNCTION data.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
BEGIN
  INSERT INTO data.profiles (id, email, full_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data->>'full_name',
    NEW.raw_user_meta_data->>'avatar_url'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_auth_users_new_profile
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION data.handle_new_user();

-- =============================================================================
-- Índexs
-- =============================================================================
CREATE INDEX idx_tenant_members_tenant  ON data.tenant_members(tenant_id);
CREATE INDEX idx_tenant_members_user    ON data.tenant_members(user_id);
CREATE INDEX idx_notes_tenant           ON data.notes(tenant_id);
CREATE INDEX idx_notes_created_by       ON data.notes(created_by);
CREATE INDEX idx_files_tenant           ON data.files(tenant_id);
CREATE INDEX idx_audit_logs_tenant      ON data.audit_logs(tenant_id);
CREATE INDEX idx_audit_logs_user        ON data.audit_logs(user_id);
CREATE INDEX idx_audit_logs_created_at  ON data.audit_logs(created_at DESC);

-- =============================================================================
-- Funció i trigger: reconstrueix la cache de permisos quan tenant_members canvia
-- =============================================================================
-- Recalcula i persisteix el JSON de permisos d'un usuari concret.
-- Cridada des del trigger; única font de veritat per al contingut de la cache.
CREATE OR REPLACE FUNCTION data.rebuild_user_permissions_cache(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_user_tenants jsonb := '{}';
  rec            RECORD;
BEGIN
  FOR rec IN
    SELECT tenant_id, site_id, role
    FROM data.tenant_members
    WHERE user_id   = p_user_id
      AND is_active = true
    ORDER BY tenant_id, site_id NULLS FIRST
  LOOP
    IF NOT (v_user_tenants ? rec.tenant_id::text) THEN
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text],
        '{"global_role": null, "sites": {}}'
      );
    END IF;

    IF rec.site_id IS NULL THEN
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text, 'global_role'],
        to_jsonb(rec.role)
      );
    ELSE
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text, 'sites', rec.site_id::text],
        to_jsonb(rec.role)
      );
    END IF;
  END LOOP;

  INSERT INTO data.user_permissions_cache (user_id, tenant_data, updated_at)
  VALUES (p_user_id, v_user_tenants, now())
  ON CONFLICT (user_id) DO UPDATE
    SET tenant_data = EXCLUDED.tenant_data,
        updated_at  = now();
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_refresh_permissions_cache()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
BEGIN
  PERFORM data.rebuild_user_permissions_cache(COALESCE(NEW.user_id, OLD.user_id));
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_tenant_members_refresh_cache
  AFTER INSERT OR UPDATE OR DELETE ON data.tenant_members
  FOR EACH ROW EXECUTE FUNCTION data.trg_refresh_permissions_cache();

-- =============================================================================
-- Trigger: enforce_site_quota — impedeix crear sites actius per sobre del límit del pla
-- =============================================================================
-- Bypass:
--   · max_sites = 0 → plans personalitzats / enterprise il·limitat
--   · current_role IN ('postgres','service_role','supabase_admin') → admin-portal i scripts
-- =============================================================================
CREATE OR REPLACE FUNCTION data.enforce_site_quota()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_limit   integer;
  v_current integer;
BEGIN
  -- Salta si estem desactivant un site (no s'afegeix capacitat)
  IF NEW.is_active = false THEN
    RETURN NEW;
  END IF;

  -- Salta si el site ja existia actiu i el canvi no l'activa de nou
  IF TG_OP = 'UPDATE' AND OLD.is_active = true THEN
    RETURN NEW;
  END IF;

  -- Bypass per a rols privilegiats (admin-portal via Prisma, scripts de suport)
  IF current_role IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  -- Obtenir el límit de sites del pla actiu del tenant
  SELECT p.max_sites
    INTO v_limit
    FROM data.tenants t
    JOIN data.plans   p ON p.id = t.plan_id
   WHERE t.id = NEW.tenant_id;

  -- Sense pla, sense límit, o límit 0 = sense restricció
  IF v_limit IS NULL OR v_limit = 0 THEN
    RETURN NEW;
  END IF;

  -- Comptar sites actius actuals (sense comptar la fila nova)
  SELECT COUNT(*)::integer
    INTO v_current
    FROM data.sites
   WHERE tenant_id = NEW.tenant_id
     AND is_active = true
     AND (TG_OP = 'INSERT' OR id != NEW.id);

  IF v_current >= v_limit THEN
    RAISE EXCEPTION 'quota_exceeded: El pla d''aquest tenant només permet % locals actius. Millora el pla per afegir-ne més.',
      v_limit
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_site_quota
  BEFORE INSERT OR UPDATE ON data.sites
  FOR EACH ROW EXECUTE FUNCTION data.enforce_site_quota();

-- =============================================================================
-- Funció atòmica: data.provision_tenant()
-- =============================================================================
-- Crea un Tenant i el seu Site inicial en una sola transacció.
-- Si qualsevol dels dos INSERTs falla (slug duplicat, pla inexistent, etc.)
-- tot fa rollback automàticament: mai queda un Tenant sense Site inicial.
--
-- SECURITY DEFINER s'executa com a postgres: bypassa RLS i el trigger
-- enforce_site_quota (que comprova current_role = 'postgres').
-- =============================================================================
CREATE OR REPLACE FUNCTION data.provision_tenant(
  p_name    text,
  p_slug    text,
  p_plan_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid;
  v_site_id   uuid;
BEGIN
  -- 1. Crear el Tenant
  INSERT INTO data.tenants (name, slug, plan_id)
  VALUES (trim(p_name), lower(trim(p_slug)), p_plan_id)
  RETURNING id INTO v_tenant_id;

  -- 2. Crear el Site inicial amb el mateix nom que el Tenant
  INSERT INTO data.sites (tenant_id, name)
  VALUES (v_tenant_id, trim(p_name))
  RETURNING id INTO v_site_id;

  -- 3. Pre-poblar email_configs (from_name = nom del tenant)
  INSERT INTO data.email_configs (tenant_id, default_from_name)
  VALUES (v_tenant_id, trim(p_name))
  ON CONFLICT (tenant_id) DO NOTHING;

  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'site_id',   v_site_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION data.provision_tenant(text, text, uuid)
  TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION data.provision_tenant(text, text, uuid) FROM PUBLIC;

COMMENT ON FUNCTION data.provision_tenant(text, text, uuid)
  IS 'Crea un Tenant i el seu Site inicial de forma atòmica. '
     'Usar sempre en lloc d''INSERTs separats per garantir consistència.';
