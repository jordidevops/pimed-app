-- CF-21-h7: cancel / suspend / resume RPCs + keyset pagination for the agreements UI.
-- Rolled back at the end (ZZ001) so the file is re-runnable.

-- Test helper (session-scoped): framework/prepared draft -> pending_signature -> signed + active.
CREATE OR REPLACE FUNCTION pg_temp.cf21h7_make_active(
  p_tenant uuid,
  p_agreement uuid,
  p_owner uuid
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_version uuid;
  v_rendered uuid;
  v_signed uuid;
BEGIN
  SELECT active_version_id INTO v_version
  FROM data.commercial_agreements WHERE id = p_agreement;

  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (p_tenant, 'CF21h7 rendered stub', 'commercial', '{}', p_owner)
  RETURNING id INTO v_rendered;
  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (p_tenant, 'CF21h7 signed stub', 'commercial', '{}', p_owner)
  RETURNING id INTO v_signed;

  UPDATE data.commercial_agreement_versions
  SET rendered_document_id = v_rendered,
      status = 'pending_signature'
  WHERE id = v_version;

  PERFORM data.finalize_commercial_agreement_version(
    v_version, v_signed, p_owner, CURRENT_DATE
  );
  RETURN v_version;
END;
$$;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_tpl_specific uuid := '76100000-0000-0000-0000-000000000001';
  v_tpl_recurring uuid := '76100000-0000-0000-0000-000000000002';
  v_client uuid;
  v_quote uuid;
  v_a uuid;          -- framework: suspend / resume / cancel
  v_b uuid;          -- recurring monthly billing: suspended jobs + cancel keeps periods
  v_c uuid;          -- draft framework (never active)
  v_d uuid;          -- active framework used for the permission checks
  v_ver_a uuid;
  v_ver_b uuid;
  v_cycle_a uuid;
  v_result uuid;
  v_retry uuid;
  v_status text;
  v_cycle_status text;
  v_count int;
  v_total int;
  v_payload jsonb;
  v_rendered uuid;
  v_signed uuid;
  v_periods_before int;
  v_op_a_suspend uuid := '93000000-0000-0000-0000-0000000000a1';
  v_op_a_suspend2 uuid := '93000000-0000-0000-0000-0000000000a2';
  v_op_a_resume uuid := '93000000-0000-0000-0000-0000000000a3';
  v_op_a_resume2 uuid := '93000000-0000-0000-0000-0000000000a4';
  v_op_a_cancel uuid := '93000000-0000-0000-0000-0000000000a5';
  v_op_a_cancel2 uuid := '93000000-0000-0000-0000-0000000000a6';
  v_op_b_suspend uuid := '93000000-0000-0000-0000-0000000000b1';
  v_op_b_resume uuid := '93000000-0000-0000-0000-0000000000b2';
  v_op_b_cancel uuid := '93000000-0000-0000-0000-0000000000b3';
  v_op_c_cancel uuid := '93000000-0000-0000-0000-0000000000c1';
  v_op_c_suspend uuid := '93000000-0000-0000-0000-0000000000c2';
  v_op_d_suspend uuid := '93000000-0000-0000-0000-0000000000d1';
  v_op_d_cancel uuid := '93000000-0000-0000-0000-0000000000d2';
  v_op_d_resume uuid := '93000000-0000-0000-0000-0000000000d3';
  v_cur_created timestamptz;
  v_cur_id uuid;
  v_prev_created timestamptz;
  v_prev_id uuid;
  v_seen uuid[] := ARRAY[]::uuid[];
  v_page_rows int;
  v_pages int;
  v_row record;
  v_due date;
  v_prev_due date;
  v_prev_pid uuid;
  v_seen_p uuid[] := ARRAY[]::uuid[];
  v_has_a boolean;
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

    SELECT client_id INTO v_client FROM data.projects WHERE id = v_project;

    -- Fixtures ---------------------------------------------------------------
    v_a := api.create_framework_agreement(
      v_tenant, v_client, v_tpl_specific, 'none',
      '93000000-0000-0000-0000-000000000f01'::uuid,
      CURRENT_DATE, CURRENT_DATE + 365, 30, 'ca'
    );
    v_ver_a := pg_temp.cf21h7_make_active(v_tenant, v_a, v_owner);

    v_c := api.create_framework_agreement(
      v_tenant, v_client, v_tpl_specific, 'none',
      '93000000-0000-0000-0000-000000000f02'::uuid,
      CURRENT_DATE, CURRENT_DATE + 365, 30, 'ca'
    );

    v_d := api.create_framework_agreement(
      v_tenant, v_client, v_tpl_specific, 'none',
      '93000000-0000-0000-0000-000000000f03'::uuid,
      CURRENT_DATE, CURRENT_DATE + 365, 30, 'ca'
    );
    PERFORM pg_temp.cf21h7_make_active(v_tenant, v_d, v_owner);

    v_quote := api.issue_commercial_document(
      v_project, 'quote', true,
      '93000000-0000-0000-0000-000000000e01'::uuid,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote, '{"method":"sql_test"}'::jsonb,
      '93000000-0000-0000-0000-000000000e02'::uuid
    );
    v_b := api.prepare_agreement_from_quote(
      v_quote, v_tpl_recurring, 'none',
      '93000000-0000-0000-0000-000000000e03'::uuid,
      'recurring', CURRENT_DATE, CURRENT_DATE + 400, 30, false,
      NULL, NULL, NULL,
      'monthly', 12100, 'EUR', 1
    );
    v_ver_b := pg_temp.cf21h7_make_active(v_tenant, v_b, v_owner);

    SELECT status, active_cycle_id INTO v_status, v_cycle_a
    FROM data.commercial_agreements WHERE id = v_a;
    IF v_status IS DISTINCT FROM 'active' OR v_cycle_a IS NULL THEN
      RAISE EXCEPTION 'CF21h7 fixture A not active with a cycle (status %, cycle %)', v_status, v_cycle_a;
    END IF;

    -- 1. suspend: active -> suspended, reason in the event, cycle stays open ---
    v_result := api.suspend_commercial_agreement(v_a, v_op_a_suspend, '  maintenance pause  ');
    IF v_result IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'CF21h7 suspend returned a different agreement';
    END IF;
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_a;
    IF v_status IS DISTINCT FROM 'suspended' THEN
      RAISE EXCEPTION 'CF21h7 suspend left status %', v_status;
    END IF;
    SELECT status INTO v_cycle_status FROM data.commercial_agreement_cycles WHERE id = v_cycle_a;
    IF v_cycle_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21h7 suspend changed the cycle to %', v_cycle_status;
    END IF;
    SELECT payload INTO v_payload
    FROM data.commercial_agreement_events
    WHERE tenant_id = v_tenant AND client_op_id = v_op_a_suspend AND event_type = 'suspended';
    IF v_payload IS NULL
       OR v_payload->>'reason' IS DISTINCT FROM 'maintenance pause'
       OR v_payload->>'previous_status' IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21h7 suspended event payload wrong: %', v_payload;
    END IF;

    -- 1b. replay (same op) and second op on an already suspended agreement: no new event
    v_retry := api.suspend_commercial_agreement(v_a, v_op_a_suspend, 'maintenance pause');
    IF v_retry IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'CF21h7 suspend replay returned a different agreement';
    END IF;
    v_retry := api.suspend_commercial_agreement(v_a, v_op_a_suspend2, 'again');
    IF v_retry IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'CF21h7 second suspend returned a different agreement';
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_events
    WHERE agreement_id = v_a AND event_type = 'suspended';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h7 suspend wrote % events', v_count;
    END IF;

    -- 1c. typed replay: a suspend op cannot be reused for resume / cancel
    BEGIN
      PERFORM api.resume_commercial_agreement(v_a, v_op_a_suspend);
      RAISE EXCEPTION 'CF21h7 suspend op was accepted by resume';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_conflict%' THEN
        RAISE;
      END IF;
    END;
    BEGIN
      PERFORM api.cancel_commercial_agreement(v_a, v_op_a_suspend, NULL);
      RAISE EXCEPTION 'CF21h7 suspend op was accepted by cancel';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_conflict%' THEN
        RAISE;
      END IF;
    END;

    -- 1d. suspend needs an active agreement (draft framework is pending_start)
    BEGIN
      PERFORM api.suspend_commercial_agreement(v_c, v_op_c_suspend, NULL);
      RAISE EXCEPTION 'CF21h7 suspend of a pending_start agreement was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_not_active%' THEN
        RAISE;
      END IF;
    END;

    -- 2. resume: suspended -> active -------------------------------------------
    v_result := api.resume_commercial_agreement(v_a, v_op_a_resume);
    IF v_result IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'CF21h7 resume returned a different agreement';
    END IF;
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_a;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21h7 resume left status %', v_status;
    END IF;
    SELECT payload INTO v_payload
    FROM data.commercial_agreement_events
    WHERE tenant_id = v_tenant AND client_op_id = v_op_a_resume AND event_type = 'resumed';
    IF v_payload IS NULL
       OR v_payload->>'status' IS DISTINCT FROM 'active'
       OR v_payload->>'previous_status' IS DISTINCT FROM 'suspended' THEN
      RAISE EXCEPTION 'CF21h7 resumed event payload wrong: %', v_payload;
    END IF;

    v_retry := api.resume_commercial_agreement(v_a, v_op_a_resume);
    IF v_retry IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'CF21h7 resume replay returned a different agreement';
    END IF;
    v_retry := api.resume_commercial_agreement(v_a, v_op_a_resume2);
    IF v_retry IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'CF21h7 resume of an active agreement was not a no-op';
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_events
    WHERE agreement_id = v_a AND event_type = 'resumed';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h7 resume wrote % events', v_count;
    END IF;

    -- 3. suspended agreements are skipped by the billing generator -------------
    SELECT count(*) INTO v_periods_before
    FROM data.commercial_agreement_billing_periods WHERE agreement_id = v_b;

    PERFORM api.suspend_commercial_agreement(v_b, v_op_b_suspend, 'billing hold');
    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE + 40, 500);
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_billing_periods WHERE agreement_id = v_b;
    IF v_count <> v_periods_before THEN
      RAISE EXCEPTION 'CF21h7 suspended agreement generated % new periods', v_count - v_periods_before;
    END IF;

    PERFORM api.resume_commercial_agreement(v_b, v_op_b_resume);
    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE, 500);
    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE + 40, 500);
    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE + 80, 500);
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_billing_periods WHERE agreement_id = v_b;
    IF v_count < 2 THEN
      RAISE EXCEPTION 'CF21h7 resumed agreement generated only % periods', v_count;
    END IF;

    -- 4. cancel: closes the cycle, keeps documents and periods ------------------
    SELECT count(*) INTO v_periods_before
    FROM data.commercial_agreement_billing_periods WHERE agreement_id = v_b;

    v_result := api.cancel_commercial_agreement(v_b, v_op_b_cancel, 'client left');
    IF v_result IS DISTINCT FROM v_b THEN
      RAISE EXCEPTION 'CF21h7 cancel returned a different agreement';
    END IF;
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_b;
    IF v_status IS DISTINCT FROM 'cancelled' THEN
      RAISE EXCEPTION 'CF21h7 cancel left status %', v_status;
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_billing_periods WHERE agreement_id = v_b;
    IF v_count <> v_periods_before THEN
      RAISE EXCEPTION 'CF21h7 cancel changed the billing periods (% -> %)', v_periods_before, v_count;
    END IF;
    SELECT rendered_document_id, signed_document_id INTO v_rendered, v_signed
    FROM data.commercial_agreement_versions WHERE id = v_ver_b;
    IF v_rendered IS NULL OR v_signed IS NULL THEN
      RAISE EXCEPTION 'CF21h7 cancel lost the rendered/signed document';
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_cycles
    WHERE agreement_id = v_b AND status IN ('pending', 'active');
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'CF21h7 cancel left % open cycles', v_count;
    END IF;
    IF (SELECT active_cycle_id FROM data.commercial_agreements WHERE id = v_b) IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h7 cancel left active_cycle_id set';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM data.commercial_agreement_cycles WHERE agreement_id = v_b AND status = 'cancelled'
    ) THEN
      RAISE EXCEPTION 'CF21h7 cancel did not mark the cycle cancelled';
    END IF;

    -- cancelled agreements are no longer billed
    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE + 200, 500);
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_billing_periods WHERE agreement_id = v_b;
    IF v_count <> v_periods_before THEN
      RAISE EXCEPTION 'CF21h7 cancelled agreement generated new periods';
    END IF;

    -- cancel A from suspended, with replay + extra op + wrong-state calls
    PERFORM api.suspend_commercial_agreement(v_a, '93000000-0000-0000-0000-0000000000a7'::uuid, NULL);
    v_result := api.cancel_commercial_agreement(v_a, v_op_a_cancel, 'contract ended');
    v_retry := api.cancel_commercial_agreement(v_a, v_op_a_cancel, 'contract ended');
    IF v_retry IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'CF21h7 cancel replay returned a different agreement';
    END IF;
    v_retry := api.cancel_commercial_agreement(v_a, v_op_a_cancel2, NULL);
    IF v_retry IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'CF21h7 second cancel returned a different agreement';
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_events
    WHERE agreement_id = v_a AND event_type = 'cancelled';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h7 cancel wrote % events', v_count;
    END IF;
    SELECT payload INTO v_payload
    FROM data.commercial_agreement_events
    WHERE agreement_id = v_a AND event_type = 'cancelled';
    IF v_payload->>'reason' IS DISTINCT FROM 'contract ended'
       OR v_payload->>'previous_status' IS DISTINCT FROM 'suspended' THEN
      RAISE EXCEPTION 'CF21h7 cancelled event payload wrong: %', v_payload;
    END IF;

    BEGIN
      PERFORM api.resume_commercial_agreement(v_a, '93000000-0000-0000-0000-0000000000a8'::uuid);
      RAISE EXCEPTION 'CF21h7 resume of a cancelled agreement was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_not_suspended%' THEN
        RAISE;
      END IF;
    END;
    BEGIN
      PERFORM api.suspend_commercial_agreement(v_a, '93000000-0000-0000-0000-0000000000a9'::uuid, NULL);
      RAISE EXCEPTION 'CF21h7 suspend of a cancelled agreement was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_not_active%' THEN
        RAISE;
      END IF;
    END;

    -- cancel a never-activated draft
    PERFORM api.cancel_commercial_agreement(v_c, v_op_c_cancel, NULL);
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_c;
    IF v_status IS DISTINCT FROM 'cancelled' THEN
      RAISE EXCEPTION 'CF21h7 draft cancel left status %', v_status;
    END IF;

    -- client_op_id is mandatory
    BEGIN
      PERFORM api.cancel_commercial_agreement(v_d, NULL, NULL);
      RAISE EXCEPTION 'CF21h7 cancel without client_op_id was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_id_required%' THEN
        RAISE;
      END IF;
    END;

    -- 5. pagination: keyset on (created_at DESC, id DESC) -------------------------
    -- All rows created in this transaction share created_at, so this also covers the
    -- id tie-break.
    SELECT count(*) INTO v_total FROM data.commercial_agreements WHERE tenant_id = v_tenant;
    IF v_total < 4 THEN
      RAISE EXCEPTION 'CF21h7 expected at least 4 agreements, got %', v_total;
    END IF;

    v_cur_created := NULL;
    v_cur_id := NULL;
    v_pages := 0;
    LOOP
      v_page_rows := 0;
      FOR v_row IN
        SELECT * FROM api.list_commercial_agreements_page(2, v_cur_created, v_cur_id, NULL, NULL)
      LOOP
        v_page_rows := v_page_rows + 1;
        IF v_row.id = ANY (v_seen) THEN
          RAISE EXCEPTION 'CF21h7 pagination repeated agreement %', v_row.id;
        END IF;
        IF v_prev_created IS NOT NULL
           AND NOT ((v_row.created_at, v_row.id) < (v_prev_created, v_prev_id)) THEN
          RAISE EXCEPTION 'CF21h7 pagination order is not (created_at, id) DESC';
        END IF;
        v_seen := v_seen || v_row.id;
        v_prev_created := v_row.created_at;
        v_prev_id := v_row.id;
        v_cur_created := v_row.created_at;
        v_cur_id := v_row.id;
      END LOOP;
      v_pages := v_pages + 1;
      EXIT WHEN v_page_rows < 2;
      IF v_pages > v_total + 2 THEN
        RAISE EXCEPTION 'CF21h7 pagination did not terminate';
      END IF;
    END LOOP;
    IF cardinality(v_seen) <> v_total THEN
      RAISE EXCEPTION 'CF21h7 pagination returned % of % agreements', cardinality(v_seen), v_total;
    END IF;

    -- limit is clamped to [1, 200]
    SELECT count(*) INTO v_count FROM api.list_commercial_agreements_page(0, NULL, NULL, NULL, NULL);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h7 limit 0 should clamp to 1, got %', v_count;
    END IF;

    -- columns: billing rule, cycle, billing_state
    SELECT * INTO v_row FROM api.list_commercial_agreements_page(200, NULL, NULL, NULL, NULL) p
    WHERE p.active_version_id = v_ver_b;
    IF v_row.id IS DISTINCT FROM v_b
       OR v_row.billing_cadence IS DISTINCT FROM 'monthly'
       OR v_row.billing_amount_cents IS DISTINCT FROM 12100
       OR v_row.billing_currency IS DISTINCT FROM 'EUR'
       OR v_row.next_billing_on IS NULL
       OR v_row.status IS DISTINCT FROM 'cancelled'
       OR v_row.version_status IS DISTINCT FROM 'signed' THEN
      RAISE EXCEPTION 'CF21h7 list columns wrong for the billing agreement: %', to_jsonb(v_row);
    END IF;

    SELECT * INTO v_row FROM api.list_commercial_agreements_page(200, NULL, NULL, NULL, NULL) p
    WHERE p.id = v_d;
    IF v_row.cycle_id IS NULL
       OR v_row.cycle_status IS DISTINCT FROM 'active'
       OR v_row.cycle_starts_on IS NULL
       OR v_row.cycle_ends_on IS NULL
       OR v_row.ends_on IS NULL THEN
      RAISE EXCEPTION 'CF21h7 list cycle columns wrong for the active agreement: %', to_jsonb(v_row);
    END IF;

    -- filters
    SELECT count(*) INTO v_count
    FROM api.list_commercial_agreements_page(200, NULL, NULL, 'signed', NULL) p
    WHERE p.version_status IS DISTINCT FROM 'signed';
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'CF21h7 signature filter signed returned other rows';
    END IF;
    SELECT count(*) INTO v_count
    FROM api.list_commercial_agreements_page(200, NULL, NULL, 'draft', NULL) p
    WHERE p.id = v_c;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h7 signature filter draft missed the draft agreement';
    END IF;
    SELECT count(*) INTO v_count
    FROM api.list_commercial_agreements_page(200, NULL, NULL, 'pending', NULL) p
    WHERE p.version_status IS DISTINCT FROM 'pending_signature';
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'CF21h7 signature filter pending returned other rows';
    END IF;

    SELECT count(*) INTO v_count
    FROM api.list_commercial_agreements_page(200, NULL, NULL, NULL, 'active') p
    WHERE p.status IS DISTINCT FROM 'active';
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'CF21h7 validity filter active returned other rows';
    END IF;
    SELECT count(*) INTO v_count
    FROM api.list_commercial_agreements_page(200, NULL, NULL, NULL, 'active') p
    WHERE p.id = v_d;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h7 validity filter active missed the active agreement';
    END IF;
    SELECT count(*) INTO v_count
    FROM api.list_commercial_agreements_page(200, NULL, NULL, NULL, 'finished') p
    WHERE p.id IN (v_a, v_b, v_c);
    IF v_count <> 3 THEN
      RAISE EXCEPTION 'CF21h7 validity filter finished returned % of 3 cancelled agreements', v_count;
    END IF;
    SELECT EXISTS (
      SELECT 1 FROM api.list_commercial_agreements_page(200, NULL, NULL, NULL, 'expiring') p
      WHERE p.id = v_d
    ) INTO v_has_a;
    IF v_has_a THEN
      RAISE EXCEPTION 'CF21h7 expiring filter returned an agreement ending in a year';
    END IF;

    BEGIN
      PERFORM * FROM api.list_commercial_agreements_page(10, NULL, NULL, 'bogus', NULL);
      RAISE EXCEPTION 'CF21h7 invalid signature filter was accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%invalid_signature_filter%' THEN
        RAISE;
      END IF;
    END;
    BEGIN
      PERFORM * FROM api.list_commercial_agreements_page(10, NULL, NULL, NULL, 'bogus');
      RAISE EXCEPTION 'CF21h7 invalid validity filter was accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%invalid_validity_filter%' THEN
        RAISE;
      END IF;
    END;
    BEGIN
      PERFORM * FROM api.list_commercial_agreements_page(10, now(), NULL, NULL, NULL);
      RAISE EXCEPTION 'CF21h7 half cursor was accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%invalid_cursor%' THEN
        RAISE;
      END IF;
    END;

    -- 6. billing periods page: keyset on (due_on DESC, id DESC) ----------------------
    v_due := NULL;
    v_cur_id := NULL;
    v_prev_due := NULL;
    v_prev_pid := NULL;
    v_pages := 0;
    LOOP
      v_page_rows := 0;
      FOR v_row IN
        SELECT * FROM api.list_agreement_billing_periods_page(v_b, 1, v_due, v_cur_id)
      LOOP
        v_page_rows := v_page_rows + 1;
        IF v_row.id = ANY (v_seen_p) THEN
          RAISE EXCEPTION 'CF21h7 periods pagination repeated %', v_row.id;
        END IF;
        IF v_prev_due IS NOT NULL
           AND NOT ((v_row.due_on, v_row.id) < (v_prev_due, v_prev_pid)) THEN
          RAISE EXCEPTION 'CF21h7 periods order is not (due_on, id) DESC';
        END IF;
        v_seen_p := v_seen_p || v_row.id;
        v_prev_due := v_row.due_on;
        v_prev_pid := v_row.id;
        v_due := v_row.due_on;
        v_cur_id := v_row.id;
      END LOOP;
      v_pages := v_pages + 1;
      EXIT WHEN v_page_rows < 1;
      IF v_pages > 100 THEN
        RAISE EXCEPTION 'CF21h7 periods pagination did not terminate';
      END IF;
    END LOOP;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_billing_periods WHERE agreement_id = v_b;
    IF cardinality(v_seen_p) <> v_count OR v_count < 2 THEN
      RAISE EXCEPTION 'CF21h7 periods pagination returned % of % periods', cardinality(v_seen_p), v_count;
    END IF;

    BEGIN
      PERFORM * FROM api.list_agreement_billing_periods_page(
        '93000000-0000-0000-0000-00000000dead'::uuid, 10, NULL, NULL
      );
      RAISE EXCEPTION 'CF21h7 periods page accepted an unknown agreement';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_not_found%' THEN
        RAISE;
      END IF;
    END;

    -- 7. tenant isolation: another active tenant header is rejected ----------------------
    PERFORM set_config(
      'request.headers',
      json_build_object('x-tenant-id', '93000000-0000-0000-0000-00000000beef')::text,
      true
    );
    BEGIN
      PERFORM * FROM api.list_commercial_agreements_page(10, NULL, NULL, NULL, NULL);
      RAISE EXCEPTION 'CF21h7 list accepted a foreign tenant header';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%tenant_access_denied%' THEN
        RAISE;
      END IF;
    END;
    BEGIN
      PERFORM * FROM api.list_agreement_billing_periods_page(v_b, 10, NULL, NULL);
      RAISE EXCEPTION 'CF21h7 periods page accepted a foreign tenant header';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%tenant_access_denied%' THEN
        RAISE;
      END IF;
    END;
    PERFORM set_config(
      'request.headers',
      json_build_object('x-tenant-id', v_tenant)::text,
      true
    );

    -- 8. permissions: a plain member cannot cancel / suspend / resume ---------------------
    UPDATE data.tenant_members
    SET role = 'member'
    WHERE tenant_id = v_tenant AND user_id = v_member AND site_id IS NULL;
    INSERT INTO data.tenant_members (tenant_id, user_id, role)
    VALUES (v_tenant, v_member, 'member')
    ON CONFLICT (tenant_id, user_id) WHERE site_id IS NULL DO NOTHING;

    PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
    PERFORM set_config(
      'request.jwt.claim',
      json_build_object(
        'sub', v_member,
        'role', 'authenticated',
        'app_metadata', json_build_object(
          'user_tenants', json_build_object(
            v_tenant::text, json_build_object('global_role', 'member', 'sites', json_build_object())
          )
        )
      )::text,
      true
    );

    BEGIN
      PERFORM api.suspend_commercial_agreement(v_d, v_op_d_suspend, NULL);
      RAISE EXCEPTION 'CF21h7 member suspend was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%permission_denied%' THEN
        RAISE;
      END IF;
    END;
    BEGIN
      PERFORM api.cancel_commercial_agreement(v_d, v_op_d_cancel, NULL);
      RAISE EXCEPTION 'CF21h7 member cancel was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%permission_denied%' THEN
        RAISE;
      END IF;
    END;
    BEGIN
      PERFORM api.resume_commercial_agreement(v_d, v_op_d_resume);
      RAISE EXCEPTION 'CF21h7 member resume was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%permission_denied%' THEN
        RAISE;
      END IF;
    END;
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_d;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21h7 member changed agreement D to %', v_status;
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_events
    WHERE tenant_id = v_tenant
      AND client_op_id IN (v_op_d_suspend, v_op_d_cancel, v_op_d_resume);
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'CF21h7 denied member calls wrote % events', v_count;
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'lifecycle ui tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: CF-21-h7 cancel/suspend/resume + keyset pagination + role gating';
  END;
END;
$$;
