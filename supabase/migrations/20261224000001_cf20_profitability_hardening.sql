-- CF-20 hardening: Europe/Madrid freeze date, accepted-docs real_basis,
-- coverage for closed logs missing freeze, revoke public execute on helpers,
-- immutable labor cost rows (UPDATE blocked; DELETE allowed for CASCADE).

-- ---------------------------------------------------------------------------
-- 1. Freeze: resolve contract cost on local calendar day (Europe/Madrid)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.freeze_work_log_labor_cost(p_work_log_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_log data.work_logs%ROWTYPE;
  v_duration int;
  v_on_date date;
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

  -- Same TZ convention as HR period confirmations (not session/UTC blind).
  v_on_date := (v_log.check_in AT TIME ZONE 'Europe/Madrid')::date;

  IF v_log.employee_id IS NULL THEN
    INSERT INTO data.work_log_labor_costs (
      work_log_id, tenant_id, employee_id, contract_id,
      duration_minutes, hourly_cost_cents, total_labor_cost_cents,
      cost_method, cost_snapshot
    ) VALUES (
      v_log.id, v_log.tenant_id, NULL, NULL,
      v_duration, NULL, 0,
      'unavailable',
      jsonb_build_object('reason', 'employee_id_missing', 'on_date', v_on_date)
    )
    ON CONFLICT (work_log_id) DO NOTHING;
    RETURN;
  END IF;

  v_contract := data.resolve_employee_contract_for_cost(
    v_log.employee_id,
    v_on_date
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
      jsonb_build_object('reason', 'no_effective_contract', 'on_date', v_on_date)
    )
    ON CONFLICT (work_log_id) DO NOTHING;
    RETURN;
  END IF;

  v_snap := data.resolve_contract_planning_cost(v_contract, v_on_date);
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
      v_snap || jsonb_build_object('reason', 'cost_unavailable', 'on_date', v_on_date)
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
    v_method,
    v_snap || jsonb_build_object('on_date', v_on_date)
  )
  ON CONFLICT (work_log_id) DO NOTHING;
END;
$$;

-- Only DEFINER callers (stop_work_log / migrations / service_role) need this.
REVOKE ALL ON FUNCTION data.freeze_work_log_labor_cost(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION data.freeze_work_log_labor_cost(uuid) TO service_role;

REVOKE ALL ON FUNCTION data.resolve_employee_contract_for_cost(uuid, date)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION data.resolve_employee_contract_for_cost(uuid, date)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Immutable snapshot (block UPDATE; allow DELETE for work_logs CASCADE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_work_log_labor_costs_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  RAISE EXCEPTION 'work_log_labor_cost_immutable' USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS trg_work_log_labor_costs_immutable ON data.work_log_labor_costs;
CREATE TRIGGER trg_work_log_labor_costs_immutable
  BEFORE UPDATE ON data.work_log_labor_costs
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_work_log_labor_costs_immutable();

-- Tenant trigger mutates frozen_at on INSERT; keep it BEFORE the immutable gate
-- (immutable is UPDATE-only). No change needed to tenant trigger.

-- ---------------------------------------------------------------------------
-- 3. Summary: accepted docs (even subtotal 0) + closed-without-freeze coverage
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
  v_has_accepted boolean := false;
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

  SELECT
    COALESCE(SUM(d.subtotal), 0),
    EXISTS (
      SELECT 1
      FROM data.commercial_documents d2
      WHERE d2.project_id = p_project_id
        AND d2.tenant_id = v_project.tenant_id
        AND d2.doc_type IN ('quote', 'quote_amendment')
        AND d2.status = 'accepted'
    )
  INTO v_accepted_subtotal, v_has_accepted
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
  IF v_has_accepted THEN
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

  SELECT COALESCE(SUM(lc.total_labor_cost_cents), 0)::bigint
  INTO v_labor_cents
  FROM data.work_log_labor_costs lc
  JOIN data.work_logs wl ON wl.id = lc.work_log_id
  WHERE wl.project_id = p_project_id
    AND wl.tenant_id = v_project.tenant_id;

  -- Unavailable method OR closed log with no freeze row at all.
  SELECT COUNT(*)::int
  INTO v_labor_unavailable
  FROM data.work_logs wl
  LEFT JOIN data.work_log_labor_costs lc ON lc.work_log_id = wl.id
  WHERE wl.project_id = p_project_id
    AND wl.tenant_id = v_project.tenant_id
    AND wl.status = 'closed'
    AND (
      lc.work_log_id IS NULL
      OR lc.cost_method = 'unavailable'
    );

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
  'CF-20: resultat brut estimat/real (ex-VAT). Requires commercial.costs.view. Line costs exclude unit=h. labor_unavailable_logs includes closed logs without freeze.';

COMMENT ON FUNCTION data.freeze_work_log_labor_cost(uuid) IS
  'CF-20: freeze labor cost on closed work log. Contract date = check_in in Europe/Madrid. Idempotent.';

NOTIFY pgrst, 'reload schema';
