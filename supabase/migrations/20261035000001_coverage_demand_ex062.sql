-- =============================================================================
-- EX-06.2 — Demanda de cobertura (recurrent + extraordinària)
-- Substitueix progressivament l'ús exclusiu de shift_coverage_requirements
-- (recompte diari sense rol/ubicació/franja). Legacy es manté sumat a get_coverage.
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.coverage_demands (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id          uuid        NOT NULL REFERENCES data.sites(id) ON DELETE CASCADE,
  location_id      uuid        REFERENCES data.locations(id) ON DELETE SET NULL,
  role_id          uuid        REFERENCES data.work_roles(id) ON DELETE SET NULL,
  kind             text        NOT NULL
    CONSTRAINT coverage_demands_kind_chk CHECK (kind IN ('recurring', 'extraordinary')),
  day_of_week      smallint
    CONSTRAINT coverage_demands_dow_chk CHECK (day_of_week IS NULL OR day_of_week BETWEEN 0 AND 6),
  demand_date      date,
  start_time       time        NOT NULL,
  end_time         time        NOT NULL,
  required_min     int         NOT NULL DEFAULT 0
    CONSTRAINT coverage_demands_min_chk CHECK (required_min >= 0),
  required_target  int         NOT NULL
    CONSTRAINT coverage_demands_target_chk CHECK (required_target >= 0),
  required_max     int
    CONSTRAINT coverage_demands_max_chk CHECK (required_max IS NULL OR required_max >= 0),
  priority         int         NOT NULL DEFAULT 100,
  source           text        NOT NULL DEFAULT 'manual'
    CONSTRAINT coverage_demands_source_chk CHECK (
      source IN ('manual', 'template', 'pos', 'orders', 'production', 'event', 'import')
    ),
  name             text,
  notes            text,
  effective_from   date        NOT NULL DEFAULT CURRENT_DATE,
  effective_to     date,
  is_active        boolean     NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT coverage_demands_dates_chk
    CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT coverage_demands_headcount_chk
    CHECK (
      required_target >= required_min
      AND (required_max IS NULL OR required_max >= required_target)
    ),
  CONSTRAINT coverage_demands_times_chk
    CHECK (start_time <> end_time),
  CONSTRAINT coverage_demands_kind_shape_chk
    CHECK (
      (kind = 'recurring' AND day_of_week IS NOT NULL AND demand_date IS NULL)
      OR (kind = 'extraordinary' AND demand_date IS NOT NULL AND day_of_week IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_coverage_demands_site_active
  ON data.coverage_demands (site_id, is_active, kind);

CREATE INDEX IF NOT EXISTS idx_coverage_demands_site_date
  ON data.coverage_demands (site_id, demand_date)
  WHERE kind = 'extraordinary' AND is_active = true;

CREATE INDEX IF NOT EXISTS idx_coverage_demands_site_dow
  ON data.coverage_demands (site_id, day_of_week, effective_from, effective_to)
  WHERE kind = 'recurring' AND is_active = true;

COMMENT ON TABLE data.coverage_demands IS
  'EX-06.2: demanda de cobertura per centre/ubicació/rol. Recurrent (DOW) o extraordinària (data).';

DROP TRIGGER IF EXISTS trg_updated_at_coverage_demands ON data.coverage_demands;
CREATE TRIGGER trg_updated_at_coverage_demands
  BEFORE UPDATE ON data.coverage_demands
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

CREATE OR REPLACE FUNCTION data.trg_validate_coverage_demand_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_site_tenant uuid;
  v_loc record;
  v_role record;
BEGIN
  SELECT tenant_id INTO v_site_tenant FROM data.sites WHERE id = NEW.site_id;
  IF v_site_tenant IS NULL OR v_site_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: coverage demand site tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.location_id IS NOT NULL THEN
    SELECT tenant_id, site_id INTO v_loc FROM data.locations WHERE id = NEW.location_id;
    IF NOT FOUND OR v_loc.tenant_id <> NEW.tenant_id OR v_loc.site_id <> NEW.site_id THEN
      RAISE EXCEPTION 'integrity_violation: coverage demand location mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  IF NEW.role_id IS NOT NULL THEN
    SELECT tenant_id, site_id, is_active INTO v_role FROM data.work_roles WHERE id = NEW.role_id;
    IF NOT FOUND OR v_role.tenant_id <> NEW.tenant_id THEN
      RAISE EXCEPTION 'integrity_violation: coverage demand role mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_role.site_id IS NOT NULL AND v_role.site_id <> NEW.site_id THEN
      RAISE EXCEPTION 'integrity_violation: coverage demand role site mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_coverage_demand_integrity ON data.coverage_demands;
CREATE TRIGGER trg_validate_coverage_demand_integrity
  BEFORE INSERT OR UPDATE ON data.coverage_demands
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_coverage_demand_integrity();

ALTER TABLE data.coverage_demands ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cd_select ON data.coverage_demands;
CREATE POLICY cd_select ON data.coverage_demands FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.view', site_id)
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
      OR data.jwt_has_permission(tenant_id, 'attendance.view_all', site_id)
    )
  );

DROP POLICY IF EXISTS cd_write ON data.coverage_demands;
CREATE POLICY cd_write ON data.coverage_demands FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  );

GRANT SELECT ON data.coverage_demands TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.coverage_demands TO service_role;

CREATE OR REPLACE VIEW api.coverage_demands
WITH (security_invoker = true) AS
SELECT * FROM data.coverage_demands;

GRANT SELECT ON api.coverage_demands TO authenticated, service_role;

-- ─── Helper: demanda activa que aplica a una data ────────────────────────────

CREATE OR REPLACE FUNCTION data.coverage_demand_applies_on(
  p_demand data.coverage_demands,
  p_on_date date
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_demand.is_active
    AND p_demand.effective_from <= p_on_date
    AND (p_demand.effective_to IS NULL OR p_demand.effective_to > p_on_date)
    AND (
      (p_demand.kind = 'extraordinary' AND p_demand.demand_date = p_on_date)
      OR (
        p_demand.kind = 'recurring'
        AND p_demand.day_of_week = EXTRACT(DOW FROM p_on_date)::smallint
      )
    );
$$;

CREATE OR REPLACE FUNCTION data.sum_coverage_demand_target(
  p_site_id uuid,
  p_on_date date
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(SUM(cd.required_target), 0)::int
  FROM data.coverage_demands cd
  WHERE cd.site_id = p_site_id
    AND data.coverage_demand_applies_on(cd, p_on_date);
$$;

REVOKE ALL ON FUNCTION data.coverage_demand_applies_on(data.coverage_demands, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.sum_coverage_demand_target(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.sum_coverage_demand_target(uuid, date) TO authenticated, service_role;

COMMENT ON FUNCTION data.sum_coverage_demand_target IS
  'EX-06.2: suma required_target de demandes actives (recurrent+extraordinària) per dia.';
