-- CF-16 acceptance tests.
-- Runs mutations as `authenticated`, verifies the complete batch contract and
-- always rolls fixtures back.
\echo 1..1
BEGIN;

DO $setup$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000102';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000cf6';
  v_project_b uuid := '51000000-0000-0000-0000-000000000cf7';
  v_line uuid := 'cf160000-0000-0000-0000-000000000101';
  v_run uuid := 'cf160000-0000-0000-0000-000000000102';
  v_item uuid := 'cf160000-0000-0000-0000-000000000103';
  v_template uuid;
  v_version uuid;
BEGIN
  DELETE FROM data.projects WHERE id IN (v_project, v_project_b);

  SELECT t.id, v.id
  INTO v_template, v_version
  FROM data.checklist_template_versions v
  JOIN data.checklist_templates t ON t.id = v.template_id
  ORDER BY v.created_at
  LIMIT 1;

  IF v_template IS NULL OR v_version IS NULL THEN
    RAISE EXCEPTION 'CF16 test requires one checklist template version';
  END IF;

  INSERT INTO data.projects (
    id, tenant_id, type, name, status, visibility,
    site_id, client_id, created_by, authorized_total
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-16 P1 acceptance',
    'active', 'company', v_site, v_client, v_owner, 0
  );

  INSERT INTO data.projects (
    id, tenant_id, type, name, status, visibility,
    site_id, client_id, created_by, authorized_total
  ) VALUES (
    v_project_b, v_tenant, 'work_order', 'CF-16 P2 conflict',
    'active', 'company', v_site, v_client, v_owner, 0
  );

  INSERT INTO data.project_lines (
    id, tenant_id, project_id, kind, name, unit, quantity,
    unit_price, discount_pct, tax_rate, position
  ) VALUES (
    v_line, v_tenant, v_project, 'service', 'Hores CF-16',
    'h', 1, 0, 0, 21, 0
  );

  INSERT INTO data.checklist_runs (
    id, tenant_id, project_id, template_id, template_version_id,
    name_snapshot, version_number, status
  ) VALUES (
    v_run, v_tenant, v_project, v_template, v_version,
    'CF-16 test run', 1, 'pending'
  );

  INSERT INTO data.checklist_run_items (
    id, tenant_id, run_id, position, title, response_type, is_required
  ) VALUES (
    v_item, v_tenant, v_run, 0, 'CF-16 optional answer', 'checkbox', false
  );
END;
$setup$;

SET LOCAL ROLE authenticated;

DO $tests$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000cf6';
  v_line uuid := 'cf160000-0000-0000-0000-000000000101';
  v_item uuid := 'cf160000-0000-0000-0000-000000000103';
  v_start uuid := 'cf160000-0000-0000-0000-000000000110';
  v_stop uuid := 'cf160000-0000-0000-0000-000000000111';
  v_actual uuid := 'cf160000-0000-0000-0000-000000000112';
  v_material uuid := 'cf160000-0000-0000-0000-000000000113';
  v_close uuid := 'cf160000-0000-0000-0000-000000000114';
  v_guard_start uuid := 'cf160000-0000-0000-0000-000000000115';
  v_guard_close uuid := 'cf160000-0000-0000-0000-000000000116';
  v_conflict_start uuid := 'cf160000-0000-0000-0000-000000000117';
  v_project_b uuid := '51000000-0000-0000-0000-000000000cf7';
  v_batch jsonb;
  v_result jsonb;
  v_retry jsonb;
  v_log_id uuid;
  v_qty numeric;
  v_material_count int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_owner,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text,
          json_build_object('global_role', 'owner', 'sites', json_build_object())
        ),
        'user_permissions', json_build_object(
          v_tenant::text,
          json_build_object(
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

  v_result := api.start_work_log(
    v_guard_start,
    v_project,
    NULL,
    now() - interval '1 minute',
    NULL,
    'notrequired',
    NULL
  );
  BEGIN
    PERFORM api.complete_project_close_out(v_project, v_guard_close, NULL);
    RAISE EXCEPTION 'close-out accepted an open worklog';
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%open_work_logs_require_stop%' THEN RAISE; END IF;
  END;
  PERFORM api.stop_work_log(
    (v_result->>'work_log_id')::uuid,
    NULL,
    now(),
    NULL,
    'notrequired',
    false,
    NULL
  );

  BEGIN
    PERFORM api.add_project_material(
      v_project,
      'orphan cable',
      1,
      'm',
      NULL,
      'cf160000-0000-0000-0000-000000000199',
      'cf160000-0000-0000-0000-000000000198'
    );
    RAISE EXCEPTION 'unresolved work log was accepted as a null material';
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%work_log_dependency_missing%' THEN RAISE; END IF;
  END;

  v_result := api.start_work_log(
    v_conflict_start,
    v_project,
    NULL,
    now() - interval '2 minutes',
    NULL,
    'notrequired',
    NULL
  );
  BEGIN
    PERFORM api.start_work_log(
      v_conflict_start,
      v_project_b,
      NULL,
      now() - interval '2 minutes',
      NULL,
      'notrequired',
      NULL
    );
    RAISE EXCEPTION 'start client_op_id reused on another project';
  EXCEPTION WHEN unique_violation THEN
    IF SQLERRM NOT LIKE '%client_op_id_conflict%' THEN RAISE; END IF;
  END;
  PERFORM api.stop_work_log(
    (v_result->>'work_log_id')::uuid,
    NULL,
    now(),
    NULL,
    'notrequired',
    false,
    NULL
  );

  v_batch := jsonb_build_array(
    jsonb_build_object(
      'id', v_start,
      'kind', 'worklog.start',
      'payload', jsonb_build_object(
        'project_id', v_project,
        'occurred_at', now() - interval '30 minutes',
        'location_permission', 'notrequired'
      )
    ),
    jsonb_build_object(
      'id', v_stop,
      'kind', 'worklog.stop',
      'payload', jsonb_build_object(
        'client_op_id', v_start,
        'occurred_at', now(),
        'location_permission', 'notrequired'
      )
    ),
    jsonb_build_object(
      'id', v_actual,
      'kind', 'project_line.actual',
      'payload', jsonb_build_object(
        'project_id', v_project,
        'line_id', v_line,
        'unit', 'h',
        'quantity', 2.5
      )
    ),
    jsonb_build_object(
      'id', v_material,
      'kind', 'project_material.add',
      'payload', jsonb_build_object(
        'project_id', v_project,
        'name', 'CF-16 cable',
        'quantity', 2,
        'unit', 'm',
        'work_log_client_op_id', v_start
      )
    ),
    jsonb_build_object(
      'id', v_close,
      'kind', 'project.close_out',
      'payload', jsonb_build_object('project_id', v_project)
    )
  );

  v_result := api.sync_field_ops(v_batch);

  IF jsonb_array_length(v_result) <> 5
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(v_result) item
       WHERE item->>'status' NOT IN ('created', 'duplicate', 'synced')
     ) THEN
    RAISE EXCEPTION 'complete field batch failed: %', v_result;
  END IF;

  SELECT quantity INTO v_qty
  FROM data.project_lines
  WHERE id = v_line;
  IF v_qty IS DISTINCT FROM 2.5::numeric THEN
    RAISE EXCEPTION 'actual quantity not applied: %', v_qty;
  END IF;

  SELECT id INTO v_log_id
  FROM data.work_logs
  WHERE tenant_id = v_tenant AND client_op_id = v_start;
  IF v_log_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM data.work_logs
    WHERE id = v_log_id AND status = 'closed'
  ) THEN
    RAISE EXCEPTION 'worklog start/stop was not applied';
  END IF;

  SELECT count(*) INTO v_material_count
  FROM data.project_materials
  WHERE project_id = v_project
    AND client_op_id = v_material
    AND work_log_id = v_log_id;
  IF v_material_count <> 1 THEN
    RAISE EXCEPTION 'material was not linked idempotently: %', v_material_count;
  END IF;

  IF (SELECT status FROM data.projects WHERE id = v_project)
     NOT IN ('completed', 'on_hold') THEN
    RAISE EXCEPTION 'project close-out was not applied';
  END IF;

  -- Retrying the complete batch must not duplicate or mutate anything.
  v_retry := api.sync_field_ops(v_batch);
  IF jsonb_array_length(v_retry) <> 5
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(v_retry) item
       WHERE item->>'status' NOT IN ('duplicate', 'synced')
     ) THEN
    RAISE EXCEPTION 'batch retry is not idempotent: %', v_retry;
  END IF;

  -- Legacy mutation paths must not alter a closed visit.
  BEGIN
    PERFORM api.upsert_project_line(
      v_project, v_line, NULL, 'service', 'Mutated after close', NULL, 'h',
      99, 0, 0, 21, 0, NULL,
      'cf160000-0000-0000-0000-000000000120'::uuid
    );
    RAISE EXCEPTION 'legacy upsert mutated a closed project';
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%project_already_closed%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM api.delete_project_line(v_line);
    RAISE EXCEPTION 'legacy delete mutated a closed project';
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%project_already_closed%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM api.answer_checklist_run_item(
      v_item, true, NULL, NULL, NULL, NULL,
      'cf16-answer-after-close',
      true, false, false, false, false
    );
    RAISE EXCEPTION 'checklist answer mutated a closed project';
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%project_already_closed%' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'CF-16 authenticated batch and closed-state tests passed';
END;
$tests$;

RESET ROLE;

DO $receipts$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_start uuid := 'cf160000-0000-0000-0000-000000000110';
  v_stop uuid := 'cf160000-0000-0000-0000-000000000111';
  v_log_id uuid;
BEGIN
  SELECT id INTO v_log_id
  FROM data.work_logs
  WHERE tenant_id = v_tenant AND client_op_id = v_start;

  IF v_log_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM data.field_operation_receipts
    WHERE tenant_id = v_tenant
      AND client_op_id = v_stop
      AND kind = 'worklog.stop'
      AND result_id = v_log_id
  ) THEN
    RAISE EXCEPTION 'stop receipt was not recorded';
  END IF;
END;
$receipts$;

ROLLBACK;
\echo ok 1 - CF-16 authenticated batch, idempotency and closed-state invariants
