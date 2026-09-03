-- =============================================================================
-- CP-A0.1 / CP-C: contact_relationships + contact_delivery_channels + rules
-- =============================================================================
-- Cobertura:
--   T1 Crear relació company↔person (mateix tenant) OK — role commercial label
--   T2 Relació cross-company / wrong kind denegada
--   T3 Offboarding (revoke) deixa fila i bloqueja duplicat actiu (sense role a unique)
--   T4 Canal delivery persona OK; company mailbox també OK (CP-C)
--   T5 Delivery rule account+point OK
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- -----------------------------------------------------------------------------
-- Fixtures: company + two persons on Volt; extra company for wrong-kind
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  INSERT INTO data.contacts (id, tenant_id, kind, display_name, given_name, family_name, source)
  VALUES
    ('80000000-0000-0000-0000-00000000aa01', '10000000-0000-0000-0000-000000000003', 'company', 'CP-A0 Co', NULL, NULL, 'test'),
    ('80000000-0000-0000-0000-00000000aa02', '10000000-0000-0000-0000-000000000003', 'person', 'CP-A0 Pers A', 'A', 'Pers', 'test'),
    ('80000000-0000-0000-0000-00000000aa03', '10000000-0000-0000-0000-000000000003', 'person', 'CP-A0 Pers B', 'B', 'Pers', 'test'),
    ('80000000-0000-0000-0000-00000000aa04', '10000000-0000-0000-0000-000000000003', 'company', 'CP-A0 Co 2', NULL, NULL, 'test')
  ON CONFLICT (id) DO NOTHING;
END $$;

-- -----------------------------------------------------------------------------
-- T1: create relationship same tenant OK (role = operations, not portal)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_id uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  v_id := api.create_contact_relationship(
    '80000000-0000-0000-0000-00000000aa01'::uuid,
    '80000000-0000-0000-0000-00000000aa02'::uuid,
    'operations',
    'test'
  );

  IF v_id IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T1 create relationship same tenant', 'PASS', v_id::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 create relationship same tenant', 'FAIL', 'null id');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 create relationship same tenant', 'FAIL', SQLERRM);
END $$;

-- -----------------------------------------------------------------------------
-- T2: wrong kind (company as person) denied
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  BEGIN
    PERFORM api.create_contact_relationship(
      '80000000-0000-0000-0000-00000000aa01'::uuid,
      '80000000-0000-0000-0000-00000000aa04'::uuid, -- company as "person"
      'other',
      'test'
    );
    INSERT INTO test_results VALUES ('T2 wrong kind denied', 'FAIL', 'expected exception');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%contact_relationship_person_must_be_person%'
       OR SQLERRM LIKE '%person_must_be_person%' THEN
      INSERT INTO test_results VALUES ('T2 wrong kind denied', 'PASS', SQLERRM);
    ELSE
      INSERT INTO test_results VALUES ('T2 wrong kind denied', 'FAIL', 'denied with unexpected error: ' || SQLERRM);
    END IF;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- T3: revoke + unique active (pair unique without role)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_rel uuid;
  v_active int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  SELECT id INTO v_rel
  FROM data.contact_relationships
  WHERE organization_contact_id = '80000000-0000-0000-0000-00000000aa01'::uuid
    AND person_contact_id = '80000000-0000-0000-0000-00000000aa02'::uuid
    AND revoked_at IS NULL
  LIMIT 1;

  PERFORM api.revoke_contact_relationship(v_rel, 'offboard test');

  SELECT COUNT(*) INTO v_active
  FROM data.contact_relationships
  WHERE id = v_rel AND revoked_at IS NOT NULL AND ends_at IS NOT NULL;

  -- Re-create same pair should succeed after revoke
  PERFORM api.create_contact_relationship(
    '80000000-0000-0000-0000-00000000aa01'::uuid,
    '80000000-0000-0000-0000-00000000aa02'::uuid,
    'billing',
    'test'
  );

  IF v_active = 1 THEN
    INSERT INTO test_results VALUES ('T3 revoke + recreate', 'PASS', 'revoked and recreated');
  ELSE
    INSERT INTO test_results VALUES ('T3 revoke + recreate', 'FAIL', format('active_check=%s', v_active));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 revoke + recreate', 'FAIL', SQLERRM);
END $$;

-- -----------------------------------------------------------------------------
-- T4: delivery channel on person OK; company mailbox also OK (CP-C)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_ch_person uuid;
  v_ch_company uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  v_ch_person := api.create_contact_delivery_channel(
    '80000000-0000-0000-0000-00000000aa03'::uuid,
    'email',
    'pers-b@example.com',
    true,
    'staff_confirmed'
  );

  v_ch_company := api.create_contact_delivery_channel(
    '80000000-0000-0000-0000-00000000aa01'::uuid,
    'email',
    'co@example.com',
    true,
    'staff_confirmed'
  );

  IF v_ch_person IS NOT NULL AND v_ch_company IS NOT NULL THEN
    INSERT INTO test_results VALUES (
      'T4 channel person + company ok',
      'PASS',
      format('person=%s company=%s', v_ch_person, v_ch_company)
    );
  ELSE
    INSERT INTO test_results VALUES ('T4 channel person + company ok', 'FAIL', 'null channel id');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 channel person + company ok', 'FAIL', SQLERRM);
END $$;

-- -----------------------------------------------------------------------------
-- T5: delivery rule for company account + company mailbox point
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_ch uuid;
  v_rule uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  SELECT id INTO v_ch
  FROM data.contact_delivery_channels
  WHERE contact_id = '80000000-0000-0000-0000-00000000aa01'::uuid
    AND value_normalized = 'co@example.com'
    AND disabled_at IS NULL
  LIMIT 1;

  v_rule := api.create_contact_delivery_rule(
    '80000000-0000-0000-0000-00000000aa01'::uuid,
    v_ch,
    'bulletin',
    'manual'
  );

  IF v_rule IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T5 delivery rule', 'PASS', v_rule::text);
  ELSE
    INSERT INTO test_results VALUES ('T5 delivery rule', 'FAIL', 'null rule');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 delivery rule', 'FAIL', SQLERRM);
END $$;

-- -----------------------------------------------------------------------------
-- T6: scheduled ends_at still blocks a second live affiliation
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_rel uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);

  SELECT id INTO v_rel
  FROM data.contact_relationships
  WHERE organization_contact_id = '80000000-0000-0000-0000-00000000aa01'::uuid
    AND person_contact_id = '80000000-0000-0000-0000-00000000aa02'::uuid
    AND revoked_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1;

  UPDATE data.contact_relationships
  SET ends_at = now() + interval '30 days'
  WHERE id = v_rel;

  BEGIN
    PERFORM api.create_contact_relationship(
      '80000000-0000-0000-0000-00000000aa01'::uuid,
      '80000000-0000-0000-0000-00000000aa02'::uuid,
      'operations',
      'test'
    );
    INSERT INTO test_results VALUES ('T6 future ends_at blocks', 'FAIL', 'second live row allowed');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%contact_relationship_already_active%' OR SQLERRM LIKE '%unique%' THEN
      INSERT INTO test_results VALUES ('T6 future ends_at blocks', 'PASS', SQLERRM);
    ELSE
      INSERT INTO test_results VALUES ('T6 future ends_at blocks', 'FAIL', SQLERRM);
    END IF;
  END;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 future ends_at blocks', 'FAIL', SQLERRM);
END $$;

-- Report
SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'CP-A0.1/CP-C tests failed: % failures', v_fail;
  END IF;
END $$;

ROLLBACK;
