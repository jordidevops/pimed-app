-- CF-21-h1: typed client_op replay + one active agreement per source quote.
-- Rolled back at the end (ZZ001) so the file is re-runnable.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_tpl_specific uuid := '76100000-0000-0000-0000-000000000001';
  v_tpl_recurring uuid := '76100000-0000-0000-0000-000000000002';
  v_op_prepare uuid := '92000000-0000-0000-0000-0000000000c1';
  v_op_prepare_b uuid := '92000000-0000-0000-0000-0000000000c2';
  v_op_framework uuid := '92000000-0000-0000-0000-0000000000c3';
  v_op_sent uuid := '92000000-0000-0000-0000-0000000000c4';
  v_op_billing_prep uuid := '92000000-0000-0000-0000-0000000000c5';
  v_op_invoiced uuid := '92000000-0000-0000-0000-0000000000c6';
  v_op_skipped uuid := '92000000-0000-0000-0000-0000000000c7';
  v_client uuid;
  v_quote uuid;
  v_quote2 uuid;
  v_quote3 uuid;
  v_agreement uuid;
  v_retry uuid;
  v_again uuid;
  v_framework uuid;
  v_fw_version uuid;
  v_billing uuid;
  v_version uuid;
  v_billing_version uuid;
  v_doc uuid;
  v_period1 uuid;
  v_period2 uuid;
  v_result uuid;
  v_count int;
  v_status text;
  v_result_json jsonb;
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

    -- Quotes -----------------------------------------------------------------
    v_quote := api.issue_commercial_document(
      v_project, 'quote', true,
      '92000000-0000-0000-0000-0000000000a1'::uuid,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote, '{"method":"sql_test"}'::jsonb,
      '92000000-0000-0000-0000-0000000000a2'::uuid
    );
    v_quote2 := api.issue_commercial_document(
      v_project, 'quote', true,
      '92000000-0000-0000-0000-0000000000a3'::uuid,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote2, '{"method":"sql_test"}'::jsonb,
      '92000000-0000-0000-0000-0000000000a4'::uuid
    );
    v_quote3 := api.issue_commercial_document(
      v_project, 'quote', true,
      '92000000-0000-0000-0000-0000000000a5'::uuid,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote3, '{"method":"sql_test"}'::jsonb,
      '92000000-0000-0000-0000-0000000000a6'::uuid
    );

    -- 1. prepare: replay of the same op returns the same agreement ----------
    v_agreement := api.prepare_agreement_from_quote(
      v_quote, v_tpl_specific, 'none', v_op_prepare
    );
    v_retry := api.prepare_agreement_from_quote(
      v_quote, v_tpl_specific, 'none', v_op_prepare
    );
    IF v_retry IS DISTINCT FROM v_agreement THEN
      RAISE EXCEPTION 'CF21h1 prepare replay returned a different agreement';
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_events
    WHERE tenant_id = v_tenant AND client_op_id = v_op_prepare;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h1 prepare replay wrote % events', v_count;
    END IF;

    -- 2. two prepares with different ops for the same quote -> still 1 agreement
    v_again := api.prepare_agreement_from_quote(
      v_quote, v_tpl_specific, 'none', v_op_prepare_b
    );
    IF v_again IS DISTINCT FROM v_agreement THEN
      RAISE EXCEPTION 'CF21h1 second prepare created another agreement';
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreements
    WHERE tenant_id = v_tenant AND source_quote_id = v_quote AND status <> 'cancelled';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h1 expected 1 active agreement for quote, got %', v_count;
    END IF;

    -- 2b. the unique index rejects a direct duplicate insert
    BEGIN
      INSERT INTO data.commercial_agreements (
        tenant_id, client_id, kind, status, source_quote_id
      ) VALUES (v_tenant, v_client, 'specific', 'pending_start', v_quote);
      RAISE EXCEPTION 'CF21h1 duplicate agreement for quote was allowed';
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;

    -- 3. cross-type conflicts ------------------------------------------------
    SELECT active_version_id INTO v_version
    FROM data.commercial_agreements WHERE id = v_agreement;

    -- 3a. prepared op reused for mark_sent
    BEGIN
      PERFORM api.mark_agreement_sent_for_signature(
        v_version, NULL, 'client', v_op_prepare
      );
      RAISE EXCEPTION 'CF21h1 prepared op was accepted by mark_sent';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_conflict%' THEN
        RAISE;
      END IF;
    END;

    -- 3b. prepared op reused for prepare on another quote
    BEGIN
      PERFORM api.prepare_agreement_from_quote(
        v_quote2, v_tpl_specific, 'none', v_op_prepare
      );
      RAISE EXCEPTION 'CF21h1 prepared op was accepted for another quote';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_conflict%' THEN
        RAISE;
      END IF;
    END;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreements WHERE source_quote_id = v_quote2;
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'CF21h1 conflicting prepare still created an agreement';
    END IF;

    -- 4. framework: replay + cross-type conflict -----------------------------
    v_framework := api.create_framework_agreement(
      v_tenant, v_client, v_tpl_specific, 'none', v_op_framework,
      CURRENT_DATE, CURRENT_DATE + 365, 30, 'ca'
    );
    v_retry := api.create_framework_agreement(
      v_tenant, v_client, v_tpl_specific, 'none', v_op_framework,
      CURRENT_DATE, CURRENT_DATE + 365, 30, 'ca'
    );
    IF v_retry IS DISTINCT FROM v_framework THEN
      RAISE EXCEPTION 'CF21h1 framework replay returned a different agreement';
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreements
    WHERE tenant_id = v_tenant AND id = v_framework;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h1 framework replay duplicated the agreement';
    END IF;

    BEGIN
      PERFORM api.prepare_agreement_from_quote(
        v_quote3, v_tpl_specific, 'none', v_op_framework
      );
      RAISE EXCEPTION 'CF21h1 framework op was accepted by prepare_from_quote';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_conflict%' THEN
        RAISE;
      END IF;
    END;

    -- 5. mark_sent: replay + conflict on another agreement -------------------
    INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
    VALUES (v_tenant, 'CF21h1 rendered stub', 'commercial', '{}', v_owner)
    RETURNING id INTO v_doc;
    UPDATE data.commercial_agreement_versions
    SET rendered_document_id = v_doc
    WHERE id = v_version;

    v_result := api.mark_agreement_sent_for_signature(
      v_version, NULL, 'client', v_op_sent
    );
    IF v_result IS DISTINCT FROM v_agreement THEN
      RAISE EXCEPTION 'CF21h1 mark_sent returned the wrong agreement';
    END IF;
    v_retry := api.mark_agreement_sent_for_signature(
      v_version, NULL, 'client', v_op_sent
    );
    IF v_retry IS DISTINCT FROM v_agreement THEN
      RAISE EXCEPTION 'CF21h1 mark_sent replay returned a different agreement';
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_events
    WHERE tenant_id = v_tenant AND client_op_id = v_op_sent AND event_type = 'sent';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h1 mark_sent replay wrote % sent events', v_count;
    END IF;

    SELECT active_version_id INTO v_fw_version
    FROM data.commercial_agreements WHERE id = v_framework;
    BEGIN
      PERFORM api.mark_agreement_sent_for_signature(
        v_fw_version, NULL, 'client', v_op_sent
      );
      RAISE EXCEPTION 'CF21h1 sent op was accepted for another agreement';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_conflict%' THEN
        RAISE;
      END IF;
    END;

    -- 6. billing: invoiced / skipped typed + period-bound replay --------------
    v_billing := api.prepare_agreement_from_quote(
      v_quote2, v_tpl_recurring, 'none', v_op_billing_prep,
      'recurring', CURRENT_DATE, CURRENT_DATE + 400, 30, false,
      NULL, NULL, NULL,
      'monthly', 12100, 'EUR', 1
    );
    SELECT active_version_id INTO v_billing_version
    FROM data.commercial_agreements WHERE id = v_billing;

    -- finalize is internal (CF-21-h2): pending_signature + signed PDF
    INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
    VALUES (v_tenant, 'CF21h1 signed stub', 'commercial', '{}', v_owner)
    RETURNING id INTO v_doc;
    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature' WHERE id = v_billing_version;
    PERFORM data.finalize_commercial_agreement_version(
      v_billing_version, v_doc, v_owner, CURRENT_DATE
    );
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_billing;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21h1 billing agreement expected active, got %', v_status;
    END IF;

    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE, 500);
    PERFORM api.generate_due_agreement_billing_periods(CURRENT_DATE + 40, 500);

    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_billing_periods
    WHERE agreement_id = v_billing AND status = 'due';
    IF v_count < 2 THEN
      RAISE EXCEPTION 'CF21h1 expected 2 due periods, got %', v_count;
    END IF;
    SELECT id INTO v_period1
    FROM data.commercial_agreement_billing_periods
    WHERE agreement_id = v_billing AND status = 'due'
    ORDER BY due_on ASC LIMIT 1;
    SELECT id INTO v_period2
    FROM data.commercial_agreement_billing_periods
    WHERE agreement_id = v_billing AND status = 'due' AND id <> v_period1
    ORDER BY due_on ASC LIMIT 1;

    v_result := api.mark_agreement_billing_period_invoiced(v_period1, 'IDEM-001', v_op_invoiced);
    v_retry := api.mark_agreement_billing_period_invoiced(v_period1, 'IDEM-001', v_op_invoiced);
    IF v_result IS DISTINCT FROM v_period1 OR v_retry IS DISTINCT FROM v_period1 THEN
      RAISE EXCEPTION 'CF21h1 invoiced replay returned a different period';
    END IF;
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_events
    WHERE tenant_id = v_tenant AND client_op_id = v_op_invoiced;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h1 invoiced replay wrote % events', v_count;
    END IF;

    -- invoiced op reused for skip (type mismatch)
    BEGIN
      PERFORM api.skip_agreement_billing_period(v_period2, v_op_invoiced, NULL);
      RAISE EXCEPTION 'CF21h1 invoiced op was accepted by skip';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_conflict%' THEN
        RAISE;
      END IF;
    END;

    -- invoiced op reused for another period (period mismatch)
    BEGIN
      PERFORM api.mark_agreement_billing_period_invoiced(v_period2, 'IDEM-002', v_op_invoiced);
      RAISE EXCEPTION 'CF21h1 invoiced op was accepted for another period';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_conflict%' THEN
        RAISE;
      END IF;
    END;

    -- prepared op reused for invoiced
    BEGIN
      PERFORM api.mark_agreement_billing_period_invoiced(v_period2, 'IDEM-003', v_op_billing_prep);
      RAISE EXCEPTION 'CF21h1 prepared op was accepted by mark_invoiced';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_conflict%' THEN
        RAISE;
      END IF;
    END;

    -- skip: replay ok, other period conflicts
    v_result := api.skip_agreement_billing_period(v_period2, v_op_skipped, 'skip test');
    v_retry := api.skip_agreement_billing_period(v_period2, v_op_skipped, 'skip test');
    IF v_result IS DISTINCT FROM v_period2 OR v_retry IS DISTINCT FROM v_period2 THEN
      RAISE EXCEPTION 'CF21h1 skip replay returned a different period';
    END IF;
    BEGIN
      PERFORM api.skip_agreement_billing_period(v_period1, v_op_skipped, NULL);
      RAISE EXCEPTION 'CF21h1 skip op was accepted for another period';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%client_op_conflict%' THEN
        RAISE;
      END IF;
    END;

    -- 7. the helper itself ---------------------------------------------------
    IF (data.commercial_agreement_replay_event(
          v_tenant, '92000000-0000-0000-0000-0000000000ff'::uuid, 'prepared')).id IS NOT NULL THEN
      RAISE EXCEPTION 'CF21h1 helper returned an event for an unknown op';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'idempotency tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: CF-21-h1 typed client_op replay + unique active agreement per quote';
  END;
END;
$$;
