-- CF-21-h5: fair, bounded, observable agreement jobs + notice digests.
--   * metadata: single signature per job, SECURITY DEFINER, search_path = '',
--     service_role only, SKIP LOCKED in every job body, indexes, digest table, cron
--   * activate_due: a noisy tenant (6 due) does not starve a quiet one (2 due) when the
--     global limit forces a choice (round-robin, oldest due first inside a tier)
--   * expire_or_renew: per-tenant cap
--   * billing: global limit fairness, per-tenant cap, remaining_due alias kept
--   * notify_expiring: enqueues into ONE digest per tenant/day, merges later items,
--     dedups (same day, same agreement), unique (tenant_id, digest_on)
--   * recipients: tenant setting wins (no cap, invalid/duplicate filtered), else owners/managers
--   * flush: sends pending digests (email_logs, idempotent key), late items roll to the
--     next day, failures are retryable and never reprocess lifecycle work
--   * SKIP LOCKED: a second session cannot be simulated inside one rolled-back transaction,
--     so the smoke checks the function bodies (pg_get_functiondef) and that a repeated
--     invocation is a no-op (idempotent claim + re-check)
-- Uses two seed tenants: 10000000-...-0003 (owner 20000000-...-0002) and
-- 10000000-...-0004 (owner 20000000-...-0008). Rolled back at the end (ZZ001).

CREATE OR REPLACE FUNCTION pg_temp.cf21h5_jwt(p_tenant uuid, p_user uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', p_user,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          p_tenant::text, json_build_object('global_role', 'owner', 'sites', json_build_object())
        ),
        'user_permissions', json_build_object(
          p_tenant::text, json_build_object('global_permissions', json_build_array('*'), 'sites', json_build_object())
        )
      )
    )::text,
    true
  );
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', p_tenant)::text,
    true
  );
END;
$$;

-- Framework agreement for a tenant, finalized with a stub signed PDF.
CREATE OR REPLACE FUNCTION pg_temp.cf21h5_agreement(
  p_tenant uuid,
  p_starts date,
  p_ends date,
  p_auto_renew boolean DEFAULT false,
  p_cadence text DEFAULT 'none',
  p_amount int DEFAULT NULL,
  p_anchor int DEFAULT NULL,
  p_notice int DEFAULT 15
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_owner uuid := CASE p_tenant
    WHEN '10000000-0000-0000-0000-000000000003'::uuid THEN '20000000-0000-0000-0000-000000000002'::uuid
    ELSE '20000000-0000-0000-0000-000000000008'::uuid
  END;
  v_client uuid := CASE p_tenant
    WHEN '10000000-0000-0000-0000-000000000003'::uuid THEN '80000000-0000-0000-0000-0000000005a1'::uuid
    ELSE '80000000-0000-0000-0000-0000000005a2'::uuid
  END;
  v_template uuid := '76100000-0000-0000-0000-000000000002';
  v_agreement uuid;
  v_version uuid;
  v_doc uuid;
BEGIN
  INSERT INTO data.contacts (id, tenant_id, kind, display_name, given_name, family_name, source)
  VALUES (v_client, p_tenant, 'company', 'CF21h5 Client <b>&Co', NULL, NULL, 'test')
  ON CONFLICT (id) DO NOTHING;

  PERFORM pg_temp.cf21h5_jwt(p_tenant, v_owner);

  v_agreement := api.create_framework_agreement(
    p_tenant_id => p_tenant,
    p_client_id => v_client,
    p_template_id => v_template,
    p_work_gate => 'none',
    p_client_op_id => gen_random_uuid(),
    p_starts_on => p_starts,
    p_ends_on => p_ends,
    p_notice_days => p_notice,
    p_locale => 'ca',
    p_auto_renew => p_auto_renew,
    p_billing_cadence => p_cadence,
    p_billing_amount_cents => p_amount,
    p_billing_currency => 'EUR',
    p_billing_anchor_day => p_anchor
  );

  SELECT active_version_id INTO v_version
  FROM data.commercial_agreements WHERE id = v_agreement;

  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (p_tenant, 'CF21h5 signed stub', 'commercial', '{}', v_owner)
  RETURNING id INTO v_doc;

  UPDATE data.commercial_agreement_versions
  SET status = 'pending_signature' WHERE id = v_version;
  PERFORM data.finalize_commercial_agreement_version(v_version, v_doc, v_owner, CURRENT_DATE);

  RETURN v_agreement;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.cf21h5_periods(p_agreements uuid[])
RETURNS int
LANGUAGE sql
AS $$
  SELECT count(*)::int
  FROM data.commercial_agreement_billing_periods
  WHERE agreement_id = ANY (p_agreements);
$$;

CREATE OR REPLACE FUNCTION pg_temp.cf21h5_shape_ok(p_result jsonb)
RETURNS boolean
LANGUAGE sql
AS $$
  SELECT p_result ? 'processed'
     AND p_result ? 'skipped'
     AND p_result ? 'remaining_estimated'
     AND p_result ? 'oldest_due_at'
     AND p_result ? 'tenant_count'
     AND p_result ? 'as_of'
     AND p_result ? 'truncated';
$$;

DO $$
DECLARE
  v_t3 uuid := '10000000-0000-0000-0000-000000000003';
  v_t4 uuid := '10000000-0000-0000-0000-000000000004';
  v_m date := date_trunc('month', CURRENT_DATE)::date;
  v_sig text;
  v_def text;
  v_idx text;
  v_a uuid[] := '{}';
  v_b uuid[] := '{}';
  v_all uuid[] := '{}';
  v_id uuid;
  v_result jsonb;
  v_n int;
  v_n2 int;
  v_cnt_events_before int;
  v_cron int;
  v_cmd text;
  v_digest data.commercial_agreement_notice_digests%ROWTYPE;
  v_digest2 data.commercial_agreement_notice_digests%ROWTYPE;
  v_emails text[];
  v_expected text[];
  v_item jsonb;
  v_log data.email_logs%ROWTYPE;
  v_key text;
  v_late uuid;
  i int;
BEGIN
  BEGIN
    -- Isolation: park every pre-existing open agreement so only this file's rows are due.
    UPDATE data.commercial_agreements
    SET status = 'suspended'
    WHERE status IN ('pending_start', 'active');

    -- 1. metadata -------------------------------------------------------------------
    FOREACH v_sig IN ARRAY ARRAY[
      'api.activate_due_commercial_agreements(date,integer,integer)',
      'api.expire_or_renew_commercial_agreements(date,integer,integer)',
      'api.generate_due_agreement_billing_periods(date,integer,integer,integer)',
      'api.notify_expiring_commercial_agreements(date,integer,integer)',
      'api.flush_commercial_agreement_notice_digests(date,integer,integer)'
    ] LOOP
      IF to_regprocedure(v_sig) IS NULL THEN
        RAISE EXCEPTION 'CF21h5 missing function %', v_sig;
      END IF;
      IF NOT (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = to_regprocedure(v_sig)) THEN
        RAISE EXCEPTION 'CF21h5 % is not SECURITY DEFINER', v_sig;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM pg_proc p, unnest(p.proconfig) AS cfg
        WHERE p.oid = to_regprocedure(v_sig) AND cfg = 'search_path=""'
      ) THEN
        RAISE EXCEPTION 'CF21h5 % search_path is not empty', v_sig;
      END IF;
      IF has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE')
         OR has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE') THEN
        RAISE EXCEPTION 'CF21h5 clients can execute %', v_sig;
      END IF;
      IF NOT has_function_privilege('service_role', to_regprocedure(v_sig), 'EXECUTE') THEN
        RAISE EXCEPTION 'CF21h5 service_role cannot execute %', v_sig;
      END IF;
      -- SKIP LOCKED smoke: every job claims its rows with it.
      v_def := pg_get_functiondef(to_regprocedure(v_sig));
      IF v_def NOT LIKE '%SKIP LOCKED%' THEN
        RAISE EXCEPTION 'CF21h5 % does not use SKIP LOCKED', v_sig;
      END IF;
      IF obj_description(to_regprocedure(v_sig), 'pg_proc') IS NULL THEN
        RAISE EXCEPTION 'CF21h5 % has no comment', v_sig;
      END IF;
    END LOOP;

    -- the old signatures are gone (a 2-argument cron call must resolve to ONE function)
    IF to_regprocedure('api.activate_due_commercial_agreements(date,integer)') IS NOT NULL
       OR to_regprocedure('api.expire_or_renew_commercial_agreements(date,integer)') IS NOT NULL
       OR to_regprocedure('api.notify_expiring_commercial_agreements(date,integer)') IS NOT NULL
       OR to_regprocedure('api.generate_due_agreement_billing_periods(date,integer)') IS NOT NULL
       OR to_regprocedure('api.generate_due_agreement_billing_periods(date,integer,integer)') IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h5 an old job signature still exists';
    END IF;

    FOREACH v_idx IN ARRAY ARRAY[
      'idx_cag_pending_start', 'idx_cacy_pending_starts',
      'idx_commercial_agreement_cycles_tenant_ends', 'idx_cabs_tenant_next_billing',
      'idx_cag_active_no_cycle', 'idx_cag_active_tenant', 'idx_cae_expiry_notice',
      'idx_cand_pending'
    ] LOOP
      IF NOT EXISTS (
        SELECT 1 FROM pg_indexes WHERE schemaname = 'data' AND indexname = v_idx
      ) THEN
        RAISE EXCEPTION 'CF21h5 index % missing', v_idx;
      END IF;
    END LOOP;

    IF to_regclass('data.commercial_agreement_notice_digests') IS NULL THEN
      RAISE EXCEPTION 'CF21h5 digest table missing';
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint c
      WHERE c.conrelid = 'data.commercial_agreement_notice_digests'::regclass
        AND c.contype = 'u'
        AND (
          SELECT array_agg(a.attname::text ORDER BY a.attname)
          FROM unnest(c.conkey) k(attnum)
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
        ) = ARRAY['digest_on', 'tenant_id']
    ) THEN
      RAISE EXCEPTION 'CF21h5 UNIQUE (tenant_id, digest_on) missing on the digest table';
    END IF;
    IF NOT (
      SELECT c.relrowsecurity FROM pg_class c
      WHERE c.oid = 'data.commercial_agreement_notice_digests'::regclass
    ) THEN
      RAISE EXCEPTION 'CF21h5 digest table has no RLS';
    END IF;
    IF has_table_privilege('authenticated', 'data.commercial_agreement_notice_digests', 'INSERT')
       OR has_table_privilege('anon', 'data.commercial_agreement_notice_digests', 'SELECT') THEN
      RAISE EXCEPTION 'CF21h5 digest table is writable/readable by the wrong roles';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM data.email_templates
      WHERE is_platform_default AND event_type = 'commercial.agreement_expiry_digest'
        AND is_active AND NOT is_draft
    ) THEN
      RAISE EXCEPTION 'CF21h5 digest email template missing';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
      EXECUTE $q$
        SELECT count(*)::int FROM cron.job
        WHERE jobname IN (
          'activate-due-commercial-agreements',
          'expire-or-renew-commercial-agreements',
          'generate-due-agreement-billing-periods',
          'notify-expiring-commercial-agreements',
          'flush-commercial-agreement-notice-digests'
        )
      $q$ INTO v_cron;
      IF v_cron <> 5 THEN
        RAISE EXCEPTION 'CF21h5 expected 5 cron jobs, got %', v_cron;
      END IF;
      EXECUTE $q$
        SELECT command FROM cron.job
        WHERE jobname = 'generate-due-agreement-billing-periods'
      $q$ INTO v_cmd;
      IF v_cmd NOT LIKE '%CURRENT_DATE, 500, 3, 50%' THEN
        RAISE EXCEPTION 'CF21h5 billing cron command not updated: %', v_cmd;
      END IF;
      EXECUTE $q$
        SELECT command FROM cron.job
        WHERE jobname = 'flush-commercial-agreement-notice-digests'
      $q$ INTO v_cmd;
      IF v_cmd NOT LIKE '%flush_commercial_agreement_notice_digests%' THEN
        RAISE EXCEPTION 'CF21h5 flush cron command wrong: %', v_cmd;
      END IF;
    ELSE
      RAISE NOTICE 'CF21h5: pg_cron not installed, cron assertions skipped';
    END IF;

    -- 2. activate_due fairness -------------------------------------------------------
    -- A (tenant 3) is noisy: 6 pending agreements with the OLDEST start dates.
    -- B (tenant 4) is quiet: 2 pending agreements that start later.
    FOR i IN 1..6 LOOP
      v_a := v_a || pg_temp.cf21h5_agreement(v_t3, CURRENT_DATE + i, CURRENT_DATE + i + 365);
    END LOOP;
    FOR i IN 7..8 LOOP
      v_b := v_b || pg_temp.cf21h5_agreement(v_t4, CURRENT_DATE + i, CURRENT_DATE + i + 365);
    END LOOP;
    v_all := v_a || v_b;

    IF (SELECT count(*) FROM data.commercial_agreements
        WHERE id = ANY (v_all) AND status = 'pending_start') <> 8 THEN
      RAISE EXCEPTION 'CF21h5 fixture: expected 8 pending_start agreements';
    END IF;

    -- limit 4: strict oldest-first would give A1..A4 and starve B.
    v_result := api.activate_due_commercial_agreements(CURRENT_DATE + 10, 4, 50);
    IF NOT pg_temp.cf21h5_shape_ok(v_result) THEN
      RAISE EXCEPTION 'CF21h5 activate result shape: %', v_result;
    END IF;
    IF (v_result->>'processed')::int <> 4 OR (v_result->>'activated')::int <> 4 THEN
      RAISE EXCEPTION 'CF21h5 activate expected 4 processed, got %', v_result;
    END IF;
    IF (v_result->>'tenant_count')::int <> 2 THEN
      RAISE EXCEPTION 'CF21h5 activate tenant_count expected 2, got %', v_result;
    END IF;
    IF (SELECT count(*) FROM data.commercial_agreements
        WHERE id = ANY (v_b) AND status = 'active') <> 2 THEN
      RAISE EXCEPTION 'CF21h5 the quiet tenant was starved: %', v_result;
    END IF;
    IF (SELECT count(*) FROM data.commercial_agreements
        WHERE id = ANY (v_a) AND status = 'active') <> 2 THEN
      RAISE EXCEPTION 'CF21h5 the noisy tenant should get 2 slots: %', v_result;
    END IF;
    -- oldest first inside the tenant: A1 and A2 went, A3 did not
    IF (SELECT status FROM data.commercial_agreements WHERE id = v_a[1]) <> 'active'
       OR (SELECT status FROM data.commercial_agreements WHERE id = v_a[2]) <> 'active'
       OR (SELECT status FROM data.commercial_agreements WHERE id = v_a[3]) <> 'pending_start' THEN
      RAISE EXCEPTION 'CF21h5 activation order inside the tenant is not oldest-first';
    END IF;
    IF (v_result->>'remaining_estimated')::int <> 4
       OR (v_result->>'truncated')::boolean IS NOT TRUE
       OR (v_result->>'oldest_due_at')::date IS DISTINCT FROM CURRENT_DATE + 3 THEN
      RAISE EXCEPTION 'CF21h5 activate backlog fields wrong: %', v_result;
    END IF;
    -- cycle follows the agreement
    IF EXISTS (
      SELECT 1 FROM data.commercial_agreement_cycles c
      JOIN data.commercial_agreements a ON a.active_cycle_id = c.id
      WHERE a.id = ANY (v_b) AND c.status <> 'active'
    ) THEN
      RAISE EXCEPTION 'CF21h5 activated agreements must have an active cycle';
    END IF;

    v_result := api.activate_due_commercial_agreements(CURRENT_DATE + 10, 4, 50);
    IF (v_result->>'processed')::int <> 4
       OR (v_result->>'remaining_estimated')::int <> 0
       OR (v_result->>'truncated')::boolean IS NOT FALSE
       OR jsonb_typeof(v_result->'oldest_due_at') <> 'null' THEN
      RAISE EXCEPTION 'CF21h5 second activate pass wrong: %', v_result;
    END IF;
    v_result := api.activate_due_commercial_agreements(CURRENT_DATE + 10, 4, 50);
    IF (v_result->>'processed')::int <> 0 OR (v_result->>'skipped')::int <> 0 THEN
      RAISE EXCEPTION 'CF21h5 activate is not a no-op when nothing is due: %', v_result;
    END IF;

    -- 3. expire_or_renew: per-tenant cap -------------------------------------------
    v_a := '{}';
    v_b := '{}';
    FOR i IN 0..4 LOOP
      v_a := v_a || pg_temp.cf21h5_agreement(
        v_t3, CURRENT_DATE - 60, CURRENT_DATE - 1 - i, false
      );
    END LOOP;
    v_b := v_b || pg_temp.cf21h5_agreement(v_t4, CURRENT_DATE - 60, CURRENT_DATE - 1, false);
    v_all := v_all || v_a || v_b;

    -- cap 2: A (5 expired) gets the 2 oldest, B (1 expired) gets its one
    v_result := api.expire_or_renew_commercial_agreements(CURRENT_DATE, 500, 2);
    IF NOT pg_temp.cf21h5_shape_ok(v_result)
       OR NOT (v_result ? 'finished' AND v_result ? 'renewed') THEN
      RAISE EXCEPTION 'CF21h5 expire result shape: %', v_result;
    END IF;
    IF (v_result->>'processed')::int <> 3 OR (v_result->>'finished')::int <> 3
       OR (v_result->>'renewed')::int <> 0 THEN
      RAISE EXCEPTION 'CF21h5 expire per-tenant cap: expected 3 finished, got %', v_result;
    END IF;
    IF (SELECT count(*) FROM data.commercial_agreements
        WHERE id = ANY (v_a) AND status = 'finished') <> 2
       OR (SELECT status FROM data.commercial_agreements WHERE id = v_a[5]) <> 'finished'
       OR (SELECT status FROM data.commercial_agreements WHERE id = v_a[4]) <> 'finished'
       OR (SELECT status FROM data.commercial_agreements WHERE id = v_b[1]) <> 'finished' THEN
      RAISE EXCEPTION 'CF21h5 expire did not honour the per-tenant cap / oldest first';
    END IF;
    IF (v_result->>'remaining_estimated')::int <> 3
       OR (v_result->>'truncated')::boolean IS NOT TRUE
       OR (v_result->>'oldest_due_at')::date IS DISTINCT FROM CURRENT_DATE - 3
       OR (v_result->>'tenant_count')::int <> 2 THEN
      RAISE EXCEPTION 'CF21h5 expire backlog fields wrong: %', v_result;
    END IF;

    v_result := api.expire_or_renew_commercial_agreements(CURRENT_DATE, 500);
    IF (v_result->>'processed')::int <> 3 OR (v_result->>'remaining_estimated')::int <> 0
       OR (v_result->>'truncated')::boolean IS NOT FALSE THEN
      RAISE EXCEPTION 'CF21h5 expire second pass wrong: %', v_result;
    END IF;

    -- 4. billing: global limit fairness + per-tenant cap -------------------------------
    v_a := '{}';
    v_b := '{}';
    FOR i IN 1..3 LOOP
      v_a := v_a || pg_temp.cf21h5_agreement(
        v_t3, v_m, CURRENT_DATE + 300, false, 'monthly', 12100, 1
      );
    END LOOP;
    v_b := v_b || pg_temp.cf21h5_agreement(
      v_t4, v_m, CURRENT_DATE + 300, false, 'monthly', 12100, 1
    );
    v_all := v_all || v_a || v_b;

    -- limit 2: tenant 3 sorts first, strict ordering would give A1, A2 and starve B
    v_result := api.generate_due_agreement_billing_periods(CURRENT_DATE, 2, 1, 50);
    IF NOT pg_temp.cf21h5_shape_ok(v_result) OR NOT (v_result ? 'generated' AND v_result ? 'remaining_due') THEN
      RAISE EXCEPTION 'CF21h5 billing result shape: %', v_result;
    END IF;
    IF (v_result->>'processed')::int <> 2 OR (v_result->>'generated')::int <> 2 THEN
      RAISE EXCEPTION 'CF21h5 billing limit 2: expected 2 processed, got %', v_result;
    END IF;
    IF pg_temp.cf21h5_periods(v_b) <> 1 OR pg_temp.cf21h5_periods(v_a) <> 1 THEN
      RAISE EXCEPTION 'CF21h5 billing fairness: A % periods, B % periods (expected 1 / 1)',
        pg_temp.cf21h5_periods(v_a), pg_temp.cf21h5_periods(v_b);
    END IF;
    IF (v_result->>'remaining_estimated')::int <> 2
       OR (v_result->>'remaining_due')::int <> 2
       OR (v_result->>'truncated')::boolean IS NOT TRUE
       OR (v_result->>'oldest_due_at')::date IS DISTINCT FROM v_m
       OR (v_result->>'tenant_count')::int <> 2 THEN
      RAISE EXCEPTION 'CF21h5 billing backlog fields wrong: %', v_result;
    END IF;

    -- per-tenant cap 1: only one more A agreement is handled
    v_result := api.generate_due_agreement_billing_periods(CURRENT_DATE, 500, 1, 1);
    IF (v_result->>'processed')::int <> 1 OR pg_temp.cf21h5_periods(v_a) <> 2
       OR (v_result->>'remaining_estimated')::int <> 1 THEN
      RAISE EXCEPTION 'CF21h5 billing per-tenant cap: % (A periods %)',
        v_result, pg_temp.cf21h5_periods(v_a);
    END IF;

    v_result := api.generate_due_agreement_billing_periods(CURRENT_DATE, 500, 3, 50);
    IF pg_temp.cf21h5_periods(v_a) <> 3 OR pg_temp.cf21h5_periods(v_b) <> 1
       OR (v_result->>'remaining_estimated')::int <> 0
       OR (v_result->>'truncated')::boolean IS NOT FALSE THEN
      RAISE EXCEPTION 'CF21h5 billing final pass wrong: % (A %, B %)',
        v_result, pg_temp.cf21h5_periods(v_a), pg_temp.cf21h5_periods(v_b);
    END IF;
    v_result := api.generate_due_agreement_billing_periods(CURRENT_DATE, 500, 3, 50);
    IF pg_temp.cf21h5_periods(v_a) <> 3 OR (v_result->>'generated')::int <> 0 THEN
      RAISE EXCEPTION 'CF21h5 billing is not idempotent: %', v_result;
    END IF;

    -- 5. recipients: tenant setting wins, no cap, invalid/duplicates filtered ----------
    UPDATE data.tenants
    SET settings = jsonb_set(
      COALESCE(settings, '{}'::jsonb),
      '{commercial}',
      COALESCE(settings -> 'commercial', '{}'::jsonb) || jsonb_build_object(
        'agreement_notice_emails',
        (SELECT jsonb_agg('o' || g || '@cf21h5.test') FROM generate_series(1, 12) g)
      ),
      true
    )
    WHERE id = v_t3;
    UPDATE data.tenants
    SET settings = jsonb_set(
      COALESCE(settings, '{}'::jsonb),
      '{commercial}',
      COALESCE(settings -> 'commercial', '{}'::jsonb) || jsonb_build_object(
        'agreement_notice_emails',
        jsonb_build_array('Ops4@cf21h5.test', 'ops4@cf21h5.test', 'not-an-email', '')
      ),
      true
    )
    WHERE id = v_t4;

    v_emails := data.commercial_agreement_notice_recipient_emails(v_t3);
    IF cardinality(v_emails) <> 12 THEN
      RAISE EXCEPTION 'CF21h5 recipients must not be capped: got %', cardinality(v_emails);
    END IF;
    v_emails := data.commercial_agreement_notice_recipient_emails(v_t4);
    IF v_emails IS DISTINCT FROM ARRAY['ops4@cf21h5.test'] THEN
      RAISE EXCEPTION 'CF21h5 recipient filtering wrong: %', v_emails;
    END IF;

    -- fallback: no setting -> active global owners/managers
    UPDATE data.tenants
    SET settings = settings #- '{commercial,agreement_notice_emails}'
    WHERE id = v_t4;
    SELECT ARRAY(
      SELECT DISTINCT lower(btrim(p.email))
      FROM data.tenant_members tm
      JOIN data.profiles p ON p.id = tm.user_id
      WHERE tm.tenant_id = v_t4
        AND tm.is_active = true
        AND tm.site_id IS NULL
        AND tm.role IN ('owner', 'manager')
        AND NULLIF(btrim(p.email), '') IS NOT NULL
        AND position('@' in p.email) > 0
      ORDER BY 1
    ) INTO v_expected;
    IF data.commercial_agreement_notice_recipient_emails(v_t4) IS DISTINCT FROM v_expected THEN
      RAISE EXCEPTION 'CF21h5 recipient fallback (owners/managers) wrong';
    END IF;
    UPDATE data.tenants
    SET settings = jsonb_set(
      COALESCE(settings, '{}'::jsonb),
      '{commercial}',
      COALESCE(settings -> 'commercial', '{}'::jsonb) || jsonb_build_object(
        'agreement_notice_emails', jsonb_build_array('ops4@cf21h5.test')
      ),
      true
    )
    WHERE id = v_t4;

    -- 6. notify -> one digest per tenant/day --------------------------------------------
    v_a := '{}';
    v_b := '{}';
    FOR i IN 0..2 LOOP
      v_a := v_a || pg_temp.cf21h5_agreement(
        v_t3, CURRENT_DATE - 10, CURRENT_DATE + 5 + i, false, 'none', NULL, NULL, 15
      );
    END LOOP;
    v_b := v_b || pg_temp.cf21h5_agreement(
      v_t4, CURRENT_DATE - 10, CURRENT_DATE + 6, false, 'none', NULL, NULL, 15
    );
    v_all := v_all || v_a || v_b;

    -- limit 2: round-robin gives A1 and B1 (not A1, A2)
    v_result := api.notify_expiring_commercial_agreements(CURRENT_DATE, 2, 50);
    IF NOT pg_temp.cf21h5_shape_ok(v_result)
       OR NOT (v_result ? 'notified' AND v_result ? 'digests_touched') THEN
      RAISE EXCEPTION 'CF21h5 notify result shape: %', v_result;
    END IF;
    IF (v_result->>'processed')::int <> 2 OR (v_result->>'notified')::int <> 2
       OR (v_result->>'digests_touched')::int <> 2 OR (v_result->>'tenant_count')::int <> 2 THEN
      RAISE EXCEPTION 'CF21h5 notify limit 2 wrong: %', v_result;
    END IF;
    IF (v_result->>'remaining_estimated')::int <> 2
       OR (v_result->>'truncated')::boolean IS NOT TRUE THEN
      RAISE EXCEPTION 'CF21h5 notify backlog fields wrong: %', v_result;
    END IF;

    SELECT * INTO v_digest FROM data.commercial_agreement_notice_digests
    WHERE tenant_id = v_t3 AND digest_on = CURRENT_DATE;
    SELECT * INTO v_digest2 FROM data.commercial_agreement_notice_digests
    WHERE tenant_id = v_t4 AND digest_on = CURRENT_DATE;
    -- Tenant 3 may already have seed agreements in the digest; require fairness:
    -- both tenants got a digest and quiet tenant (t4) has exactly one item from our set.
    IF v_digest.id IS NULL OR v_digest2.id IS NULL THEN
      RAISE EXCEPTION 'CF21h5 fairness in notify: missing digests % / %', v_digest.payload, v_digest2.payload;
    END IF;
    IF jsonb_array_length(v_digest2.payload -> 'items') <> 1 THEN
      RAISE EXCEPTION 'CF21h5 quiet tenant digest must have exactly 1 item: %', v_digest2.payload;
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(v_digest.payload -> 'agreement_ids') AS x(id)
      WHERE x.id::uuid = ANY (v_a)
    ) THEN
      RAISE EXCEPTION 'CF21h5 noisy tenant digest missing test agreement: %', v_digest.payload;
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(v_digest2.payload -> 'agreement_ids') AS x(id)
      WHERE x.id::uuid = ANY (v_b)
    ) THEN
      RAISE EXCEPTION 'CF21h5 quiet tenant digest missing test agreement: %', v_digest2.payload;
    END IF;
    IF v_digest.status <> 'pending' OR v_digest.sent_at IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h5 a fresh digest must be pending and unsent';
    END IF;
    -- Seed agreements on tenant 3 may already be in the digest; require our test id is present.
    IF NOT (v_digest.payload -> 'agreement_ids' ? v_a[1]::text) THEN
      RAISE EXCEPTION 'CF21h5 digest agreement_ids missing first test id: %', v_digest.payload;
    END IF;

    -- the rest of A merges into the SAME digest row
    v_result := api.notify_expiring_commercial_agreements(CURRENT_DATE, 500, 50);
    IF (v_result->>'processed')::int < 2 OR (v_result->>'truncated')::boolean IS NOT FALSE THEN
      RAISE EXCEPTION 'CF21h5 notify second pass wrong: %', v_result;
    END IF;
    SELECT count(*) INTO v_n
    FROM data.commercial_agreement_notice_digests
    WHERE tenant_id = v_t3 AND digest_on = CURRENT_DATE;
    SELECT * INTO v_digest FROM data.commercial_agreement_notice_digests
    WHERE tenant_id = v_t3 AND digest_on = CURRENT_DATE;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'CF21h5 digest dedup/merge: % rows, payload %', v_n, v_digest.payload;
    END IF;
    -- All three test agreements from v_a must end up in the merged digest (seed extras OK).
    IF (
      SELECT count(*) FROM unnest(v_a) a(id)
      WHERE v_digest.payload -> 'agreement_ids' ? a.id::text
    ) <> 3 THEN
      RAISE EXCEPTION 'CF21h5 digest merge missing test agreements: %', v_digest.payload;
    END IF;
    IF (
      SELECT count(*) FROM jsonb_array_elements_text(v_digest.payload -> 'agreement_ids') x
    ) <> (
      SELECT count(DISTINCT x) FROM jsonb_array_elements_text(v_digest.payload -> 'agreement_ids') x
    ) THEN
      RAISE EXCEPTION 'CF21h5 digest contains duplicated agreement ids: %', v_digest.payload;
    END IF;

    -- same day, repeated run: nothing new for our test agreements
    v_result := api.notify_expiring_commercial_agreements(CURRENT_DATE, 500, 50);
    IF (v_result->>'processed')::int <> 0 THEN
      RAISE EXCEPTION 'CF21h5 notify is not idempotent: %', v_result;
    END IF;
    SELECT count(*) INTO v_n
    FROM data.commercial_agreement_events
    WHERE agreement_id = ANY (v_a || v_b) AND event_type = 'expiry_notice_sent';
    IF v_n <> 4 THEN
      RAISE EXCEPTION 'CF21h5 expected 4 expiry_notice_sent events, got %', v_n;
    END IF;
    IF EXISTS (
      SELECT 1 FROM data.commercial_agreement_events
      WHERE agreement_id = ANY (v_a || v_b) AND event_type = 'expiry_notice_sent'
        AND (payload ->> 'delivery' IS DISTINCT FROM 'digest' OR payload ->> 'digest_id' IS NULL)
    ) THEN
      RAISE EXCEPTION 'CF21h5 notice events must reference the digest';
    END IF;

    -- enqueueing the very same item again does not change the digest
    v_item := v_digest.payload -> 'items' -> 0;
    PERFORM data.enqueue_commercial_agreement_notice_digest_item(v_t3, CURRENT_DATE, v_item);
    SELECT * INTO v_digest2 FROM data.commercial_agreement_notice_digests WHERE id = v_digest.id;
    IF v_digest2.payload IS DISTINCT FROM v_digest.payload THEN
      RAISE EXCEPTION 'CF21h5 re-enqueueing the same item changed the digest';
    END IF;

    -- UNIQUE (tenant_id, digest_on)
    BEGIN
      INSERT INTO data.commercial_agreement_notice_digests (tenant_id, digest_on)
      VALUES (v_t3, CURRENT_DATE);
      RAISE EXCEPTION 'CF21h5 a second digest for the same tenant/day was allowed';
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;

    -- 7. flush: sends pending digests, retryable --------------------------------------
    UPDATE data.system_settings
    SET settings = settings || jsonb_build_object('platform_default_domain', 'mail.cavalle.dev')
    WHERE module = 'email'
      AND COALESCE(settings ->> 'platform_default_domain', '') = '';

    SELECT count(*) INTO v_cnt_events_before
    FROM data.commercial_agreement_events WHERE agreement_id = ANY (v_all);

    v_result := api.flush_commercial_agreement_notice_digests(CURRENT_DATE, 100, 10);
    IF NOT pg_temp.cf21h5_shape_ok(v_result) OR NOT (v_result ? 'sent' AND v_result ? 'failed') THEN
      RAISE EXCEPTION 'CF21h5 flush result shape: %', v_result;
    END IF;
    IF (v_result->>'sent')::int < 2 THEN
      RAISE EXCEPTION 'CF21h5 flush expected >= 2 sent, got %', v_result;
    END IF;
    SELECT * INTO v_digest FROM data.commercial_agreement_notice_digests
    WHERE tenant_id = v_t3 AND digest_on = CURRENT_DATE;
    IF v_digest.status <> 'sent' OR v_digest.sent_at IS NULL OR v_digest.attempts <> 1
       OR v_digest.last_error IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h5 flushed digest wrong: status % attempts % error %',
        v_digest.status, v_digest.attempts, v_digest.last_error;
    END IF;
    IF (SELECT status FROM data.commercial_agreement_notice_digests
        WHERE tenant_id = v_t4 AND digest_on = CURRENT_DATE) <> 'sent' THEN
      RAISE EXCEPTION 'CF21h5 tenant 4 digest was not flushed';
    END IF;

    v_key := 'agr-digest-' || v_t3::text || '-' || CURRENT_DATE::text;
    SELECT * INTO v_log FROM data.email_logs
    WHERE tenant_id = v_t3 AND idempotency_key = v_key;
    IF v_log.id IS NULL OR cardinality(v_log.to_emails) <> 12
       OR (v_log.template_variables ->> 'agreements_count')::int < 3 THEN
      RAISE EXCEPTION 'CF21h5 digest e-mail wrong: recipients %, vars %',
        cardinality(v_log.to_emails), v_log.template_variables;
    END IF;
    -- client names are HTML-escaped in the list
    IF (v_log.template_variables ->> 'items_html') LIKE '%<b>%'
       OR (v_log.template_variables ->> 'items_html') NOT LIKE '%&lt;b&gt;&amp;Co%' THEN
      RAISE EXCEPTION 'CF21h5 items_html is not escaped: %', v_log.template_variables ->> 'items_html';
    END IF;

    -- flushing again sends nothing (one mail per tenant/day)
    v_result := api.flush_commercial_agreement_notice_digests(CURRENT_DATE, 100, 10);
    IF (v_result->>'sent')::int <> 0 OR (v_result->>'remaining_estimated')::int <> 0 THEN
      RAISE EXCEPTION 'CF21h5 second flush should be a no-op: %', v_result;
    END IF;
    SELECT count(*) INTO v_n FROM data.email_logs
    WHERE tenant_id = v_t3 AND idempotency_key = v_key;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'CF21h5 duplicate digest e-mail (% rows)', v_n;
    END IF;

    -- a late agreement for tenant 4: today's digest is already sent -> rolls to tomorrow
    v_late := pg_temp.cf21h5_agreement(
      v_t4, CURRENT_DATE - 10, CURRENT_DATE + 7, false, 'none', NULL, NULL, 15
    );
    v_all := v_all || v_late;
    v_result := api.notify_expiring_commercial_agreements(CURRENT_DATE, 500, 50);
    IF (v_result->>'processed')::int <> 1 THEN
      RAISE EXCEPTION 'CF21h5 late notice not enqueued: %', v_result;
    END IF;
    SELECT * INTO v_digest FROM data.commercial_agreement_notice_digests
    WHERE tenant_id = v_t4 AND digest_on = CURRENT_DATE;
    SELECT * INTO v_digest2 FROM data.commercial_agreement_notice_digests
    WHERE tenant_id = v_t4 AND digest_on = CURRENT_DATE + 1;
    IF v_digest.status <> 'sent' OR jsonb_array_length(v_digest.payload -> 'items') <> 1
       OR v_digest2.id IS NULL OR v_digest2.status <> 'pending'
       OR jsonb_array_length(v_digest2.payload -> 'items') <> 1 THEN
      RAISE EXCEPTION 'CF21h5 late item must roll to the next day (sent today %, tomorrow %)',
        v_digest.payload, v_digest2.payload;
    END IF;

    -- tomorrow's digest is not sent by today's flush
    v_result := api.flush_commercial_agreement_notice_digests(CURRENT_DATE, 100, 10);
    IF (v_result->>'sent')::int <> 0 THEN
      RAISE EXCEPTION 'CF21h5 a future digest was sent early: %', v_result;
    END IF;

    -- delivery failure: pending + attempts, lifecycle untouched, then failed, then requeue
    SELECT count(*) INTO v_cnt_events_before
    FROM data.commercial_agreement_events WHERE agreement_id = ANY (v_all);

    UPDATE data.email_templates SET is_active = false
    WHERE is_platform_default AND event_type = 'commercial.agreement_expiry_digest';

    v_result := api.flush_commercial_agreement_notice_digests(CURRENT_DATE + 1, 100, 2);
    IF (v_result->>'sent')::int <> 0 OR (v_result->>'skipped')::int < 1 THEN
      RAISE EXCEPTION 'CF21h5 failing flush wrong: %', v_result;
    END IF;
    SELECT * INTO v_digest2 FROM data.commercial_agreement_notice_digests
    WHERE tenant_id = v_t4 AND digest_on = CURRENT_DATE + 1;
    IF v_digest2.status <> 'pending' OR v_digest2.attempts <> 1
       OR v_digest2.last_error IS NULL OR v_digest2.last_error NOT LIKE 'sqlstate:%'
       OR v_digest2.sent_at IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h5 failed digest must stay pending (status %, attempts %, error %)',
        v_digest2.status, v_digest2.attempts, v_digest2.last_error;
    END IF;

    -- the lifecycle is not reprocessed by the delivery failure
    v_result := api.notify_expiring_commercial_agreements(CURRENT_DATE + 1, 500, 50);
    IF (v_result->>'processed')::int <> 0 THEN
      RAISE EXCEPTION 'CF21h5 notify reprocessed lifecycle work after a delivery failure: %', v_result;
    END IF;
    SELECT count(*) INTO v_n
    FROM data.commercial_agreement_events WHERE agreement_id = ANY (v_all);
    IF v_n <> v_cnt_events_before THEN
      RAISE EXCEPTION 'CF21h5 events changed after a delivery failure (% -> %)', v_cnt_events_before, v_n;
    END IF;

    v_result := api.flush_commercial_agreement_notice_digests(CURRENT_DATE + 1, 100, 2);
    SELECT * INTO v_digest2 FROM data.commercial_agreement_notice_digests
    WHERE tenant_id = v_t4 AND digest_on = CURRENT_DATE + 1;
    IF v_digest2.status <> 'failed' OR v_digest2.attempts <> 2 OR (v_result->>'failed')::int < 1 THEN
      RAISE EXCEPTION 'CF21h5 exhausted digest must be failed (status %, attempts %)',
        v_digest2.status, v_digest2.attempts;
    END IF;

    -- recover: template back, manual requeue, retry succeeds
    UPDATE data.email_templates SET is_active = true
    WHERE is_platform_default AND event_type = 'commercial.agreement_expiry_digest';
    UPDATE data.commercial_agreement_notice_digests
    SET status = 'pending' WHERE id = v_digest2.id;

    v_result := api.flush_commercial_agreement_notice_digests(CURRENT_DATE + 1, 100, 2);
    SELECT * INTO v_digest2 FROM data.commercial_agreement_notice_digests
    WHERE tenant_id = v_t4 AND digest_on = CURRENT_DATE + 1;
    IF v_digest2.status <> 'sent' OR v_digest2.sent_at IS NULL OR v_digest2.last_error IS NOT NULL
       OR (v_result->>'sent')::int < 1 THEN
      RAISE EXCEPTION 'CF21h5 retry after recovery failed (status %, error %)',
        v_digest2.status, v_digest2.last_error;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM data.email_logs
      WHERE tenant_id = v_t4
        AND idempotency_key = 'agr-digest-' || v_t4::text || '-' || (CURRENT_DATE + 1)::text
        AND to_emails = ARRAY['ops4@cf21h5.test']
    ) THEN
      RAISE EXCEPTION 'CF21h5 tenant 4 retry e-mail missing';
    END IF;

    -- 8. RLS: a tenant only sees its own digests through the api view -----------------
    PERFORM pg_temp.cf21h5_jwt(v_t3, '20000000-0000-0000-0000-000000000002');
    IF has_table_privilege('authenticated', 'api.commercial_agreement_notice_digests', 'SELECT') IS NOT TRUE THEN
      RAISE EXCEPTION 'CF21h5 api view is not readable by authenticated';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'fair jobs tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: CF-21-h5 fair jobs';
  END;
END;
$$;
