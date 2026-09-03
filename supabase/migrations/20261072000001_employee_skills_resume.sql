-- =============================================================================
-- M-EHR-06 — Employee skills (talent) — mínim
-- Catàleg tenant-scoped + assignacions. Sense certificacions (CR) ni IBAN.
-- Résumé (employee_resume_entries) diferit post-mínim.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.jwt_can_manage_employee_skills(
  p_tenant_id uuid,
  p_site_id   uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT CASE
    WHEN (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
      THEN true
    WHEN (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.skills.manage')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.manage')
      THEN true
    WHEN p_site_id IS NOT NULL
      AND data.jwt_has_employee_permission(p_tenant_id, 'employees.skills.manage', p_site_id)
      THEN true
    WHEN p_site_id IS NOT NULL
      AND data.jwt_has_employee_permission(p_tenant_id, 'employees.manage', p_site_id)
      THEN true
    ELSE false
  END;
$$;

GRANT EXECUTE ON FUNCTION data.jwt_can_manage_employee_skills(uuid, uuid) TO authenticated;

-- ─── skill_types ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.skill_types (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name                  text NOT NULL,
  is_certification_type boolean NOT NULL DEFAULT false,
  color_token           text,
  is_active             boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_types_name_not_blank CHECK (btrim(name) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_types_tenant_name
  ON data.skill_types (tenant_id, lower(btrim(name)));

CREATE INDEX IF NOT EXISTS idx_skill_types_tenant
  ON data.skill_types (tenant_id);

COMMENT ON TABLE data.skill_types IS
  'Tipus de skill de talent (no compliment). is_certification_type només visual; no afecta Readiness.';

-- ─── skills ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.skills (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  skill_type_id uuid NOT NULL REFERENCES data.skill_types(id) ON DELETE CASCADE,
  name          text NOT NULL,
  description   text,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skills_name_not_blank CHECK (btrim(name) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_skills_tenant_type_name
  ON data.skills (tenant_id, skill_type_id, lower(btrim(name)));

CREATE INDEX IF NOT EXISTS idx_skills_tenant_type
  ON data.skills (tenant_id, skill_type_id);

-- ─── skill_levels ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.skill_levels (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  skill_type_id uuid NOT NULL REFERENCES data.skill_types(id) ON DELETE CASCADE,
  name          text NOT NULL,
  rank          int NOT NULL DEFAULT 0,
  progress_pct  int,
  is_default    boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_levels_name_not_blank CHECK (btrim(name) <> ''),
  CONSTRAINT skill_levels_rank_nonneg CHECK (rank >= 0),
  CONSTRAINT skill_levels_progress_pct CHECK (progress_pct IS NULL OR (progress_pct >= 0 AND progress_pct <= 100))
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_levels_type_rank
  ON data.skill_levels (skill_type_id, rank);

CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_levels_type_name
  ON data.skill_levels (skill_type_id, lower(btrim(name)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_levels_one_default
  ON data.skill_levels (skill_type_id)
  WHERE is_default;

CREATE INDEX IF NOT EXISTS idx_skill_levels_type
  ON data.skill_levels (skill_type_id);

-- ─── employee_skills ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employee_skills (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id       uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  skill_id          uuid NOT NULL REFERENCES data.skills(id) ON DELETE CASCADE,
  level_id          uuid REFERENCES data.skill_levels(id) ON DELETE SET NULL,
  acquired_on       date,
  last_assessed_on  date,
  assessed_by       uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, skill_id)
);

CREATE INDEX IF NOT EXISTS idx_employee_skills_tenant_skill
  ON data.employee_skills (tenant_id, skill_id);

CREATE INDEX IF NOT EXISTS idx_employee_skills_employee
  ON data.employee_skills (employee_id);

CREATE INDEX IF NOT EXISTS idx_employee_skills_skill_level
  ON data.employee_skills (skill_id, level_id);

COMMENT ON TABLE data.employee_skills IS
  'Assignació de skills de talent a empleats. Mai conté dades de compliment (CR).';

-- ─── Tenant / level consistency triggers ─────────────────────────────────────

CREATE OR REPLACE FUNCTION data.enforce_skill_tenant_refs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_type_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_type_tenant FROM data.skill_types WHERE id = NEW.skill_type_id;
  IF v_type_tenant IS NULL OR v_type_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'skill_type_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_skills_tenant_refs ON data.skills;
CREATE TRIGGER trg_skills_tenant_refs
  BEFORE INSERT OR UPDATE ON data.skills
  FOR EACH ROW EXECUTE FUNCTION data.enforce_skill_tenant_refs();

CREATE OR REPLACE FUNCTION data.enforce_employee_skill_refs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp_tenant uuid;
  v_skill_tenant uuid;
  v_skill_type uuid;
  v_level_type uuid;
BEGIN
  SELECT tenant_id INTO v_emp_tenant FROM data.employees WHERE id = NEW.employee_id;
  SELECT tenant_id, skill_type_id INTO v_skill_tenant, v_skill_type
  FROM data.skills WHERE id = NEW.skill_id;

  IF v_emp_tenant IS NULL OR v_skill_tenant IS NULL OR v_emp_tenant <> v_skill_tenant THEN
    RAISE EXCEPTION 'employee_skill_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;
  NEW.tenant_id := v_emp_tenant;

  IF NEW.level_id IS NOT NULL THEN
    SELECT skill_type_id INTO v_level_type FROM data.skill_levels WHERE id = NEW.level_id;
    IF v_level_type IS NULL OR v_level_type <> v_skill_type THEN
      RAISE EXCEPTION 'employee_skill_level_type_mismatch' USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employee_skills_refs ON data.employee_skills;
CREATE TRIGGER trg_employee_skills_refs
  BEFORE INSERT OR UPDATE ON data.employee_skills
  FOR EACH ROW EXECUTE FUNCTION data.enforce_employee_skill_refs();

CREATE OR REPLACE FUNCTION data.touch_skill_types_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_skill_types_touch ON data.skill_types;
CREATE TRIGGER trg_skill_types_touch
  BEFORE UPDATE ON data.skill_types
  FOR EACH ROW EXECUTE FUNCTION data.touch_skill_types_updated_at();

-- ─── RLS ─────────────────────────────────────────────────────────────────────

ALTER TABLE data.skill_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.skills ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.skill_levels ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employee_skills ENABLE ROW LEVEL SECURITY;

-- skill_types
DROP POLICY IF EXISTS skill_types_select ON data.skill_types;
CREATE POLICY skill_types_select ON data.skill_types
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS skill_types_write ON data.skill_types;
CREATE POLICY skill_types_insert ON data.skill_types
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_manage_employee_skills(tenant_id, NULL)
  );

CREATE POLICY skill_types_update ON data.skill_types
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_manage_employee_skills(tenant_id, NULL)
  )
  WITH CHECK (data.jwt_can_manage_employee_skills(tenant_id, NULL));

CREATE POLICY skill_types_delete ON data.skill_types
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employee_skills(tenant_id, NULL)
  );

-- skills
DROP POLICY IF EXISTS skills_select ON data.skills;
CREATE POLICY skills_select ON data.skills
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

CREATE POLICY skills_insert ON data.skills
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_manage_employee_skills(tenant_id, NULL)
  );

CREATE POLICY skills_update ON data.skills
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employee_skills(tenant_id, NULL)
  )
  WITH CHECK (data.jwt_can_manage_employee_skills(tenant_id, NULL));

CREATE POLICY skills_delete ON data.skills
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employee_skills(tenant_id, NULL)
  );

-- skill_levels: via skill_type tenant
DROP POLICY IF EXISTS skill_levels_select ON data.skill_levels;
CREATE POLICY skill_levels_select ON data.skill_levels
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.skill_types st
      WHERE st.id = skill_type_id
        AND data.jwt_user_tenants() ? st.tenant_id::text
        AND (data.active_tenant_id() IS NULL OR st.tenant_id = data.active_tenant_id())
    )
  );

CREATE POLICY skill_levels_insert ON data.skill_levels
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.skill_types st
      WHERE st.id = skill_type_id
        AND data.jwt_can_manage_employee_skills(st.tenant_id, NULL)
    )
  );

CREATE POLICY skill_levels_update ON data.skill_levels
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.skill_types st
      WHERE st.id = skill_type_id
        AND data.jwt_can_manage_employee_skills(st.tenant_id, NULL)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.skill_types st
      WHERE st.id = skill_type_id
        AND data.jwt_can_manage_employee_skills(st.tenant_id, NULL)
    )
  );

CREATE POLICY skill_levels_delete ON data.skill_levels
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.skill_types st
      WHERE st.id = skill_type_id
        AND data.jwt_can_manage_employee_skills(st.tenant_id, NULL)
    )
  );

-- employee_skills
DROP POLICY IF EXISTS employee_skills_select ON data.employee_skills;
CREATE POLICY employee_skills_select ON data.employee_skills
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id AND e.tenant_id = employee_skills.tenant_id
        AND data.jwt_can_view_employee(e.tenant_id, e.site_id, e.user_id)
    )
  );

CREATE POLICY employee_skills_insert ON data.employee_skills
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id AND e.tenant_id = employee_skills.tenant_id
        AND data.jwt_can_manage_employee_skills(e.tenant_id, e.site_id)
    )
  );

CREATE POLICY employee_skills_update ON data.employee_skills
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id AND e.tenant_id = employee_skills.tenant_id
        AND data.jwt_can_manage_employee_skills(e.tenant_id, e.site_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id AND e.tenant_id = employee_skills.tenant_id
        AND data.jwt_can_manage_employee_skills(e.tenant_id, e.site_id)
    )
  );

CREATE POLICY employee_skills_delete ON data.employee_skills
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id AND e.tenant_id = employee_skills.tenant_id
        AND data.jwt_can_manage_employee_skills(e.tenant_id, e.site_id)
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.skill_types TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.skills TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.skill_levels TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.employee_skills TO authenticated;

-- ─── API views ───────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW api.skill_types
  WITH (security_invoker = true) AS
SELECT id, tenant_id, name, is_certification_type, color_token, is_active, created_at, updated_at
FROM data.skill_types;

CREATE OR REPLACE VIEW api.skills
  WITH (security_invoker = true) AS
SELECT id, tenant_id, skill_type_id, name, description, is_active, created_at, updated_at
FROM data.skills;

CREATE OR REPLACE VIEW api.skill_levels
  WITH (security_invoker = true) AS
SELECT id, skill_type_id, name, rank, progress_pct, is_default, created_at
FROM data.skill_levels;

CREATE OR REPLACE VIEW api.employee_skills
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, employee_id, skill_id, level_id,
  acquired_on, last_assessed_on, assessed_by, notes,
  created_at, updated_at
FROM data.employee_skills;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.skill_types TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.skills TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.skill_levels TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.employee_skills TO authenticated;

-- ─── Search RPC ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.search_employees_by_skill(
  p_skill_id uuid,
  p_min_level_rank int DEFAULT NULL
)
RETURNS TABLE (
  employee_id uuid,
  full_name text,
  preferred_name text,
  skill_id uuid,
  skill_name text,
  level_id uuid,
  level_name text,
  level_rank int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.skills s
    WHERE s.id = p_skill_id AND s.tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'skill_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  RETURN QUERY
  SELECT
    e.id,
    e.full_name,
    e.preferred_name,
    s.id,
    s.name,
    lv.id,
    lv.name,
    lv.rank
  FROM data.employee_skills es
  JOIN data.employees e ON e.id = es.employee_id AND e.tenant_id = es.tenant_id
  JOIN data.skills s ON s.id = es.skill_id
  LEFT JOIN data.skill_levels lv ON lv.id = es.level_id
  WHERE es.tenant_id = v_tenant_id
    AND es.skill_id = p_skill_id
    AND data.jwt_can_view_employee(e.tenant_id, e.site_id, e.user_id)
    AND (p_min_level_rank IS NULL OR coalesce(lv.rank, 0) >= p_min_level_rank)
  ORDER BY coalesce(lv.rank, -1) DESC, coalesce(e.preferred_name, e.full_name);
END;
$$;

REVOKE EXECUTE ON FUNCTION api.search_employees_by_skill(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_employees_by_skill(uuid, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
