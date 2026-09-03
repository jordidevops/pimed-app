-- =============================================================================
-- Migration: 20260502000002_locations_assets.sql
-- Propòsit : Infraestructura genèrica d'Espais (EAM/CAFM) per a SaaS
--            Multi-Tenant i Multi-Site.
--
-- Conté:
--   1. DDL : data.locations  — jerarquia espacial infinita dins d'un site
--   2. DDL : data.assets     — actius/equips físics amb localització dinàmica
--   3. FK  : data.projects.location_id → data.locations(id) ON DELETE SET NULL
--            (columna reservada a la migració anterior, ara formalitzada)
--   4. RLS : polítiques d'accés heretades del patró de sites
--   5. Audit: triggers AFTER INSERT/UPDATE/DELETE per locations i assets
--   6. Vistes: api.locations, api.assets  (security_invoker = true)
--   7. Grants
--
-- Patró RLS aplicat (idèntic a data.sites):
--   READ : membre del tenant (rol global) O accés JWT al site_id concret
--   WRITE: owner o manager (global o del site concret)
--   DELETE: owner global únicament
--
-- Auditoria:
--   LOCATION_CREATED, LOCATION_UPDATED, LOCATION_STATUS_CHANGED,
--   LOCATION_DELETED, ASSET_CREATED, ASSET_UPDATED,
--   ASSET_STATUS_CHANGED, ASSET_MOVED, ASSET_DELETED
--
-- Futures integracions:
--   · Control Horari: fitxatge GPS contra geo_coordinates d'una location
--   · Work Orders: incidència vinculada a un asset + location + site
--   · Inventari: stock associat a una location concreta
-- =============================================================================

-- =============================================================================
-- 1. DDL: data.locations
-- =============================================================================

CREATE TABLE data.locations (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid        NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  site_id          uuid        NOT NULL REFERENCES data.sites(id)     ON DELETE CASCADE,
  parent_id        uuid                 REFERENCES data.locations(id) ON DELETE CASCADE,
  name             text        NOT NULL,
  type             text        NOT NULL DEFAULT 'zone'
                               CHECK (type IN ('floor', 'room', 'zone', 'outdoor', 'other')),
  status           text        NOT NULL DEFAULT 'active'
                               CHECK (status IN ('active', 'maintenance', 'inactive')),
  geo_coordinates  jsonb,      -- ex: {"lat": 41.38, "lng": 2.17} o polígon GeoJSON
  metadata         jsonb,      -- camps addicionals lliures per al tenant
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_locations_tenant_id ON data.locations (tenant_id);
CREATE INDEX idx_locations_site_id   ON data.locations (site_id);
CREATE INDEX idx_locations_parent_id ON data.locations (parent_id);

COMMENT ON TABLE data.locations
  IS 'Jerarquia espacial infinita dins d''un site (Adjacency List). '
     'Exemple: Site (Fàbrica) → Nau 1 → Planta Baixa → Zona d''Empaquetatge.';

COMMENT ON COLUMN data.locations.parent_id
  IS 'NULL = zona arrel del site. NOT NULL = sub-zona d''una altra location.';

COMMENT ON COLUMN data.locations.geo_coordinates
  IS 'Coordenades GPS o polígon GeoJSON per al geofencing de fitxatge. '
     'Ex: {"lat":41.38,"lng":2.17} o {"type":"Polygon","coordinates":[...]}';

COMMENT ON COLUMN data.locations.type
  IS 'floor=planta, room=sala/cuina/despatx, zone=zona de treball, '
     'outdoor=exterior/pàrquing, other=genèric.';

-- =============================================================================
-- 2. DDL: data.assets
-- =============================================================================

CREATE TABLE data.assets (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  site_id       uuid        NOT NULL REFERENCES data.sites(id)     ON DELETE CASCADE,
  location_id   uuid                 REFERENCES data.locations(id) ON DELETE SET NULL,
  name          text        NOT NULL,
  serial_number text,
  asset_tag     text,       -- codi per a QR / NFC / etiqueta física
  status        text        NOT NULL DEFAULT 'operational'
                            CHECK (status IN ('operational', 'down', 'repairing', 'retired')),
  metadata      jsonb,      -- especificacions tècniques, manuals, model, marca...
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_assets_tenant_id   ON data.assets (tenant_id);
CREATE INDEX idx_assets_site_id     ON data.assets (site_id);
CREATE INDEX idx_assets_location_id ON data.assets (location_id);
CREATE INDEX idx_assets_asset_tag   ON data.assets (asset_tag);
CREATE UNIQUE INDEX uq_assets_tenant_asset_tag
  ON data.assets (tenant_id, asset_tag)
  WHERE asset_tag IS NOT NULL;

COMMENT ON TABLE data.assets
  IS 'Actius / equips físics (maquinària, electrodomèstics, vehicles...). '
     'El location_id es pot canviar quan l''actiu es mou o va a reparar; '
     'tot l''historial queda associat a l''asset, no a la location.';

COMMENT ON COLUMN data.assets.asset_tag
  IS 'Codi únic per a QR/NFC. Permet identificar l''actiu amb un escàner mòbil.';

COMMENT ON COLUMN data.assets.status
  IS 'operational=en servei, down=avaria, repairing=en reparació, retired=de baixa.';

COMMENT ON COLUMN data.assets.metadata
  IS 'Camp lliure JSONB: marca, model, any de fabricació, manuals URL, etc.';

-- =============================================================================
-- 2b. Validacions d'integritat transversal (tenant/site)
-- =============================================================================

-- Garanteix que el parent d'una location pertany al mateix tenant i site.
CREATE OR REPLACE FUNCTION data.trg_validate_location_hierarchy()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_parent_tenant_id uuid;
  v_parent_site_id   uuid;
BEGIN
  IF NEW.parent_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.parent_id = NEW.id THEN
    RAISE EXCEPTION 'invalid parent_id: a location cannot be parent of itself';
  END IF;

  SELECT l.tenant_id, l.site_id
  INTO v_parent_tenant_id, v_parent_site_id
  FROM data.locations l
  WHERE l.id = NEW.parent_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid parent_id: parent location % not found', NEW.parent_id;
  END IF;

  IF v_parent_tenant_id <> NEW.tenant_id OR v_parent_site_id <> NEW.site_id THEN
    RAISE EXCEPTION 'invalid hierarchy: parent location must belong to same tenant and site';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_location_hierarchy
  BEFORE INSERT OR UPDATE OF parent_id, tenant_id, site_id ON data.locations
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_location_hierarchy();

-- Garanteix que l'asset sempre apunta a una location del mateix tenant i site.
CREATE OR REPLACE FUNCTION data.trg_validate_asset_location_consistency()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_location_tenant_id uuid;
  v_location_site_id   uuid;
BEGIN
  IF NEW.location_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT l.tenant_id, l.site_id
  INTO v_location_tenant_id, v_location_site_id
  FROM data.locations l
  WHERE l.id = NEW.location_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid location_id: location % not found', NEW.location_id;
  END IF;

  IF v_location_tenant_id <> NEW.tenant_id OR v_location_site_id <> NEW.site_id THEN
    RAISE EXCEPTION 'invalid relation: asset and location must belong to same tenant and site';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_asset_location_consistency
  BEFORE INSERT OR UPDATE OF location_id, tenant_id, site_id ON data.assets
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_asset_location_consistency();

-- Si un projecte té location, ha de ser del mateix tenant i site.
CREATE OR REPLACE FUNCTION data.trg_validate_project_location_consistency()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_location_tenant_id uuid;
  v_location_site_id   uuid;
BEGIN
  IF NEW.location_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT l.tenant_id, l.site_id
  INTO v_location_tenant_id, v_location_site_id
  FROM data.locations l
  WHERE l.id = NEW.location_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid location_id: location % not found', NEW.location_id;
  END IF;

  IF v_location_tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'invalid relation: project and location must belong to same tenant';
  END IF;

  IF NEW.site_id IS NULL OR NEW.site_id <> v_location_site_id THEN
    RAISE EXCEPTION 'invalid relation: project.site_id must match location.site_id when location_id is set';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_project_location_consistency
  BEFORE INSERT OR UPDATE OF location_id, tenant_id, site_id ON data.projects
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_project_location_consistency();

-- =============================================================================
-- 3. FK: data.projects.location_id → data.locations(id)
--    Columna reservada a la migració 20260502000001; ara s'afegeix la FK.
-- =============================================================================

ALTER TABLE data.projects
  ADD CONSTRAINT projects_location_id_fkey
  FOREIGN KEY (location_id) REFERENCES data.locations(id) ON DELETE SET NULL;

CREATE INDEX idx_projects_location_id ON data.projects (location_id);

-- =============================================================================
-- 4. Row Level Security
-- =============================================================================

-- ---------------------------------------------------------------------------
-- data.locations — herència del patró RLS de data.sites
-- ---------------------------------------------------------------------------
ALTER TABLE data.locations ENABLE ROW LEVEL SECURITY;

-- SELECT: membre del tenant (global) O accés JWT al site concret
CREATE POLICY "locations: veure del tenant o del site accessible"
  ON data.locations FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      -- Rol global: veu totes les locations del tenant
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IS NOT NULL
      OR
      -- Rol de site concret: veu les locations del seu site
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites') ? site_id::text
    )
  );

-- INSERT: owner o manager (global o del site concret)
CREATE POLICY "locations: owner/manager pot crear"
  ON data.locations FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
    )
  );

-- UPDATE: owner o manager (global o del site concret)
CREATE POLICY "locations: owner/manager pot modificar"
  ON data.locations FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
    )
  );

-- DELETE: owner global únicament (operació destructiva per cascada sobre sub-zones)
CREATE POLICY "locations: owner pot eliminar"
  ON data.locations FOR DELETE
  TO authenticated
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
  );

-- ---------------------------------------------------------------------------
-- data.assets — herència del patró RLS de data.sites
-- ---------------------------------------------------------------------------
ALTER TABLE data.assets ENABLE ROW LEVEL SECURITY;

-- SELECT: membre del tenant (global) O accés JWT al site de l'actiu
CREATE POLICY "assets: veure del tenant o del site accessible"
  ON data.assets FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IS NOT NULL
      OR
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites') ? site_id::text
    )
  );

-- INSERT: owner o manager (global o del site concret)
CREATE POLICY "assets: owner/manager pot crear"
  ON data.assets FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
    )
  );

-- UPDATE: owner o manager (global o del site concret)
CREATE POLICY "assets: owner/manager pot modificar"
  ON data.assets FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
    )
  );

-- DELETE: owner global únicament
CREATE POLICY "assets: owner pot eliminar"
  ON data.assets FOR DELETE
  TO authenticated
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
  );

-- =============================================================================
-- 5. Grants sobre data.* per a authenticated
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON data.locations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.assets     TO authenticated;

-- updated_at coherent tant per escriptura directa com via vistes/RULES
CREATE TRIGGER trg_locations_updated_at
  BEFORE UPDATE ON data.locations
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_assets_updated_at
  BEFORE UPDATE ON data.assets
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- =============================================================================
-- 6. Triggers d'auditoria
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Audit: data.locations
-- Accions: LOCATION_CREATED, LOCATION_UPDATED, LOCATION_STATUS_CHANGED,
--          LOCATION_DELETED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_locations()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NEW.site_id,
      'LOCATION_CREATED',
      'location', NEW.id,
      jsonb_build_object(
        'name',      NEW.name,
        'type',      NEW.type,
        'status',    NEW.status,
        'parent_id', NEW.parent_id
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'LOCATION_STATUS_CHANGED',
        'location', NEW.id,
        jsonb_build_object(
          'name',       NEW.name,
          'old_status', OLD.status,
          'new_status', NEW.status
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'LOCATION_UPDATED',
        'location', NEW.id,
        jsonb_build_object(
          'old', jsonb_build_object('name', OLD.name, 'type', OLD.type, 'parent_id', OLD.parent_id),
          'new', jsonb_build_object('name', NEW.name, 'type', NEW.type, 'parent_id', NEW.parent_id)
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, auth.uid(), OLD.site_id,
      'LOCATION_DELETED',
      'location', OLD.id,
      jsonb_build_object('name', OLD.name, 'type', OLD.type)
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_locations
  AFTER INSERT OR UPDATE OR DELETE ON data.locations
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_locations();

-- ---------------------------------------------------------------------------
-- Audit: data.assets
-- Accions: ASSET_CREATED, ASSET_STATUS_CHANGED, ASSET_MOVED,
--          ASSET_UPDATED, ASSET_DELETED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_assets()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NEW.site_id,
      'ASSET_CREATED',
      'asset', NEW.id,
      jsonb_build_object(
        'name',        NEW.name,
        'asset_tag',   NEW.asset_tag,
        'status',      NEW.status,
        'location_id', NEW.location_id
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'ASSET_STATUS_CHANGED',
        'asset', NEW.id,
        jsonb_build_object(
          'name',       NEW.name,
          'old_status', OLD.status,
          'new_status', NEW.status
        )
      );
    ELSIF OLD.location_id IS DISTINCT FROM NEW.location_id THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'ASSET_MOVED',
        'asset', NEW.id,
        jsonb_build_object(
          'name',             NEW.name,
          'old_location_id',  OLD.location_id,
          'new_location_id',  NEW.location_id,
          'old_site_id',      OLD.site_id,
          'new_site_id',      NEW.site_id
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'ASSET_UPDATED',
        'asset', NEW.id,
        jsonb_build_object(
          'old', jsonb_build_object('name', OLD.name, 'serial_number', OLD.serial_number, 'asset_tag', OLD.asset_tag),
          'new', jsonb_build_object('name', NEW.name, 'serial_number', NEW.serial_number, 'asset_tag', NEW.asset_tag)
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, auth.uid(), OLD.site_id,
      'ASSET_DELETED',
      'asset', OLD.id,
      jsonb_build_object('name', OLD.name, 'asset_tag', OLD.asset_tag, 'status', OLD.status)
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_assets
  AFTER INSERT OR UPDATE OR DELETE ON data.assets
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_assets();

-- =============================================================================
-- 7. Vistes api.*
-- =============================================================================

-- ---------------------------------------------------------------------------
-- api.locations — jerarquia espacial del tenant
-- Updatable: sí (single-table, no virtual columns → auto-updatable)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.locations
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    site_id,
    parent_id,
    name,
    type,
    status,
    geo_coordinates,
    metadata,
    created_at,
    updated_at
  FROM data.locations;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.locations TO authenticated;

-- ---------------------------------------------------------------------------
-- api.assets — actius/equips físics del tenant
-- Inclou el nom de la location actual per a conveniència del frontend.
-- Updatable: NO (JOIN amb locations). Les escriptures van directament via
-- PostgREST a la vista o via RULE si es vol mantenir l'stàndard.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.assets
  WITH (security_invoker = true) AS
  SELECT
    a.id,
    a.tenant_id,
    a.site_id,
    a.location_id,
    a.name,
    a.serial_number,
    a.asset_tag,
    a.status,
    a.metadata,
    a.created_at,
    a.updated_at,
    -- Camp virtual: nom de la location actual (NULL si l'actiu no té location)
    l.name AS location_name
  FROM data.assets a
  LEFT JOIN data.locations l ON l.id = a.location_id;

GRANT SELECT ON api.assets TO authenticated;

-- RULE per a INSERT (sense camp virtual location_name):
CREATE RULE "api_assets_insert" AS ON INSERT TO api.assets
  DO INSTEAD
  INSERT INTO data.assets (
    tenant_id, site_id, location_id, name,
    serial_number, asset_tag, status, metadata
  )
  VALUES (
    NEW.tenant_id,
    NEW.site_id,
    NEW.location_id,
    NEW.name,
    NEW.serial_number,
    NEW.asset_tag,
    COALESCE(NEW.status, 'operational'),
    NEW.metadata
  );

-- RULE per a UPDATE (sense camp virtual):
CREATE RULE "api_assets_update" AS ON UPDATE TO api.assets
  DO INSTEAD
  UPDATE data.assets SET
    site_id       = NEW.site_id,
    location_id   = NEW.location_id,
    name          = NEW.name,
    serial_number = NEW.serial_number,
    asset_tag     = NEW.asset_tag,
    status        = NEW.status,
    metadata      = NEW.metadata
  WHERE id = OLD.id;

-- RULE per a DELETE:
CREATE RULE "api_assets_delete" AS ON DELETE TO api.assets
  DO INSTEAD
  DELETE FROM data.assets WHERE id = OLD.id;

GRANT INSERT, UPDATE, DELETE ON api.assets TO authenticated;
