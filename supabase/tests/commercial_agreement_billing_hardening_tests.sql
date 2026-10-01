-- CF-21-h4: billing generation hardening.
--   * function metadata: search_path = '', service_role only, single signature, comments,
--     (tenant_id, next_billing_on) partial index
--   * an already-existing exact period is reconciled WITHOUT consuming the quota
--   * catch-up generates > 1 period per agreement, capped by p_max_per_agreement
--   * a failing agreement is skipped: no period, pointer NOT advanced; retry succeeds
--   * renew realigns billing_state.next_billing_on (NULL / behind / ahead / out of range)
--     and never touches versions.next_billing_on
--   * next_billing_on of a signed version is fully immutable (billing_unlocked is dead)
-- Rolled back at the end (ZZ001) so the file is re-runnable.

-- Helper: framework agreement (+ optional finalize with a stub signed PDF).
CREATE OR REPLACE FUNCTION pg_temp.cf21h4_agreement(
  p_starts date,
  p_ends date,
  p_auto_renew boolean,
  p_cadence text DEFAULT 'monthly',
  p_amount int DEFAULT 12100,
  p_anchor int DEFAULT 1,
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
    VALUES (v_tenant, 'CF21h4 signed stub', 'commercial', '{}', v_owner)
    RETURNING id INTO v_doc;

    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature' WHERE id = v_version;
    PERFORM data.finalize_commercial_agreement_version(v_version, v_doc, v_owner, CURRENT_DATE);
  END IF;

  RETURN v_agreement;
END;
$$;

-- Helper: pointer of an agreement.
CREATE OR REPLACE FUNCTION pg_temp.cf21h4_pointer(p_agreement uuid)
RETURNS date
LANGUAGE sql
AS $$
  SELECT next_billing_on FROM data.commercial_agreement_billing_state WHERE agreement_id = p_agreement;
$$;

-- Helper: number of periods of an agreement.
CREATE OR REPLACE FUNCTION pg_temp.cf21h4_periods(p_agreement uuid)
RETURNS int
LANGUAGE sql
AS $$
  SELECT count(*)::int FROM data.commercial_agreement_billing_periods WHERE agreement_id = p_agreement;
$$;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_m date := date_trunc('month', CURRENT_DATE)::date;
  v_m1 date := (date_trunc('month', CURRENT_DATE)::date - INTERVAL '1 month')::date;
  v_m2 date := (date_trunc('month', CURRENT_DATE)::date - INTERVAL '2 months')::date;
  v_m5 date := (date_trunc('month', CURRENT_DATE)::date - INTERVAL '5 months')::date;
  v_mnext date := (date_trunc('month', CURRENT_DATE)::date + INTERVAL '1 month')::date;
  v_a uuid;   -- conflict does not consume quota
  v_b uuid;   -- catch-up
  v_c uuid;   -- catch-up capped
  v_d uuid;   -- forced failure
  v_e1 uuid;  -- renew: pointer NULL
  v_e2 uuid;  -- renew: pointer behind
  v_e3 uuid;  -- renew: pointer ahead (in range)
  v_e4 uuid;  -- renew: pointer out of range
  v_e5 uuid;  -- renew: no billing
  v_agreement data.commercial_agreements%ROWTYPE;
  v_ver data.commercial_agreement_versions%ROWTYPE;
  v_version uuid;
  v_cycle uuid;
  v_cycle2 uuid;
  v_result jsonb;
  v_n int;
  v_date date;
  v_event data.commercial_agreement_events%ROWTYPE;
  v_text text;
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

    -- 1. metadata -------------------------------------------------------------------
    IF to_regprocedure('api.generate_due_agreement_billing_periods(date,integer)') IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h4 the old 2-argument generator still exists';
    END IF;
    IF to_regprocedure('api.generate_due_agreement_billing_periods(date,integer,integer,integer)') IS NULL THEN
      RAISE EXCEPTION 'CF21h4 the 4-argument generator (h5 per-tenant cap) is missing';
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM pg_proc p, unnest(p.proconfig) AS cfg
      WHERE p.oid = 'api.generate_due_agreement_billing_periods(date,integer,integer,integer)'::regprocedure
        AND cfg = 'search_path=""'
    ) THEN
      RAISE EXCEPTION 'CF21h4 generator search_path is not empty';
    END IF;
    IF NOT (
      SELECT p.prosecdef FROM pg_proc p
      WHERE p.oid = 'api.generate_due_agreement_billing_periods(date,integer,integer,integer)'::regprocedure
    ) THEN
      RAISE EXCEPTION 'CF21h4 generator is not SECURITY DEFINER';
    END IF;
    IF has_function_privilege(
         'authenticated', 'api.generate_due_agreement_billing_periods(date,integer,integer,integer)', 'EXECUTE'
       )
       OR has_function_privilege(
         'anon', 'api.generate_due_agreement_billing_periods(date,integer,integer,integer)', 'EXECUTE'
       ) THEN
      RAISE EXCEPTION 'CF21h4 clients can execute the generator';
    END IF;
    IF NOT has_function_privilege(
         'service_role', 'api.generate_due_agreement_billing_periods(date,integer,integer,integer)', 'EXECUTE'
       ) THEN
      RAISE EXCEPTION 'CF21h4 service_role cannot execute the generator';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_indexes
      WHERE schemaname = 'data'
        AND tablename = 'commercial_agreement_billing_state'
        AND indexname = 'idx_cabs_tenant_next_billing'
        AND indexdef LIKE '%(tenant_id, next_billing_on)%'
        AND indexdef LIKE '%next_billing_on IS NOT NULL%'
    ) THEN
      RAISE EXCEPTION 'CF21h4 billing_state (tenant_id, next_billing_on) partial index missing';
    END IF;
    v_text := obj_description(
      'api.generate_due_agreement_billing_periods(date,integer,integer,integer)'::regprocedure, 'pg_proc'
    );
    IF v_text IS NULL OR v_text NOT LIKE '%remaining_due%' THEN
      RAISE EXCEPTION 'CF21h4 generator comment missing';
    END IF;
    v_text := obj_description('data.commercial_agreement_billing_periods'::regclass, 'pg_class');
    IF v_text IS NULL
       OR v_text NOT LIKE '%SENSE impostos%'
       OR v_text NOT LIKE '%ISO%'
       OR v_text NOT LIKE '%ADVAN%'
       OR v_text NOT LIKE '%prorrateig%'
       OR v_text NOT LIKE '%ERP%' THEN
      RAISE EXCEPTION 'CF21h4 billing_periods comment does not document the semantics (%)', v_text;
    END IF;

    -- 2. conflict does not consume the quota -------------------------------------------
    v_a := pg_temp.cf21h4_agreement(v_m2, CURRENT_DATE + 300, false);
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_a;
    IF pg_temp.cf21h4_pointer(v_a) IS DISTINCT FROM v_m2 THEN
      RAISE EXCEPTION 'CF21h4 fixture: pointer expected %, got %', v_m2, pg_temp.cf21h4_pointer(v_a);
    END IF;

    -- the first window already exists (exact same agreement/start/end)
    INSERT INTO data.commercial_agreement_billing_periods (
      tenant_id, agreement_id, version_id, period_start, period_end, due_on,
      amount_cents, currency, status
    ) VALUES (
      v_tenant, v_a, v_agreement.active_version_id, v_m2, v_m1 - 1, v_m2,
      12100, 'EUR', 'due'
    );

    v_result := api.generate_due_agreement_billing_periods(CURRENT_DATE, 500, 1);
    IF NOT (v_result ? 'generated' AND v_result ? 'skipped'
            AND v_result ? 'remaining_due' AND v_result ? 'as_of') THEN
      RAISE EXCEPTION 'CF21h4 unexpected result shape: %', v_result;
    END IF;

    -- quota is 1: the existing window is reconciled for free, then ONE new period is made
    IF pg_temp.cf21h4_periods(v_a) <> 2 THEN
      RAISE EXCEPTION 'CF21h4 conflict consumed the quota: % periods', pg_temp.cf21h4_periods(v_a);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM data.commercial_agreement_billing_periods
      WHERE agreement_id = v_a AND period_start = v_m1 AND period_end = v_m - 1
    ) THEN
      RAISE EXCEPTION 'CF21h4 the next window was not generated after the conflict';
    END IF;
    IF pg_temp.cf21h4_pointer(v_a) IS DISTINCT FROM v_m THEN
      RAISE EXCEPTION 'CF21h4 pointer expected %, got %', v_m, pg_temp.cf21h4_pointer(v_a);
    END IF;
    SELECT count(*) INTO v_n
    FROM data.commercial_agreement_events
    WHERE agreement_id = v_a AND event_type = 'billing_period_generated';
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'CF21h4 expected 1 generated event (the reconciled one has none), got %', v_n;
    END IF;
    IF (SELECT cycle_id FROM data.commercial_agreement_billing_periods
        WHERE agreement_id = v_a AND period_start = v_m1)
         IS DISTINCT FROM v_agreement.active_cycle_id THEN
      RAISE EXCEPTION 'CF21h4 generated period does not carry active_cycle_id';
    END IF;

    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE, 500);
    IF pg_temp.cf21h4_periods(v_a) <> 3 OR pg_temp.cf21h4_pointer(v_a) IS DISTINCT FROM v_mnext THEN
      RAISE EXCEPTION 'CF21h4 second pass: % periods, pointer %',
        pg_temp.cf21h4_periods(v_a), pg_temp.cf21h4_pointer(v_a);
    END IF;
    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE, 500);
    IF pg_temp.cf21h4_periods(v_a) <> 3 THEN
      RAISE EXCEPTION 'CF21h4 generator is not idempotent (% periods)', pg_temp.cf21h4_periods(v_a);
    END IF;

    -- 3. catch-up -----------------------------------------------------------------------
    v_b := pg_temp.cf21h4_agreement(v_m2, CURRENT_DATE + 300, false);
    v_result := api.generate_due_agreement_billing_periods(CURRENT_DATE, 500);
    IF pg_temp.cf21h4_periods(v_b) <> 3 THEN
      RAISE EXCEPTION 'CF21h4 catch-up expected 3 periods, got %', pg_temp.cf21h4_periods(v_b);
    END IF;
    IF pg_temp.cf21h4_pointer(v_b) IS DISTINCT FROM v_mnext THEN
      RAISE EXCEPTION 'CF21h4 catch-up pointer expected %, got %', v_mnext, pg_temp.cf21h4_pointer(v_b);
    END IF;
    SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_b;
    IF EXISTS (
      SELECT 1 FROM data.commercial_agreement_billing_periods
      WHERE agreement_id = v_b AND cycle_id IS DISTINCT FROM v_agreement.active_cycle_id
    ) THEN
      RAISE EXCEPTION 'CF21h4 catch-up periods must carry cycle_id = active_cycle_id';
    END IF;
    IF (SELECT count(DISTINCT period_start) FROM data.commercial_agreement_billing_periods
        WHERE agreement_id = v_b) <> 3 THEN
      RAISE EXCEPTION 'CF21h4 catch-up periods overlap or repeat';
    END IF;

    -- cap: 6 windows due, default quota 3 per pass
    v_c := pg_temp.cf21h4_agreement(v_m5, CURRENT_DATE + 300, false);
    v_result := api.generate_due_agreement_billing_periods(CURRENT_DATE, 500);
    IF pg_temp.cf21h4_periods(v_c) <> 3 THEN
      RAISE EXCEPTION 'CF21h4 cap expected 3 periods in the first pass, got %', pg_temp.cf21h4_periods(v_c);
    END IF;
    IF pg_temp.cf21h4_pointer(v_c) IS DISTINCT FROM (v_m5 + INTERVAL '3 months')::date THEN
      RAISE EXCEPTION 'CF21h4 cap pointer wrong: %', pg_temp.cf21h4_pointer(v_c);
    END IF;
    IF COALESCE((v_result->>'remaining_due')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21h4 remaining_due should report the capped agreement: %', v_result;
    END IF;
    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE, 500);
    IF pg_temp.cf21h4_periods(v_c) <> 6 OR pg_temp.cf21h4_pointer(v_c) IS DISTINCT FROM v_mnext THEN
      RAISE EXCEPTION 'CF21h4 cap second pass: % periods, pointer %',
        pg_temp.cf21h4_periods(v_c), pg_temp.cf21h4_pointer(v_c);
    END IF;

    -- 4. a failing agreement does not advance and does not lose periods ----------------
    v_d := pg_temp.cf21h4_agreement(v_m1, CURRENT_DATE + 300, false);
    -- Fault injection (DDL is transactional: rolled back with the ZZ001 at the end).
    EXECUTE $ddl$
      CREATE FUNCTION data.cf21h4_fail_period()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $f$
      BEGIN
        IF NEW.agreement_id::text = current_setting('app.cf21h4_fail_agreement', true) THEN
          RAISE EXCEPTION 'cf21h4 forced failure';
        END IF;
        RETURN NEW;
      END;
      $f$
    $ddl$;
    EXECUTE 'CREATE TRIGGER trg_cf21h4_fail BEFORE INSERT ON data.commercial_agreement_billing_periods '
         || 'FOR EACH ROW EXECUTE FUNCTION data.cf21h4_fail_period()';
    PERFORM set_config('app.cf21h4_fail_agreement', v_d::text, true);

    v_result := api.generate_due_agreement_billing_periods(CURRENT_DATE, 500);
    IF COALESCE((v_result->>'skipped')::int, 0) < 1 THEN
      RAISE EXCEPTION 'CF21h4 failing agreement was not counted as skipped: %', v_result;
    END IF;
    IF pg_temp.cf21h4_periods(v_d) <> 0 OR pg_temp.cf21h4_pointer(v_d) IS DISTINCT FROM v_m1 THEN
      RAISE EXCEPTION 'CF21h4 failing agreement: % periods, pointer % (expected 0 / %)',
        pg_temp.cf21h4_periods(v_d), pg_temp.cf21h4_pointer(v_d), v_m1;
    END IF;
    IF EXISTS (
      SELECT 1 FROM data.commercial_agreement_events
      WHERE agreement_id = v_d AND event_type = 'billing_period_generated'
    ) THEN
      RAISE EXCEPTION 'CF21h4 failing agreement left a generated event behind';
    END IF;

    PERFORM set_config('app.cf21h4_fail_agreement', '', true);
    EXECUTE 'DROP TRIGGER trg_cf21h4_fail ON data.commercial_agreement_billing_periods';
    EXECUTE 'DROP FUNCTION data.cf21h4_fail_period()';

    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE, 500);
    IF pg_temp.cf21h4_periods(v_d) <> 2 OR pg_temp.cf21h4_pointer(v_d) IS DISTINCT FROM v_mnext THEN
      RAISE EXCEPTION 'CF21h4 retry after failure: % periods, pointer %',
        pg_temp.cf21h4_periods(v_d), pg_temp.cf21h4_pointer(v_d);
    END IF;

    -- 5. renew realigns billing_state ---------------------------------------------------
    -- e1: generate first -> every old-cycle window done -> pointer NULL (beyond cycle end)
    v_e1 := pg_temp.cf21h4_agreement(CURRENT_DATE - 40, CURRENT_DATE - 1, true, 'monthly', 12100, NULL);
    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE, 500, 12);
    IF pg_temp.cf21h4_periods(v_e1) < 2 THEN
      RAISE EXCEPTION 'CF21h4 e1 expected >= 2 periods before renewal, got %', pg_temp.cf21h4_periods(v_e1);
    END IF;
    IF pg_temp.cf21h4_pointer(v_e1) IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h4 e1 pointer should be NULL past the cycle end, got %', pg_temp.cf21h4_pointer(v_e1);
    END IF;
    SELECT active_version_id, active_cycle_id INTO v_version, v_cycle
    FROM data.commercial_agreements WHERE id = v_e1;
    SELECT * INTO v_ver FROM data.commercial_agreement_versions WHERE id = v_version;

    -- e2: pointer behind the new cycle; e3: ahead (in range); e4: out of range
    v_e2 := pg_temp.cf21h4_agreement(CURRENT_DATE - 40, CURRENT_DATE - 1, true, 'monthly', 12100, NULL);
    v_e3 := pg_temp.cf21h4_agreement(CURRENT_DATE - 40, CURRENT_DATE - 1, true, 'monthly', 12100, NULL);
    v_e4 := pg_temp.cf21h4_agreement(CURRENT_DATE - 40, CURRENT_DATE - 1, true, 'monthly', 12100, NULL);
    v_e5 := pg_temp.cf21h4_agreement(CURRENT_DATE - 40, CURRENT_DATE - 1, true, 'none', NULL, NULL);
    UPDATE data.commercial_agreement_billing_state
    SET next_billing_on = CURRENT_DATE + 5 WHERE agreement_id = v_e3;
    UPDATE data.commercial_agreement_billing_state
    SET next_billing_on = CURRENT_DATE + 100 WHERE agreement_id = v_e4;

    IF EXISTS (SELECT 1 FROM data.commercial_agreement_billing_state WHERE agreement_id = v_e5) THEN
      RAISE EXCEPTION 'CF21h4 e5 (cadence none) must not have a billing_state row';
    END IF;

    v_result := api.expire_or_renew_commercial_agreements(CURRENT_DATE, 500);
    IF COALESCE((v_result->>'renewed')::int, 0) < 5 THEN
      RAISE EXCEPTION 'CF21h4 expected 5 renewals, got %', v_result;
    END IF;

    -- e1: NULL -> new cycle start
    IF pg_temp.cf21h4_pointer(v_e1) IS DISTINCT FROM CURRENT_DATE THEN
      RAISE EXCEPTION 'CF21h4 e1 pointer expected today, got %', pg_temp.cf21h4_pointer(v_e1);
    END IF;
    -- e2: behind -> GREATEST = new cycle start
    IF pg_temp.cf21h4_pointer(v_e2) IS DISTINCT FROM CURRENT_DATE THEN
      RAISE EXCEPTION 'CF21h4 e2 pointer expected today, got %', pg_temp.cf21h4_pointer(v_e2);
    END IF;
    -- e3: ahead but inside the new cycle -> kept
    IF pg_temp.cf21h4_pointer(v_e3) IS DISTINCT FROM CURRENT_DATE + 5 THEN
      RAISE EXCEPTION 'CF21h4 e3 pointer expected today+5, got %', pg_temp.cf21h4_pointer(v_e3);
    END IF;
    -- e4: beyond the new cycle end (today+39) -> new cycle start
    IF pg_temp.cf21h4_pointer(v_e4) IS DISTINCT FROM CURRENT_DATE THEN
      RAISE EXCEPTION 'CF21h4 e4 pointer expected today, got %', pg_temp.cf21h4_pointer(v_e4);
    END IF;
    -- e5: no billing -> still no row
    IF EXISTS (SELECT 1 FROM data.commercial_agreement_billing_state WHERE agreement_id = v_e5) THEN
      RAISE EXCEPTION 'CF21h4 renewal created a billing_state row for a no-billing agreement';
    END IF;

    -- the signed version is untouched (dates and its initial next_billing_on)
    IF EXISTS (
      SELECT 1 FROM data.commercial_agreement_versions v
      WHERE v.id = v_ver.id
        AND (v.starts_on IS DISTINCT FROM v_ver.starts_on
             OR v.ends_on IS DISTINCT FROM v_ver.ends_on
             OR v.next_billing_on IS DISTINCT FROM v_ver.next_billing_on)
    ) THEN
      RAISE EXCEPTION 'CF21h4 renewal mutated the signed version';
    END IF;

    SELECT * INTO v_event
    FROM data.commercial_agreement_events
    WHERE agreement_id = v_e1 AND event_type = 'renewed';
    SELECT active_cycle_id INTO v_cycle2 FROM data.commercial_agreements WHERE id = v_e1;
    IF NOT FOUND OR v_cycle2 IS NOT DISTINCT FROM v_cycle
       OR (v_event.payload->>'old_cycle_id') IS DISTINCT FROM v_cycle::text
       OR (v_event.payload->>'new_cycle_id') IS DISTINCT FROM v_cycle2::text
       OR (v_event.payload->>'next_billing_on') IS DISTINCT FROM CURRENT_DATE::text THEN
      RAISE EXCEPTION 'CF21h4 renewed event payload wrong: %', v_event.payload;
    END IF;

    -- the realigned pointer is honoured by the generator and labelled with the new cycle
    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE, 500);
    SELECT count(*) INTO v_n
    FROM data.commercial_agreement_billing_periods
    WHERE agreement_id = v_e1 AND period_start = CURRENT_DATE AND cycle_id = v_cycle2;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'CF21h4 e1 expected a period starting today in the new cycle, got %', v_n;
    END IF;
    v_date := pg_temp.cf21h4_pointer(v_e1);
    IF v_date IS NULL OR v_date <= CURRENT_DATE THEN
      RAISE EXCEPTION 'CF21h4 e1 pointer did not advance after generation: %', v_date;
    END IF;

    -- 6. next_billing_on of a signed version is fully immutable --------------------------
    PERFORM set_config('app.commercial_agreement_billing_unlocked', 'on', true);
    BEGIN
      UPDATE data.commercial_agreement_versions
      SET next_billing_on = COALESCE(next_billing_on, CURRENT_DATE) + 1
      WHERE id = v_ver.id;
      RAISE EXCEPTION 'CF21h4 signed version next_billing_on mutation was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_version_immutable%' THEN
        RAISE;
      END IF;
    END;
    PERFORM set_config('app.commercial_agreement_billing_unlocked', 'off', true);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'billing hardening tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: CF-21-h4 billing hardening';
  END;
END;
$$;
