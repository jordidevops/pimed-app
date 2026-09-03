-- =============================================================================
-- Migration: 20260503000006_catalog_and_project_lines.sql
-- Propòsit : Catàleg de productes/serveis del tenant (data.catalog_items) i
--            línies de pressupost/facturació per projecte (data.project_lines).
--            Permet generar pressupostos a partir del catàleg o línies lliures,
--            amb càlcul de subtotal i IVA a la vista api.project_lines.
--
-- Per què cal RPC per a TOTES les escriptures al catàleg?
-- ─────────────────────────────────────────────────────────
-- La vista api.catalog_items filtra per is_active = true. Quan PostgREST intenta
-- fer UPDATE sobre una vista amb un WHERE sobre columna no-PK, falla en runtime.
-- El patró correcte (usat a tot el projecte) és: SELECT via vista, escriptures
-- via RPC SECURITY INVOKER. La RLS owner/manager de data.catalog_items s'aplica
-- igualment a cada RPC, sense necessitat de replicar les comprovacions.
--
-- Per què cal validació cross-tenant a les FK de contactes?
-- ──────────────────────────────────────────────────────────
-- PostgreSQL valida que contact.id existeixi a data.contacts però NO que
-- contacts.tenant_id = projects.tenant_id. Un atacant que coneixés l'UUID d'un
-- contacte aliè podria assignar-lo a un recurs del seu tenant, filtrant dades o
-- creant inconsistències entre tenants. Els triggers BEFORE INSERT/UPDATE tanquen
-- aquest forat a nivell de BD, independentment del canal d'accés (RPC, trigger
-- intern, Edge Function amb service_role).
--
-- Per què cal validació cross-tenant a upsert_project_line?
-- ──────────────────────────────────────────────────────────
-- L'RPC rep p_project_id i p_catalog_item_id com a UUIDs arbitraris de l'usuari.
-- Sense validació explícita, un usuari podria passar un p_project_id d'un altre
-- tenant (si en coneix l'UUID) i la inserció es completaria amb tenant_id del
-- projecte aliè. La comprovació al principi de la funció garanteix que tots dos
-- recursos pertanyen al tenant actiu (x-tenant-id) abans de qualsevol DML.
--
-- Conté:
--   1.  ENUM  : data.catalog_item_kind ('product', 'service')
--   2.  DDL   : data.catalog_items
--   3.  DDL   : data.project_lines
--   4.  RLS   : data.catalog_items (SELECT: membres tenant; INSERT/UPDATE/DELETE: owner/manager)
--   5.  RLS   : data.project_lines (SELECT/INSERT/UPDATE/DELETE: membres tenant)
--   6.  Triggers updated_at
--   7.  Triggers d'auditoria: catalog_items, project_lines
--   8.  Vista  : api.catalog_items (GRANT SELECT; escriptures via RPC)
--   9.  Vista  : api.project_lines (amb subtotal, total_with_tax i join catalog_item)
--   10. RPC    : api.create_catalog_item
--   11. RPC    : api.update_catalog_item  (SECURITY INVOKER; RLS owner/manager)
--   12. RPC    : api.deactivate_catalog_item  (soft-delete; SECURITY INVOKER)
--   13. RPC    : api.upsert_project_line  (amb validació cross-tenant)
--   14. RPC    : api.delete_project_line
--   15. Triggers de validació cross-tenant FK:
--       · data.validate_project_contact_tenant       (data.projects.client_id)
--       · data.validate_calendar_event_contact_tenant (data.calendar_events.contact_id)
--       · data.validate_contact_site_tenant           (data.contact_sites.contact_id)
--   16. Grants
--
-- Patró RLS aplicat:
--   · Pertinença tenant  : data.jwt_user_tenants() ? tenant_id::text
--   · Rol global         : data.jwt_user_tenants() -> tenant_id::text ->> 'global_role'
--   · Filtre UX tenant   : data.active_tenant_id() (header x-tenant-id)
--
-- Auditoria:
--   Accions registrades: CATALOG_ITEM_CREATED, CATALOG_ITEM_UPDATED,
--   CATALOG_ITEM_ACTIVATED, CATALOG_ITEM_DEACTIVATED, CATALOG_ITEM_DELETED,
--   PROJECT_LINE_ADDED, PROJECT_LINE_UPDATED, PROJECT_LINE_REMOVED
-- =============================================================================

-- =============================================================================
-- 1. ENUM: data.catalog_item_kind
-- =============================================================================

CREATE TYPE data.catalog_item_kind AS ENUM (
  'product',   -- Producte físic (material, component, etc.)
  'service'    -- Servei (hores de feina, visita, subscripció, etc.)
);

-- =============================================================================
-- 2. DDL: data.catalog_items
-- =============================================================================

CREATE TABLE data.catalog_items (
  id          uuid                    PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid                    NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  kind        data.catalog_item_kind  NOT NULL DEFAULT 'service',
  name        text                    NOT NULL,
  description text,
  sku         text,                -- Referència interna (opcional, única per tenant quan informat)
  unit        text                    NOT NULL DEFAULT 'u',
                                   -- Unitat de mesura: 'u' (unitats), 'h' (hores),
                                   --   'm2', 'm', 'kg', 'visita', 'dia', etc.
  unit_price  numeric(12,4)           NOT NULL DEFAULT 0,
  tax_rate    numeric(5,2)            NOT NULL DEFAULT 21.00,
                                   -- Percentatge IVA (ex: 21.00, 10.00, 4.00, 0.00)
  currency    char(3)                 NOT NULL DEFAULT 'EUR',
  category    text,                -- Classificació lliure (opcional)
  is_active   boolean                 NOT NULL DEFAULT true,
  created_at  timestamptz             NOT NULL DEFAULT now(),
  updated_at  timestamptz             NOT NULL DEFAULT now()
);

CREATE INDEX idx_catalog_items_tenant_id     ON data.catalog_items (tenant_id);
CREATE INDEX idx_catalog_items_tenant_kind   ON data.catalog_items (tenant_id, kind);
CREATE INDEX idx_catalog_items_tenant_active ON data.catalog_items (tenant_id, is_active);

-- Codi SKU únic per tenant (quan informat)
CREATE UNIQUE INDEX uq_catalog_items_tenant_sku
  ON data.catalog_items (tenant_id, sku)
  WHERE sku IS NOT NULL;

COMMENT ON TABLE data.catalog_items
  IS 'Catàleg de productes i serveis del tenant. Cada ítem defineix preu, unitat i IVA '
     'per a ser referenciat des de les línies de pressupost/facturació dels projectes.';

COMMENT ON COLUMN data.catalog_items.sku
  IS 'Referència interna de l''ítem. Opcional, però únic per tenant quan informat. '
     'Útil per a importació/exportació i integracions amb ERP.';

COMMENT ON COLUMN data.catalog_items.unit
  IS 'Unitat de mesura: ''u'' (unitats), ''h'' (hores), ''m2'', ''m'', ''kg'', '
     '''visita'', ''dia'', etc.';

COMMENT ON COLUMN data.catalog_items.tax_rate
  IS 'Percentatge IVA aplicat a l''ítem. Ex: 21.00 (IVA general), 10.00 (reduït), '
     '4.00 (superreduït), 0.00 (exempt).';

COMMENT ON COLUMN data.catalog_items.currency
  IS 'Codi de divisa ISO 4217 en 3 caràcters. Default ''EUR''.';

COMMENT ON COLUMN data.catalog_items.category
  IS 'Classificació lliure per agrupar ítems (ex: ''mà d''obra'', ''materials'', '
     '''llicències''). Opcional.';

-- =============================================================================
-- 3. DDL: data.project_lines
-- =============================================================================

CREATE TABLE data.project_lines (
  id              uuid                   PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid                   NOT NULL REFERENCES data.tenants(id)       ON DELETE CASCADE,
  project_id      uuid                   NOT NULL REFERENCES data.projects(id)      ON DELETE CASCADE,
  catalog_item_id uuid                   REFERENCES data.catalog_items(id)          ON DELETE SET NULL,
                                      -- NULL = línia lliure no vinculada al catàleg
  kind            data.catalog_item_kind NOT NULL DEFAULT 'service',
  name            text                   NOT NULL, -- Pot ser copiat del catalog_item o lliure
  description     text,
  unit            text                   NOT NULL DEFAULT 'u',
  quantity        numeric(10,3)          NOT NULL DEFAULT 1,
  unit_price      numeric(12,4)          NOT NULL DEFAULT 0,
                                      -- Preu en el moment de la línia (pot divergir del catàleg)
  discount_pct    numeric(5,2)           NOT NULL DEFAULT 0,
                                      -- Descompte en percentatge (0-100)
  tax_rate        numeric(5,2)           NOT NULL DEFAULT 21.00,
  position        int                    NOT NULL DEFAULT 0,  -- Ordre dins el projecte
  notes           text,
  created_at      timestamptz            NOT NULL DEFAULT now(),
  updated_at      timestamptz            NOT NULL DEFAULT now()
);

CREATE INDEX idx_project_lines_project_id      ON data.project_lines (project_id);
CREATE INDEX idx_project_lines_tenant_id       ON data.project_lines (tenant_id);
CREATE INDEX idx_project_lines_catalog_item_id ON data.project_lines (catalog_item_id);

COMMENT ON TABLE data.project_lines
  IS 'Línies de pressupost/facturació d''un projecte. Cada línia pot referenciar un '
     'ítem del catàleg (catalog_item_id NOT NULL) o ser una línia lliure (NULL). '
     'El subtotal i el total amb IVA es calculen a la vista api.project_lines.';

COMMENT ON COLUMN data.project_lines.catalog_item_id
  IS 'NULL = línia lliure. NOT NULL = línia vinculada a un ítem del catàleg. '
     'El preu es copia en el moment de creació i pot divergir del catàleg posteriorment.';

COMMENT ON COLUMN data.project_lines.discount_pct
  IS 'Descompte en percentatge aplicat sobre unit_price. Rang: 0.00 a 100.00.';

COMMENT ON COLUMN data.project_lines.position
  IS 'Ordre de presentació de la línia dins el projecte (0-based). '
     'Permet reordenar sense canviar IDs.';

-- =============================================================================
-- 4. RLS: data.catalog_items
-- =============================================================================

ALTER TABLE data.catalog_items ENABLE ROW LEVEL SECURITY;

-- SELECT: qualsevol membre del tenant veu els ítems del seu catàleg
CREATE POLICY "catalog_items: veure ítems del tenant"
  ON data.catalog_items FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- INSERT: owner o manager global del tenant
CREATE POLICY "catalog_items: owner/manager pot crear"
  ON data.catalog_items FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- UPDATE: owner o manager global del tenant
CREATE POLICY "catalog_items: owner/manager pot modificar"
  ON data.catalog_items FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- DELETE: owner o manager global del tenant
CREATE POLICY "catalog_items: owner/manager pot eliminar"
  ON data.catalog_items FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- =============================================================================
-- 5. RLS: data.project_lines
-- =============================================================================

ALTER TABLE data.project_lines ENABLE ROW LEVEL SECURITY;

-- SELECT: qualsevol membre del tenant veu les línies dels projectes
CREATE POLICY "project_lines: veure línies del tenant"
  ON data.project_lines FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- INSERT: qualsevol membre actiu del tenant pot afegir línies
CREATE POLICY "project_lines: membre pot crear línies"
  ON data.project_lines FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- UPDATE: qualsevol membre actiu del tenant pot modificar línies
CREATE POLICY "project_lines: membre pot modificar línies"
  ON data.project_lines FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
  );

-- DELETE: qualsevol membre actiu del tenant pot eliminar línies
CREATE POLICY "project_lines: membre pot eliminar línies"
  ON data.project_lines FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- =============================================================================
-- 6. Triggers updated_at
-- Reutilitza data.set_updated_at() definit a la migració inicial.
-- =============================================================================

CREATE TRIGGER trg_catalog_items_updated_at
  BEFORE UPDATE ON data.catalog_items
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_project_lines_updated_at
  BEFORE UPDATE ON data.project_lines
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- =============================================================================
-- 7. Triggers d'auditoria
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Audit: data.catalog_items
-- Accions: CATALOG_ITEM_CREATED, CATALOG_ITEM_UPDATED,
--          CATALOG_ITEM_ACTIVATED, CATALOG_ITEM_DEACTIVATED, CATALOG_ITEM_DELETED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_catalog_items()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      NULL,
      'CATALOG_ITEM_CREATED',
      'catalog_item',
      NEW.id,
      jsonb_build_object(
        'name',       NEW.name,
        'kind',       NEW.kind,
        'unit_price', NEW.unit_price,
        'sku',        NEW.sku
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.is_active IS DISTINCT FROM NEW.is_active THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        CASE WHEN NEW.is_active THEN 'CATALOG_ITEM_ACTIVATED' ELSE 'CATALOG_ITEM_DEACTIVATED' END,
        'catalog_item', NEW.id,
        jsonb_build_object('name', NEW.name, 'kind', NEW.kind)
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'CATALOG_ITEM_UPDATED',
        'catalog_item', NEW.id,
        jsonb_build_object(
          'name',       NEW.name,
          'kind',       NEW.kind,
          'unit_price', NEW.unit_price,
          'sku',        NEW.sku
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, auth.uid(), NULL,
      'CATALOG_ITEM_DELETED',
      'catalog_item', OLD.id,
      jsonb_build_object(
        'name', OLD.name,
        'kind', OLD.kind,
        'sku',  OLD.sku
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_catalog_items
  AFTER INSERT OR UPDATE OR DELETE ON data.catalog_items
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_catalog_items();

-- ---------------------------------------------------------------------------
-- Audit: data.project_lines
-- Accions: PROJECT_LINE_ADDED, PROJECT_LINE_UPDATED, PROJECT_LINE_REMOVED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_project_lines()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      NULL,
      'PROJECT_LINE_ADDED',
      'project_line',
      NEW.id,
      jsonb_build_object(
        'project_id', NEW.project_id,
        'name',       NEW.name,
        'quantity',   NEW.quantity,
        'unit_price', NEW.unit_price
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NULL,
      'PROJECT_LINE_UPDATED',
      'project_line', NEW.id,
      jsonb_build_object(
        'project_id', NEW.project_id,
        'name',       NEW.name,
        'quantity',   NEW.quantity,
        'unit_price', NEW.unit_price
      )
    );

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, auth.uid(), NULL,
      'PROJECT_LINE_REMOVED',
      'project_line', OLD.id,
      jsonb_build_object(
        'project_id', OLD.project_id,
        'name',       OLD.name,
        'quantity',   OLD.quantity,
        'unit_price', OLD.unit_price
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_project_lines
  AFTER INSERT OR UPDATE OR DELETE ON data.project_lines
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_project_lines();

-- =============================================================================
-- 8. Vista api.catalog_items
-- Filtrada per tenant actiu (UX) i is_active = true.
-- No és actualitzable directament (PostgREST rebutja UPDATE sobre vistes amb
-- WHERE sobre columnes no-PK). Per aquest motiu el GRANT és SELECT-only i
-- totes les escriptures van obligatòriament per les RPCs d'aquesta migració.
-- =============================================================================

CREATE OR REPLACE VIEW api.catalog_items
  WITH (security_invoker = true)
AS
SELECT
  id,
  tenant_id,
  kind,
  name,
  description,
  sku,
  unit,
  unit_price,
  tax_rate,
  currency,
  category,
  is_active,
  created_at,
  updated_at
FROM data.catalog_items
WHERE tenant_id = data.active_tenant_id()
  AND is_active = true;

GRANT SELECT ON api.catalog_items TO authenticated;

-- =============================================================================
-- 9. Vista api.project_lines
-- Inclou subtotal calculat, total amb IVA i join amb catalog_item.
-- =============================================================================

CREATE OR REPLACE VIEW api.project_lines
  WITH (security_invoker = true)
AS
SELECT
  pl.id,
  pl.tenant_id,
  pl.project_id,
  pl.catalog_item_id,
  pl.kind,
  pl.name,
  pl.description,
  pl.unit,
  pl.quantity,
  pl.unit_price,
  pl.discount_pct,
  pl.tax_rate,
  pl.position,
  pl.notes,
  pl.created_at,
  pl.updated_at,
  -- Subtotal sense IVA: qty * unit_price * (1 - discount_pct/100)
  ROUND(
    pl.quantity * pl.unit_price * (1 - pl.discount_pct / 100),
    2
  ) AS subtotal,
  -- Subtotal amb IVA
  ROUND(
    pl.quantity * pl.unit_price * (1 - pl.discount_pct / 100) * (1 + pl.tax_rate / 100),
    2
  ) AS total_with_tax,
  -- Nom de l'ítem del catàleg (si vinculat)
  ci.name AS catalog_item_name,
  ci.sku  AS catalog_item_sku
FROM data.project_lines pl
LEFT JOIN data.catalog_items ci ON ci.id = pl.catalog_item_id
WHERE pl.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.project_lines TO authenticated;

-- =============================================================================
-- 10. RPC: api.create_catalog_item
-- Crea un ítem al catàleg del tenant actiu.
-- SECURITY INVOKER: la RLS INSERT de data.catalog_items exigeix owner/manager,
-- per tant no cal replicar la comprovació aquí.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_catalog_item(
  p_kind        text,
  p_name        text,
  p_description text       DEFAULT NULL,
  p_sku         text       DEFAULT NULL,
  p_unit        text       DEFAULT 'u',
  p_unit_price  numeric    DEFAULT 0,
  p_tax_rate    numeric    DEFAULT 21.00,
  p_category    text       DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id        uuid;
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  INSERT INTO data.catalog_items (
    tenant_id, kind, name, description, sku,
    unit, unit_price, tax_rate, category
  ) VALUES (
    v_tenant_id,
    p_kind::data.catalog_item_kind,
    p_name,
    p_description,
    p_sku,
    p_unit,
    p_unit_price,
    p_tax_rate,
    p_category
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_catalog_item(
  text, text, text, text, text, numeric, numeric, text
) TO authenticated;

COMMENT ON FUNCTION api.create_catalog_item IS
  'Crea un ítem al catàleg del tenant actiu (x-tenant-id). '
  'Requereix rol owner o manager (controlat per RLS sobre data.catalog_items). '
  'Retorna l''UUID del nou ítem.';

-- =============================================================================
-- 11. RPC: api.update_catalog_item
-- Actualitza un ítem existent del catàleg del tenant actiu.
-- SECURITY INVOKER: la RLS UPDATE de data.catalog_items exigeix owner/manager.
-- El filtre AND tenant_id = data.active_tenant_id() a l'UPDATE afegeix una capa
-- extra: un owner d'un segon tenant amb l'UUID no pot editar aquest ítem.
-- Llança no_data_found si l'ítem no existeix o no pertany al tenant actiu;
-- aixo permet al frontend distingir 404 de 403.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.update_catalog_item(
  p_id          uuid,
  p_kind        text,
  p_name        text,
  p_description text    DEFAULT NULL,
  p_sku         text    DEFAULT NULL,
  p_unit        text    DEFAULT 'u',
  p_unit_price  numeric DEFAULT 0,
  p_tax_rate    numeric DEFAULT 21.00,
  p_category    text    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.catalog_items SET
    kind        = p_kind::data.catalog_item_kind,
    name        = p_name,
    description = p_description,
    sku         = p_sku,
    unit        = COALESCE(p_unit, 'u'),
    unit_price  = p_unit_price,
    tax_rate    = p_tax_rate,
    category    = p_category,
    updated_at  = now()
  WHERE id        = p_id
    AND tenant_id = data.active_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'catalog item % not found or not authorized', p_id
      USING ERRCODE = 'no_data_found';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_catalog_item(
  uuid, text, text, text, text, text, numeric, numeric, text
) TO authenticated;

COMMENT ON FUNCTION api.update_catalog_item IS
  'Actualitza un ítem del catàleg del tenant actiu (x-tenant-id). '
  'Requereix rol owner o manager (RLS sobre data.catalog_items). '
  'Llança no_data_found si l''ítem no existeix o no pertany al tenant actiu.';

-- =============================================================================
-- 12. RPC: api.deactivate_catalog_item
-- Desactiva (soft-delete) un ítem del catàleg.
-- SECURITY INVOKER: la RLS UPDATE de data.catalog_items exigeix owner/manager.
-- L'ítem desapareix de la vista api.catalog_items (filtre is_active = true) però
-- les project_lines vinculades conserven el snapshot de nom i preu copiat en el
-- moment de creació: no es fa hard-delete per preservar historial de pressupostos.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.deactivate_catalog_item(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.catalog_items
  SET is_active  = false,
      updated_at = now()
  WHERE id        = p_id
    AND tenant_id = data.active_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'catalog item % not found or not authorized', p_id
      USING ERRCODE = 'no_data_found';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.deactivate_catalog_item(uuid) TO authenticated;

COMMENT ON FUNCTION api.deactivate_catalog_item IS
  'Desactiva (soft-delete) un ítem del catàleg del tenant actiu. '
  'L''ítem desapareix de la vista api.catalog_items (filtre is_active = true). '
  'Les project_lines vinculades conserven el snapshot de nom i preu. '
  'Requereix rol owner o manager (RLS sobre data.catalog_items).';

-- =============================================================================
-- 13. RPC: api.upsert_project_line
-- Crea (p_line_id IS NULL) o actualitza (p_line_id NOT NULL) una línia de projecte.
-- SECURITY INVOKER: la RLS sobre data.project_lines s'encarrega del control d'accés.
--
-- Validació cross-tenant (imprescindible):
-- L'RPC rep UUIDs arbitraris de l'usuari. Sense validació, un usuari podria passar
-- un p_project_id d'un altre tenant (si en coneix l'UUID, p.ex. per força bruta o
-- filtratge previ) i la inserció es completaria amb un tenant_id incorrecte.
-- La comprovació explícita al principi garanteix que el projecte i l'ítem de catàleg
-- (si s'aporta) pertanyen al tenant actiu (x-tenant-id) ABANS de qualsevol DML.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.upsert_project_line(
  p_project_id       uuid,
  p_line_id          uuid       DEFAULT NULL,
  p_catalog_item_id  uuid       DEFAULT NULL,
  p_kind             text       DEFAULT 'service',
  p_name             text       DEFAULT '',
  p_description      text       DEFAULT NULL,
  p_unit             text       DEFAULT 'u',
  p_quantity         numeric    DEFAULT 1,
  p_unit_price       numeric    DEFAULT 0,
  p_discount_pct     numeric    DEFAULT 0,
  p_tax_rate         numeric    DEFAULT 21.00,
  p_position         int        DEFAULT 0,
  p_notes            text       DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id        uuid;
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  -- ── Validació cross-tenant ─────────────────────────────────────────────────
  -- 1. El projecte ha de pertànyer al tenant actiu.
  --    Evita que un p_project_id aliè s'usi com a contenidor de línies.
  IF NOT EXISTS (
    SELECT 1 FROM data.projects
    WHERE id = p_project_id AND tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'project % not found in active tenant %',
      p_project_id, v_tenant_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- 2. L'ítem del catàleg (si s'aporta) ha de pertànyer al tenant actiu.
  --    Evita referenciar preus o descripcions d'un catàleg aliè.
  IF p_catalog_item_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.catalog_items
      WHERE id = p_catalog_item_id AND tenant_id = v_tenant_id
    ) THEN
      RAISE EXCEPTION 'catalog item % not found in active tenant %',
        p_catalog_item_id, v_tenant_id
        USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  -- ── Operació INSERT o UPDATE ───────────────────────────────────────────────
  IF p_line_id IS NULL THEN
    -- Crear nova línia
    INSERT INTO data.project_lines (
      tenant_id, project_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position, notes
    ) VALUES (
      v_tenant_id,
      p_project_id,
      p_catalog_item_id,
      p_kind::data.catalog_item_kind,
      p_name,
      p_description,
      p_unit,
      p_quantity,
      p_unit_price,
      p_discount_pct,
      p_tax_rate,
      p_position,
      p_notes
    ) RETURNING id INTO v_id;
  ELSE
    -- Actualitzar línia existent (verifica tenant_id i project_id per seguretat)
    UPDATE data.project_lines SET
      catalog_item_id = p_catalog_item_id,
      kind            = p_kind::data.catalog_item_kind,
      name            = p_name,
      description     = p_description,
      unit            = p_unit,
      quantity        = p_quantity,
      unit_price      = p_unit_price,
      discount_pct    = p_discount_pct,
      tax_rate        = p_tax_rate,
      position        = p_position,
      notes           = p_notes,
      updated_at      = now()
    WHERE id         = p_line_id
      AND tenant_id  = v_tenant_id
      AND project_id = p_project_id
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_project_line(
  uuid, uuid, uuid, text, text, text, text, numeric, numeric, numeric, numeric, int, text
) TO authenticated;

COMMENT ON FUNCTION api.upsert_project_line IS
  'Crea o actualitza una línia de projecte. Si p_line_id és NULL, crea; si no, actualitza. '
  'La verificació de tenant_id i project_id a l''UPDATE prevé modificació creuada entre tenants. '
  'Retorna l''UUID de la línia creada o actualitzada (NULL si no s''ha trobat la línia a actualitzar).';

-- =============================================================================
-- 14. RPC: api.delete_project_line
-- Elimina una línia de projecte del tenant actiu.
-- SECURITY INVOKER: la RLS sobre data.project_lines s'encarrega del control d'accés.
-- El filtre AND tenant_id evita eliminació creuada entre tenants fins i tot si
-- l'atacant coneix el p_line_id (UUID d'una línia d'un altre tenant).
-- =============================================================================

CREATE OR REPLACE FUNCTION api.delete_project_line(p_line_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  DELETE FROM data.project_lines
  WHERE id        = p_line_id
    AND tenant_id = data.active_tenant_id();
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_project_line(uuid) TO authenticated;

COMMENT ON FUNCTION api.delete_project_line IS
  'Elimina una línia de projecte del tenant actiu. '
  'El filtre AND tenant_id evita eliminació creuada entre tenants.';

-- =============================================================================
-- 15. Triggers de validació cross-tenant FK
--
-- Problema: PostgreSQL valida l'existència de la FK (contacts.id ∈ data.contacts)
-- però NO valida que contacts.tenant_id coincideixi amb el tenant de la fila pare.
-- Sense aquests triggers, un usuari que conegui l'UUID d'un contacte d'un altre
-- tenant podria assignar-lo a un recurs del seu tenant, creant inconsistències
-- o filtrant metadades del contacte aliè.
--
-- Solució: triggers BEFORE INSERT OR UPDATE SECURITY DEFINER que comproven
-- explícitament la coherència tenant_id. SECURITY DEFINER és necessari perquè
-- la RLS de data.contacts (filtrada per jwt) podria impedir la consulta de
-- validació per a contactes d'un altre tenant si s'executés com INVOKER.
--
-- S'apliquen a tres relacions:
--   · data.projects.client_id         → data.contacts
--   · data.calendar_events.contact_id → data.contacts
--   · data.contact_sites.contact_id   → data.contacts
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 15a. Trigger: data.projects.client_id → data.contacts (tenant consistent)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.validate_project_contact_tenant()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  -- NEW.client_id IS NOT NULL garantit pel WHEN del trigger
  IF NOT EXISTS (
    SELECT 1 FROM data.contacts
    WHERE id        = NEW.client_id
      AND tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION
      'contact % does not belong to tenant % (cross-tenant FK on projects.client_id)',
      NEW.client_id, NEW.tenant_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_project_contact_tenant
  BEFORE INSERT OR UPDATE OF client_id ON data.projects
  FOR EACH ROW
  WHEN (NEW.client_id IS NOT NULL)
  EXECUTE FUNCTION data.validate_project_contact_tenant();

-- ---------------------------------------------------------------------------
-- 15b. Trigger: data.calendar_events.contact_id → data.contacts (tenant consistent)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.validate_calendar_event_contact_tenant()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.contacts
    WHERE id        = NEW.contact_id
      AND tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION
      'contact % does not belong to tenant % (cross-tenant FK on calendar_events.contact_id)',
      NEW.contact_id, NEW.tenant_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_calendar_event_contact_tenant
  BEFORE INSERT OR UPDATE OF contact_id ON data.calendar_events
  FOR EACH ROW
  WHEN (NEW.contact_id IS NOT NULL)
  EXECUTE FUNCTION data.validate_calendar_event_contact_tenant();

-- ---------------------------------------------------------------------------
-- 15c. Trigger: data.contact_sites.contact_id → data.contacts (tenant consistent)
-- La RLS de contact_sites ja prevé insercions d'usuaris a tenants aliens, però
-- aquest trigger tanca el forat per a canals interns (triggers, Edge Functions
-- amb service_role) que bypassen la RLS.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.validate_contact_site_tenant()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.contacts
    WHERE id        = NEW.contact_id
      AND tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION
      'contact % does not belong to tenant % (cross-tenant FK on contact_sites.contact_id)',
      NEW.contact_id, NEW.tenant_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_contact_site_tenant
  BEFORE INSERT OR UPDATE OF contact_id ON data.contact_sites
  FOR EACH ROW
  EXECUTE FUNCTION data.validate_contact_site_tenant();

-- =============================================================================
-- 16. Grants sobre data.* per a authenticated
-- Les polítiques RLS limiten les files; els grants habiliten les operacions
-- a nivell de taula (prerequisit per a vistes security_invoker = true i RPCs).
-- api.catalog_items rep només GRANT SELECT: tot el DML va per RPC (seccions 10-12).
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON data.catalog_items  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.project_lines  TO authenticated;
