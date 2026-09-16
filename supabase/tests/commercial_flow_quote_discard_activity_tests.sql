-- Discard issued quotes + project Activity projection from commercial events.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000c1d';
  v_quote uuid;
  v_retry uuid;
  v_accepted uuid;
  v_reissued uuid;
  v_status text;
  v_events int;
  v_audits int;
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
          v_tenant::text, json_build_object(
            'global_permissions', json_build_array('*'),
            'sites', json_build_object()
          )
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

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF discard quote test',
    'Disposable', 'active', 'company', v_site, v_client, v_owner
  )
  ON CONFLICT (id) DO UPDATE SET
    status = 'active',
    client_id = EXCLUDED.client_id,
    updated_at = now();

  ALTER TABLE data.commercial_document_events DISABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_lines DISABLE TRIGGER USER;
  ALTER TABLE data.commercial_documents DISABLE TRIGGER USER;
  DELETE FROM data.commercial_document_events
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  DELETE FROM data.commercial_document_lines
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  UPDATE data.commercial_documents
  SET rendered_document_id = NULL, pdf_job_id = NULL
  WHERE project_id = v_project;
  DELETE FROM data.commercial_documents WHERE project_id = v_project;
  ALTER TABLE data.commercial_documents ENABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_lines ENABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_events ENABLE TRIGGER USER;
  DELETE FROM data.project_lines WHERE project_id = v_project;

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Base discard', NULL, 'u',
    1, 50, 0, 21, 0, NULL,
    'cf1d0000-0000-0000-0000-000000000001'::uuid
  );

  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf1d0000-0000-0000-0000-000000000002'::uuid,
    NULL
  );

  PERFORM api.cancel_commercial_document(
    v_quote,
    'cf1d0000-0000-0000-0000-000000000010'::uuid,
    'preus canviats'
  );
  v_retry := api.cancel_commercial_document(
    v_quote,
    'cf1d0000-0000-0000-0000-000000000010'::uuid,
    'preus canviats'
  );
  IF v_retry IS DISTINCT FROM v_quote THEN
    RAISE EXCEPTION 'cancel should be idempotent';
  END IF;

  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_quote;
  IF v_status IS DISTINCT FROM 'cancelled' THEN
    RAISE EXCEPTION 'quote should be cancelled, got %', v_status;
  END IF;

  SELECT COUNT(*) INTO v_events
  FROM data.commercial_document_events
  WHERE document_id = v_quote AND event_type = 'cancelled';
  IF v_events <> 1 THEN
    RAISE EXCEPTION 'exactly one cancelled event, got %', v_events;
  END IF;

  SELECT COUNT(*) INTO v_audits
  FROM data.audit_logs
  WHERE entity_type = 'project'
    AND entity_id = v_project
    AND action = 'PROJECT_COMMERCIAL_CANCELLED'
    AND payload->>'commercial_document_id' = v_quote::text;
  IF v_audits < 1 THEN
    RAISE EXCEPTION 'project activity projection missing for cancel';
  END IF;

  SELECT COUNT(*) INTO v_audits
  FROM data.audit_logs
  WHERE entity_type = 'project'
    AND entity_id = v_project
    AND action = 'PROJECT_COMMERCIAL_ISSUED'
    AND payload->>'commercial_document_id' = v_quote::text;
  IF v_audits < 1 THEN
    RAISE EXCEPTION 'project activity projection missing for issue';
  END IF;

  v_reissued := api.reissue_commercial_quote(
    v_quote,
    'cf1d0000-0000-0000-0000-000000000011'::uuid
  );
  IF v_reissued IS NULL THEN
    RAISE EXCEPTION 'reissue after cancel should work';
  END IF;

  PERFORM api.reject_commercial_document(
    v_reissued,
    '{"method":"sql_test"}'::jsonb,
    'cf1d0000-0000-0000-0000-000000000012'::uuid
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Accept path', NULL, 'u',
    1, 40, 0, 21, 0, NULL,
    'cf1d0000-0000-0000-0000-000000000021'::uuid
  );
  v_accepted := api.reissue_commercial_quote(
    v_reissued,
    'cf1d0000-0000-0000-0000-000000000013'::uuid
  );
  PERFORM api.accept_commercial_document(
    v_accepted,
    '{"method":"sql_test"}'::jsonb,
    'cf1d0000-0000-0000-0000-000000000014'::uuid
  );

  BEGIN
    PERFORM api.cancel_commercial_document(
      v_accepted,
      'cf1d0000-0000-0000-0000-000000000015'::uuid,
      NULL
    );
    RAISE EXCEPTION 'accepted quote should not cancel';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%document_not_cancellable_state%' THEN
      RAISE;
    END IF;
  END;

  RAISE NOTICE 'commercial quote discard and activity tests passed';
END;
$$;
