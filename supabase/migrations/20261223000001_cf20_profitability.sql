-- CF-20: frozen labor cost per work log + project profitability summary (ex-VAT).
-- Decisions: revenue 1A (line_net / accepted subtotals); expenses 2A; line costs exclude unit='h'.

-- ---------------------------------------------------------------------------
-- 1. work_log_labor_costs
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.work_log_labor_costs (
  work_log_id uuid PRIMARY KEY
    REFERENCES data.work_logs(id) ON DELETE CASCADE,
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id uuid NULL REFERENCES data.employees(id) ON DELETE SET NULL,
  contract_id uuid NULL REFERENCES data.employment_contracts(id) ON DELETE SET NULL,
  duration_minutes integer NOT NULL CHECK (duration_minutes >= 0),
  hourly_cost_cents integer NULL CHECK (hourly_cost_cents IS NULL OR hourly_cost_cents >= 0),
  total_labor_cost_cents integer NOT NULL DEFAULT 0 CHECK (total_labor_cost_cents >= 0),
  cost_method text NOT NULL CHECK (
    cost_method IN ('hourly_rate', 'derived_annual_cost', 'unavailable')
  ),
  cost_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  frozen_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_work_log_labor_costs_tenant
  ON data.work_log_labor_costs (tenant_id);

CREATE OR REPLACE FUNCTION data.trg_work_log_labor_costs_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  SELECT wl.tenant_id INTO v_tenant
  FROM data.work_logs wl
  WHERE wl.id = NEW.work_log_id;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'work_log_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.tenant_id IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  NEW.frozen_at := COALESCE(NEW.frozen_at, now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_log_labor_costs_tenant ON data.work_log_labor_costs;
CREATE TRIGGER trg_work_log_labor_costs_tenant
  BEFORE INSERT OR UPDATE ON data.work_log_labor_costs
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_work_log_labor_costs_tenant();

CREATE OR REPLACE FUNCTION data.work_log_labor_cost_visible(p_work_log_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT data.can_view_commercial_costs(wl.tenant_id, p.site_id)
  FROM data.work_logs wl
  JOIN data.projects p ON p.id = wl.project_id
  WHERE wl.id = p_work_log_id;
$$;

REVOKE ALL ON FUNCTION data.work_log_labor_cost_visible(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.work_log_labor_cost_visible(uuid)
  TO authenticated, service_role;

ALTER TABLE data.work_log_labor_costs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS work_log_labor_costs_select ON data.work_log_labor_costs;
CREATE POLICY work_log_labor_costs_select
  ON data.work_log_labor_costs FOR SELECT TO authenticated
  USING (data.work_log_labor_cost_visible(work_log_id));

-- No client writes; freeze helper is DEFINER (bypasses RLS insert policies).
GRANT SELECT ON TABLE data.work_log_labor_costs TO authenticated;

CREATE OR REPLACE VIEW api.work_log_labor_costs
  WITH (security_invoker = true) AS
  SELECT
    work_log_id, tenant_id, employee_id, contract_id,
    duration_minutes, hourly_cost_cents, total_labor_cost_cents,
    cost_method, cost_snapshot, frozen_at
  FROM data.work_log_labor_costs;

REVOKE ALL ON api.work_log_labor_costs FROM PUBLIC, anon;
GRANT SELECT ON api.work_log_labor_costs TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Helpers: contract resolve + freeze
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.resolve_employee_contract_for_cost(
  p_employee_id uuid,
  p_on_date date DEFAULT CURRENT_DATE
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_on date := COALESCE(p_on_date, CURRENT_DATE);
  v_id uuid;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c.id INTO v_id
  FROM data.employment_contracts c
  WHERE c.employee_id = p_employee_id
    AND c.is_primary
    AND c.lifecycle_status IN ('active', 'scheduled', 'ended')
    AND c.starts_on <= v_on
    AND (c.ends_on IS NULL OR c.ends_on >= v_on)
  ORDER BY
    CASE c.lifecycle_status
      WHEN 'active' THEN 0
      WHEN 'scheduled' THEN 1
      ELSE 2
    END,
    c.starts_on DESC
  LIMIT 1;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_employee_contract_for_cost(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.resolve_employee_contract_for_cost(uuid, date)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.freeze_work_log_labor_cost(p_work_log_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_log data.work_logs%ROWTYPE;
  v_duration int;
  v_contract uuid;
  v_snap jsonb;
  v_method text;
  v_cpm numeric;
  v_hourly numeric;
  v_hourly_cents int;
  v_total_cents int;
BEGIN
  IF p_work_log_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.work_log_labor_costs WHERE work_log_id = p_work_log_id
  ) THEN
    RETURN;
  END IF;

  SELECT * INTO v_log
  FROM data.work_logs
  WHERE id = p_work_log_id;

  IF NOT FOUND OR v_log.status IS DISTINCT FROM 'closed' THEN
    RETURN;
  END IF;

  v_duration := GREATEST(
    0,
    EXTRACT(EPOCH FROM (v_log.check_out - v_log.check_in))::int / 60
  );

  IF v_log.employee_id IS NULL THEN
    INSERT INTO data.work_log_labor_costs (
      work_log_id, tenant_id, employee_id, contract_id,
      duration_minutes, hourly_cost_cents, total_labor_cost_cents,
      cost_method, cost_snapshot
    ) VALUES (
      v_log.id, v_log.tenant_id, NULL, NULL,
      v_duration, NULL, 0,
      'unavailable',
      jsonb_build_object('reason', 'employee_id_missing')
    )
    ON CONFLICT (work_log_id) DO NOTHING;
    RETURN;
  END IF;

  v_contract := data.resolve_employee_contract_for_cost(
    v_log.employee_id,
    (v_log.check_in AT TIME ZONE 'UTC')::date
  );

  IF v_contract IS NULL THEN
    INSERT INTO data.work_log_labor_costs (
      work_log_id, tenant_id, employee_id, contract_id,
      duration_minutes, hourly_cost_cents, total_labor_cost_cents,
      cost_method, cost_snapshot
    ) VALUES (
      v_log.id, v_log.tenant_id, v_log.employee_id, NULL,
      v_duration, NULL, 0,
      'unavailable',
      jsonb_build_object('reason', 'no_effective_contract')
    )
    ON CONFLICT (work_log_id) DO NOTHING;
    RETURN;
  END IF;

  v_snap := data.resolve_contract_planning_cost(
    v_contract,
    (v_log.check_in AT TIME ZONE 'UTC')::date
  );
  v_snap := COALESCE(v_snap, '{}'::jsonb);
  v_method := COALESCE(v_snap->>'method', 'unavailable');
  v_cpm := NULLIF(v_snap->>'cost_per_minute', '')::numeric;
  v_hourly := NULLIF(v_snap->>'hourly_cost', '')::numeric;

  IF v_method NOT IN ('hourly_rate', 'derived_annual_cost') OR v_cpm IS NULL THEN
    INSERT INTO data.work_log_labor_costs (
      work_log_id, tenant_id, employee_id, contract_id,
      duration_minutes, hourly_cost_cents, total_labor_cost_cents,
      cost_method, cost_snapshot
    ) VALUES (
      v_log.id, v_log.tenant_id, v_log.employee_id, v_contract,
      v_duration, NULL, 0,
      'unavailable',
      v_snap || jsonb_build_object('reason', 'cost_unavailable')
    )
    ON CONFLICT (work_log_id) DO NOTHING;
    RETURN;
  END IF;

  v_total_cents := GREATEST(0, ROUND(v_cpm * v_duration * 100)::int);
  v_hourly_cents := CASE
    WHEN v_hourly IS NULL THEN NULL
    ELSE GREATEST(0, ROUND(v_hourly * 100)::int)
  END;

  INSERT INTO data.work_log_labor_costs (
    work_log_id, tenant_id, employee_id, contract_id,
    duration_minutes, hourly_cost_cents, total_labor_cost_cents,
    cost_method, cost_snapshot
  ) VALUES (
    v_log.id, v_log.tenant_id, v_log.employee_id, v_contract,
    v_duration, v_hourly_cents, v_total_cents,
    v_method, v_snap
  )
  ON CONFLICT (work_log_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION data.freeze_work_log_labor_cost(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.freeze_work_log_labor_cost(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Patch stop_work_log — freeze on close and duplicate retry
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.stop_work_log(
  p_log_id         uuid        DEFAULT NULL,
  p_client_op_id   uuid        DEFAULT NULL,
  p_check_out      timestamptz DEFAULT now(),
  p_geo            jsonb       DEFAULT NULL,
  p_location_perm  text        DEFAULT 'notrequired',
  p_close_task     boolean     DEFAULT false,
  p_notes          text        DEFAULT NULL,
  p_stop_op_id     uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_tenant_id uuid := data.active_tenant_id();
  v_resolved_id uuid := p_log_id;
  v_match_count int := 0;
  v_log data.work_logs%ROWTYPE;
  v_anomalies text[];
  v_duration_min int;
  v_status text;
BEGIN
  IF v_resolved_id IS NULL AND p_client_op_id IS NOT NULL THEN
    SELECT COUNT(*)
    INTO v_match_count
    FROM data.work_logs wl
    WHERE wl.client_op_id = p_client_op_id
      AND wl.worker_id = v_user_id
      AND (v_tenant_id IS NULL OR wl.tenant_id = v_tenant_id);
    IF COALESCE(v_match_count, 0) > 1 THEN
      RAISE EXCEPTION 'work_log_ambiguous'
        USING ERRCODE = 'unique_violation';
    END IF;
    SELECT wl.id
    INTO v_resolved_id
    FROM data.work_logs wl
    WHERE wl.client_op_id = p_client_op_id
      AND wl.worker_id = v_user_id
      AND (v_tenant_id IS NULL OR wl.tenant_id = v_tenant_id)
    LIMIT 1;
  END IF;
  IF v_resolved_id IS NULL THEN
    RAISE EXCEPTION 'work_log_reference_required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_log
  FROM data.work_logs
  WHERE id = v_resolved_id
    AND worker_id = v_user_id
    AND (v_tenant_id IS NULL OR tenant_id = v_tenant_id)
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'work_log_not_found_or_forbidden'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_log.status = 'closed' THEN
    v_status := 'duplicate';
    v_duration_min := GREATEST(
      0,
      EXTRACT(EPOCH FROM (v_log.check_out - v_log.check_in))::int / 60
    );
  ELSIF v_log.status <> 'open' THEN
    RAISE EXCEPTION 'work_log_not_open' USING ERRCODE = 'check_violation';
  ELSE
    v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);
    SELECT ARRAY(SELECT DISTINCT unnest(v_log.anomaly_codes || v_anomalies))
    INTO v_anomalies;
    v_duration_min := GREATEST(
      0,
      EXTRACT(EPOCH FROM (p_check_out - v_log.check_in))::int / 60
    );

    UPDATE data.work_logs SET
      status = 'closed',
      check_out = p_check_out,
      check_out_geo = p_geo,
      check_out_received_at = now(),
      anomaly_codes = v_anomalies,
      notes = COALESCE(p_notes, notes),
      updated_at = now()
    WHERE id = v_resolved_id;

    IF p_close_task AND v_log.task_id IS NOT NULL THEN
      UPDATE data.tasks SET status = 'done', updated_at = now()
      WHERE id = v_log.task_id;
    END IF;

    PERFORM data.log_audit_event(
      v_log.tenant_id, v_user_id, v_log.site_id,
      'WORK_LOG_STOPPED', 'work_log', v_resolved_id,
      jsonb_build_object(
        'project_id', v_log.project_id,
        'task_id', v_log.task_id,
        'check_out', p_check_out,
        'duration_min', v_duration_min,
        'anomaly_codes', v_anomalies,
        'task_closed', p_close_task AND v_log.task_id IS NOT NULL
      )
    );
    v_status := 'synced';
  END IF;

  -- CF-20: freeze labor cost (idempotent; also on offline duplicate retry).
  PERFORM data.freeze_work_log_labor_cost(v_resolved_id);

  PERFORM data.remember_field_op_receipt(
    v_log.tenant_id,
    p_stop_op_id,
    'worklog.stop',
    v_log.project_id,
    v_resolved_id,
    jsonb_build_object(
      'project_id', v_log.project_id,
      'work_log_id', v_resolved_id,
      'start_client_op_id', v_log.client_op_id
    ),
    v_user_id
  );

  RETURN jsonb_build_object(
    'work_log_id', v_resolved_id,
    'duration_minutes', v_duration_min,
    'status', v_status
  );
END;
$$;

REVOKE ALL ON FUNCTION api.stop_work_log(
  uuid, uuid, timestamptz, jsonb, text, boolean, text, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.stop_work_log(
  uuid, uuid, timestamptz, jsonb, text, boolean, text, uuid
) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Backfill closed work logs
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT wl.id
    FROM data.work_logs wl
    WHERE wl.status = 'closed'
      AND NOT EXISTS (
        SELECT 1 FROM data.work_log_labor_costs c WHERE c.work_log_id = wl.id
      )
  LOOP
    PERFORM data.freeze_work_log_labor_cost(r.id);
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Profitability summary RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_project_profitability_summary(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_estimated numeric(14,2) := 0;
  v_accepted_subtotal numeric(14,2) := 0;
  v_billed_subtotal numeric(14,2) := 0;
  v_estimated_cents bigint;
  v_real_cents bigint;
  v_billed_cents bigint;
  v_real_basis text;
  v_lines_cents bigint := 0;
  v_materials_cents bigint := 0;
  v_labor_cents bigint := 0;
  v_expenses_cents bigint := 0;
  v_cost_total bigint;
  v_lines_missing int := 0;
  v_materials_missing int := 0;
  v_labor_unavailable int := 0;
  v_open_logs int := 0;
  v_hour_lines int := 0;
BEGIN
  IF p_project_id IS NULL THEN
    RAISE EXCEPTION 'project_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project
  FROM data.projects
  WHERE id = p_project_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF auth.uid() IS NOT NULL
     AND NOT (data.jwt_user_tenants() ? v_project.tenant_id::text)
     AND COALESCE(auth.role(), '') <> 'service_role'
  THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  IF NOT data.can_view_commercial_costs(v_project.tenant_id, v_project.site_id) THEN
    RAISE EXCEPTION 'permission_denied:commercial.costs.view' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(SUM(data.line_net(pl.quantity, pl.unit_price, pl.discount_pct)), 0)
  INTO v_estimated
  FROM data.project_lines pl
  WHERE pl.project_id = p_project_id
    AND pl.tenant_id = v_project.tenant_id;

  SELECT COALESCE(SUM(d.subtotal), 0)
  INTO v_accepted_subtotal
  FROM data.commercial_documents d
  WHERE d.project_id = p_project_id
    AND d.tenant_id = v_project.tenant_id
    AND d.doc_type IN ('quote', 'quote_amendment')
    AND d.status = 'accepted';

  SELECT COALESCE(SUM(d.subtotal), 0)
  INTO v_billed_subtotal
  FROM data.commercial_documents d
  WHERE d.project_id = p_project_id
    AND d.tenant_id = v_project.tenant_id
    AND d.doc_type = 'delivery_note'
    AND d.status IN ('issued', 'accepted', 'signed');

  v_estimated_cents := ROUND(v_estimated * 100)::bigint;
  IF v_accepted_subtotal > 0 THEN
    v_real_cents := ROUND(v_accepted_subtotal * 100)::bigint;
    v_real_basis := 'accepted_subtotal';
  ELSE
    v_real_cents := v_estimated_cents;
    v_real_basis := 'lines';
  END IF;
  v_billed_cents := ROUND(v_billed_subtotal * 100)::bigint;

  SELECT
    COALESCE(SUM(
      CASE
        WHEN f.unit_cost_cents IS NULL THEN 0
        ELSE ROUND(COALESCE(pl.quantity, 0) * f.unit_cost_cents)::bigint
      END
    ), 0),
    COUNT(*) FILTER (WHERE f.project_line_id IS NULL)::int
  INTO v_lines_cents, v_lines_missing
  FROM data.project_lines pl
  LEFT JOIN data.project_line_financials f ON f.project_line_id = pl.id
  WHERE pl.project_id = p_project_id
    AND pl.tenant_id = v_project.tenant_id
    AND COALESCE(pl.unit, '') IS DISTINCT FROM 'h';

  SELECT COUNT(*)::int INTO v_hour_lines
  FROM data.project_lines pl
  WHERE pl.project_id = p_project_id
    AND pl.tenant_id = v_project.tenant_id
    AND COALESCE(pl.unit, '') = 'h';

  SELECT
    COALESCE(SUM(
      CASE
        WHEN c.unit_cost_cents IS NULL THEN 0
        ELSE ROUND(COALESCE(m.quantity, 0) * c.unit_cost_cents)::bigint
      END
    ), 0),
    COUNT(*) FILTER (WHERE c.material_id IS NULL)::int
  INTO v_materials_cents, v_materials_missing
  FROM data.project_materials m
  LEFT JOIN data.project_material_costs c ON c.material_id = m.id
  WHERE m.project_id = p_project_id
    AND m.tenant_id = v_project.tenant_id;

  SELECT
    COALESCE(SUM(lc.total_labor_cost_cents), 0)::bigint,
    COUNT(*) FILTER (WHERE lc.cost_method = 'unavailable')::int
  INTO v_labor_cents, v_labor_unavailable
  FROM data.work_log_labor_costs lc
  JOIN data.work_logs wl ON wl.id = lc.work_log_id
  WHERE wl.project_id = p_project_id
    AND wl.tenant_id = v_project.tenant_id;

  SELECT COUNT(*)::int INTO v_open_logs
  FROM data.work_logs wl
  WHERE wl.project_id = p_project_id
    AND wl.tenant_id = v_project.tenant_id
    AND wl.status IN ('open', 'paused');

  SELECT COALESCE(SUM(e.amount_cents), 0)::bigint
  INTO v_expenses_cents
  FROM data.project_expenses e
  WHERE e.project_id = p_project_id
    AND e.tenant_id = v_project.tenant_id
    AND (
      e.paid_by = 'company'
      OR (e.paid_by = 'employee' AND e.is_billable IS NOT TRUE)
    );

  v_cost_total := v_lines_cents + v_materials_cents + v_labor_cents + v_expenses_cents;

  RETURN jsonb_build_object(
    'project_id', p_project_id,
    'currency', 'EUR',
    'revenue', jsonb_build_object(
      'estimated_cents', v_estimated_cents,
      'real_cents', v_real_cents,
      'billed_cents', v_billed_cents,
      'real_basis', v_real_basis
    ),
    'cost', jsonb_build_object(
      'lines_cents', v_lines_cents,
      'materials_cents', v_materials_cents,
      'labor_cents', v_labor_cents,
      'expenses_cents', v_expenses_cents,
      'total_cents', v_cost_total
    ),
    'gross', jsonb_build_object(
      'estimated_cents', v_estimated_cents - v_cost_total,
      'real_cents', v_real_cents - v_cost_total
    ),
    'coverage', jsonb_build_object(
      'lines_missing_cost', v_lines_missing,
      'materials_missing_cost', v_materials_missing,
      'labor_unavailable_logs', v_labor_unavailable,
      'open_work_logs', v_open_logs,
      'hour_lines_excluded', v_hour_lines
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_project_profitability_summary(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_project_profitability_summary(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.get_project_profitability_summary(uuid) IS
  'CF-20: resultat brut estimat/real (ex-VAT). Requires commercial.costs.view. Line costs exclude unit=h.';

NOTIFY pgrst, 'reload schema';
