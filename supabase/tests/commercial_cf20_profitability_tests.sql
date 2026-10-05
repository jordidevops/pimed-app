-- CF-20 profitability + labor freeze. Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000c20';
  v_emp uuid := '40000000-0000-0000-0000-000000000c20';
  v_contract uuid := 'ec000000-0000-0000-0000-000000000c20';
  v_line_prod uuid := '61000000-0000-0000-0000-000000000c20';
  v_line_h uuid := '61000000-0000-0000-0000-000000000c21';
  v_mat uuid := '62000000-0000-0000-0000-000000000c20';
  v_wl uuid := '63000000-0000-0000-0000-000000000c20';
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'project_lines'
      AND column_name = 'unit_cost_cents'
  ) THEN
    RAISE EXCEPTION 'api.project_lines must not expose unit_cost_cents';
  END IF;

  INSERT INTO data.tenant_members (tenant_id, user_id, role)
  VALUES
    (v_tenant, v_manager, 'manager'),
    (v_tenant, v_member, 'member')
  ON CONFLICT DO NOTHING;

  UPDATE data.tenants
  SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
    'role_permissions', jsonb_build_object('member', '["storage.upload"]'::jsonb)
  )
  WHERE id = v_tenant;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-20 profitability', 'disposable',
    'active', 'company', v_site, v_client, v_owner
  );

  INSERT INTO data.employees (
    id, tenant_id, site_id, user_id, full_name, email, status, weekly_hours
  ) VALUES (
    v_emp, v_tenant, v_site, v_member, 'CF20 Worker', 'cf20@volt.test', 'active', 40
  );

  INSERT INTO data.employment_contracts (
    id, tenant_id, employee_id, lifecycle_status, is_primary,
    starts_on, weekly_hours, created_by
  ) VALUES (
    v_contract, v_tenant, v_emp, 'active', true,
    CURRENT_DATE - 30, 40, v_owner
  );

  INSERT INTO data.employment_contract_compensation (
    tenant_id, contract_id, currency, gross_amount, pay_period
  ) VALUES (
    v_tenant, v_contract, 'EUR', 30.00, 'hourly'
  );

  -- Product line with cost (should count)
  INSERT INTO data.project_lines (
    id, tenant_id, project_id, kind, name, unit, quantity,
    unit_price, discount_pct, tax_rate, position
  ) VALUES (
    v_line_prod, v_tenant, v_project, 'product', 'Cable', 'u', 2,
    50.00, 0, 21, 0
  );
  INSERT INTO data.project_line_financials (
    project_line_id, tenant_id, unit_cost_cents
  ) VALUES (v_line_prod, v_tenant, 1000);

  -- Hour line with cost (must NOT count in cost.lines)
  INSERT INTO data.project_lines (
    id, tenant_id, project_id, kind, name, unit, quantity,
    unit_price, discount_pct, tax_rate, position
  ) VALUES (
    v_line_h, v_tenant, v_project, 'service', 'Tècnic', 'h', 2,
    40.00, 0, 21, 1
  );
  INSERT INTO data.project_line_financials (
    project_line_id, tenant_id, unit_cost_cents
  ) VALUES (v_line_h, v_tenant, 99999);

  INSERT INTO data.project_materials (
    id, tenant_id, project_id, name, quantity, unit, created_by
  ) VALUES (
    v_mat, v_tenant, v_project, 'Cinta', 3, 'u', v_owner
  );
  INSERT INTO data.project_material_costs (
    material_id, tenant_id, unit_cost_cents
  ) VALUES (v_mat, v_tenant, 200);

  -- company expense + billable employee (excluded) + non-billable employee (included)
  INSERT INTO data.project_expenses (
    tenant_id, project_id, description, amount_cents, is_billable, paid_by, created_by
  ) VALUES
    (v_tenant, v_project, 'Parking company', 500, false, 'company', v_owner),
    (v_tenant, v_project, 'Toll billable', 900, true, 'employee', v_owner),
    (v_tenant, v_project, 'Tools employee', 300, false, 'employee', v_owner);

  -- Closed work log 60 min @ 30€/h → 3000 cents
  INSERT INTO data.work_logs (
    id, tenant_id, project_id, site_id, worker_id, employee_id,
    status, check_in, check_out, client_op_id
  ) VALUES (
    v_wl, v_tenant, v_project, v_site, v_member, v_emp,
    'closed',
    timestamptz '2026-10-01 08:00:00+00',
    timestamptz '2026-10-01 09:00:00+00',
    'cf200000-0000-0000-0000-000000000001'::uuid
  );

  PERFORM data.freeze_work_log_labor_cost(v_wl);
END;
$$;

-- Freeze math + immutability
DO $$
DECLARE
  v_wl uuid := '63000000-0000-0000-0000-000000000c20';
  v_contract uuid := 'ec000000-0000-0000-0000-000000000c20';
  v_total int;
  v_method text;
  v_count int;
BEGIN
  SELECT total_labor_cost_cents, cost_method
  INTO v_total, v_method
  FROM data.work_log_labor_costs
  WHERE work_log_id = v_wl;

  IF v_method IS DISTINCT FROM 'hourly_rate' OR v_total IS DISTINCT FROM 3000 THEN
    RAISE EXCEPTION 'freeze math failed: method=% total=%', v_method, v_total;
  END IF;

  UPDATE data.employment_contract_compensation
  SET gross_amount = 99.00
  WHERE contract_id = v_contract;

  PERFORM data.freeze_work_log_labor_cost(v_wl);

  SELECT COUNT(*), MAX(total_labor_cost_cents)
  INTO v_count, v_total
  FROM data.work_log_labor_costs
  WHERE work_log_id = v_wl;

  IF v_count <> 1 OR v_total IS DISTINCT FROM 3000 THEN
    RAISE EXCEPTION 'freeze must be immutable: count=% total=%', v_count, v_total;
  END IF;
END;
$$;

-- Member denied summary + cannot see labor costs
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000c20';
  v_wl uuid := '63000000-0000-0000-0000-000000000c20';
  v_count int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_member,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text,
          json_build_object('global_role', 'member', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );
  SET ROLE authenticated;

  BEGIN
    PERFORM api.get_project_profitability_summary(v_project);
    RAISE EXCEPTION 'member summary should fail';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%permission_denied:commercial.costs.view%' THEN
        RAISE;
      END IF;
  END;

  SELECT count(*) INTO v_count
  FROM api.work_log_labor_costs
  WHERE work_log_id = v_wl;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'member must not see labor costs';
  END IF;
END;
$$;

RESET ROLE;

-- Manager summary math (ex-VAT, no double-count h, expenses 2A)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000c20';
  v_summary jsonb;
  v_est bigint;
  v_lines bigint;
  v_mats bigint;
  v_labor bigint;
  v_exp bigint;
  v_hour_excl int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_manager,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text,
          json_build_object('global_role', 'manager', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );
  SET ROLE authenticated;

  v_summary := api.get_project_profitability_summary(v_project);

  -- Revenue: 2*50 + 2*40 = 180€ → 18000 cents
  v_est := (v_summary -> 'revenue' ->> 'estimated_cents')::bigint;
  IF v_est IS DISTINCT FROM 18000 THEN
    RAISE EXCEPTION 'estimated revenue wrong: %', v_est;
  END IF;
  IF v_summary -> 'revenue' ->> 'real_basis' IS DISTINCT FROM 'lines' THEN
    RAISE EXCEPTION 'expected real_basis=lines without accepted quotes';
  END IF;

  -- Lines cost: only product 2*1000 = 2000 (hour line excluded)
  v_lines := (v_summary -> 'cost' ->> 'lines_cents')::bigint;
  IF v_lines IS DISTINCT FROM 2000 THEN
    RAISE EXCEPTION 'lines cost wrong (hour double-count?): %', v_lines;
  END IF;

  v_mats := (v_summary -> 'cost' ->> 'materials_cents')::bigint;
  IF v_mats IS DISTINCT FROM 600 THEN
    RAISE EXCEPTION 'materials cost wrong: %', v_mats;
  END IF;

  v_labor := (v_summary -> 'cost' ->> 'labor_cents')::bigint;
  IF v_labor IS DISTINCT FROM 3000 THEN
    RAISE EXCEPTION 'labor cost wrong: %', v_labor;
  END IF;

  -- Expenses: 500 company + 300 employee non-billable = 800 (900 billable excluded)
  v_exp := (v_summary -> 'cost' ->> 'expenses_cents')::bigint;
  IF v_exp IS DISTINCT FROM 800 THEN
    RAISE EXCEPTION 'expenses 2A wrong: %', v_exp;
  END IF;

  v_hour_excl := (v_summary -> 'coverage' ->> 'hour_lines_excluded')::int;
  IF v_hour_excl IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'hour_lines_excluded wrong: %', v_hour_excl;
  END IF;

  IF (v_summary -> 'gross' ->> 'estimated_cents')::bigint
     IS DISTINCT FROM (18000 - 2000 - 600 - 3000 - 800) THEN
    RAISE EXCEPTION 'gross estimated wrong: %', v_summary -> 'gross';
  END IF;
END;
$$;

RESET ROLE;

-- stop_work_log duplicate still freezes
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_emp uuid := '40000000-0000-0000-0000-000000000c20';
  v_project uuid := '51000000-0000-0000-0000-000000000c20';
  v_wl uuid := '63000000-0000-0000-0000-000000000c22';
  v_result jsonb;
  v_count int;
BEGIN
  INSERT INTO data.work_logs (
    id, tenant_id, project_id, site_id, worker_id, employee_id,
    status, check_in, check_out, client_op_id
  ) VALUES (
    v_wl, v_tenant, v_project, v_site, v_member, v_emp,
    'closed',
    timestamptz '2026-10-02 08:00:00+00',
    timestamptz '2026-10-02 08:30:00+00',
    'cf200000-0000-0000-0000-000000000002'::uuid
  );

  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_member,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text,
          json_build_object('global_role', 'member', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );
  SET ROLE authenticated;

  v_result := api.stop_work_log(
    v_wl, NULL, now(), NULL, 'notrequired', false, NULL, NULL
  );
  IF v_result ->> 'status' IS DISTINCT FROM 'duplicate' THEN
    RAISE EXCEPTION 'expected duplicate stop: %', v_result;
  END IF;

  RESET ROLE;
  SELECT count(*) INTO v_count
  FROM data.work_log_labor_costs
  WHERE work_log_id = v_wl;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'duplicate stop must freeze labor cost';
  END IF;
END;
$$;

RESET ROLE;

-- Cross-tenant deny
DO $$
DECLARE
  v_other uuid := '10000000-0000-0000-0000-000000000001';
  v_other_owner uuid := '20000000-0000-0000-0000-000000000001';
  v_project uuid := '51000000-0000-0000-0000-000000000c20';
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_other_owner::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_other_owner,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_other::text,
          json_build_object('global_role', 'owner', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_other)::text,
    true
  );
  SET ROLE authenticated;

  BEGIN
    PERFORM api.get_project_profitability_summary(v_project);
    RAISE EXCEPTION 'cross-tenant summary should fail';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%project_not_found%'
         AND SQLERRM NOT LIKE '%permission_denied%'
         AND SQLERRM NOT LIKE '%access_denied%' THEN
        RAISE;
      END IF;
  END;
END;
$$;

RESET ROLE;

-- Immutable: UPDATE of frozen labor cost must fail
DO $$
DECLARE
  v_wl uuid := '63000000-0000-0000-0000-000000000c20';
BEGIN
  BEGIN
    UPDATE data.work_log_labor_costs
    SET total_labor_cost_cents = 1
    WHERE work_log_id = v_wl;
    RAISE EXCEPTION 'labor cost UPDATE should be blocked';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%work_log_labor_cost_immutable%' THEN
        RAISE;
      END IF;
  END;
END;
$$;

-- Employee without contract → unavailable
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000c20';
  v_emp uuid := '40000000-0000-0000-0000-000000000c21';
  v_wl uuid := '63000000-0000-0000-0000-000000000c23';
  v_method text;
  v_total int;
BEGIN
  INSERT INTO data.employees (
    id, tenant_id, site_id, user_id, full_name, email, status, weekly_hours
  ) VALUES (
    v_emp, v_tenant, v_site, NULL, 'CF20 NoContract', 'cf20nc@volt.test', 'active', 40
  );

  INSERT INTO data.work_logs (
    id, tenant_id, project_id, site_id, worker_id, employee_id,
    status, check_in, check_out, client_op_id
  ) VALUES (
    v_wl, v_tenant, v_project, v_site, v_member, v_emp,
    'closed',
    timestamptz '2026-10-03 08:00:00+00',
    timestamptz '2026-10-03 09:00:00+00',
    'cf200000-0000-0000-0000-000000000003'::uuid
  );

  PERFORM data.freeze_work_log_labor_cost(v_wl);

  SELECT cost_method, total_labor_cost_cents
  INTO v_method, v_total
  FROM data.work_log_labor_costs
  WHERE work_log_id = v_wl;

  IF v_method IS DISTINCT FROM 'unavailable' OR v_total IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'no-contract freeze expected unavailable: method=% total=%', v_method, v_total;
  END IF;
END;
$$;

-- Accepted quote with subtotal 0 → real_basis accepted_subtotal (not lines)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000c20';
  v_doc uuid := '71000000-0000-0000-0000-000000000c20';
  v_summary jsonb;
BEGIN
  INSERT INTO data.commercial_documents (
    id, tenant_id, doc_type, doc_number, client_id, project_id, status,
    currency, subtotal, total, show_prices, issued_at, created_by,
    seller_snapshot, buyer_snapshot
  ) VALUES (
    v_doc, v_tenant, 'quote', 'CF20-Q-ZERO', v_client, v_project, 'accepted',
    'EUR', 0, 0, true, now(), v_owner,
    '{}'::jsonb, '{}'::jsonb
  );

  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_manager,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text,
          json_build_object('global_role', 'manager', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );
  SET ROLE authenticated;

  v_summary := api.get_project_profitability_summary(v_project);

  IF v_summary -> 'revenue' ->> 'real_basis' IS DISTINCT FROM 'accepted_subtotal' THEN
    RAISE EXCEPTION 'zero accepted quote must use accepted_subtotal: %', v_summary -> 'revenue';
  END IF;
  IF (v_summary -> 'revenue' ->> 'real_cents')::bigint IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'zero accepted quote real_cents must be 0: %', v_summary -> 'revenue';
  END IF;
END;
$$;

RESET ROLE;

-- Closed log without freeze row counts in labor_unavailable_logs
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_emp uuid := '40000000-0000-0000-0000-000000000c20';
  v_manager uuid := '20000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000c20';
  v_wl uuid := '63000000-0000-0000-0000-000000000c24';
  v_summary jsonb;
  v_unavail int;
BEGIN
  INSERT INTO data.work_logs (
    id, tenant_id, project_id, site_id, worker_id, employee_id,
    status, check_in, check_out, client_op_id
  ) VALUES (
    v_wl, v_tenant, v_project, v_site, v_member, v_emp,
    'closed',
    timestamptz '2026-10-04 10:00:00+00',
    timestamptz '2026-10-04 11:00:00+00',
    'cf200000-0000-0000-0000-000000000004'::uuid
  );
  -- intentionally no freeze

  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_manager,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text,
          json_build_object('global_role', 'manager', 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claims', current_setting('request.jwt.claim'), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );
  SET ROLE authenticated;

  v_summary := api.get_project_profitability_summary(v_project);
  v_unavail := (v_summary -> 'coverage' ->> 'labor_unavailable_logs')::int;

  -- at least: no-contract unavailable (c23) + missing freeze (c24)
  IF v_unavail < 2 THEN
    RAISE EXCEPTION 'coverage must count unavailable + missing freeze: %', v_unavail;
  END IF;
END;
$$;

RESET ROLE;

-- Europe/Madrid date: early-morning local check_in must not resolve as previous UTC day
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000c20';
  v_emp uuid := '40000000-0000-0000-0000-000000000c22';
  v_contract uuid := 'ec000000-0000-0000-0000-000000000c22';
  v_wl uuid := '63000000-0000-0000-0000-000000000c25';
  v_method text;
  v_total int;
  v_on text;
BEGIN
  INSERT INTO data.employees (
    id, tenant_id, site_id, user_id, full_name, email, status, weekly_hours
  ) VALUES (
    v_emp, v_tenant, v_site, NULL, 'CF20 TZ', 'cf20tz@volt.test', 'active', 40
  );

  INSERT INTO data.employment_contracts (
    id, tenant_id, employee_id, lifecycle_status, is_primary,
    starts_on, weekly_hours, created_by
  ) VALUES (
    v_contract, v_tenant, v_emp, 'active', true,
    DATE '2026-10-05', 40, v_owner
  );

  INSERT INTO data.employment_contract_compensation (
    tenant_id, contract_id, currency, gross_amount, pay_period
  ) VALUES (
    v_tenant, v_contract, 'EUR', 20.00, 'hourly'
  );

  -- 00:30 Europe/Madrid on 2026-10-05 = 2026-10-04 22:30 UTC
  INSERT INTO data.work_logs (
    id, tenant_id, project_id, site_id, worker_id, employee_id,
    status, check_in, check_out, client_op_id
  ) VALUES (
    v_wl, v_tenant, v_project, v_site, v_member, v_emp,
    'closed',
    timestamptz '2026-10-05 00:30:00+02',
    timestamptz '2026-10-05 01:30:00+02',
    'cf200000-0000-0000-0000-000000000005'::uuid
  );

  PERFORM data.freeze_work_log_labor_cost(v_wl);

  SELECT cost_method, total_labor_cost_cents, cost_snapshot->>'on_date'
  INTO v_method, v_total, v_on
  FROM data.work_log_labor_costs
  WHERE work_log_id = v_wl;

  IF v_method IS DISTINCT FROM 'hourly_rate' OR v_total IS DISTINCT FROM 2000 THEN
    RAISE EXCEPTION 'Madrid TZ freeze failed: method=% total=% on_date=%', v_method, v_total, v_on;
  END IF;
  IF v_on IS DISTINCT FROM '2026-10-05' THEN
    RAISE EXCEPTION 'on_date must be Madrid calendar day: %', v_on;
  END IF;
END;
$$;

DO $$
BEGIN
  RAISE NOTICE 'PASS: CF-20 profitability';
END;
$$;

ROLLBACK;
