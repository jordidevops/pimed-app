-- CT-2: agreement core. Tenant view, kind gate, version lock, append-only events.
DO $$
DECLARE
  v_op_1 uuid := gen_random_uuid();
  v_op_2 uuid := gen_random_uuid();
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_other uuid := '10000000-0000-0000-0000-000000000001';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_quote uuid;
  v_client uuid;
  v_agreement uuid;
  v_version uuid;
  v_other_client uuid;
  v_other_quote uuid;
  v_other_agreement uuid;
  v_project_b uuid;
  v_visible integer;
  v_hidden integer;
BEGIN
  BEGIN
    PERFORM set_config(
      'request.jwt.claim.sub',
      '20000000-0000-0000-0000-000000000002',
      true
    );
    PERFORM set_config(
      'request.jwt.claim',
      '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
      true
    );
    PERFORM set_config(
      'request.headers',
      '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}',
      true
    );

    IF has_table_privilege('authenticated', 'data.commercial_agreements', 'INSERT')
       OR has_table_privilege('authenticated', 'api.commercial_agreements', 'INSERT') THEN
      RAISE EXCEPTION 'CT2 authenticated must not insert agreements';
    END IF;

    v_quote := api.issue_commercial_document(
      v_project, 'quote', true,
      v_op_1,
      NULL, 'separate_agreement', NULL
    );
    SELECT client_id INTO v_client
    FROM data.commercial_documents WHERE id = v_quote;

    INSERT INTO data.commercial_agreements (
      tenant_id, client_id, kind, source_quote_id, work_gate
    ) VALUES (
      v_tenant, v_client, 'specific', v_quote, 'none'
    ) RETURNING id INTO v_agreement;

    -- CF-21-h1: one non-cancelled agreement per source quote; side rows are cancelled.
    INSERT INTO data.commercial_agreements (
      tenant_id, client_id, kind, status, source_quote_id
    ) VALUES (
      v_tenant, v_client, 'recurring', 'cancelled', v_quote
    ) RETURNING id INTO v_other_agreement;
    DELETE FROM data.commercial_agreements WHERE id = v_other_agreement;

    BEGIN
      -- CF-21-d: framework is allowed; project remains reserved without unlock.
      INSERT INTO data.commercial_agreements (
        tenant_id, client_id, kind, source_quote_id
      ) VALUES (
        v_tenant, v_client, 'project', NULL
      );
      RAISE EXCEPTION 'CT2 project insert was allowed without unlock';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_kind_reserved%' THEN
        RAISE;
      END IF;
    END;

    PERFORM set_config('app.commercial_agreement_kind_unlocked', 'on', true);

    BEGIN
      INSERT INTO data.commercial_agreements (
        tenant_id, client_id, kind, source_quote_id
      ) VALUES (
        v_tenant, v_client, 'employment', NULL
      );
      RAISE EXCEPTION 'CT2 unknown kind was allowed';
    EXCEPTION WHEN check_violation THEN
      NULL;
    END;

    INSERT INTO data.commercial_agreements (
      tenant_id, client_id, kind, status, source_quote_id
    ) VALUES (
      v_tenant, v_client, 'project', 'cancelled', NULL
    ) RETURNING id INTO v_other_agreement;
    IF v_other_agreement IS NULL THEN
      RAISE EXCEPTION 'CT2 unlocked kind insert failed';
    END IF;
    DELETE FROM data.commercial_agreements WHERE id = v_other_agreement;
    PERFORM set_config('app.commercial_agreement_kind_unlocked', '', true);

    -- CF-21-h1: second non-cancelled agreement for the same quote must fail unique.
    BEGIN
      INSERT INTO data.commercial_agreements (
        tenant_id, client_id, kind, source_quote_id, work_gate
      ) VALUES (
        v_tenant, v_client, 'specific', v_quote, 'none'
      );
      RAISE EXCEPTION 'CT2 duplicate active source_quote was allowed';
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;

    INSERT INTO data.commercial_agreement_versions (
      tenant_id, agreement_id, version_no, status,
      source_quote_id, source_quote_content_hash, content_hash
    ) VALUES (
      v_tenant, v_agreement, 1, 'draft',
      v_quote, 'hash-quote', 'hash-draft'
    ) RETURNING id INTO v_version;

    UPDATE data.commercial_agreement_versions
    SET content_hash = 'hash-draft-2'
    WHERE id = v_version;

    UPDATE data.commercial_agreement_versions
    SET status = 'pending_signature'
    WHERE id = v_version;

    BEGIN
      UPDATE data.commercial_agreement_versions
      SET content_hash = 'mutated'
      WHERE id = v_version;
      RAISE EXCEPTION 'CT2 version content update was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_version_immutable%' THEN
        RAISE;
      END IF;
    END;

    UPDATE data.commercial_agreement_versions
    SET status = 'signed'
    WHERE id = v_version;

    UPDATE data.commercial_agreements
    SET active_version_id = v_version, status = 'active'
    WHERE id = v_agreement;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, client_op_id, payload
    ) VALUES (
      v_tenant, v_agreement, 'created',
      v_op_2,
      jsonb_build_object('source_quote_id', v_quote)
    );

    BEGIN
      UPDATE data.commercial_agreement_events
      SET payload = '{}'::jsonb
      WHERE agreement_id = v_agreement;
      RAISE EXCEPTION 'CT2 event update was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%agreement_event_immutable%' THEN
        RAISE;
      END IF;
    END;

    INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
    VALUES (v_tenant, v_agreement, v_project);

    BEGIN
      INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
      VALUES (v_tenant, v_agreement, v_project);
      RAISE EXCEPTION 'CT2 duplicate project link was allowed';
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;

    SELECT id INTO v_project_b
    FROM data.projects
    WHERE tenant_id = v_tenant AND id <> v_project
    LIMIT 1;
    IF v_project_b IS NOT NULL THEN
      INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
      VALUES (v_tenant, v_agreement, v_project_b);
    END IF;

    SELECT count(*) INTO v_visible
    FROM api.commercial_agreements
    WHERE id = v_agreement;
    IF v_visible <> 1 THEN
      RAISE EXCEPTION 'CT2 own-tenant view missed the agreement: %', v_visible;
    END IF;

    PERFORM set_config(
      'request.headers',
      '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}',
      true
    );
    SELECT count(*) INTO v_hidden
    FROM api.commercial_agreements
    WHERE id = v_agreement;
    IF v_hidden <> 0 THEN
      RAISE EXCEPTION 'CT2 other tenant saw the agreement';
    END IF;

    SELECT c.id, d.id INTO v_other_client, v_other_quote
    FROM data.contacts c
    JOIN data.commercial_documents d ON d.client_id = c.id AND d.tenant_id = c.tenant_id
    WHERE c.tenant_id = v_other
    LIMIT 1;
    IF v_other_client IS NOT NULL THEN
      INSERT INTO data.commercial_agreements (
        tenant_id, client_id, kind, source_quote_id
      ) VALUES (
        v_other, v_other_client, 'specific', v_other_quote
      ) RETURNING id INTO v_other_agreement;

      PERFORM set_config(
        'request.headers',
        '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}',
        true
      );
      IF EXISTS (
        SELECT 1 FROM api.commercial_agreements WHERE id = v_other_agreement
      ) THEN
        RAISE EXCEPTION 'CT2 view leaked the other tenant agreement';
      END IF;
    END IF;

    RAISE EXCEPTION USING
      ERRCODE = 'ZZ001',
      MESSAGE = 'commercial agreement core tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: kind gate, version lock, events, tenant view';
  END;
END;
$$;
