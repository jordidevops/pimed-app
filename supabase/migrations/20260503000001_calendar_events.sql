-- =============================================================================
-- Migration: 20260503000001_calendar_events.sql
-- Propòsit : Sistema de Calendari Multi-tenant i Multi-site genèric.
--            Patró 'Read Model' (CQRS): la taula és un mirall d'events de
--            qualsevol mòdul. Les entitats de negoci es creen transaccionalment
--            junt amb el seu event de calendari.
--
-- Conté:
--   1. DDL  : data.calendar_events
--   2. Índexs compostos per a consultes mensuals òptimes
--   3. Helper: data.jwt_can_see_calendar_event(p_tenant_id, p_perms, p_site_id)
--   4. RLS  : lectura multi-condició (permisos + owner bypass + addon check)
--   5. Audit: trigger AFTER INSERT/UPDATE/DELETE
--   6. Vista: api.calendar_events (security_invoker = true)
--   7. RPC  : api.create_task_with_event() — exemple transaccional
--   8. Seed addon: 'addon_calendar' a data.billing_addons
--   9. Grants
--
-- Patró RLS de visibilitat d'events:
--   L'event és visible si es compleix UNA d'aquestes condicions:
--     A. L'usuari és owner_id de l'event (bypass total)
--     B. required_permissions és buit → event públic al tenant
--     C. Event global (site_id IS NULL):
--          comprova intersecció de required_permissions amb global_permissions del JWT
--     D. Event de site (site_id IS NOT NULL):
--          comprova intersecció amb global_permissions (herència) O
--          permisos específics del site al JWT
--
-- Auditoria:
--   CALENDAR_EVENT_CREATED, CALENDAR_EVENT_UPDATED, CALENDAR_EVENT_DELETED
-- =============================================================================

-- =============================================================================
-- 1. DDL: data.calendar_events
-- =============================================================================

CREATE TABLE data.calendar_events (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Context multi-tenant i multi-site
  tenant_id            uuid        NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  site_id              uuid                 REFERENCES data.sites(id)     ON DELETE CASCADE,
    -- NULL  → event global del tenant (visible per tots els membres)
    -- NOT NULL → event d'un site concret

  -- Polimorfisme: de quina entitat de negoci prové
  entity_type          text        NOT NULL,
    -- Ex: 'task', 'project', 'work_order', 'invoice', 'maintenance'
  entity_id            uuid        NOT NULL,
    -- UUID de la fila concreta a la taula de l'entitat

  -- Dades de l'event
  title                text        NOT NULL,
  description          text,
  start_at             timestamptz NOT NULL,
  end_at               timestamptz,
    -- NULL → event puntual (sense durada explícita)
  all_day              boolean     NOT NULL DEFAULT false,

  -- Vinculació al sistema d'addons (Hub and Spoke)
  module_id            text        REFERENCES data.billing_addons(id) ON DELETE SET NULL,
    -- Ex: 'addon_calendar', 'addon_invoices'. NULL → core, sempre visible.

  -- Control d'accés injectat a la creació (Read Model / CQRS)
  -- S'omple transaccionalment per la capa de servei/RPC, mai per l'usuari.
  required_permissions text[]      NOT NULL DEFAULT '{}',
    -- Ex: ARRAY['calendar.view'] o ARRAY['invoices.view']
    -- Buit ({}) → event públic per a qualsevol membre del tenant
  owner_id             uuid                 REFERENCES data.profiles(id) ON DELETE SET NULL,
    -- Creador de l'entitat. Té accés de lectura sempre, independentment de permisos.

  -- Metadades visuals (usades pel Registry del frontend)
  color                text,
    -- Ex: '#3b82f6', 'blue', 'red'. NULL → el Registry usa el color per defecte del mòdul.
  metadata             jsonb,
    -- Camp lliure: dades extra que el frontend pot mostrar al modal de detall.

  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.calendar_events
  IS 'Read Model de Calendari (CQRS). Mirall d''events de qualsevol mòdul. '
     'Les entitats de negoci insereixen el seu event de forma transaccional. '
     'No modificar directament: usar els RPCs de cada mòdul.';

COMMENT ON COLUMN data.calendar_events.site_id
  IS 'NULL = event global del tenant. NOT NULL = event d''un site concret.';

COMMENT ON COLUMN data.calendar_events.entity_type
  IS 'Discriminador polimòrfic. Ex: ''task'', ''project'', ''invoice'', ''maintenance''.';

COMMENT ON COLUMN data.calendar_events.module_id
  IS 'Addon del sistema al qual pertany l''event. NULL = core (sempre visible). '
     'Si l''addon és canceled/expired, el frontend el mostra en gris o l''amaga.';

COMMENT ON COLUMN data.calendar_events.required_permissions
  IS 'Array de permisos necessaris per veure l''event. {} = públic per al tenant. '
     'Ex: ARRAY[''invoices.view''] per a events de facturació.';

COMMENT ON COLUMN data.calendar_events.owner_id
  IS 'Creador de l''entitat. Sempre pot veure l''event, independentment de required_permissions.';

-- =============================================================================
-- 2. Índexs compostos per a consultes mensuals
-- =============================================================================

-- Consulta principal del calendari: rango mensual per tenant
CREATE INDEX idx_calendar_events_tenant_range
  ON data.calendar_events (tenant_id, start_at, end_at);

-- Filtre per site + rang mensual (vista per local)
CREATE INDEX idx_calendar_events_site_range
  ON data.calendar_events (site_id, start_at)
  WHERE site_id IS NOT NULL;

-- Filtre per entitat (trobar events d'una tasca o projecte concret)
CREATE INDEX idx_calendar_events_entity
  ON data.calendar_events (entity_type, entity_id);

-- Filtre per owner (bypass RLS: l'usuari veu els seus propis events ràpidament)
CREATE INDEX idx_calendar_events_owner
  ON data.calendar_events (owner_id, tenant_id);

-- Filtre per module_id (per a l'addon check del frontend)
CREATE INDEX idx_calendar_events_module
  ON data.calendar_events (module_id)
  WHERE module_id IS NOT NULL;

-- =============================================================================
-- 3. Funció helper RLS: data.jwt_can_see_calendar_event
-- =============================================================================
--
-- Encapsula la lògica de visibilitat multi-condició per evitar repetir-la
-- a cada política. SECURITY DEFINER per evitar recursió sobre RLS.
--
-- Condicions (OR):
--   A. owner_id = auth.uid()                         → bypass total
--   B. required_permissions = '{}'                   → públic al tenant
--   C. site_id IS NULL → intersecció perms globals JWT
--   D. site_id IS NOT NULL → intersecció (globals | site concret JWT)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.jwt_can_see_calendar_event(
  p_tenant_id          uuid,
  p_required_perms     text[],
  p_site_id            uuid,
  p_owner_id           uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT
    -- A. Owner bypass
    p_owner_id = auth.uid()
    -- B. Event públic (sense restriccions de permís)
    OR cardinality(p_required_perms) = 0
    -- C/D. Comprova permisos via RBAC helper per cada clau requerida
    --      (TRUE si TOTES les claus requerides estan satisfetes)
    OR (
      cardinality(p_required_perms) > 0
      AND NOT EXISTS (
        SELECT 1
        FROM unnest(p_required_perms) AS req_perm
        WHERE NOT data.jwt_has_permission(p_tenant_id, req_perm, p_site_id)
      )
    );
$$;

GRANT EXECUTE ON FUNCTION data.jwt_can_see_calendar_event(uuid, text[], uuid, uuid)
  TO authenticated;

-- =============================================================================
-- 4. Row Level Security
-- =============================================================================

ALTER TABLE data.calendar_events ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- SELECT: pertinença al tenant + lògica de visibilitat multi-condició
-- ---------------------------------------------------------------------------
CREATE POLICY "calendar_events: veure per permisos i context de site"
  ON data.calendar_events FOR SELECT
  TO authenticated
  USING (
    -- 1. L'usuari pertany al tenant
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    -- 2. Té accés específic a l'event (owner | públic | permisos)
    AND data.jwt_can_see_calendar_event(
      tenant_id,
      required_permissions,
      site_id,
      owner_id
    )
  );

-- ---------------------------------------------------------------------------
-- INSERT: creadors amb permís 'calendar.edit' en el context adequat
-- Els events es creen des de RPCs de mòdul, no directament per l'usuari.
-- Però deixem el grant per a escenaris futurs i tests.
-- ---------------------------------------------------------------------------
CREATE POLICY "calendar_events: crear amb permís calendar.edit"
  ON data.calendar_events FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_permission(tenant_id, 'calendar.edit', site_id)
  );

-- ---------------------------------------------------------------------------
-- UPDATE: owner de l'event o usuaris amb 'calendar.manage'
-- ---------------------------------------------------------------------------
CREATE POLICY "calendar_events: modificar si owner o calendar.manage"
  ON data.calendar_events FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      owner_id = auth.uid()
      OR data.jwt_has_permission(tenant_id, 'calendar.manage', site_id)
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      owner_id = auth.uid()
      OR data.jwt_has_permission(tenant_id, 'calendar.manage', site_id)
    )
  );

-- ---------------------------------------------------------------------------
-- DELETE: 'calendar.manage' únicament (operació irreversible)
-- ---------------------------------------------------------------------------
CREATE POLICY "calendar_events: eliminar amb calendar.manage"
  ON data.calendar_events FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'calendar.manage', site_id)
  );

-- =============================================================================
-- 5. Grants
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON data.calendar_events TO authenticated;

-- =============================================================================
-- 6. Trigger d'auditoria
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_audit_calendar_events()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NEW.owner_id), NEW.site_id,
      'CALENDAR_EVENT_CREATED',
      'calendar_event', NEW.id,
      jsonb_build_object(
        'entity_type', NEW.entity_type,
        'entity_id',   NEW.entity_id,
        'title',       NEW.title,
        'start_at',    NEW.start_at,
        'module_id',   NEW.module_id
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NEW.site_id,
      'CALENDAR_EVENT_UPDATED',
      'calendar_event', NEW.id,
      jsonb_build_object(
        'old', jsonb_build_object('title', OLD.title, 'start_at', OLD.start_at, 'end_at', OLD.end_at),
        'new', jsonb_build_object('title', NEW.title, 'start_at', NEW.start_at, 'end_at', NEW.end_at)
      )
    );

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, auth.uid(), OLD.site_id,
      'CALENDAR_EVENT_DELETED',
      'calendar_event', OLD.id,
      jsonb_build_object(
        'entity_type', OLD.entity_type,
        'entity_id',   OLD.entity_id,
        'title',       OLD.title
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_calendar_events
  AFTER INSERT OR UPDATE OR DELETE ON data.calendar_events
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_calendar_events();

-- =============================================================================
-- 7. Vista: api.calendar_events
-- =============================================================================
-- Inclou el camp addon_status per a l'addon check del frontend sense JOIN
-- addicional a cada component.
-- =============================================================================

CREATE OR REPLACE VIEW api.calendar_events
  WITH (security_invoker = true) AS
  SELECT
    ce.id,
    ce.tenant_id,
    ce.site_id,
    ce.entity_type,
    ce.entity_id,
    ce.title,
    ce.description,
    ce.start_at,
    ce.end_at,
    ce.all_day,
    ce.module_id,
    ce.required_permissions,
    ce.owner_id,
    ce.color,
    ce.metadata,
    ce.created_at,
    ce.updated_at,
    -- Camp virtual: estat de l'addon per al tenant actiu (per a l'addon check del frontend)
    ta.status AS addon_status
      -- NULL si module_id és NULL (event core) o si el tenant no té l'addon subscrit
  FROM data.calendar_events ce
  LEFT JOIN data.tenant_addons ta
    ON ta.addon_id  = ce.module_id
    AND ta.tenant_id = ce.tenant_id;

GRANT SELECT ON api.calendar_events TO authenticated;

-- INSERT via RULE (sense camp virtual addon_status):
CREATE RULE "api_calendar_events_insert" AS ON INSERT TO api.calendar_events
  DO INSTEAD
  INSERT INTO data.calendar_events (
    tenant_id, site_id, entity_type, entity_id, title, description,
    start_at, end_at, all_day, module_id, required_permissions,
    owner_id, color, metadata
  )
  VALUES (
    NEW.tenant_id, NEW.site_id, NEW.entity_type, NEW.entity_id,
    NEW.title, NEW.description, NEW.start_at, NEW.end_at,
    COALESCE(NEW.all_day, false), NEW.module_id,
    COALESCE(NEW.required_permissions, '{}'),
    COALESCE(NEW.owner_id, auth.uid()),
    NEW.color, NEW.metadata
  );

GRANT INSERT ON api.calendar_events TO authenticated;

-- =============================================================================
-- 8. RPC Transaccional: api.create_task_with_event
-- =============================================================================
-- Exemple canònic del patró CQRS: crea una tasca (entitat de negoci) i el seu
-- corresponent event de calendari en una sola transacció atòmica.
--
-- La funció:
--   1. Valida autenticació i permisos (calendar.edit + accés al tenant)
--   2. Insereix la tasca a data.tasks
--   3. Insereix el calendar_event vinculat (entity_type='task', entity_id=nova tasca)
--      passant explícitament required_permissions i site_id
--   4. Retorna el JSON amb els IDs de les dues entitats creades
--
-- Ús des del frontend:
--   const { data } = await supabase.rpc('create_task_with_event', {
--     p_tenant_id: selectedTenantId,
--     p_project_id: projectId,
--     p_title: 'Revisió mensual',
--     p_start_at: '2026-06-01T09:00:00Z',
--     p_site_id: selectedSiteId,  // null si tasca global
--   })
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_task_with_event(
  p_tenant_id   uuid,
  p_project_id  uuid,
  p_title       text,
  p_start_at    timestamptz,
  p_end_at      timestamptz   DEFAULT NULL,
  p_description text          DEFAULT NULL,
  p_status      varchar       DEFAULT 'todo',
  p_assignee_id uuid          DEFAULT NULL,
  p_site_id     uuid          DEFAULT NULL,
  p_all_day     boolean       DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_task_id    uuid;
  v_event_id   uuid;
BEGIN
  -- 1. Autenticació
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  -- 2. Permís 'calendar.edit' en el context (global o de site)
  IF NOT data.jwt_has_permission(p_tenant_id, 'calendar.edit', p_site_id) THEN
    RAISE EXCEPTION 'forbidden: permís calendar.edit necessari per crear events al tenant %', p_tenant_id;
  END IF;

  -- 3. Inserir la tasca (entitat de negoci)
  INSERT INTO data.tasks (tenant_id, project_id, title, status, assignee_id)
  VALUES (p_tenant_id, p_project_id, p_title, COALESCE(p_status, 'todo'), p_assignee_id)
  RETURNING id INTO v_task_id;

  -- 4. Inserir el calendar_event vinculat a la tasca (Read Model)
  --    required_permissions reflecteix el mínim per veure events de tasques
  INSERT INTO data.calendar_events (
    tenant_id,
    site_id,
    entity_type,
    entity_id,
    title,
    description,
    start_at,
    end_at,
    all_day,
    module_id,
    required_permissions,
    owner_id
  )
  VALUES (
    p_tenant_id,
    p_site_id,
    'task',
    v_task_id,
    p_title,
    p_description,
    p_start_at,
    p_end_at,
    COALESCE(p_all_day, false),
    'addon_calendar',
    ARRAY['calendar.view'],   -- permís mínim: qualsevol que pugui veure el calendari
    v_user_id
  )
  RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'task_id',  v_task_id,
    'event_id', v_event_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_task_with_event(
  uuid, uuid, text, timestamptz, timestamptz, text, varchar, uuid, uuid, boolean
) TO authenticated;

COMMENT ON FUNCTION api.create_task_with_event IS
  'Exemple transaccional CQRS: crea una tasca (data.tasks) i el seu event de '
  'calendari (data.calendar_events) de forma atòmica. Usar com a plantilla '
  'per a altres RPCs de mòdul (invoices, maintenance, work_orders).';

-- =============================================================================
-- 9. Seed addon: addon_calendar
-- =============================================================================

INSERT INTO data.billing_addons (
  id,
  name,
  price_monthly,
  trial_days,
  trial_cooldown_months,
  spoke_config
)
VALUES (
  'addon_calendar',
  'Calendari Unificat',
  0,    -- inclòs en tots els plans base
  0,
  0,
  '{"features": {"calendar_enabled": true}}'::jsonb
)
ON CONFLICT (id) DO NOTHING;
