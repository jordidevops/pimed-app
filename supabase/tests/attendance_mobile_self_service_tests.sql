BEGIN;
SELECT plan(4);

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a1500000-0000-0000-0000-000000000001', 'Mobile attendance test', 'mobile-attendance-test', true);

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES (
  'b1500000-0000-0000-0000-000000000001',
  'a1500000-0000-0000-0000-000000000001',
  'Test site',
  true
);

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c1500000-0000-0000-0000-000000000001', 'mobile-member@test.local', 'authenticated', 'authenticated'),
  ('c1500000-0000-0000-0000-000000000002', 'other-member@test.local', 'authenticated', 'authenticated'),
  ('c1500000-0000-0000-0000-000000000003', 'mobile-manager@test.local', 'authenticated', 'authenticated');

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd1500000-0000-0000-0000-000000000001',
  'a1500000-0000-0000-0000-000000000001',
  'b1500000-0000-0000-0000-000000000001',
  'c1500000-0000-0000-0000-000000000001',
  'Mobile Member',
  'active'
);

INSERT INTO data.tenant_absence_type_configs (
  tenant_id, absence_type, name_i18n, parent_key, is_active
)
VALUES (
  'a1500000-0000-0000-0000-000000000001',
  'mobile_permission_test',
  '{"ca":"Permís de prova"}',
  'permission',
  true
);

DO $$
BEGIN
  BEGIN
    INSERT INTO data.employee_absences (
      tenant_id, site_id, employee_id, absence_type,
      start_date, end_date, status, requested_by
    )
    VALUES (
      'a1500000-0000-0000-0000-000000000001',
      'b1500000-0000-0000-0000-000000000001',
      'd1500000-0000-0000-0000-000000000001',
      'mobile_permission_test',
      '2026-10-01', '2026-10-01', 'requested',
      'c1500000-0000-0000-0000-000000000001'
    );
    RAISE EXCEPTION 'expected absence_reason_required';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;
END;
$$;
SELECT pass('permission absences require a reason');

INSERT INTO data.employee_absences (
  id, tenant_id, site_id, employee_id, absence_type,
  start_date, end_date, status, notes, requested_by
)
VALUES (
  'e1500000-0000-0000-0000-000000000001',
  'a1500000-0000-0000-0000-000000000001',
  'b1500000-0000-0000-0000-000000000001',
  'd1500000-0000-0000-0000-000000000001',
  'mobile_permission_test',
  '2026-10-02', '2026-10-02', 'requested', 'Assumpte familiar',
  'c1500000-0000-0000-0000-000000000001'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"c1500000-0000-0000-0000-000000000001","app_metadata":{"user_permissions":{"a1500000-0000-0000-0000-000000000001":{"global_permissions":["absences.request"],"sites":{}}}}}',
  true
);

DO $$
BEGIN
  PERFORM api.cancel_my_absence(
    'e1500000-0000-0000-0000-000000000001',
    'Ja no és necessari'
  );
END;
$$;

SELECT is(
  (
    SELECT status
    FROM data.employee_absences
    WHERE id = 'e1500000-0000-0000-0000-000000000001'
  ),
  'cancelled',
  'employee can cancel an own pending absence'
);

INSERT INTO data.employee_absences (
  id, tenant_id, site_id, employee_id, absence_type,
  start_date, end_date, status, notes, requested_by
)
VALUES (
  'e1500000-0000-0000-0000-000000000002',
  'a1500000-0000-0000-0000-000000000001',
  'b1500000-0000-0000-0000-000000000001',
  'd1500000-0000-0000-0000-000000000001',
  'mobile_permission_test',
  '2026-10-03', '2026-10-03', 'approved', 'Assumpte familiar',
  'c1500000-0000-0000-0000-000000000001'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"c1500000-0000-0000-0000-000000000003","app_metadata":{"user_permissions":{"a1500000-0000-0000-0000-000000000001":{"global_permissions":["attendance.approve"],"sites":{}}}}}',
  true
);

DO $$
BEGIN
  PERFORM api.revoke_absence(
    'e1500000-0000-0000-0000-000000000002',
    'Aprovació incorrecta'
  );
END;
$$;

SELECT is(
  (
    SELECT status
    FROM data.employee_absences
    WHERE id = 'e1500000-0000-0000-0000-000000000002'
  ),
  'revoked',
  'manager can revoke an approved absence'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"c1500000-0000-0000-0000-000000000002","app_metadata":{"user_permissions":{"a1500000-0000-0000-0000-000000000001":{"global_permissions":["absences.request"],"sites":{}}}}}',
  true
);

DO $$
BEGIN
  BEGIN
    PERFORM api.get_vacation_entitlement(
      'd1500000-0000-0000-0000-000000000001',
      2026,
      'vacation'
    );
    RAISE EXCEPTION 'expected unauthorized vacation balance';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
SELECT pass('another employee cannot read the vacation balance');

SELECT * FROM finish();
ROLLBACK;
