-- CF-21-h3: agreement cycles.
--   * finalize creates cycle 1 (mirrors the signed version, pointer + billing_state)
--   * backfill (data.commercial_agreement_backfill_cycles) is idempotent and maps statuses
--   * renew closes the cycle and opens cycle_no + 1 WITHOUT mutating the signed version
--   * contractual dates are immutable even with the legacy renew_unlocked GUC
--   * at most one open cycle per agreement; cycle date range check
--   * activate_due flips pending -> active (and creates cycle 1 when missing)
--   * expire creates a missing cycle (safety net) and finishes non-renewing agreements
--   * RLS / api views / grants
-- The main block is rolled back (ZZ001) so the file is re-runnable.
-- The last block documents the preflight (hard stop on legacy 'renewed' events).

-- Helper: framework agreement (+ optional finalize with a stub signed PDF).
CREATE OR REPLACE FUNCTION pg_temp.cf21h3_agreement(
  p_starts date,
  p_ends date,
  p_auto_renew boolean,
  p_cadence text DEFAULT 'none',
  p_amount int DEFAULT NULL,
  p_anchor int DEFAULT NULL,
  p_finalize boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_template uuid := '76100000-0000-0000-0000-000000000002';
  v_client uuid;
  v_agreement uuid;
  v_version uuid;
  v_doc uuid;
BEGIN
  SELECT client_id INTO v_client FROM data.projects WHERE id = v_project;

  v_agreement := api.create_framework_agreement(
    p_tenant_id => v_tenant,
    p_client_id => v_client,
    p_template_id => v_template,
    p_work_gate => 'none',
    p_client_op_id => gen_random_uuid(),
    p_starts_on => p_starts,
    p_ends_on => p_ends,
    p_notice_days => 15,
    p_locale => 'ca',
    p_auto_renew => p_auto_renew,
    p_billing_cadence => p_cadence,
    p_billing_amount_cents => p_amount,
    p_billing_currency => 'EUR',
    p_billing_anchor_day => p_anchor
  );

  IF p_finalize THEN
    SELECT active_version_id INTO v_version
    FROM data.commercial_agreements WHERE id = v_agreement;

    INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
    VALUES (v_tenant, 'CF21h3 signed stub', 'commercial', '{}', v_owner)
    RETURNING id INTO v_doc;

    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature' WHERE id = v_version;
    PERFORM data.finalize_commercial_agreement_version(v_version, v_doc, v_owner, CURRENT_DATE);
  END IF;

  RETURN v_agreement;
END;
$$;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_a uuid;       -- active, monthly billing
  v_b uuid;       -- future start (pending)
  v_c uuid;       -- future start, cycle wiped before activate_due
  v_d uuid;       -- finished
  v_e uuid;       -- auto_renew, expired
  v_f uuid;       -- not auto_renew, expired
  v_g uuid;       -- active, cycle wiped before expire
  v_version uuid;
  v_cycle data.commercial_agreement_cycles%ROWTYPE;
  v_cycle2 data.commercial_agreement_cycles%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_ver data.commercial_agreement_versions%ROWTYPE;
  v_result jsonb;
  v_n int;
  v_next date;
  v_status text;
  v_event data.commercial_agreement_events%ROWTYPE;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
    PERFORM set_config(
      'request.jwt.claim',
      json_build_object(
        'sub', v_owner,
        'role', 'authenticated',
        'app_metadata', json_build_object(
          'user_tenants', json_build_object(
            v_tenant::text, json_build_object('global_role', 'owner', 'sites', json_build_object())
          ),
          'user_permissions', json_build_object(
            v_tenant::text, json_build_object('global_permissions', json_build_array('*'), 'sites', json_build_object())
          )
        )
      )::text,
      true
    );
    PERFORM set_config(
      'request.headers',
      json_build_object('x-tenant-id', v_tenant)::text,
      true
    );

    -- 1. finalize creates cycle 1 -------------------------------------------------
    v_a := pg_temp.cf21h3_agreement(
      CURRENT_DATE - 10, CURRENT_DATE + 355, false, 'monthly', 10000, 1, true
    );
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_a;
    SELECT * INTO v_ver FROM data.commercial_agreement_versions WHERE id = v_agreement.active_version_id;

    SELECT count(*) INTO v_n FROM data.commercial_agreement_cycles WHERE agreement_id = v_a;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'CF21h3 finalize expected 1 cycle, got %', v_n;
    END IF;
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_a;
    IF v_cycle.cycle_no <> 1 OR v_cycle.origin <> 'initial' OR v_cycle.status <> 'active' THEN
      RAISE EXCEPTION 'CF21h3 unexpected cycle 1: no=% origin=% status=%',
        v_cycle.cycle_no, v_cycle.origin, v_cycle.status;
    END IF;
    IF v_cycle.starts_on IS DISTINCT FROM v_ver.starts_on
       OR v_cycle.ends_on IS DISTINCT FROM v_ver.ends_on THEN
      RAISE EXCEPTION 'CF21h3 cycle 1 dates differ from the version (% / %)',
        v_cycle.starts_on, v_cycle.ends_on;
    END IF;
    IF v_agreement.active_cycle_id IS DISTINCT FROM v_cycle.id THEN
      RAISE EXCEPTION 'CF21h3 active_cycle_id not set after finalize';
    END IF;
    SELECT next_billing_on INTO v_next
    FROM data.commercial_agreement_billing_state WHERE agreement_id = v_a;
    IF NOT FOUND OR v_next IS DISTINCT FROM v_ver.starts_on THEN
      RAISE EXCEPTION 'CF21h3 billing_state not seeded from prepare (got %)', v_next;
    END IF;

    -- re-finalizing is a no-op for cycles
    PERFORM data.finalize_commercial_agreement_version(
      v_ver.id, v_ver.signed_document_id, v_owner, CURRENT_DATE
    );
    SELECT count(*) INTO v_n FROM data.commercial_agreement_cycles WHERE agreement_id = v_a;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'CF21h3 re-finalize created % cycles', v_n;
    END IF;

    -- 2. open cycle is unique; date range is checked ------------------------------
    BEGIN
      INSERT INTO data.commercial_agreement_cycles (
        tenant_id, agreement_id, cycle_no, starts_on, ends_on, status, origin
      ) VALUES (v_tenant, v_a, 2, CURRENT_DATE, CURRENT_DATE + 30, 'active', 'manual');
      RAISE EXCEPTION 'CF21h3 second open cycle was allowed';
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;
    BEGIN
      INSERT INTO data.commercial_agreement_cycles (
        tenant_id, agreement_id, cycle_no, starts_on, ends_on, status, origin
      ) VALUES (v_tenant, v_a, 3, CURRENT_DATE + 30, CURRENT_DATE, 'finished', 'manual');
      RAISE EXCEPTION 'CF21h3 cycle with ends_on < starts_on was allowed';
    EXCEPTION WHEN check_violation THEN
      NULL;
    END;
    -- a closed cycle does not conflict with the open one
    INSERT INTO data.commercial_agreement_cycles (
      tenant_id, agreement_id, cycle_no, starts_on, ends_on, status, origin
    ) VALUES (v_tenant, v_a, 4, CURRENT_DATE - 400, CURRENT_DATE - 300, 'finished', 'manual');
    DELETE FROM data.commercial_agreement_cycles WHERE agreement_id = v_a AND cycle_no = 4;

    -- 3. backfill: wipe cycle + pointer + billing_state, then re-derive -------------
    UPDATE data.commercial_agreements SET active_cycle_id = NULL WHERE id = v_a;
    DELETE FROM data.commercial_agreement_billing_state WHERE agreement_id = v_a;
    DELETE FROM data.commercial_agreement_cycles WHERE agreement_id = v_a;

    v_result := data.commercial_agreement_backfill_cycles();
    IF COALESCE((v_result->>'cycles_created')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21h3 backfill created no cycle: %', v_result;
    END IF;

    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_a;
    IF NOT FOUND
       OR v_cycle.cycle_no <> 1 OR v_cycle.origin <> 'initial' OR v_cycle.status <> 'active'
       OR v_cycle.starts_on IS DISTINCT FROM v_ver.starts_on
       OR v_cycle.ends_on IS DISTINCT FROM v_ver.ends_on THEN
      RAISE EXCEPTION 'CF21h3 backfilled cycle is wrong';
    END IF;
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_a;
    IF v_agreement.active_cycle_id IS DISTINCT FROM v_cycle.id THEN
      RAISE EXCEPTION 'CF21h3 backfill did not set active_cycle_id';
    END IF;
    SELECT next_billing_on INTO v_next
    FROM data.commercial_agreement_billing_state WHERE agreement_id = v_a;
    IF NOT FOUND OR v_next IS DISTINCT FROM v_ver.next_billing_on THEN
      RAISE EXCEPTION 'CF21h3 backfill did not copy next_billing_on (got %)', v_next;
    END IF;

    PERFORM data.commercial_agreement_backfill_cycles();   -- idempotent
    SELECT count(*) INTO v_n FROM data.commercial_agreement_cycles WHERE agreement_id = v_a;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'CF21h3 backfill is not idempotent (% cycles)', v_n;
    END IF;

    -- 3b. backfill maps agreement status -> cycle status ---------------------------
    v_b := pg_temp.cf21h3_agreement(
      CURRENT_DATE + 30, CURRENT_DATE + 395, false, 'none', NULL, NULL, true
    );
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_b;
    IF v_status IS DISTINCT FROM 'pending_start' THEN
      RAISE EXCEPTION 'CF21h3 future agreement expected pending_start, got %', v_status;
    END IF;
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_b;
    IF v_cycle.status <> 'pending' THEN
      RAISE EXCEPTION 'CF21h3 future agreement cycle expected pending, got %', v_cycle.status;
    END IF;
    UPDATE data.commercial_agreements SET active_cycle_id = NULL WHERE id = v_b;
    DELETE FROM data.commercial_agreement_cycles WHERE agreement_id = v_b;
    PERFORM data.commercial_agreement_backfill_cycles();
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_b;
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_b;
    IF v_cycle.id IS NULL OR v_cycle.status <> 'pending'
       OR v_agreement.active_cycle_id IS DISTINCT FROM v_cycle.id THEN
      RAISE EXCEPTION 'CF21h3 pending backfill wrong (% / pointer %)',
        v_cycle.status, v_agreement.active_cycle_id;
    END IF;

    v_d := pg_temp.cf21h3_agreement(
      CURRENT_DATE - 10, CURRENT_DATE + 355, false, 'none', NULL, NULL, true
    );
    UPDATE data.commercial_agreements SET status = 'finished' WHERE id = v_d;
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_d;
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_d;
    IF v_cycle.status <> 'finished' OR v_agreement.active_cycle_id IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h3 finishing the agreement must close the cycle and clear the pointer';
    END IF;
    DELETE FROM data.commercial_agreement_cycles WHERE agreement_id = v_d;
    PERFORM data.commercial_agreement_backfill_cycles();
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_d;
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_d;
    IF v_cycle.id IS NULL OR v_cycle.status <> 'finished' OR v_agreement.active_cycle_id IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h3 finished backfill wrong (% / pointer %)',
        v_cycle.status, v_agreement.active_cycle_id;
    END IF;

    -- 4. activate_due: pending cycle -> active ---------------------------------------
    v_result := api.activate_due_commercial_agreements(CURRENT_DATE + 30, 500);
    IF COALESCE((v_result->>'activated')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21h3 activate_due activated nothing: %', v_result;
    END IF;
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_b;
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_b;
    IF v_agreement.status <> 'active' OR v_cycle.status <> 'active'
       OR v_agreement.active_cycle_id IS DISTINCT FROM v_cycle.id THEN
      RAISE EXCEPTION 'CF21h3 activate_due: agreement % cycle %', v_agreement.status, v_cycle.status;
    END IF;

    -- 4b. activate_due without a cycle uses the version start and creates cycle 1 -----
    v_c := pg_temp.cf21h3_agreement(
      CURRENT_DATE + 5, CURRENT_DATE + 370, false, 'none', NULL, NULL, true
    );
    UPDATE data.commercial_agreements SET active_cycle_id = NULL WHERE id = v_c;
    DELETE FROM data.commercial_agreement_cycles WHERE agreement_id = v_c;

    v_result := api.activate_due_commercial_agreements(CURRENT_DATE + 4, 500);
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_c;
    IF v_status IS DISTINCT FROM 'pending_start' THEN
      RAISE EXCEPTION 'CF21h3 activate_due ran before the version start (%)', v_status;
    END IF;
    v_result := api.activate_due_commercial_agreements(CURRENT_DATE + 5, 500);
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_c;
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_c;
    IF v_agreement.status <> 'active' OR NOT FOUND OR v_cycle.status <> 'active'
       OR v_agreement.active_cycle_id IS DISTINCT FROM v_cycle.id THEN
      RAISE EXCEPTION 'CF21h3 activate_due without cycle: agreement %', v_agreement.status;
    END IF;
    SELECT * INTO v_event
    FROM data.commercial_agreement_events
    WHERE agreement_id = v_c AND event_type = 'activated' AND payload->>'source' = 'activate_due';
    IF NOT FOUND OR (v_event.payload->>'cycle_id') IS DISTINCT FROM v_cycle.id::text THEN
      RAISE EXCEPTION 'CF21h3 activated event lacks cycle_id';
    END IF;

    -- 5. renew: new cycle, version untouched -------------------------------------------
    v_e := pg_temp.cf21h3_agreement(
      CURRENT_DATE - 40, CURRENT_DATE - 1, true, 'none', NULL, NULL, true
    );
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_e;
    SELECT * INTO v_ver FROM data.commercial_agreement_versions WHERE id = v_agreement.active_version_id;
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_e;
    IF v_cycle.status <> 'active' OR v_cycle.ends_on IS DISTINCT FROM CURRENT_DATE - 1 THEN
      RAISE EXCEPTION 'CF21h3 renew fixture: cycle 1 wrong (% / %)', v_cycle.status, v_cycle.ends_on;
    END IF;

    v_f := pg_temp.cf21h3_agreement(
      CURRENT_DATE - 5, CURRENT_DATE - 1, false, 'none', NULL, NULL, true
    );

    -- 6g. safety net: active signed agreement without cycle gets one from expire ------
    v_g := pg_temp.cf21h3_agreement(
      CURRENT_DATE - 10, CURRENT_DATE + 355, false, 'none', NULL, NULL, true
    );
    UPDATE data.commercial_agreements SET active_cycle_id = NULL WHERE id = v_g;
    DELETE FROM data.commercial_agreement_cycles WHERE agreement_id = v_g;

    v_result := api.expire_or_renew_commercial_agreements(CURRENT_DATE, 500);
    IF COALESCE((v_result->>'renewed')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21h3 expire did not renew: %', v_result;
    END IF;
    IF COALESCE((v_result->>'finished')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21h3 expire did not finish the non-renewing agreement: %', v_result;
    END IF;

    -- renewed agreement
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_e;
    IF v_agreement.status <> 'active' THEN
      RAISE EXCEPTION 'CF21h3 renewed agreement should stay active, got %', v_agreement.status;
    END IF;
    SELECT count(*) INTO v_n FROM data.commercial_agreement_cycles WHERE agreement_id = v_e;
    IF v_n <> 2 THEN
      RAISE EXCEPTION 'CF21h3 renew expected 2 cycles, got %', v_n;
    END IF;
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles
    WHERE agreement_id = v_e AND cycle_no = 1;
    SELECT * INTO v_cycle2 FROM data.commercial_agreement_cycles
    WHERE agreement_id = v_e AND cycle_no = 2;
    IF v_cycle.status <> 'finished' THEN
      RAISE EXCEPTION 'CF21h3 old cycle should be finished, got %', v_cycle.status;
    END IF;
    IF v_cycle2.status <> 'active' OR v_cycle2.origin <> 'renewal'
       OR v_cycle2.starts_on IS DISTINCT FROM CURRENT_DATE
       OR v_cycle2.ends_on IS DISTINCT FROM CURRENT_DATE + 39 THEN
      RAISE EXCEPTION 'CF21h3 new cycle wrong: % % % %',
        v_cycle2.status, v_cycle2.origin, v_cycle2.starts_on, v_cycle2.ends_on;
    END IF;
    IF v_agreement.active_cycle_id IS DISTINCT FROM v_cycle2.id THEN
      RAISE EXCEPTION 'CF21h3 active_cycle_id not moved to the new cycle';
    END IF;

    -- the signed version is untouched
    IF (SELECT starts_on FROM data.commercial_agreement_versions WHERE id = v_ver.id)
         IS DISTINCT FROM v_ver.starts_on
       OR (SELECT ends_on FROM data.commercial_agreement_versions WHERE id = v_ver.id)
         IS DISTINCT FROM v_ver.ends_on THEN
      RAISE EXCEPTION 'CF21h3 renew mutated the signed version dates';
    END IF;
    IF (SELECT status FROM data.commercial_agreement_versions WHERE id = v_ver.id) <> 'signed' THEN
      RAISE EXCEPTION 'CF21h3 version no longer signed';
    END IF;

    -- renewed event payload
    SELECT * INTO v_event
    FROM data.commercial_agreement_events
    WHERE agreement_id = v_e AND event_type = 'renewed';
    IF NOT FOUND
       OR (v_event.payload->>'old_cycle_id') IS DISTINCT FROM v_cycle.id::text
       OR (v_event.payload->>'new_cycle_id') IS DISTINCT FROM v_cycle2.id::text THEN
      RAISE EXCEPTION 'CF21h3 renewed event payload wrong: %', v_event.payload;
    END IF;

    -- second run: nothing else to renew for this agreement
    PERFORM api.expire_or_renew_commercial_agreements(CURRENT_DATE, 500);
    SELECT count(*) INTO v_n FROM data.commercial_agreement_cycles WHERE agreement_id = v_e;
    IF v_n <> 2 THEN
      RAISE EXCEPTION 'CF21h3 second expire run changed cycles (% cycles)', v_n;
    END IF;

    -- non-renewing agreement: finished, cycle closed, pointer cleared
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_f;
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_f;
    IF v_agreement.status <> 'finished' OR v_cycle.status <> 'finished'
       OR v_agreement.active_cycle_id IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h3 expired agreement: % cycle % pointer %',
        v_agreement.status, v_cycle.status, v_agreement.active_cycle_id;
    END IF;

    -- safety net result
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_g;
    SELECT * INTO v_cycle FROM data.commercial_agreement_cycles WHERE agreement_id = v_g;
    IF NOT FOUND OR v_cycle.status <> 'active'
       OR v_agreement.active_cycle_id IS DISTINCT FROM v_cycle.id THEN
      RAISE EXCEPTION 'CF21h3 expire did not create the missing cycle';
    END IF;

    -- 7. contractual dates are immutable, even with the legacy renew GUC ---------------
    PERFORM set_config('app.commercial_agreement_renew_unlocked', 'on', true);
    BEGIN
      UPDATE data.commercial_agreement_versions
      SET ends_on = ends_on + 30
      WHERE id = v_ver.id;
      RAISE EXCEPTION 'CF21h3 version ends_on mutation was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_version_immutable%' THEN
        RAISE;
      END IF;
    END;
    BEGIN
      UPDATE data.commercial_agreement_versions
      SET starts_on = starts_on + 1
      WHERE id = v_ver.id;
      RAISE EXCEPTION 'CF21h3 version starts_on mutation was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_version_immutable%' THEN
        RAISE;
      END IF;
    END;
    PERFORM set_config('app.commercial_agreement_renew_unlocked', 'off', true);

    -- 8. RLS, grants, api views ---------------------------------------------------------
    IF NOT (SELECT relrowsecurity FROM pg_class
            WHERE oid = 'data.commercial_agreement_cycles'::regclass) THEN
      RAISE EXCEPTION 'CF21h3 RLS disabled on cycles';
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class
            WHERE oid = 'data.commercial_agreement_billing_state'::regclass) THEN
      RAISE EXCEPTION 'CF21h3 RLS disabled on billing_state';
    END IF;
    IF has_table_privilege('authenticated', 'data.commercial_agreement_cycles', 'INSERT')
       OR has_table_privilege('authenticated', 'data.commercial_agreement_cycles', 'UPDATE')
       OR has_table_privilege('authenticated', 'data.commercial_agreement_billing_state', 'UPDATE')
       OR has_table_privilege('anon', 'data.commercial_agreement_cycles', 'SELECT') THEN
      RAISE EXCEPTION 'CF21h3 clients have write/anon access to cycle tables';
    END IF;
    IF NOT has_table_privilege('authenticated', 'data.commercial_agreement_cycles', 'SELECT')
       OR NOT has_table_privilege('authenticated', 'api.commercial_agreement_cycles', 'SELECT')
       OR NOT has_table_privilege('authenticated', 'api.commercial_agreement_billing_state', 'SELECT') THEN
      RAISE EXCEPTION 'CF21h3 authenticated cannot read cycle views';
    END IF;
    IF has_function_privilege(
         'authenticated', 'data.commercial_agreement_backfill_cycles()', 'EXECUTE'
       ) THEN
      RAISE EXCEPTION 'CF21h3 authenticated can run the backfill';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'api' AND table_name = 'commercial_agreements'
        AND column_name = 'active_cycle_id'
    ) THEN
      RAISE EXCEPTION 'CF21h3 api.commercial_agreements does not expose active_cycle_id';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'api' AND table_name = 'commercial_agreement_billing_periods'
        AND column_name = 'cycle_id'
    ) THEN
      RAISE EXCEPTION 'CF21h3 api.commercial_agreement_billing_periods does not expose cycle_id';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'cycles tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: CF-21-h3 agreement cycles';
  END;
END;
$$;

-- Preflight documentation (committed data; read-only).
--
-- The h3 migration HARD-STOPS when a 'renewed' event exists: before h3 a renewal
-- overwrote versions.starts_on/ends_on, so the original contractual dates are lost and
-- cannot be backfilled automatically. Ops must reconcile (restore the signed dates) or,
-- on non-production data only, acknowledge with
--   PGOPTIONS="-c app.cf21h3_renewed_history_ack=on"
-- If this database exists, the migration was applied, so either there was no legacy
-- history or it was acknowledged. Renewals performed AFTER h3 must be fully traceable.
DO $$
DECLARE
  v_legacy int;
  v_modern int;
  v_untraceable int;
BEGIN
  SELECT count(*) INTO v_legacy
  FROM data.commercial_agreement_events e
  WHERE e.event_type = 'renewed' AND NOT (e.payload ? 'new_cycle_id');

  SELECT count(*) INTO v_modern
  FROM data.commercial_agreement_events e
  WHERE e.event_type = 'renewed' AND e.payload ? 'new_cycle_id';

  SELECT count(*) INTO v_untraceable
  FROM data.commercial_agreement_events e
  WHERE e.event_type = 'renewed'
    AND e.payload ? 'new_cycle_id'
    AND NOT EXISTS (
      SELECT 1
      FROM data.commercial_agreement_cycles c
      WHERE c.id = (e.payload->>'new_cycle_id')::uuid
        AND c.agreement_id = e.agreement_id
        AND c.cycle_no >= 2
        AND c.origin = 'renewal'
    );

  IF v_untraceable > 0 THEN
    RAISE EXCEPTION 'CF21h3 % renewed event(s) point to a missing renewal cycle', v_untraceable;
  END IF;

  IF v_legacy > 0 THEN
    RAISE NOTICE
      'CF-21-h3 preflight doc: % legacy renewed event(s) (pre-h3) exist; their historical dates must be reconciled by ops (migration hard-stops unless acknowledged).',
      v_legacy;
  END IF;
  RAISE NOTICE 'PASS: CF-21-h3 preflight documentation (legacy=%, traced=%)', v_legacy, v_modern;
END;
$$;
