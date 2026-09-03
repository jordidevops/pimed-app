-- =============================================================================
-- EX-06.1 — Rols operatius, assignacions i qualificacions mínimes (SP-3 base)
-- =============================================================================

-- ─── 1. work_roles ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.work_roles (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id     uuid        REFERENCES data.sites(id) ON DELETE CASCADE,
  key         text        NOT NULL,
  name        text        NOT NULL,
  sort_order  int         NOT NULL DEFAULT 100,
  is_active   boolean     NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT work_roles_key_format CHECK (key ~ '^[a-z0-9_]{1,64}$'),
  CONSTRAINT work_roles_name_nonempty CHECK (length(btrim(name)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_work_roles_tenant_site_key
  ON data.work_roles (tenant_id, COALESCE(site_id, '00000000-0000-0000-0000-000000000000'::uuid), key);

CREATE INDEX IF NOT EXISTS idx_work_roles_tenant_active
  ON data.work_roles (tenant_id, is_active, sort_order);

COMMENT ON TABLE data.work_roles IS
  'EX-06.1: rols operatius (cambrer, cuina, …). site_id NULL = tot el tenant.';

ALTER TABLE data.work_roles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS work_roles_select ON data.work_roles;
CREATE POLICY work_roles_select ON data.work_roles FOR SELECT
  USING (data.jwt_user_tenants() ? tenant_id::text);

DROP POLICY IF EXISTS work_roles_write ON data.work_roles;
CREATE POLICY work_roles_write ON data.work_roles FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  );

GRANT SELECT ON data.work_roles TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.work_roles TO service_role;

CREATE OR REPLACE VIEW api.work_roles
WITH (security_invoker = true) AS
SELECT * FROM data.work_roles;

GRANT SELECT ON api.work_roles TO authenticated, service_role;

-- ─── 2. employee_role_assignments ────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employee_role_assignments (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id  uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  role_id      uuid        NOT NULL REFERENCES data.work_roles(id) ON DELETE CASCADE,
  level        smallint    NOT NULL DEFAULT 1
    CONSTRAINT employee_role_assignments_level_chk CHECK (level BETWEEN 1 AND 3),
  valid_from   date,
  valid_to     date,
  is_primary   boolean     NOT NULL DEFAULT false,
  is_active    boolean     NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_role_assignments_dates_chk
    CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_role_active
  ON data.employee_role_assignments (employee_id, role_id)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_employee_role_assignments_emp
  ON data.employee_role_assignments (employee_id, is_active);

COMMENT ON TABLE data.employee_role_assignments IS
  'EX-06.1: rols que un empleat pot cobrir (nivell 1–3 + vigència).';

ALTER TABLE data.employee_role_assignments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS era_select ON data.employee_role_assignments;
CREATE POLICY era_select ON data.employee_role_assignments FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_role_assignments.employee_id AND e.user_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS era_write ON data.employee_role_assignments;
CREATE POLICY era_write ON data.employee_role_assignments FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

GRANT SELECT ON data.employee_role_assignments TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.employee_role_assignments TO service_role;

CREATE OR REPLACE VIEW api.employee_role_assignments
WITH (security_invoker = true) AS
SELECT * FROM data.employee_role_assignments;

GRANT SELECT ON api.employee_role_assignments TO authenticated, service_role;

-- ─── 3. employee_qualifications ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employee_qualifications (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id  uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  key          text        NOT NULL,
  label        text        NOT NULL,
  issued_at    date,
  expires_at   date,
  is_active    boolean     NOT NULL DEFAULT true,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_qualifications_key_format CHECK (key ~ '^[a-z0-9_]{1,64}$'),
  CONSTRAINT employee_qualifications_label_nonempty CHECK (length(btrim(label)) > 0),
  CONSTRAINT employee_qualifications_dates_chk
    CHECK (expires_at IS NULL OR issued_at IS NULL OR expires_at >= issued_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_qual_active_key
  ON data.employee_qualifications (employee_id, key)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_employee_qualifications_emp
  ON data.employee_qualifications (employee_id, is_active);

COMMENT ON TABLE data.employee_qualifications IS
  'EX-06.1: capacitacions/certificats amb caducitat (no usar job_title).';

ALTER TABLE data.employee_qualifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS eq_select ON data.employee_qualifications;
CREATE POLICY eq_select ON data.employee_qualifications FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_qualifications.employee_id AND e.user_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS eq_write ON data.employee_qualifications;
CREATE POLICY eq_write ON data.employee_qualifications FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

GRANT SELECT ON data.employee_qualifications TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.employee_qualifications TO service_role;

CREATE OR REPLACE VIEW api.employee_qualifications
WITH (security_invoker = true) AS
SELECT * FROM data.employee_qualifications;

GRANT SELECT ON api.employee_qualifications TO authenticated, service_role;

-- ─── 4. role_qualification_requirements ──────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.role_qualification_requirements (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  role_id            uuid        NOT NULL REFERENCES data.work_roles(id) ON DELETE CASCADE,
  qualification_key  text        NOT NULL,
  required           boolean     NOT NULL DEFAULT true,
  min_level          smallint
    CONSTRAINT role_qual_req_min_level_chk CHECK (min_level IS NULL OR min_level BETWEEN 1 AND 3),
  is_active          boolean     NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT role_qual_req_key_format CHECK (qualification_key ~ '^[a-z0-9_]{1,64}$')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_role_qual_req_active
  ON data.role_qualification_requirements (role_id, qualification_key)
  WHERE is_active = true;

COMMENT ON TABLE data.role_qualification_requirements IS
  'EX-06.1: qualificacions obligatòries (per key) per cobrir un rol.';

ALTER TABLE data.role_qualification_requirements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rqr_select ON data.role_qualification_requirements;
CREATE POLICY rqr_select ON data.role_qualification_requirements FOR SELECT
  USING (data.jwt_user_tenants() ? tenant_id::text);

DROP POLICY IF EXISTS rqr_write ON data.role_qualification_requirements;
CREATE POLICY rqr_write ON data.role_qualification_requirements FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

GRANT SELECT ON data.role_qualification_requirements TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.role_qualification_requirements TO service_role;

CREATE OR REPLACE VIEW api.role_qualification_requirements
WITH (security_invoker = true) AS
SELECT * FROM data.role_qualification_requirements;

GRANT SELECT ON api.role_qualification_requirements TO authenticated, service_role;

-- ─── 5. FKs nullable a plantilles / slots ─────────────────────────────────────

ALTER TABLE data.work_shifts
  ADD COLUMN IF NOT EXISTS default_role_id uuid REFERENCES data.work_roles(id) ON DELETE SET NULL;

ALTER TABLE data.shift_slots
  ADD COLUMN IF NOT EXISTS role_id uuid REFERENCES data.work_roles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS role_name_snapshot text;

CREATE INDEX IF NOT EXISTS idx_work_shifts_default_role
  ON data.work_shifts (default_role_id) WHERE default_role_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_shift_slots_role
  ON data.shift_slots (role_id) WHERE role_id IS NOT NULL;

COMMENT ON COLUMN data.work_shifts.default_role_id IS
  'EX-06.1: rol per defecte de la plantilla (nullable).';
COMMENT ON COLUMN data.shift_slots.role_id IS
  'EX-06.1: rol del slot (nullable; heretat de plantilla si no s''indica).';
COMMENT ON COLUMN data.shift_slots.role_name_snapshot IS
  'EX-06.1: nom del rol congelat a assignació/publicació.';

-- ─── 6. Helpers ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.employee_has_active_role(
  p_employee_id uuid,
  p_role_id     uuid,
  p_on_date     date DEFAULT CURRENT_DATE
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.employee_role_assignments a
    WHERE a.employee_id = p_employee_id
      AND a.role_id = p_role_id
      AND a.is_active = true
      AND (a.valid_from IS NULL OR a.valid_from <= p_on_date)
      AND (a.valid_to IS NULL OR a.valid_to >= p_on_date)
  );
$$;

CREATE OR REPLACE FUNCTION data.employee_meets_role_qualifications(
  p_employee_id uuid,
  p_role_id     uuid,
  p_on_date     date DEFAULT CURRENT_DATE
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_req record;
  v_ok boolean;
BEGIN
  IF NOT data.employee_has_active_role(p_employee_id, p_role_id, p_on_date) THEN
    RETURN false;
  END IF;

  FOR v_req IN
    SELECT r.qualification_key, r.min_level
    FROM data.role_qualification_requirements r
    WHERE r.role_id = p_role_id
      AND r.is_active = true
      AND r.required = true
  LOOP
    SELECT EXISTS (
      SELECT 1
      FROM data.employee_qualifications q
      WHERE q.employee_id = p_employee_id
        AND q.key = v_req.qualification_key
        AND q.is_active = true
        AND (q.issued_at IS NULL OR q.issued_at <= p_on_date)
        AND (q.expires_at IS NULL OR q.expires_at >= p_on_date)
    ) INTO v_ok;

    IF NOT v_ok THEN
      RETURN false;
    END IF;

    -- min_level a requisit s'aplica al nivell d'assignació de rol (si present)
    IF v_req.min_level IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1
        FROM data.employee_role_assignments a
        WHERE a.employee_id = p_employee_id
          AND a.role_id = p_role_id
          AND a.is_active = true
          AND a.level >= v_req.min_level
          AND (a.valid_from IS NULL OR a.valid_from <= p_on_date)
          AND (a.valid_to IS NULL OR a.valid_to >= p_on_date)
      ) THEN
        RETURN false;
      END IF;
    END IF;
  END LOOP;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION data.employee_has_active_role(uuid, uuid, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.employee_meets_role_qualifications(uuid, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.employee_has_active_role(uuid, uuid, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION data.employee_meets_role_qualifications(uuid, uuid, date) TO authenticated, service_role;

COMMENT ON FUNCTION data.employee_has_active_role IS
  'EX-06.1: empleat té assignació activa del rol a la data.';
COMMENT ON FUNCTION data.employee_meets_role_qualifications IS
  'EX-06.1: empleat té el rol i totes les qualificacions required no caducades.';
