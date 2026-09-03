-- Track C1 — absence taxonomy + export_code
BEGIN;

CREATE TEMP TABLE c1_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION c1_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO c1_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

DO $$
DECLARE
  v_tenant    uuid := '10000000-0000-0000-0000-000000000001';
  v_site      uuid := '30000000-0000-0000-0000-000000000001';
  v_employee  uuid := '40000000-0000-0000-0000-000000000001';
  v_manager   uuid := '20000000-0000-0000-0000-000000000004';
  v_cfg       jsonb;
  v_json      jsonb;
  v_row       jsonb;
  v_abs_id    uuid;
  v_work_date date := '2026-09-10';
BEGIN
  -- T1: system backfill
  PERFORM c1_assert(
    EXISTS (
      SELECT 1 FROM data.tenant_absence_type_configs
      WHERE is_system = true AND tenant_id IS NULL
        AND absence_type = 'vacation'
        AND parent_key = 'vacation'
        AND subtype_key = 'vacation'
        AND export_code = 'VA'
    ),
    'vacation system type has taxonomy + VA export_code'
  );

  PERFORM c1_assert(
    EXISTS (
      SELECT 1 FROM data.tenant_absence_type_configs
      WHERE is_system = true AND tenant_id IS NULL
        AND absence_type = 'it_common'
        AND parent_key = 'it'
        AND export_code = 'IT'
    ),
    'it_common system type parent it + IT export_code'
  );

  -- T2: resolver
  v_cfg := data.resolve_tenant_absence_type_config(v_tenant, 'vacation');
  PERFORM c1_assert(v_cfg->>'export_code' = 'VA', 'resolver default export_code VA');
  PERFORM c1_assert(v_cfg->>'parent_key' = 'vacation', 'resolver parent_key vacation');

  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config('request.headers', format('{"x-tenant-id":"%s"}', v_tenant), true);
  PERFORM set_config(
    'request.jwt.claims',
    format(
      '{"sub":"%s","app_metadata":{"user_tenants":{"%s":{"global_role":"manager","sites":{"%s":"manager"}}},"user_permissions":{"%s":{"global_permissions":["attendance.manage","attendance.export","attendance.view_all"],"sites":{"%s":{"permissions":["attendance.manage","attendance.export","attendance.view_all"]}}}}}}',
      v_manager, v_tenant, v_site, v_tenant, v_site
    ),
    true
  );

  -- T3: tenant override export_code
  PERFORM api.save_absence_type_export_settings('vacation', 'VAC', NULL, NULL);
  v_cfg := data.resolve_tenant_absence_type_config(v_tenant, 'vacation');
  PERFORM c1_assert(v_cfg->>'export_code' = 'VAC', 'tenant override export_code VAC');

  -- T4: absence day helper + export
  DELETE FROM data.employee_absences
  WHERE employee_id = v_employee AND start_date <= v_work_date AND end_date >= v_work_date;

  INSERT INTO data.employee_absences (
    tenant_id, site_id, employee_id, absence_type, start_date, end_date, status, is_paid, requested_by
  ) VALUES (
    v_tenant, v_site, v_employee, 'vacation', v_work_date, v_work_date, 'approved', true, v_manager
  )
  RETURNING id INTO v_abs_id;

  v_cfg := data.select_absence_for_employee_day(v_employee, v_tenant, v_work_date);
  PERFORM c1_assert((v_cfg->>'absence_id')::uuid = v_abs_id, 'select_absence_for_employee_day absence_id');
  PERFORM c1_assert(v_cfg->>'export_code' = 'VAC', 'select_absence_for_employee_day export_code override');
  PERFORM c1_assert(v_cfg->>'parent_key' = 'vacation', 'select_absence_for_employee_day parent_key');

  v_json := api.export_payroll_period(v_site, v_work_date, v_work_date, v_employee, 'daily');
  SELECT elem INTO v_row
  FROM jsonb_array_elements(v_json->'rows') elem
  WHERE (elem->>'work_date')::date = v_work_date
  LIMIT 1;

  PERFORM c1_assert(v_row->>'absence_export_code' = 'VAC', 'export daily absence_export_code');
  PERFORM c1_assert(v_row->>'absence_parent_key' = 'vacation', 'export daily absence_parent_key');
  PERFORM c1_assert(v_row->>'absence_subtype_key' = 'vacation', 'export daily absence_subtype_key');
  PERFORM c1_assert(v_row->>'payroll_action' = 'absence_ok', 'export daily payroll_action absence_ok');

  -- T5: payroll review days taxonomy
  v_json := api.get_payroll_review_days(v_employee, v_work_date, v_work_date);
  SELECT elem INTO v_row
  FROM jsonb_array_elements(v_json->'days') elem
  WHERE (elem->>'work_date')::date = v_work_date
  LIMIT 1;

  PERFORM c1_assert(v_row->>'absence_export_code' = 'VAC', 'review days absence_export_code');
  PERFORM c1_assert(v_row->>'absence_parent_key' = 'vacation', 'review days absence_parent_key');

  -- cleanup tenant override for other tests
  DELETE FROM data.tenant_absence_type_configs
  WHERE tenant_id = v_tenant AND absence_type = 'vacation' AND is_system = false;
END;
$$;

SELECT msg FROM c1_test_log ORDER BY id;

ROLLBACK;
