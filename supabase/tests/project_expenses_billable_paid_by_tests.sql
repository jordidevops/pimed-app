-- Gate slice: project_expenses.is_billable + paid_by.
-- SET ROLE authenticated after JWT — postgres bypasses RLS/EXECUTE usefully.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000cfa';
  v_other_project uuid := '51000000-0000-0000-0000-000000000cfb';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api'
      AND table_name = 'project_expenses'
      AND column_name = 'is_billable'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api'
      AND table_name = 'project_expenses'
      AND column_name = 'paid_by'
  ) THEN
    RAISE EXCEPTION 'api.project_expenses must expose is_billable and paid_by';
  END IF;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'Expense slice', 'disposable',
    'active', 'company', v_site, v_client, v_owner
  );

  -- Acme project the Volt member must not see.
  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_other_project,
    '10000000-0000-0000-0000-000000000001',
    'work_order',
    'Expense other tenant',
    'disposable',
    'active',
    'company',
    '30000000-0000-0000-0000-000000000001',
    '80000000-0000-0000-0000-000000000001',
    v_owner
  );

  INSERT INTO data.tenant_members (tenant_id, user_id, role)
  VALUES (v_tenant, v_member, 'member')
  ON CONFLICT DO NOTHING;
END;
$$;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000cfa';
  v_other_project uuid := '51000000-0000-0000-0000-000000000cfb';
  v_id uuid;
  v_billable boolean;
  v_paid text;
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

  v_id := api.add_project_expense(
    v_project, 'Parking', 1250, false, 'company', NULL, NULL
  );

  SELECT is_billable, paid_by INTO v_billable, v_paid
  FROM api.project_expenses WHERE id = v_id;
  IF v_billable IS DISTINCT FROM false OR v_paid IS DISTINCT FROM 'company' THEN
    RAISE EXCEPTION 'defaults expected false/company, got %/%', v_billable, v_paid;
  END IF;

  v_id := api.add_project_expense(
    v_project, 'Toll', 800, true, 'employee', 'travel', NULL
  );
  SELECT is_billable, paid_by INTO v_billable, v_paid
  FROM api.project_expenses WHERE id = v_id;
  IF v_billable IS DISTINCT FROM true OR v_paid IS DISTINCT FROM 'employee' THEN
    RAISE EXCEPTION 'explicit flags expected true/employee, got %/%', v_billable, v_paid;
  END IF;

  UPDATE api.project_expenses
  SET is_billable = false, paid_by = 'company'
  WHERE id = v_id;
  SELECT is_billable, paid_by INTO v_billable, v_paid
  FROM api.project_expenses WHERE id = v_id;
  IF v_billable IS DISTINCT FROM false OR v_paid IS DISTINCT FROM 'company' THEN
    RAISE EXCEPTION 'update flags failed: %/%', v_billable, v_paid;
  END IF;

  BEGIN
    INSERT INTO data.project_expenses (
      tenant_id, project_id, amount_cents, description, created_by, paid_by
    ) VALUES (
      v_tenant, v_project, 100, 'bad paid_by', v_member, 'client'
    );
    RAISE EXCEPTION 'invalid paid_by should have failed';
  EXCEPTION
    WHEN check_violation THEN
      NULL;
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%project_expenses_paid_by_check%'
         AND SQLERRM NOT LIKE '%paid_by%' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    PERFORM api.add_project_expense(
      v_project, 'Bad', 100, false, 'vendor', NULL, NULL
    );
    RAISE EXCEPTION 'RPC invalid paid_by should have failed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%expense_paid_by_invalid%' THEN
        RAISE;
      END IF;
  END;

  SELECT count(*) INTO v_count
  FROM api.project_expenses
  WHERE project_id = v_other_project;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'member must not see other-tenant expenses';
  END IF;

  BEGIN
    PERFORM api.add_project_expense(
      v_other_project, 'Leak', 100, false, 'company', NULL, NULL
    );
    RAISE EXCEPTION 'cross-tenant insert should have failed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%project_not_found_or_access_denied%'
         AND SQLERRM NOT LIKE '%insufficient%'
         AND SQLERRM NOT LIKE '%permission%' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'project expenses billable/paid_by tests passed';
END;
$$;

RESET ROLE;
ROLLBACK;
