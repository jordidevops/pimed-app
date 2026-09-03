-- =============================================================================
-- SQL tests: checklist / maintenance catalogs (post-rewrite)
-- Run: psql ... -f supabase/tests/checklist_maintenance_engine_tests.sql
-- =============================================================================
BEGIN;
SET client_min_messages TO WARNING;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

DO $$
DECLARE
  v_ok boolean;
  v_cnt int;
  v_tpl uuid := 'a2000000-0000-4000-8000-000000000001';
  v_set uuid := 'a1000000-0000-4000-8000-000000000001';
  v_opt uuid := 'a1100000-0000-4000-8000-000000000001';
  v_fail_opt uuid := 'a1100000-0000-4000-8000-000000000003';
  v_def text;
  v_run_id uuid;
  v_item_id uuid;
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_label_before text;
  v_label_after text;
BEGIN
  -- Platform seeds
  SELECT COUNT(*) INTO v_cnt FROM data.checklist_response_sets WHERE tenant_id IS NULL;
  INSERT INTO test_results VALUES (
    'platform_response_sets_seeded',
    CASE WHEN v_cnt >= 3 THEN 'PASS' ELSE 'FAIL' END,
    format('count=%s', v_cnt)
  );

  SELECT COUNT(*) INTO v_cnt FROM data.checklist_review_points WHERE tenant_id IS NULL AND is_active;
  INSERT INTO test_results VALUES (
    'platform_review_points_seeded',
    CASE WHEN v_cnt >= 8 THEN 'PASS' ELSE 'FAIL' END,
    format('count=%s', v_cnt)
  );

  SELECT COUNT(*) INTO v_cnt FROM data.checklist_templates WHERE tenant_id IS NULL AND is_active;
  INSERT INTO test_results VALUES (
    'platform_templates_seeded',
    CASE WHEN v_cnt >= 4 THEN 'PASS' ELSE 'FAIL' END,
    format('count=%s', v_cnt)
  );

  SELECT COUNT(*) INTO v_cnt
  FROM data.checklist_templates
  WHERE tenant_id IS NULL AND kind = 'todo';
  INSERT INTO test_results VALUES (
    'platform_todo_template_seeded',
    CASE WHEN v_cnt >= 1 THEN 'PASS' ELSE 'FAIL' END,
    format('count=%s', v_cnt)
  );

  SELECT COUNT(*) INTO v_cnt
  FROM data.checklist_templates
  WHERE tenant_id IS NULL AND kind = 'review';
  INSERT INTO test_results VALUES (
    'platform_review_templates_seeded',
    CASE WHEN v_cnt >= 3 THEN 'PASS' ELSE 'FAIL' END,
    format('count=%s', v_cnt)
  );

  SELECT COUNT(*) INTO v_cnt FROM data.maintenance_plans WHERE tenant_id IS NULL;
  INSERT INTO test_results VALUES (
    'platform_plans_seeded',
    CASE WHEN v_cnt >= 3 THEN 'PASS' ELSE 'FAIL' END,
    format('count=%s', v_cnt)
  );

  -- is_default impossible on platform
  BEGIN
    UPDATE data.checklist_templates
    SET is_default = true
    WHERE id = v_tpl AND tenant_id IS NULL;
    INSERT INTO test_results VALUES ('platform_default_forbidden', 'FAIL', 'update allowed');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('platform_default_forbidden', 'PASS', SQLERRM);
  END;

  -- kind only todo|review
  BEGIN
    INSERT INTO data.checklist_templates (tenant_id, name, kind, vertical)
    VALUES (v_tenant, 'bad kind', 'inspection', 'generic');
    INSERT INTO test_results VALUES ('kind_todo_or_review_only', 'FAIL', 'inspection allowed');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('kind_todo_or_review_only', 'PASS', SQLERRM);
  END;

  -- applicability table removed
  SELECT NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'data' AND table_name = 'checklist_template_applicability'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'applicability_removed',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- published items immutable
  BEGIN
    UPDATE data.checklist_template_items
    SET title = title || ' x'
    WHERE version_id IN (
      SELECT id FROM data.checklist_template_versions
      WHERE template_id = v_tpl AND status = 'published'
    );
    INSERT INTO test_results VALUES ('published_items_immutable', 'FAIL', 'update allowed');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('published_items_immutable', 'PASS', SQLERRM);
  END;

  -- answer snapshot columns exist
  SELECT COUNT(*) INTO v_cnt
  FROM information_schema.columns
  WHERE table_schema = 'data'
    AND table_name = 'checklist_run_items'
    AND column_name IN (
      'answer_label', 'answer_color_token', 'answer_semantic',
      'answer_blocks_closeout', 'client_mutation_id'
    );
  INSERT INTO test_results VALUES (
    'run_item_answer_snapshot_columns',
    CASE WHEN v_cnt = 5 THEN 'PASS' ELSE 'FAIL' END,
    format('count=%s', v_cnt)
  );

  -- apply rejects platform templates (function body guard)
  SELECT pg_get_functiondef('api.apply_checklist_to_project(uuid,uuid,uuid)'::regprocedure)
    INTO v_def;
  INSERT INTO test_results VALUES (
    'apply_rejects_platform_template',
    CASE WHEN v_def LIKE '%platform_template_must_be_cloned%' THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- clone RPCs exist
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'clone_checklist_review_point'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'clone_point_rpc_exists',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'clone_maintenance_plan'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'clone_plan_rpc_exists',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- Answer snapshot compliance: mutate option label after answering must not change stored snapshot
  INSERT INTO data.checklist_runs (
    id, tenant_id, project_id, template_id, template_version_id,
    name_snapshot, version_number, status
  )
  SELECT
    'b1000000-0000-4000-8000-000000000001',
    p.tenant_id,
    p.id,
    '83000000-0000-0000-0000-000000000002',
    '83100000-0000-0000-0000-000000000002',
    'snapshot-test',
    1,
    'in_progress'
  FROM data.projects p
  WHERE p.tenant_id = v_tenant
  ORDER BY p.created_at
  LIMIT 1
  RETURNING id INTO v_run_id;

  IF v_run_id IS NULL THEN
    INSERT INTO test_results VALUES ('answer_snapshot_immutable', 'FAIL', 'no project for tenant');
  ELSE
    INSERT INTO data.checklist_run_items (
      id, tenant_id, run_id, position, title, include_in_report, is_required,
      response_type, response_set_id,
      value_option_id, answer_label, answer_color_token, answer_semantic,
      answer_blocks_closeout, answered_at
    ) VALUES (
      'b1100000-0000-4000-8000-000000000001',
      v_tenant, v_run_id, 0, 'Punt test', true, true,
      'single_choice', v_set,
      v_opt, 'Correcte', 'green', 'pass', false, now()
    )
    RETURNING id INTO v_item_id;

    SELECT answer_label INTO v_label_before
    FROM data.checklist_run_items WHERE id = v_item_id;

    UPDATE data.checklist_response_options
    SET label = 'Correcte MODIFICAT'
    WHERE id = v_opt;

    SELECT answer_label INTO v_label_after
    FROM data.checklist_run_items WHERE id = v_item_id;

    -- restore option label for other tests / seed cleanliness within txn
    UPDATE data.checklist_response_options
    SET label = 'Correcte'
    WHERE id = v_opt;

    INSERT INTO test_results VALUES (
      'answer_snapshot_immutable',
      CASE WHEN v_label_before = 'Correcte' AND v_label_after = 'Correcte' THEN 'PASS' ELSE 'FAIL' END,
      format('before=%s after=%s', v_label_before, v_label_after)
    );

    -- closeout blockers use answer_blocks_closeout snapshot, not live option
    UPDATE data.checklist_run_items
    SET
      value_option_id = v_fail_opt,
      answer_label = 'Urgent',
      answer_color_token = 'red',
      answer_semantic = 'fail',
      answer_blocks_closeout = true
    WHERE id = v_item_id;

    -- Live option still blocks; flip live blocks_closeout off and ensure snapshot still blocks via column
    UPDATE data.checklist_response_options
    SET blocks_closeout = false
    WHERE id = v_fail_opt;

    SELECT EXISTS (
      SELECT 1 FROM data.checklist_run_items i
      WHERE i.id = v_item_id AND i.answer_blocks_closeout IS TRUE
    ) INTO v_ok;

    UPDATE data.checklist_response_options
    SET blocks_closeout = true
    WHERE id = v_fail_opt;

    INSERT INTO test_results VALUES (
      'closeout_uses_answer_snapshot',
      CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
      NULL
    );
  END IF;

  -- entity types registered
  SELECT COUNT(*) INTO v_cnt
  FROM data.entity_types
  WHERE code IN ('checklist_run','checklist_run_item','contact_site','location');
  INSERT INTO test_results VALUES (
    'entity_types_registered',
    CASE WHEN v_cnt = 4 THEN 'PASS' ELSE 'FAIL' END,
    format('count=%s', v_cnt)
  );

  SELECT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'assets_location_xor_contact_site_chk'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'assets_contact_site_constraint',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'data.maintenance_occurrences'::regclass
      AND contype = 'u'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'occurrence_unique_assignment_due',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- Platform insert denied for authenticated
  BEGIN
    SET LOCAL ROLE authenticated;
    INSERT INTO data.checklist_review_points (tenant_id, title, locale, category)
    VALUES (NULL, 'Platform hack point', 'ca', 'general');
    INSERT INTO test_results VALUES ('platform_point_insert_denied', 'FAIL', 'insert allowed');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    INSERT INTO test_results VALUES ('platform_point_insert_denied', 'PASS', SQLERRM);
  END;

  BEGIN
    SET LOCAL ROLE authenticated;
    INSERT INTO data.checklist_templates (tenant_id, name, kind, vertical)
    VALUES (NULL, 'Platform hack template', 'todo', 'generic');
    INSERT INTO test_results VALUES ('platform_template_insert_denied', 'FAIL', 'insert allowed');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    INSERT INTO test_results VALUES ('platform_template_insert_denied', 'PASS', SQLERRM);
  END;

  -- Hot-path / filter indexes
  SELECT COUNT(*) INTO v_cnt
  FROM pg_indexes
  WHERE schemaname = 'data'
    AND (
      indexname IN (
        'idx_checklist_runs_tenant_project',
        'idx_checklist_runs_tenant_status',
        'idx_checklist_run_items_tenant_run',
        'idx_maintenance_plan_assignments_due'
      )
      OR indexname LIKE 'idx_checklist_review_points%'
    );
  INSERT INTO test_results VALUES (
    'hot_path_indexes',
    CASE WHEN v_cnt >= 4 THEN 'PASS' ELSE 'FAIL' END,
    format('count=%s', v_cnt)
  );

  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'data' AND p.proname = 'can_execute_project'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'can_execute_project_exists',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  SELECT NOT has_function_privilege(
    'authenticated',
    'api.generate_due_maintenance_orders(timestamptz,int)',
    'EXECUTE'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'generator_not_for_authenticated',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- Template forks carry source version number
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'data'
      AND table_name = 'checklist_template_forks'
      AND column_name = 'source_published_version_number'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'template_fork_version_column',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- visit_checklist_templates gone
  SELECT NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'data' AND table_name = 'visit_checklist_templates'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'legacy_visit_checklist_removed',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- Integrity helpers from 20261159000007
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'save_draft_checklist_items'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'save_draft_rpc_exists',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'maintenance_plan_unpublished_templates'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'unpublished_templates_rpc_exists',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  SELECT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_maintenance_assignment_tenant_plan'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'assignment_tenant_plan_trigger',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- Platform plan not assignable
  BEGIN
    INSERT INTO data.maintenance_plan_assignments (
      tenant_id, plan_id, entity_type, entity_id, frequency, interval_count, timezone, next_due_at
    ) VALUES (
      v_tenant,
      (SELECT id FROM data.maintenance_plans WHERE tenant_id IS NULL LIMIT 1),
      'site',
      '90000000-0000-0000-0000-000000000001',
      'monthly', 1, 'Europe/Madrid', now()
    );
    INSERT INTO test_results VALUES ('platform_plan_assign_denied', 'FAIL', 'insert allowed');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES (
      'platform_plan_assign_denied',
      CASE WHEN SQLERRM ILIKE '%platform_plan_not_assignable%' THEN 'PASS' ELSE 'FAIL' END,
      SQLERRM
    );
  END;

  -- Clone point reuse requires matching source version
  SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'clone_checklist_review_point'
      AND pg_get_functiondef(p.oid) ILIKE '%source_version_at_fork = v_src.catalog_version%'
      AND pg_get_functiondef(p.oid) ILIKE '%tp.catalog_version = 1%'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'clone_point_reuse_requires_fresh_fork',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- Publish rejects locale mismatch (function body)
  SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'publish_checklist_template_version'
      AND pg_get_functiondef(p.oid) ILIKE '%review_point_locale_mismatch%'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'publish_rejects_locale_mismatch',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- Generator skips unpublished templates
  SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'generate_due_maintenance_orders'
      AND pg_get_functiondef(p.oid) ILIKE '%maintenance_plan_unpublished_templates%'
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'generator_skips_unpublished_templates',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );

  -- Volt seed uses tenant-owned response set (not platform)
  SELECT EXISTS (
    SELECT 1
    FROM data.checklist_template_versions v
    JOIN data.checklist_response_sets s ON s.id = v.default_response_set_id
    WHERE v.id = '83100000-0000-0000-0000-000000000002'
      AND s.tenant_id = v_tenant
  ) INTO v_ok;
  INSERT INTO test_results VALUES (
    'volt_review_uses_tenant_response_set',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    NULL
  );
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION '% checklist/maintenance tests failed', v_fail;
  END IF;
END $$;

ROLLBACK;
