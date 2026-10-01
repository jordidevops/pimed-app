-- CF-21-h2: signing hardening.
--   * api.finalize is not executable by authenticated/anon (service_role only)
--   * draft cannot be finalized / cannot jump to signed
--   * signed requires a signed PDF belonging to the same tenant
--   * signed_document_id cannot change after pending_signature/signed
--   * re-finalize with the same document is a no-op, another document conflicts
--   * signing_failed is a valid event type
-- Rolled back at the end (ZZ001) so the file is re-runnable.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_other_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_quote uuid;
  v_agreement uuid;
  v_version uuid;
  v_doc uuid;
  v_doc2 uuid;
  v_foreign_doc uuid;
  v_result uuid;
  v_count int;
  v_status text;
  v_signed_doc uuid;
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

    v_quote := api.issue_commercial_document(
      v_project, 'quote', true,
      '92000000-0000-0000-0000-0000000000b1'::uuid,
      NULL, 'separate_agreement', NULL
    );
    PERFORM api.accept_commercial_document(
      v_quote, '{"method":"sql_test"}'::jsonb,
      '92000000-0000-0000-0000-0000000000b2'::uuid
    );
    v_agreement := api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      '92000000-0000-0000-0000-0000000000b3'::uuid
    );
    SELECT active_version_id INTO v_version
    FROM data.commercial_agreements WHERE id = v_agreement;

    INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
    VALUES (v_tenant, 'CF21h2 signed stub A', 'commercial', '{}', v_owner)
    RETURNING id INTO v_doc;
    INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
    VALUES (v_tenant, 'CF21h2 signed stub B', 'commercial', '{}', v_owner)
    RETURNING id INTO v_doc2;
    INSERT INTO data.documents (tenant_id, title, category, required_permissions)
    VALUES (v_other_tenant, 'CF21h2 foreign stub', 'commercial', '{}')
    RETURNING id INTO v_foreign_doc;

    -- 1. authenticated / anon cannot execute api.finalize ----------------------
    IF has_function_privilege(
         'authenticated',
         'api.finalize_commercial_agreement_version(uuid, uuid, date)',
         'EXECUTE'
       ) THEN
      RAISE EXCEPTION 'CF21h2 authenticated can still execute api.finalize';
    END IF;
    IF has_function_privilege(
         'anon',
         'api.finalize_commercial_agreement_version(uuid, uuid, date)',
         'EXECUTE'
       ) THEN
      RAISE EXCEPTION 'CF21h2 anon can execute api.finalize';
    END IF;
    IF NOT has_function_privilege(
         'service_role',
         'api.finalize_commercial_agreement_version(uuid, uuid, date)',
         'EXECUTE'
       ) THEN
      RAISE EXCEPTION 'CF21h2 service_role cannot execute api.finalize';
    END IF;
    IF has_function_privilege(
         'authenticated',
         'data.finalize_commercial_agreement_version(uuid, uuid, uuid, date)',
         'EXECUTE'
       ) THEN
      RAISE EXCEPTION 'CF21h2 authenticated can execute data.finalize';
    END IF;

    -- 2. draft cannot be finalized --------------------------------------------
    BEGIN
      PERFORM data.finalize_commercial_agreement_version(v_version, v_doc, v_owner, CURRENT_DATE);
      RAISE EXCEPTION 'CF21h2 draft finalize was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_version_not_sent%' THEN
        RAISE;
      END IF;
    END;

    -- 2b. draft cannot jump to signed with a raw UPDATE either
    BEGIN
      UPDATE data.commercial_agreement_versions
      SET status = 'signed', signed_document_id = v_doc
      WHERE id = v_version;
      RAISE EXCEPTION 'CF21h2 draft -> signed UPDATE was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_version_not_sent%' THEN
        RAISE;
      END IF;
    END;

    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature'
    WHERE id = v_version;

    -- 3. signed without PDF fails ---------------------------------------------
    BEGIN
      PERFORM data.finalize_commercial_agreement_version(v_version, NULL, v_owner, CURRENT_DATE);
      RAISE EXCEPTION 'CF21h2 finalize without signed document was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%signed_document_required%' THEN
        RAISE;
      END IF;
    END;
    SELECT status INTO v_status FROM data.commercial_agreement_versions WHERE id = v_version;
    IF v_status IS DISTINCT FROM 'pending_signature' THEN
      RAISE EXCEPTION 'CF21h2 failed finalize changed status to %', v_status;
    END IF;

    -- 3b. document from another tenant is rejected ----------------------------
    BEGIN
      PERFORM data.finalize_commercial_agreement_version(
        v_version, v_foreign_doc, v_owner, CURRENT_DATE
      );
      RAISE EXCEPTION 'CF21h2 finalize with foreign-tenant document was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%signed_document_invalid%' THEN
        RAISE;
      END IF;
    END;

    -- 3c. raw UPDATE cannot set signed_document_id while pending_signature -----
    BEGIN
      UPDATE data.commercial_agreement_versions
      SET signed_document_id = v_doc
      WHERE id = v_version;
      RAISE EXCEPTION 'CF21h2 signed_document_id UPDATE while pending was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_version_immutable%' THEN
        RAISE;
      END IF;
    END;

    -- 4. valid finalize --------------------------------------------------------
    v_result := data.finalize_commercial_agreement_version(
      v_version, v_doc, v_owner, CURRENT_DATE
    );
    IF v_result IS DISTINCT FROM v_agreement THEN
      RAISE EXCEPTION 'CF21h2 finalize returned the wrong agreement';
    END IF;
    SELECT status, signed_document_id INTO v_status, v_signed_doc
    FROM data.commercial_agreement_versions WHERE id = v_version;
    IF v_status IS DISTINCT FROM 'signed' OR v_signed_doc IS DISTINCT FROM v_doc THEN
      RAISE EXCEPTION 'CF21h2 version not signed with expected document (% / %)', v_status, v_signed_doc;
    END IF;
    SELECT status INTO v_status FROM data.commercial_agreements WHERE id = v_agreement;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'CF21h2 agreement expected active, got %', v_status;
    END IF;

    -- 5. same document again is a no-op (no second signed event) ---------------
    v_result := data.finalize_commercial_agreement_version(
      v_version, v_doc, v_owner, CURRENT_DATE
    );
    IF v_result IS DISTINCT FROM v_agreement THEN
      RAISE EXCEPTION 'CF21h2 no-op finalize returned the wrong agreement';
    END IF;
    v_result := data.finalize_commercial_agreement_version(
      v_version, NULL, v_owner, CURRENT_DATE
    );
    SELECT count(*) INTO v_count
    FROM data.commercial_agreement_events
    WHERE agreement_id = v_agreement AND event_type = 'signed';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'CF21h2 expected 1 signed event, got %', v_count;
    END IF;

    -- 6. another document after signing conflicts ------------------------------
    BEGIN
      PERFORM data.finalize_commercial_agreement_version(
        v_version, v_doc2, v_owner, CURRENT_DATE
      );
      RAISE EXCEPTION 'CF21h2 re-sign with another document was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%signed_document_conflict%' THEN
        RAISE;
      END IF;
    END;

    -- 7. mutating signed_document_id after signing fails ------------------------
    BEGIN
      UPDATE data.commercial_agreement_versions
      SET signed_document_id = v_doc2
      WHERE id = v_version;
      RAISE EXCEPTION 'CF21h2 signed_document_id mutation after signing was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_version_immutable%' THEN
        RAISE;
      END IF;
    END;
    BEGIN
      UPDATE data.commercial_agreement_versions
      SET signed_document_id = NULL
      WHERE id = v_version;
      RAISE EXCEPTION 'CF21h2 clearing signed_document_id after signing was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_version_immutable%' THEN
        RAISE;
      END IF;
    END;
    SELECT signed_document_id INTO v_signed_doc
    FROM data.commercial_agreement_versions WHERE id = v_version;
    IF v_signed_doc IS DISTINCT FROM v_doc THEN
      RAISE EXCEPTION 'CF21h2 signed_document_id changed unexpectedly';
    END IF;

    -- 8. signing_failed is an accepted event type (sanitized payload) ----------
    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, payload
    ) VALUES (
      v_tenant, v_agreement, 'signing_failed',
      jsonb_build_object('sqlstate', 'P0001', 'code', 'signing_finalize_failed')
    );

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'signing hardening tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: CF-21-h2 signing hardening';
  END;
END;
$$;
