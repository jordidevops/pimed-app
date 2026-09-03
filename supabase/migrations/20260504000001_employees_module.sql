-- =============================================================================
-- Migration: 20260504000001_employees_module.sql
-- Propòsit : Mòdul Employees (RRHH bàsic) — prerequisit bloquejador per a
--            Time Attendance i Payroll.
--
-- Conté:
--   1. DDL  : data.employees (empleats del tenant)
--   2. Indexes, constraint de unicitat i trigger updated_at
--   3. RLS  : polítiques SELECT/INSERT/UPDATE/DELETE
--   4. Grants sobre data.employees a authenticated
--   5. Audit: data.trg_audit_employees() + trigger AFTER INSERT/UPDATE/DELETE
--   6. Vista: api.employees (security_invoker = true)
--   7. Grants sobre api.employees a authenticated
--
-- Patró RLS aplicat:
--   · Pertinença tenant  : data.jwt_user_tenants() ? tenant_id::text
--   · Rol global         : data.jwt_user_tenants() -> tenant_id::text ->> 'global_role'
--   · Filtre tenant actiu: data.active_tenant_id() (header x-tenant-id)
--
-- Auditoria:
--   Accions registrades: EMPLOYEE_CREATED, EMPLOYEE_UPDATED,
--   EMPLOYEE_TERMINATED, EMPLOYEE_DELETED
-- =============================================================================

-- =============================================================================
-- 1. DDL: data.employees
-- =============================================================================

CREATE TABLE data.employees (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id)     ON DELETE CASCADE,
  site_id       uuid                 REFERENCES data.sites(id)       ON DELETE SET NULL,
  user_id       uuid                 REFERENCES data.profiles(id)    ON DELETE SET NULL,
  department_id uuid                 REFERENCES data.departments(id) ON DELETE SET NULL,
  full_name     text        NOT NULL,
  email         text,
  phone         text,
  document_id   text,
  job_title     text,
  status        text        NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active', 'inactive', 'terminated')),
  starts_on     date,
  ends_on       date,
  weekly_hours  numeric(5,2),
  metadata      jsonb       NOT NULL DEFAULT '{}',
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.employees
  IS 'Empleats del tenant. Prerequisit per a Time Attendance i Payroll. '
     'user_id és opcional: un empleat pot no tenir compte d''usuari al sistema.';

COMMENT ON COLUMN data.employees.user_id
  IS 'Compte d''usuari vinculat (data.profiles). NULL = empleat sense accés al portal.';

COMMENT ON COLUMN data.employees.document_id
  IS 'DNI, NIE, passaport o equivalent. Emmagatzemat com a text simple (sense format fix).';

COMMENT ON COLUMN data.employees.status
  IS 'active: en actiu. inactive: baixa temporal. terminated: baixa definitiva.';

COMMENT ON COLUMN data.employees.weekly_hours
  IS 'Hores setmanals contractuals. NULL = no definit (ex: per hores o eventual).';

COMMENT ON COLUMN data.employees.metadata
  IS 'Camp obert per a camps addicionals del sector (ex: número SS, categoria, conveni).';

-- =============================================================================
-- 2. Indexes
-- =============================================================================

CREATE INDEX idx_employees_tenant_id     ON data.employees (tenant_id);
CREATE INDEX idx_employees_site_id       ON data.employees (site_id);
CREATE INDEX idx_employees_user_id       ON data.employees (user_id);
CREATE INDEX idx_employees_department_id ON data.employees (department_id);
CREATE INDEX idx_employees_tenant_status ON data.employees (tenant_id, status);

-- Un usuari no pot estar vinculat a més d'un empleat per tenant
CREATE UNIQUE INDEX uq_employees_tenant_user
  ON data.employees (tenant_id, user_id)
  WHERE user_id IS NOT NULL;

-- =============================================================================
-- 2b. Validacions d'integritat transversal (tenant/site/department)
-- =============================================================================

-- Si s'informa site_id o department_id, han de pertànyer al mateix tenant.
CREATE OR REPLACE FUNCTION data.trg_validate_employee_relations_consistency()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_site_tenant_id       uuid;
  v_department_tenant_id uuid;
BEGIN
  IF NEW.site_id IS NOT NULL THEN
    SELECT s.tenant_id
    INTO v_site_tenant_id
    FROM data.sites s
    WHERE s.id = NEW.site_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'invalid site_id: site % not found', NEW.site_id;
    END IF;

    IF v_site_tenant_id <> NEW.tenant_id THEN
      RAISE EXCEPTION 'invalid relation: employee.site_id must belong to the same tenant';
    END IF;
  END IF;

  IF NEW.department_id IS NOT NULL THEN
    SELECT d.tenant_id
    INTO v_department_tenant_id
    FROM data.departments d
    WHERE d.id = NEW.department_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'invalid department_id: department % not found', NEW.department_id;
    END IF;

    IF v_department_tenant_id <> NEW.tenant_id THEN
      RAISE EXCEPTION 'invalid relation: employee.department_id must belong to the same tenant';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_employee_relations_consistency
  BEFORE INSERT OR UPDATE OF tenant_id, site_id, department_id ON data.employees
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_employee_relations_consistency();

-- =============================================================================
-- 2c. Trigger updated_at
-- Reutilitza data.set_updated_at() definit a la migració inicial.
-- =============================================================================

CREATE TRIGGER trg_employees_updated_at
  BEFORE UPDATE ON data.employees
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- =============================================================================
-- 3. Row Level Security
-- =============================================================================

ALTER TABLE data.employees ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- SELECT: qualsevol membre vàlid del tenant veu els empleats del seu tenant
-- ---------------------------------------------------------------------------
CREATE POLICY "employees: membres del tenant poden veure empleats"
  ON data.employees FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- ---------------------------------------------------------------------------
-- INSERT: owner/manager global O permís granular hr.manage
-- ---------------------------------------------------------------------------
CREATE POLICY "employees: owner/manager pot crear empleats"
  ON data.employees FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'hr.manage', site_id)
    )
  );

-- ---------------------------------------------------------------------------
-- UPDATE: owner/manager global O permís granular hr.manage
-- ---------------------------------------------------------------------------
CREATE POLICY "employees: owner/manager pot modificar empleats"
  ON data.employees FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'hr.manage', site_id)
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'hr.manage', site_id)
    )
  );

-- ---------------------------------------------------------------------------
-- DELETE: owner/manager global O permís granular hr.manage
-- ---------------------------------------------------------------------------
CREATE POLICY "employees: owner/manager pot eliminar empleats"
  ON data.employees FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'hr.manage', site_id)
    )
  );

-- =============================================================================
-- 4. Grants sobre data.employees a authenticated
-- Les polítiques RLS limiten les files; els grants habiliten les operacions
-- a nivell de taula (prerequisit per a vistes security_invoker = true).
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON data.employees TO authenticated;

-- =============================================================================
-- 5. Triggers d'auditoria
-- Accions: EMPLOYEE_CREATED, EMPLOYEE_UPDATED, EMPLOYEE_TERMINATED, EMPLOYEE_DELETED
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_audit_employees()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.user_id),
      NEW.site_id,
      'EMPLOYEE_CREATED',
      'employee',
      NEW.id,
      jsonb_build_object(
        'id',            NEW.id,
        'full_name',     NEW.full_name,
        'status',        NEW.status,
        'job_title',     NEW.job_title,
        'department_id', NEW.department_id,
        'starts_on',     NEW.starts_on
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    -- Cas especial: canvi d'estat a 'terminated' → acció diferenciada
    IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'terminated' THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        auth.uid(),
        NEW.site_id,
        'EMPLOYEE_TERMINATED',
        'employee',
        NEW.id,
        jsonb_build_object(
          'id',         NEW.id,
          'full_name',  NEW.full_name,
          'status',     NEW.status,
          'old_status', OLD.status,
          'ends_on',    NEW.ends_on
        )
      );
    ELSE
      -- Canvi genèric: registra els camps rellevants old/new
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        auth.uid(),
        NEW.site_id,
        'EMPLOYEE_UPDATED',
        'employee',
        NEW.id,
        jsonb_build_object(
          'id',        NEW.id,
          'full_name', NEW.full_name,
          'status',    NEW.status,
          'old', jsonb_build_object(
            'full_name',     OLD.full_name,
            'status',        OLD.status,
            'job_title',     OLD.job_title,
            'department_id', OLD.department_id,
            'site_id',       OLD.site_id,
            'weekly_hours',  OLD.weekly_hours
          ),
          'new', jsonb_build_object(
            'full_name',     NEW.full_name,
            'status',        NEW.status,
            'job_title',     NEW.job_title,
            'department_id', NEW.department_id,
            'site_id',       NEW.site_id,
            'weekly_hours',  NEW.weekly_hours
          )
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      auth.uid(),
      OLD.site_id,
      'EMPLOYEE_DELETED',
      'employee',
      OLD.id,
      jsonb_build_object(
        'id',        OLD.id,
        'full_name', OLD.full_name,
        'status',    OLD.status,
        'ends_on',   OLD.ends_on
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_employees
  AFTER INSERT OR UPDATE OR DELETE ON data.employees
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_employees();

-- =============================================================================
-- 6. Vista api.employees
-- Updatable: sí (taula única, sense camps virtuals → auto-updatable per PostgreSQL).
-- security_invoker = true: les polítiques RLS de data.employees s'apliquen
-- amb el context de l'usuari que fa la petició, no del definidor de la vista.
-- =============================================================================

CREATE OR REPLACE VIEW api.employees
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    site_id,
    user_id,
    department_id,
    full_name,
    email,
    phone,
    document_id,
    job_title,
    status,
    starts_on,
    ends_on,
    weekly_hours,
    metadata,
    created_at,
    updated_at
  FROM data.employees;

-- =============================================================================
-- 7. Grants sobre api.employees a authenticated
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employees TO authenticated;
