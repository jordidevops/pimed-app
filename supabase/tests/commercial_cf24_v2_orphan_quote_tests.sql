-- CF-24 V2 orphan quote (+ hotfix): draft → lines → issue → accept → OS;
-- immutable formalization fields; gate without link (pending + active);
-- membership when sub null; reject no OS; N orphans.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_client uuid;
  v_draft uuid;
  v_draft2 uuid;
  v_issued uuid;
  v_rejected uuid;
  v_project uuid;
  v_line uuid;
  v_line_count int;
  v_gate boolean;
  v_agreement uuid;
  v_member_count int;
  v_accept_events int;
  v_flag boolean;
  v_mode text;
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

  SELECT client_id INTO v_client
  FROM data.projects
  WHERE id = '51000000-0000-0000-0000-000000000101'::uuid;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'fixture project missing client_id';
  END IF;

  -- T1: draft without number + two orphans same client
  v_draft := api.create_orphan_quote_draft(
    v_tenant, v_client, NULL, 'signed_quote',
    '91000000-0000-0000-0000-00000000a001'::uuid
  );
  v_draft2 := api.create_orphan_quote_draft(
    v_tenant, v_client, NULL, 'signed_quote',
    '91000000-0000-0000-0000-00000000a002'::uuid
  );
  IF v_draft = v_draft2 THEN
    RAISE EXCEPTION 'T1 expected distinct orphan drafts';
  END IF;
  IF (SELECT doc_number FROM data.commercial_documents WHERE id = v_draft) IS NOT NULL THEN
    RAISE EXCEPTION 'T1 draft must not allocate doc_number';
  END IF;

  -- T2: lines + issue
  v_line := api.upsert_commercial_document_line(
    v_draft, NULL, NULL, 'service', 'Línia orfe', NULL, 'u', 2, 50, 0, 21, 0
  );
  v_issued := api.issue_orphan_commercial_document(
    v_draft, '91000000-0000-0000-0000-00000000a003'::uuid, true, NULL, NULL
  );
  IF (SELECT doc_number FROM data.commercial_documents WHERE id = v_issued) IS NULL THEN
    RAISE EXCEPTION 'T2 issue must allocate doc_number';
  END IF;
  IF (SELECT status FROM data.commercial_documents WHERE id = v_issued) <> 'issued' THEN
    RAISE EXCEPTION 'T2 expected issued';
  END IF;

  -- T2b: immutable formalization_mode / full_body_template_id after issue
  SELECT formalization_mode INTO v_mode
  FROM data.commercial_documents WHERE id = v_issued;
  BEGIN
    UPDATE data.commercial_documents
    SET formalization_mode = CASE
      WHEN v_mode = 'signed_quote' THEN 'separate_agreement'
      ELSE 'signed_quote'
    END
    WHERE id = v_issued;
    RAISE EXCEPTION 'T2b formalization_mode update should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%commercial_document_immutable%' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    UPDATE data.commercial_documents
    SET full_body_template_id = NULL
    WHERE id = v_issued
      AND full_body_template_id IS NOT NULL;
    IF FOUND THEN
      RAISE EXCEPTION 'T2b full_body_template_id clear should fail';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%commercial_document_immutable%' THEN
      RAISE;
    END IF;
  END;

  -- T3: accept → OS + project_lines with source_quote_line_id
  PERFORM api.accept_commercial_document(
    v_issued,
    '{"method":"sql_test"}'::jsonb,
    '91000000-0000-0000-0000-00000000a004'::uuid
  );
  SELECT project_id INTO v_project FROM data.commercial_documents WHERE id = v_issued;
  IF v_project IS NULL THEN
    v_project := api.ensure_project_from_orphan_quote(v_issued);
  END IF;
  IF v_project IS NULL THEN
    RAISE EXCEPTION 'T3 expected project after accept/ensure';
  END IF;
  SELECT count(*) INTO v_line_count
  FROM data.project_lines
  WHERE project_id = v_project AND source_quote_line_id = v_line;
  IF v_line_count <> 1 THEN
    RAISE EXCEPTION 'T3 expected materialized line with source_quote_line_id';
  END IF;
  IF (SELECT planned_start FROM data.projects WHERE id = v_project) IS NOT NULL THEN
    RAISE EXCEPTION 'T3 OS should be unscheduled (planned_start null)';
  END IF;
  IF (SELECT commercial_stage FROM data.projects WHERE id = v_project) <> 'execute' THEN
    RAISE EXCEPTION 'T3 OS must be execute';
  END IF;

  SELECT count(*) INTO v_member_count
  FROM data.project_members WHERE project_id = v_project;
  IF v_member_count < 1 THEN
    RAISE EXCEPTION 'T3 expected at least one project_member';
  END IF;

  SELECT count(*) INTO v_accept_events
  FROM data.commercial_document_events
  WHERE document_id = v_issued AND event_type = 'accepted';
  IF v_accept_events <> 1 THEN
    RAISE EXCEPTION 'T3 expected single accepted event, got %', v_accept_events;
  END IF;

  SELECT COALESCE((payload->>'project_created_from_quote')::boolean, false) INTO v_flag
  FROM data.commercial_document_events
  WHERE document_id = v_issued AND event_type = 'accepted'
  ORDER BY occurred_at DESC
  LIMIT 1;
  IF v_flag IS NOT TRUE THEN
    RAISE EXCEPTION 'T3 accepted payload must flag project_created_from_quote';
  END IF;

  -- T3b: ensure idempotent
  IF api.ensure_project_from_orphan_quote(v_issued) IS DISTINCT FROM v_project THEN
    RAISE EXCEPTION 'T3b ensure must return same project';
  END IF;

  -- T4: reject orphan → no OS
  v_rejected := api.create_orphan_quote_draft(
    v_tenant, v_client, NULL, 'signed_quote',
    '91000000-0000-0000-0000-00000000a005'::uuid
  );
  PERFORM api.upsert_commercial_document_line(
    v_rejected, NULL, NULL, 'service', 'Reject me', NULL, 'u', 1, 10, 0, 21, 0
  );
  PERFORM api.issue_orphan_commercial_document(
    v_rejected, '91000000-0000-0000-0000-00000000a006'::uuid, true, NULL, NULL
  );
  PERFORM api.reject_commercial_document(
    v_rejected,
    '{"method":"sql_test"}'::jsonb,
    '91000000-0000-0000-0000-00000000a007'::uuid
  );
  IF (SELECT project_id FROM data.commercial_documents WHERE id = v_rejected) IS NOT NULL THEN
    RAISE EXCEPTION 'T4 reject must not create project';
  END IF;

  -- T5: permission denied for upsert on issued
  BEGIN
    PERFORM api.upsert_commercial_document_line(
      v_issued, NULL, NULL, 'service', 'nope', NULL, 'u', 1, 1, 0, 21, 0
    );
    RAISE EXCEPTION 'T5 upsert on issued should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%orphan_line_edit_not_allowed%'
       AND SQLERRM NOT LIKE '%commercial_document_lines_immutable%' THEN
      RAISE;
    END IF;
  END;

  -- T6: work_gate via source_quote without link (non-active)
  INSERT INTO data.commercial_agreements (
    tenant_id, client_id, kind, source_quote_id, work_gate, status, created_by
  ) VALUES (
    v_tenant, v_client, 'specific', v_issued, 'require_signed_agreement',
    'pending_start', '20000000-0000-0000-0000-000000000002'::uuid
  )
  RETURNING id INTO v_agreement;

  SELECT data.project_requires_active_agreement(v_project) INTO v_gate;
  IF v_gate IS NOT TRUE THEN
    RAISE EXCEPTION 'T6 expected gate true for unlinked require_signed_agreement';
  END IF;

  -- T6b: same gate when agreement is active but still unlinked
  UPDATE data.commercial_agreements
  SET status = 'active'
  WHERE id = v_agreement;
  SELECT data.project_requires_active_agreement(v_project) INTO v_gate;
  IF v_gate IS NOT TRUE THEN
    RAISE EXCEPTION 'T6b expected gate true for active unlinked require_signed_agreement';
  END IF;

  -- T6c: after link, active agreement no longer gates
  INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
  VALUES (v_tenant, v_agreement, v_project)
  ON CONFLICT (agreement_id, project_id) DO NOTHING;
  SELECT data.project_requires_active_agreement(v_project) INTO v_gate;
  IF v_gate IS TRUE THEN
    RAISE EXCEPTION 'T6c linked active agreement must not gate';
  END IF;

  -- T7: membership with null auth.uid on a fresh orphan (created_by fallback)
  v_draft := api.create_orphan_quote_draft(
    v_tenant, v_client, NULL, 'signed_quote',
    '91000000-0000-0000-0000-00000000a008'::uuid
  );
  PERFORM api.upsert_commercial_document_line(
    v_draft, NULL, NULL, 'service', 'Null uid', NULL, 'u', 1, 20, 0, 21, 0
  );
  v_issued := api.issue_orphan_commercial_document(
    v_draft, '91000000-0000-0000-0000-00000000a009'::uuid, true, NULL, NULL
  );
  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_tenant, v_issued, 'accepted',
    (SELECT created_by FROM data.commercial_documents WHERE id = v_issued),
    '91000000-0000-0000-0000-00000000a00a'::uuid,
    '{}'::jsonb
  );

  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim', '', true);
  -- Status→accepted fires orphan ensure trigger with auth.uid() null
  UPDATE data.commercial_documents
  SET status = 'accepted', updated_at = now()
  WHERE id = v_issued AND status = 'issued';

  SELECT project_id INTO v_project FROM data.commercial_documents WHERE id = v_issued;
  IF v_project IS NULL THEN
    v_project := api.ensure_project_from_orphan_quote(v_issued);
  END IF;
  SELECT count(*) INTO v_member_count
  FROM data.project_members WHERE project_id = v_project;
  IF v_member_count < 1 THEN
    RAISE EXCEPTION 'T7 ensure without auth.uid must still create project_member';
  END IF;

  RAISE NOTICE 'commercial_cf24_v2_orphan_quote_tests OK';
END;
$$;
