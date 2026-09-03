-- =============================================================================
-- Migration: 20260502000001_departments_projects_tasks.sql
-- Propòsit : Mòdul unificat de Departaments (estructura lògica), Projectes/Obres
--            (execució) i Tasques. Preparat per suportar treball d'oficina (Tasques)
--            i de camp (Work Orders) en arquitectura Multi-Tenant i Multi-Site.
--
-- Conté:
--   1.  ENUMs: data.project_type, data.project_visibility
--   2.  DDL  : data.departments (arbre organitzatiu)
--   3.  ALTER: data.tenant_members + department_id
--   4.  DDL  : data.projects (taula mestra unificada)
--   5.  DDL  : data.project_members (membres explícits per projecte)
--   6.  DDL  : data.tasks
--   7.  pgmq : cua 'project_events'
--   8.  Funcions helper: my_department_ids(), can_access_project()
--   9.  RLS  : totes les taules noves + patrons de visibilitat per projecte
--   10. Audit: triggers AFTER INSERT/UPDATE/DELETE per departments, projects, tasks
--   11. Vistes: api.departments, api.projects (amb camps virtuals), api.tasks,
--               api.project_members
--   12. RPC  : api.create_project (transaccional + pgmq)
--   13. Grants
--
-- Patró RLS aplicat:
--   · Pertinença tenant  : data.jwt_user_tenants() ? tenant_id::text
--   · Rol global         : data.jwt_user_tenants() -> tenant_id::text ->> 'global_role'
--   · Accés per site     : data.jwt_user_tenants() -> tenant_id::text -> 'sites' ? site_id::text
--   · Visibilitat project: owner/manager global | company | department | private | site
--
-- Auditoria:
--   Accions registrades: DEPARTMENT_CREATED, DEPARTMENT_UPDATED, DEPARTMENT_ACTIVATED,
--   DEPARTMENT_DEACTIVATED, DEPARTMENT_DELETED, PROJECT_CREATED, PROJECT_UPDATED,
--   PROJECT_STATUS_CHANGED, PROJECT_DELETED, TASK_CREATED, TASK_UPDATED,
--   TASK_STATUS_CHANGED, TASK_DELETED
-- =============================================================================

-- =============================================================================
-- 1. ENUMs
-- =============================================================================

CREATE TYPE data.project_type AS ENUM (
  'internal',     -- Projecte intern d'oficina (ex: redisseny web, campanya màrketing)
  'work_order',   -- Obra de camp / treball extern (ex: reparació local, instal·lació)
  'maintenance'   -- Manteniment periòdic (preventiu o correctiu)
);

CREATE TYPE data.project_visibility AS ENUM (
  'private',      -- Només membres explícits de project_members
  'department',   -- Visible per tots els membres del departament assignat
  'company'       -- Visible per tots els membres del tenant (públic)
);

-- =============================================================================
-- 2. DDL: data.departments
-- =============================================================================

CREATE TABLE data.departments (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id)     ON DELETE CASCADE,
  parent_id   uuid                 REFERENCES data.departments(id) ON DELETE SET NULL,
  name        text        NOT NULL,
  code        varchar(10),
  manager_id  uuid                 REFERENCES data.profiles(id)    ON DELETE SET NULL,
  is_active   boolean     NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_departments_tenant_id ON data.departments (tenant_id);
CREATE INDEX idx_departments_parent_id ON data.departments (parent_id);
CREATE INDEX idx_departments_manager_id ON data.departments (manager_id);

-- Codi únic per tenant (quan informat): no es poden repetir codis dins del mateix tenant
CREATE UNIQUE INDEX uq_departments_tenant_code
  ON data.departments (tenant_id, code)
  WHERE code IS NOT NULL;

COMMENT ON TABLE data.departments
  IS 'Arbre organitzatiu lògic del Tenant. Pot tenir múltiples nivells (parent_id). '
     'Un departament pot ser "General" per a pimes sense estructura complexa.';

COMMENT ON COLUMN data.departments.parent_id
  IS 'NULL = departament arrel. NOT NULL = subdepartament d''un altre.';

COMMENT ON COLUMN data.departments.code
  IS 'Codi curt d''identificació (ex: MKT, TIC, OPS). Opcional.';

-- =============================================================================
-- 3. ALTER data.tenant_members: afegir department_id
-- =============================================================================

ALTER TABLE data.tenant_members
  ADD COLUMN department_id uuid REFERENCES data.departments(id) ON DELETE SET NULL;

CREATE INDEX idx_tenant_members_department_id ON data.tenant_members (department_id);

COMMENT ON COLUMN data.tenant_members.department_id
  IS 'Departament al qual pertany el membre. NULL = sense departament assignat. '
     'Usat per a la visibilitat de projectes amb visibility=''department''.';

-- =============================================================================
-- 4. DDL: data.projects
-- =============================================================================

CREATE TABLE data.projects (
  id            uuid                    PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid                    NOT NULL REFERENCES data.tenants(id)     ON DELETE CASCADE,
  type          data.project_type       NOT NULL DEFAULT 'internal',
  name          text                    NOT NULL,
  description   text,
  status        varchar(50)             NOT NULL DEFAULT 'draft',
  visibility    data.project_visibility NOT NULL DEFAULT 'company',
  -- Espai lògic (qui ho executa)
  department_id uuid                    REFERENCES data.departments(id) ON DELETE SET NULL,
  -- Espai físic (on s'executa; crucial per a work_orders)
  site_id       uuid                    REFERENCES data.sites(id)       ON DELETE SET NULL,
  location_id   uuid,   -- Reservat per a futura taula data.locations
  -- Relacions externes opcionals
  client_id     uuid,   -- Reservat per a futura taula data.clients
  -- Calendari
  planned_start timestamptz,
  planned_end   timestamptz,
  -- Metadades
  created_by    uuid                    NOT NULL REFERENCES data.profiles(id),
  created_at    timestamptz             NOT NULL DEFAULT now(),
  updated_at    timestamptz             NOT NULL DEFAULT now()
);

CREATE INDEX idx_projects_tenant_id     ON data.projects (tenant_id);
CREATE INDEX idx_projects_department_id ON data.projects (department_id);
CREATE INDEX idx_projects_site_id       ON data.projects (site_id);
CREATE INDEX idx_projects_tenant_status ON data.projects (tenant_id, status);
CREATE INDEX idx_projects_created_by    ON data.projects (created_by);

COMMENT ON TABLE data.projects
  IS 'Taula mestra d''execució unificada. type=''internal'' per a projectes d''oficina, '
     '''work_order'' per a obres de camp, ''maintenance'' per a manteniments periòdics.';

COMMENT ON COLUMN data.projects.location_id
  IS 'Reservat per a futura taula data.locations (ubicació física dins un site).';

COMMENT ON COLUMN data.projects.client_id
  IS 'Reservat per a futura taula data.clients (client extern del projecte).';

-- =============================================================================
-- 5. DDL: data.project_members
-- =============================================================================

CREATE TABLE data.project_members (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id  uuid        NOT NULL REFERENCES data.projects(id)  ON DELETE CASCADE,
  user_id     uuid        NOT NULL REFERENCES data.profiles(id)  ON DELETE CASCADE,
  role        text        NOT NULL DEFAULT 'contributor'
                          CHECK (role IN ('viewer', 'contributor', 'manager')),
  joined_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (project_id, user_id)
);

CREATE INDEX idx_project_members_user_id    ON data.project_members (user_id);
CREATE INDEX idx_project_members_project_id ON data.project_members (project_id);

COMMENT ON TABLE data.project_members
  IS 'Membres explícits d''un projecte. S''usa per a projectes amb visibility=''private'' '
     'i per a control granular de qui pot editar/gestionar un projecte concret.';

COMMENT ON COLUMN data.project_members.role
  IS 'viewer: lectura. contributor: pot crear/editar tasques. manager: pot gestionar el projecte.';

-- =============================================================================
-- 6. DDL: data.tasks
-- =============================================================================

CREATE TABLE data.tasks (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  project_id  uuid        NOT NULL REFERENCES data.projects(id)  ON DELETE CASCADE,
  title       text        NOT NULL,
  status      varchar(50) NOT NULL DEFAULT 'todo',
  assignee_id uuid                 REFERENCES data.profiles(id)  ON DELETE SET NULL,
  position    int         NOT NULL DEFAULT 0,
  due_date    timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_tasks_project_id  ON data.tasks (project_id);
CREATE INDEX idx_tasks_tenant_id   ON data.tasks (tenant_id);
CREATE INDEX idx_tasks_assignee_id ON data.tasks (assignee_id);
CREATE INDEX idx_tasks_status      ON data.tasks (project_id, status);

COMMENT ON TABLE data.tasks
  IS 'Tasques d''un projecte. En projectes type=''internal'' es marquen com a fetes. '
     'En projectes type=''work_order''/''maintenance'' es complementen amb work_logs (fitxatge GPS).';

-- =============================================================================
-- 7. Cua pgmq per a notificacions de projectes
-- =============================================================================

SELECT pgmq.create('project_events');

-- =============================================================================
-- 8. Funcions helper
-- =============================================================================

-- ---------------------------------------------------------------------------
-- data.my_department_ids(p_tenant_id)
-- Retorna un array amb els department_id de l'usuari autenticat en un tenant.
-- S'usa a la política de visibilitat de projectes (visibility='department').
-- SECURITY DEFINER: evita recursió/avaluació RLS en llegir tenant_members.
-- STABLE: PostgreSQL cachejarà el resultat per tota la query.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.my_department_ids(p_tenant_id uuid)
RETURNS uuid[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(ARRAY_AGG(DISTINCT department_id), '{}')
  FROM data.tenant_members
  WHERE user_id       = auth.uid()
    AND tenant_id     = p_tenant_id
    AND is_active     = true
    AND department_id IS NOT NULL;
$$;

GRANT EXECUTE ON FUNCTION data.my_department_ids(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- data.can_access_project(p_project_id)
-- Retorna TRUE si l'usuari autenticat té accés de lectura al projecte indicat.
-- Encapsula la lògica de visibilitat multi-condició dels projectes.
--
-- Condicions (OR):
--   1. Rol global owner/manager en el tenant del projecte
--   2. Visibilitat 'company' (qualsevol membre del tenant)
--   3. Visibilitat 'department' + usuari pertany al departament
--   4. Visibilitat 'private' + usuari és a project_members
--   5. Usuari té accés al site_id del projecte (JWT sites map)
--
-- SECURITY DEFINER: necessari per llegir data.projects i data.project_members
--   sense recursió (les polítiques RLS d'ambdues taules criden aquesta funció).
-- STABLE: cachejarà el resultat per projecte dins la mateixa query.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.can_access_project(p_project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.projects p
    WHERE p.id = p_project_id
      AND (data.jwt_user_tenants() ? p.tenant_id::text)
      AND (
        -- 1. Global owner/manager: accés total als projectes del tenant
        (data.jwt_user_tenants() -> p.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
        -- 2. Company: visible per qualsevol membre del tenant
        OR p.visibility = 'company'
        -- 3. Department: visible si l'usuari pertany al departament del projecte
        OR (
          p.visibility    = 'department'
          AND p.department_id IS NOT NULL
          AND p.department_id = ANY(data.my_department_ids(p.tenant_id))
        )
        -- 4. Private: l'usuari és membre explícit del projecte
        OR (
          p.visibility = 'private'
          AND EXISTS (
            SELECT 1
            FROM data.project_members pm
            WHERE pm.project_id = p.id
              AND pm.user_id    = auth.uid()
          )
        )
        -- 5. Site access: l'usuari té accés al site del projecte via JWT
        OR (
          p.site_id IS NOT NULL
          AND (data.jwt_user_tenants() -> p.tenant_id::text -> 'sites') ? p.site_id::text
        )
      )
  );
$$;

GRANT EXECUTE ON FUNCTION data.can_access_project(uuid) TO authenticated;

-- =============================================================================
-- 9. Row Level Security
-- =============================================================================

-- ---------------------------------------------------------------------------
-- data.departments
-- ---------------------------------------------------------------------------
ALTER TABLE data.departments ENABLE ROW LEVEL SECURITY;

-- SELECT: qualsevol membre del tenant veu els departaments actius
CREATE POLICY "departments: veure departaments del tenant"
  ON data.departments FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- INSERT: owner o manager global
CREATE POLICY "departments: owner/manager pot crear"
  ON data.departments FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- UPDATE: owner o manager global
CREATE POLICY "departments: owner/manager pot modificar"
  ON data.departments FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- DELETE: owner global únicament
CREATE POLICY "departments: owner pot eliminar"
  ON data.departments FOR DELETE
  TO authenticated
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
  );

-- ---------------------------------------------------------------------------
-- data.projects — lògica de visibilitat multi-condició
-- ---------------------------------------------------------------------------
ALTER TABLE data.projects ENABLE ROW LEVEL SECURITY;

-- SELECT: multi-condició de visibilitat (see data.can_access_project)
CREATE POLICY "projects: veure per lògica de visibilitat"
  ON data.projects FOR SELECT
  TO authenticated
  USING (
    (data.jwt_user_tenants() ? tenant_id::text)
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      -- 1. Global owner/manager: veu tots els projectes del tenant
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      -- 2. Company: qualsevol membre del tenant
      OR visibility = 'company'
      -- 3. Department: l'usuari pertany al departament del projecte
      OR (
        visibility    = 'department'
        AND department_id IS NOT NULL
        AND department_id = ANY(data.my_department_ids(tenant_id))
      )
      -- 4. Private: membre explícit del projecte
      OR (
        visibility = 'private'
        AND EXISTS (
          SELECT 1
          FROM data.project_members pm
          WHERE pm.project_id = data.projects.id
            AND pm.user_id    = auth.uid()
        )
      )
      -- 5. Site access via JWT
      OR (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites') ? site_id::text
      )
    )
  );

-- INSERT: membre actiu del tenant amb rol escriptor (no viewer)
CREATE POLICY "projects: owner/manager/member pot crear"
  ON data.projects FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager', 'member')
  );

-- UPDATE: global owner/manager OR project manager explícit
CREATE POLICY "projects: owner/manager global o project manager pot modificar"
  ON data.projects FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR EXISTS (
        SELECT 1
        FROM data.project_members pm
        WHERE pm.project_id = data.projects.id
          AND pm.user_id    = auth.uid()
          AND pm.role       = 'manager'
      )
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR EXISTS (
        SELECT 1
        FROM data.project_members pm
        WHERE pm.project_id = data.projects.id
          AND pm.user_id    = auth.uid()
          AND pm.role       = 'manager'
      )
    )
  );

-- DELETE: owner o manager global
CREATE POLICY "projects: owner/manager pot eliminar"
  ON data.projects FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- ---------------------------------------------------------------------------
-- data.project_members
-- ---------------------------------------------------------------------------
ALTER TABLE data.project_members ENABLE ROW LEVEL SECURITY;

-- SELECT: qualsevol usuari que pugui veure el projecte
CREATE POLICY "project_members: veure membres de projectes accessibles"
  ON data.project_members FOR SELECT
  TO authenticated
  USING (data.can_access_project(project_id));

-- INSERT: global owner/manager del tenant, o project manager del projecte
CREATE POLICY "project_members: owner/manager pot afegir membres"
  ON data.project_members FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM data.projects p
      WHERE p.id = project_id
        AND data.jwt_user_tenants() ? p.tenant_id::text
        AND (
          (data.jwt_user_tenants() -> p.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
          OR EXISTS (
            SELECT 1
            FROM data.project_members pm2
            WHERE pm2.project_id = p.id
              AND pm2.user_id    = auth.uid()
              AND pm2.role       = 'manager'
          )
        )
    )
  );

-- UPDATE (canvi de rol): global owner/manager del tenant
CREATE POLICY "project_members: owner/manager pot canviar rols"
  ON data.project_members FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM data.projects p
      WHERE p.id = project_id
        AND (data.jwt_user_tenants() -> p.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM data.projects p
      WHERE p.id = project_id
        AND (data.jwt_user_tenants() -> p.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

-- DELETE: global owner/manager del tenant
CREATE POLICY "project_members: owner/manager pot eliminar membres"
  ON data.project_members FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM data.projects p
      WHERE p.id = project_id
        AND (data.jwt_user_tenants() -> p.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

-- ---------------------------------------------------------------------------
-- data.tasks
-- ---------------------------------------------------------------------------
ALTER TABLE data.tasks ENABLE ROW LEVEL SECURITY;

-- SELECT: membre del tenant + accés al projecte (via lògica de visibilitat)
CREATE POLICY "tasks: veure tasques de projectes accessibles"
  ON data.tasks FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.can_access_project(project_id)
  );

-- INSERT: membre amb rol escriptor (no viewer) que pot accedir al projecte
CREATE POLICY "tasks: owner/manager/member pot crear tasques"
  ON data.tasks FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager', 'member')
    AND data.can_access_project(project_id)
  );

-- UPDATE: membre escriptor amb accés al projecte
CREATE POLICY "tasks: owner/manager/member pot modificar tasques"
  ON data.tasks FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager', 'member')
    AND data.can_access_project(project_id)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager', 'member')
  );

-- DELETE: owner o manager global
CREATE POLICY "tasks: owner/manager pot eliminar tasques"
  ON data.tasks FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- =============================================================================
-- 10. Grants sobre data.* per a authenticated
-- =============================================================================
-- Les polítiques RLS limiten les files; els grants aquí habiliten les operacions
-- a nivell de taula (prerequisit per a vistes security_invoker = true).
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON data.departments     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.projects        TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.project_members TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.tasks           TO authenticated;

-- =============================================================================
-- 10b. Triggers updated_at per a les noves taules
-- Reutilitza data.set_updated_at() definit a la migració inicial.
-- =============================================================================

CREATE TRIGGER trg_departments_updated_at
  BEFORE UPDATE ON data.departments
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_projects_updated_at
  BEFORE UPDATE ON data.projects
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_tasks_updated_at
  BEFORE UPDATE ON data.tasks
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- =============================================================================
-- 11. Triggers d'auditoria
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Audit: data.departments
-- Accions: DEPARTMENT_CREATED, DEPARTMENT_UPDATED,
--          DEPARTMENT_ACTIVATED, DEPARTMENT_DEACTIVATED, DEPARTMENT_DELETED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_departments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.manager_id),
      NULL,
      'DEPARTMENT_CREATED',
      'department',
      NEW.id,
      jsonb_build_object(
        'name',      NEW.name,
        'code',      NEW.code,
        'parent_id', NEW.parent_id
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.is_active IS DISTINCT FROM NEW.is_active THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        CASE WHEN NEW.is_active THEN 'DEPARTMENT_ACTIVATED' ELSE 'DEPARTMENT_DEACTIVATED' END,
        'department', NEW.id,
        jsonb_build_object('name', NEW.name)
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'DEPARTMENT_UPDATED',
        'department', NEW.id,
        jsonb_build_object(
          'old', jsonb_build_object('name', OLD.name, 'code', OLD.code, 'manager_id', OLD.manager_id),
          'new', jsonb_build_object('name', NEW.name, 'code', NEW.code, 'manager_id', NEW.manager_id)
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, auth.uid(), NULL,
      'DEPARTMENT_DELETED',
      'department', OLD.id,
      jsonb_build_object('name', OLD.name, 'code', OLD.code)
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_departments
  AFTER INSERT OR UPDATE OR DELETE ON data.departments
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_departments();

-- ---------------------------------------------------------------------------
-- Audit: data.projects
-- Accions: PROJECT_CREATED, PROJECT_STATUS_CHANGED, PROJECT_UPDATED, PROJECT_DELETED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_projects()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by),
      NEW.site_id,
      'PROJECT_CREATED',
      'project',
      NEW.id,
      jsonb_build_object(
        'name',       NEW.name,
        'type',       NEW.type,
        'status',     NEW.status,
        'visibility', NEW.visibility
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'PROJECT_STATUS_CHANGED',
        'project', NEW.id,
        jsonb_build_object(
          'old_status', OLD.status,
          'new_status', NEW.status,
          'name',       NEW.name
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'PROJECT_UPDATED',
        'project', NEW.id,
        jsonb_build_object(
          'old', jsonb_build_object('name', OLD.name, 'status', OLD.status, 'visibility', OLD.visibility),
          'new', jsonb_build_object('name', NEW.name, 'status', NEW.status, 'visibility', NEW.visibility)
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, auth.uid(), OLD.site_id,
      'PROJECT_DELETED',
      'project', OLD.id,
      jsonb_build_object('name', OLD.name, 'type', OLD.type, 'status', OLD.status)
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_projects
  AFTER INSERT OR UPDATE OR DELETE ON data.projects
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_projects();

-- ---------------------------------------------------------------------------
-- Audit: data.tasks
-- Accions: TASK_CREATED, TASK_STATUS_CHANGED, TASK_UPDATED, TASK_DELETED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_tasks()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NULL,
      'TASK_CREATED',
      'task', NEW.id,
      jsonb_build_object(
        'title',      NEW.title,
        'status',     NEW.status,
        'project_id', NEW.project_id
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'TASK_STATUS_CHANGED',
        'task', NEW.id,
        jsonb_build_object(
          'old_status', OLD.status,
          'new_status', NEW.status,
          'title',      NEW.title,
          'project_id', NEW.project_id
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'TASK_UPDATED',
        'task', NEW.id,
        jsonb_build_object(
          'title',      NEW.title,
          'project_id', NEW.project_id,
          'assignee_id', NEW.assignee_id
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, auth.uid(), NULL,
      'TASK_DELETED',
      'task', OLD.id,
      jsonb_build_object('title', OLD.title, 'project_id', OLD.project_id)
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_tasks
  AFTER INSERT OR UPDATE OR DELETE ON data.tasks
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_tasks();

-- =============================================================================
-- 12. Vistes api.*
-- =============================================================================

-- ---------------------------------------------------------------------------
-- api.departments — arbre de departaments del tenant
-- Updatable: sí (taula única, sense camps virtuals → auto-updatable per PostgreSQL)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.departments
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    parent_id,
    name,
    code,
    manager_id,
    is_active,
    created_at,
    updated_at
  FROM data.departments;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.departments TO authenticated;

-- ---------------------------------------------------------------------------
-- api.projects — projectes amb camps virtuals calculats
-- Updatable: NO (conté subconsultes agregades). Les escriptures van per RPC.
-- Camps virtuals:
--   task_count         → nombre total de tasques del projecte
--   pending_task_count → nombre de tasques sense estat 'done'
--   member_count       → membres explícits del projecte
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.projects
  WITH (security_invoker = true) AS
  SELECT
    p.id,
    p.tenant_id,
    p.type,
    p.name,
    p.description,
    p.status,
    p.visibility,
    p.department_id,
    p.site_id,
    p.location_id,
    p.client_id,
    p.planned_start,
    p.planned_end,
    p.created_by,
    p.created_at,
    p.updated_at,
    -- Camps virtuals
    (
      SELECT COUNT(*)::int
      FROM data.tasks t
      WHERE t.project_id = p.id
    ) AS task_count,
    (
      SELECT COUNT(*)::int
      FROM data.tasks t
      WHERE t.project_id = p.id
        AND t.status     <> 'done'
    ) AS pending_task_count,
    (
      SELECT COUNT(*)::int
      FROM data.project_members pm
      WHERE pm.project_id = p.id
    ) AS member_count
  FROM data.projects p;

GRANT SELECT ON api.projects TO authenticated;

-- RULE per a INSERT directe (sense camps virtuals):
-- Per a creació transaccional completa (amb project_members + pgmq) usa api.create_project().
CREATE RULE "api_projects_insert" AS ON INSERT TO api.projects
  DO INSTEAD
  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, client_id,
    planned_start, planned_end, created_by
  )
  VALUES (
    NEW.tenant_id,
    COALESCE(NEW.type, 'internal'),
    NEW.name,
    NEW.description,
    COALESCE(NEW.status, 'draft'),
    COALESCE(NEW.visibility, 'company'),
    NEW.department_id,
    NEW.site_id,
    NEW.location_id,
    NEW.client_id,
    NEW.planned_start,
    NEW.planned_end,
    COALESCE(NEW.created_by, auth.uid())
  );

-- Habilitar INSERT a través de la vista
GRANT INSERT ON api.projects TO authenticated;

-- RULE per a UPDATE (sense camps virtuals):
CREATE RULE "api_projects_update" AS ON UPDATE TO api.projects
  DO INSTEAD
  UPDATE data.projects SET
    type          = NEW.type,
    name          = NEW.name,
    description   = NEW.description,
    status        = NEW.status,
    visibility    = NEW.visibility,
    department_id = NEW.department_id,
    site_id       = NEW.site_id,
    location_id   = NEW.location_id,
    client_id     = NEW.client_id,
    planned_start = NEW.planned_start,
    planned_end   = NEW.planned_end
  WHERE id = OLD.id;

-- Habilitar UPDATE a través de la vista
GRANT UPDATE ON api.projects TO authenticated;

-- RULE per a DELETE:
CREATE RULE "api_projects_delete" AS ON DELETE TO api.projects
  DO INSTEAD
  DELETE FROM data.projects WHERE id = OLD.id;

-- Habilitar DELETE a través de la vista
GRANT DELETE ON api.projects TO authenticated;

-- ---------------------------------------------------------------------------
-- api.tasks — tasques dels projectes
-- Updatable: sí (taula única, sense camps virtuals → auto-updatable per PostgreSQL)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.tasks
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    project_id,
    title,
    status,
    assignee_id,
    position,
    due_date,
    created_at,
    updated_at
  FROM data.tasks;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.tasks TO authenticated;

-- ---------------------------------------------------------------------------
-- api.project_members — membres explícits d'un projecte
-- Updatable: NO (JOIN de dues taules → no auto-updatable). Només lectura.
-- Les escriptures van directament a data.project_members (via RLS).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.project_members
  WITH (security_invoker = true) AS
  SELECT
    pm.id,
    pm.project_id,
    pm.user_id,
    pm.role,
    pm.joined_at,
    p.full_name,
    p.email,
    p.avatar_url
  FROM data.project_members pm
  JOIN data.profiles p ON p.id = pm.user_id;

GRANT SELECT ON api.project_members TO authenticated;

-- =============================================================================
-- 13. RPC: api.create_project
-- =============================================================================
-- Funció transaccional que:
--   1. Valida autenticació i permisos (owner/manager/member del tenant)
--   2. Insereix el projecte a data.projects
--   3. Afegeix el creador com a 'manager' a data.project_members
--   4. Si planned_start != NULL, envia missatge asíncron a la cua 'project_events'
--      via pgmq.send per a notificació/integració externa
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_project(
  p_tenant_id     uuid,
  p_name          text,
  p_type          data.project_type       DEFAULT 'internal',
  p_description   text                    DEFAULT NULL,
  p_status        varchar                 DEFAULT 'draft',
  p_visibility    data.project_visibility DEFAULT 'company',
  p_department_id uuid                    DEFAULT NULL,
  p_site_id       uuid                    DEFAULT NULL,
  p_location_id   uuid                    DEFAULT NULL,
  p_client_id     uuid                    DEFAULT NULL,
  p_planned_start timestamptz             DEFAULT NULL,
  p_planned_end   timestamptz             DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_project_id uuid;
  v_role       text;
BEGIN
  -- 1. Requereix usuari autenticat
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  -- 2. Verificar que l'usuari és membre actiu del tenant amb rol escriptor
  v_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_role NOT IN ('owner', 'manager', 'member') THEN
    RAISE EXCEPTION 'forbidden: el rol ''%'' no pot crear projectes al tenant %', v_role, p_tenant_id;
  END IF;

  -- 3. Inserir el projecte
  INSERT INTO data.projects (
    tenant_id, type, name, description, status, visibility,
    department_id, site_id, location_id, client_id,
    planned_start, planned_end, created_by
  )
  VALUES (
    p_tenant_id, p_type, p_name, p_description,
    COALESCE(p_status, 'draft'), COALESCE(p_visibility, 'company'),
    p_department_id, p_site_id, p_location_id, p_client_id,
    p_planned_start, p_planned_end, v_user_id
  )
  RETURNING id INTO v_project_id;

  -- 4. Afegir el creador com a project manager
  INSERT INTO data.project_members (project_id, user_id, role)
  VALUES (v_project_id, v_user_id, 'manager');

  -- 5. Si té data d'inici planificada → enviar a cua project_events (asíncron)
  IF p_planned_start IS NOT NULL THEN
    PERFORM pgmq.send(
      'project_events',
      jsonb_build_object(
        'event',         'PROJECT_CREATED',
        'project_id',    v_project_id,
        'tenant_id',     p_tenant_id,
        'name',          p_name,
        'type',          p_type,
        'planned_start', p_planned_start,
        'created_by',    v_user_id
      )
    );
  END IF;

  RETURN v_project_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_project(
  uuid, text, data.project_type, text, varchar, data.project_visibility,
  uuid, uuid, uuid, uuid, timestamptz, timestamptz
) TO authenticated;

COMMENT ON FUNCTION api.create_project IS
  'Crea un projecte de forma transaccional: insereix el projecte, '
  'afegeix el creador com a manager de project_members, i si té planned_start '
  'envia un missatge asíncron a la cua pgmq ''project_events''.';
