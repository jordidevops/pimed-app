-- CF-16 P1 hardening
-- Serializes every close-out-sensitive mutation on the project row and rejects
-- financial/checklist-answer changes once the visit has been closed locally on
-- the server. The common project lock makes close-out validation atomic with
-- respect to actuals, materials and checklist answers.

CREATE OR REPLACE FUNCTION data.assert_field_project_mutable(p_project_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status text;
BEGIN
  SELECT p.status
  INTO v_status
  FROM data.projects p
  WHERE p.id = p_project_id
  FOR UPDATE;

  -- Cascading deletes can reach child triggers after the parent became
  -- invisible. They must remain possible.
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_status IN ('completed', 'on_hold', 'cancelled') THEN
    RAISE EXCEPTION 'project_already_closed'
      USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_field_project_mutable(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.trg_assert_project_line_mutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_project_id uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.project_id ELSE NEW.project_id END;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.project_id IS DISTINCT FROM OLD.project_id THEN
    RAISE EXCEPTION 'project_line_project_change_forbidden'
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM data.assert_field_project_mutable(v_project_id);
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION data.trg_assert_project_line_mutable() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_project_lines_require_mutable_project
  ON data.project_lines;
CREATE TRIGGER trg_project_lines_require_mutable_project
  BEFORE INSERT OR UPDATE OR DELETE ON data.project_lines
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_assert_project_line_mutable();

CREATE OR REPLACE FUNCTION data.trg_assert_project_material_mutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_project_id uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.project_id ELSE NEW.project_id END;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.project_id IS DISTINCT FROM OLD.project_id THEN
    RAISE EXCEPTION 'project_material_project_change_forbidden'
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM data.assert_field_project_mutable(v_project_id);
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION data.trg_assert_project_material_mutable() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_project_materials_require_mutable_project
  ON data.project_materials;
CREATE TRIGGER trg_project_materials_require_mutable_project
  BEFORE INSERT OR UPDATE OR DELETE ON data.project_materials
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_assert_project_material_mutable();

CREATE OR REPLACE FUNCTION data.trg_assert_checklist_answer_mutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_run_id uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.run_id ELSE NEW.run_id END;
  v_project_id uuid;
BEGIN
  -- Updates to finding resolution/audit metadata remain valid for an on-hold
  -- project. Only answer data participates in close-out blockers.
  IF TG_OP = 'UPDATE'
     AND ROW(
       NEW.value_bool,
       NEW.value_option_id,
       NEW.value_number,
       NEW.value_text,
       NEW.note,
       NEW.answer_label,
       NEW.answer_color_token,
       NEW.answer_semantic,
       NEW.answer_blocks_closeout
     ) IS NOT DISTINCT FROM ROW(
       OLD.value_bool,
       OLD.value_option_id,
       OLD.value_number,
       OLD.value_text,
       OLD.note,
       OLD.answer_label,
       OLD.answer_color_token,
       OLD.answer_semantic,
       OLD.answer_blocks_closeout
     ) THEN
    RETURN NEW;
  END IF;

  SELECT r.project_id
  INTO v_project_id
  FROM data.checklist_runs r
  WHERE r.id = v_run_id;

  IF v_project_id IS NOT NULL THEN
    PERFORM data.assert_field_project_mutable(v_project_id);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION data.trg_assert_checklist_answer_mutable() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_checklist_answers_require_mutable_project
  ON data.checklist_run_items;
CREATE TRIGGER trg_checklist_answers_require_mutable_project
  BEFORE INSERT OR UPDATE OR DELETE ON data.checklist_run_items
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_assert_checklist_answer_mutable();

COMMENT ON FUNCTION data.assert_field_project_mutable(uuid) IS
  'Locks the project row and rejects close-out-sensitive mutations after completed/on_hold/cancelled.';

CREATE OR REPLACE FUNCTION data.trg_require_closed_project_worklogs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status IN ('completed', 'on_hold')
     AND OLD.status NOT IN ('completed', 'on_hold')
     AND EXISTS (
       SELECT 1
       FROM data.work_logs wl
       WHERE wl.project_id = NEW.id
         AND wl.tenant_id = NEW.tenant_id
         AND wl.status = 'open'
     ) THEN
    RAISE EXCEPTION 'open_work_logs_require_stop'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION data.trg_require_closed_project_worklogs() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_projects_require_closed_worklogs
  ON data.projects;
CREATE TRIGGER trg_projects_require_closed_worklogs
  BEFORE UPDATE OF status ON data.projects
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_require_closed_project_worklogs();

-- A replay of an already-created start operation must remain idempotent even
-- if the visit was closed after the original response was lost.
CREATE OR REPLACE FUNCTION api.start_work_log(
  p_client_op_id   uuid,
  p_project_id     uuid,
  p_task_id        uuid        DEFAULT NULL,
  p_check_in       timestamptz DEFAULT now(),
  p_geo            jsonb       DEFAULT NULL,
  p_location_perm  text        DEFAULT 'notrequired',
  p_notes          text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_tenant_id    uuid;
  v_site_id      uuid;
  v_status       text;
  v_published_at timestamptz;
  v_log_id       uuid;
  v_existing_project_id uuid;
  v_anomalies    text[];
  v_employee_id  uuid;
BEGIN
  SELECT p.tenant_id, p.site_id, p.status, p.client_report_published_at
  INTO v_tenant_id, v_site_id, v_status, v_published_at
  FROM data.projects p
  WHERE p.id = p_project_id
    AND data.can_access_project(p_project_id)
  FOR UPDATE;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_project_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT id, project_id INTO v_log_id, v_existing_project_id
  FROM data.work_logs
  WHERE tenant_id = v_tenant_id
    AND client_op_id = p_client_op_id;

  IF v_log_id IS NOT NULL THEN
    IF v_existing_project_id IS DISTINCT FROM p_project_id THEN
      RAISE EXCEPTION 'client_op_id_conflict'
        USING ERRCODE = 'unique_violation';
    END IF;
    RETURN jsonb_build_object(
      'work_log_id', v_log_id,
      'status', 'duplicate'
    );
  END IF;

  IF v_status IN ('completed', 'cancelled', 'on_hold')
     OR v_published_at IS NOT NULL THEN
    RAISE EXCEPTION 'work_log_blocked_visit_closed'
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_site_id IS NULL THEN
    RAISE EXCEPTION
      'El projecte % no té site_id. work_logs requereixen ubicació física.',
      p_project_id
      USING ERRCODE = 'check_violation';
  END IF;

  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);
  v_employee_id := data.resolve_employee_id_for_user(v_tenant_id, v_user_id);

  IF data.is_feature_enabled(v_tenant_id, 'employee_readiness_gate_enabled')
     AND v_employee_id IS NOT NULL THEN
    PERFORM data.assert_employee_dispatch_eligible(
      v_employee_id,
      COALESCE((p_check_in AT TIME ZONE 'UTC')::date, CURRENT_DATE)
    );
  END IF;

  INSERT INTO data.work_logs (
    tenant_id, site_id, project_id, task_id,
    worker_id, employee_id, client_op_id, status,
    check_in, check_in_geo, check_in_received_at,
    location_permission, anomaly_codes, notes
  )
  VALUES (
    v_tenant_id, v_site_id, p_project_id, p_task_id,
    v_user_id, v_employee_id, p_client_op_id, 'open',
    p_check_in, p_geo, now(),
    p_location_perm, v_anomalies, p_notes
  )
  RETURNING id INTO v_log_id;

  PERFORM data.log_audit_event(
    v_tenant_id,
    v_user_id,
    v_site_id,
    'WORK_LOG_STARTED',
    'work_log',
    v_log_id,
    jsonb_build_object(
      'project_id', p_project_id,
      'task_id', p_task_id,
      'employee_id', v_employee_id,
      'check_in', p_check_in,
      'anomaly_codes', v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'work_log_id', v_log_id,
    'status', 'created',
    'employee_id', v_employee_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.start_work_log(
  uuid, uuid, uuid, timestamptz, jsonb, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.start_work_log(
  uuid, uuid, uuid, timestamptz, jsonb, text, text
) TO authenticated, service_role;

-- P2 replacements for an already-applied 00007: unresolved material
-- worklogs fail closed, close-out audit is strict, stop is tenant-scoped
-- with a stop receipt, and transients come back as retryable.
CREATE OR REPLACE FUNCTION data.remember_field_op_receipt(
  p_tenant_id uuid,
  p_client_op_id uuid,
  p_kind text,
  p_project_id uuid,
  p_result_id uuid,
  p_payload jsonb,
  p_actor_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_hash text;
  v_receipt data.field_operation_receipts%ROWTYPE;
BEGIN
  IF p_client_op_id IS NULL THEN
    RETURN;
  END IF;

  v_hash := data.field_op_payload_hash(p_payload);
  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_tenant_id::text || ':' || p_client_op_id::text, 0)
  );

  SELECT * INTO v_receipt
  FROM data.field_operation_receipts
  WHERE tenant_id = p_tenant_id
    AND client_op_id = p_client_op_id;

  IF FOUND THEN
    IF v_receipt.kind IS DISTINCT FROM p_kind
       OR v_receipt.project_id IS DISTINCT FROM p_project_id
       OR v_receipt.payload_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'client_op_id_conflict' USING ERRCODE = 'unique_violation';
    END IF;
    RETURN;
  END IF;

  INSERT INTO data.field_operation_receipts (
    tenant_id, client_op_id, kind, project_id, result_id, payload_hash, actor_id
  ) VALUES (
    p_tenant_id, p_client_op_id, p_kind, p_project_id, p_result_id, v_hash, p_actor_id
  );
END;
$$;

REVOKE ALL ON FUNCTION data.remember_field_op_receipt(
  uuid, uuid, text, uuid, uuid, jsonb, uuid
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.add_project_material_offline(
  p_project_id uuid,
  p_name text,
  p_quantity numeric,
  p_unit text,
  p_work_log_id uuid,
  p_work_log_client_op_id uuid,
  p_client_op_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_project data.projects%ROWTYPE;
  v_receipt data.field_operation_receipts%ROWTYPE;
  v_payload jsonb;
  v_hash text;
  v_material_id uuid;
  v_resolved_work_log_id uuid := p_work_log_id;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'material_name_required' USING ERRCODE = 'check_violation';
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'material_quantity_invalid' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND OR NOT data.can_execute_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_resolved_work_log_id IS NULL AND p_work_log_client_op_id IS NOT NULL THEN
    SELECT id INTO v_resolved_work_log_id
    FROM data.work_logs
    WHERE tenant_id = v_project.tenant_id
      AND project_id = p_project_id
      AND client_op_id = p_work_log_client_op_id;
  END IF;

  IF v_resolved_work_log_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM data.work_logs
    WHERE id = v_resolved_work_log_id
      AND tenant_id = v_project.tenant_id
      AND project_id = p_project_id
  ) THEN
    RAISE EXCEPTION 'work_log_project_mismatch' USING ERRCODE = 'check_violation';
  END IF;

  IF p_work_log_client_op_id IS NOT NULL AND v_resolved_work_log_id IS NULL THEN
    RAISE EXCEPTION 'work_log_dependency_missing' USING ERRCODE = 'check_violation';
  END IF;

  v_payload := jsonb_build_object(
    'project_id', p_project_id,
    'name', btrim(p_name),
    'quantity', p_quantity,
    'unit', NULLIF(btrim(COALESCE(p_unit, '')), ''),
    'work_log_id', p_work_log_id,
    'work_log_client_op_id', p_work_log_client_op_id
  );
  v_hash := data.field_op_payload_hash(v_payload);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_project.tenant_id::text || ':' || p_client_op_id::text, 0));

  SELECT * INTO v_receipt
  FROM data.field_operation_receipts
  WHERE tenant_id = v_project.tenant_id
    AND client_op_id = p_client_op_id;

  IF FOUND THEN
    IF v_receipt.kind IS DISTINCT FROM 'project_material.add'
       OR v_receipt.project_id IS DISTINCT FROM p_project_id
       OR v_receipt.payload_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'client_op_id_conflict' USING ERRCODE = 'unique_violation';
    END IF;
    RETURN jsonb_build_object(
      'status', 'duplicate',
      'result_id', v_receipt.result_id
    );
  END IF;

  IF v_project.status IN ('completed', 'on_hold', 'cancelled') THEN
    RAISE EXCEPTION 'project_already_closed' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.project_materials (
    tenant_id, project_id, work_log_id, name, quantity, unit,
    created_by, client_op_id
  ) VALUES (
    v_project.tenant_id, p_project_id, v_resolved_work_log_id,
    btrim(p_name), p_quantity, NULLIF(btrim(COALESCE(p_unit, '')), ''),
    v_uid, p_client_op_id
  )
  RETURNING id INTO v_material_id;

  INSERT INTO data.field_operation_receipts (
    tenant_id, client_op_id, kind, project_id, result_id,
    payload_hash, actor_id
  ) VALUES (
    v_project.tenant_id, p_client_op_id, 'project_material.add',
    p_project_id, v_material_id, v_hash, v_uid
  );

  RETURN jsonb_build_object('status', 'created', 'result_id', v_material_id);
END;
$$;

REVOKE ALL ON FUNCTION data.add_project_material_offline(
  uuid, text, numeric, text, uuid, uuid, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.add_project_material_offline(
  uuid, text, numeric, text, uuid, uuid, uuid
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.add_project_material(
  p_project_id uuid,
  p_name text,
  p_quantity numeric DEFAULT 1,
  p_unit text DEFAULT NULL,
  p_work_log_id uuid DEFAULT NULL,
  p_work_log_client_op_id uuid DEFAULT NULL,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT data.add_project_material_offline(
    p_project_id, p_name, p_quantity, p_unit,
    p_work_log_id, p_work_log_client_op_id, p_client_op_id
  );
$$;

REVOKE ALL ON FUNCTION api.add_project_material(
  uuid, text, numeric, text, uuid, uuid, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.add_project_material(
  uuid, text, numeric, text, uuid, uuid, uuid
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.complete_project_close_out_offline(
  p_project_id uuid,
  p_client_op_id uuid,
  p_bypass_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_project data.projects%ROWTYPE;
  v_receipt data.field_operation_receipts%ROWTYPE;
  v_payload jsonb;
  v_hash text;
  v_blockers jsonb;
  v_role text;
  v_target_status text;
  v_is_consumer boolean;
  v_total numeric(14,2);
  v_has_deferred boolean;
  v_has_follow_up boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_project
  FROM data.projects
  WHERE id = p_project_id
  FOR UPDATE;

  IF NOT FOUND OR NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_payload := jsonb_build_object(
    'project_id', p_project_id,
    'bypass_reason', NULLIF(btrim(COALESCE(p_bypass_reason, '')), '')
  );
  v_hash := data.field_op_payload_hash(v_payload);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_project.tenant_id::text || ':' || p_client_op_id::text, 0));

  SELECT * INTO v_receipt
  FROM data.field_operation_receipts
  WHERE tenant_id = v_project.tenant_id
    AND client_op_id = p_client_op_id;

  IF FOUND THEN
    IF v_receipt.kind IS DISTINCT FROM 'project.close_out'
       OR v_receipt.project_id IS DISTINCT FROM p_project_id
       OR v_receipt.payload_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'client_op_id_conflict' USING ERRCODE = 'unique_violation';
    END IF;
    RETURN jsonb_build_object(
      'status', 'duplicate',
      'result_id', v_receipt.result_id,
      'project_status', v_project.status
    );
  END IF;

  IF v_project.status IN ('completed', 'on_hold', 'cancelled') THEN
    RAISE EXCEPTION 'already_closed' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT data.can_execute_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_executable' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_blockers := api.checklist_closeout_blockers(p_project_id);
  IF jsonb_array_length(COALESCE(v_blockers, '[]'::jsonb)) > 0 THEN
    IF NULLIF(btrim(COALESCE(p_bypass_reason, '')), '') IS NULL THEN
      RAISE EXCEPTION 'closeout_blocked:%', v_blockers::text
        USING ERRCODE = 'check_violation';
    END IF;
    v_role := data.jwt_user_tenants() -> v_project.tenant_id::text ->> 'global_role';
    IF v_role NOT IN ('owner', 'manager') THEN
      RAISE EXCEPTION 'closeout_bypass_forbidden'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  SELECT COALESCE(c.is_consumer, c.kind = 'person', true)
  INTO v_is_consumer
  FROM data.contacts c
  WHERE c.id = v_project.client_id
    AND c.tenant_id = v_project.tenant_id;

  SELECT COALESCE(SUM(
    ROUND(
      data.line_net(pl.quantity, pl.unit_price, pl.discount_pct)
        * (1 + pl.tax_rate / 100.0),
      2
    )
  ), 0)
  INTO v_total
  FROM data.project_lines pl
  WHERE pl.project_id = p_project_id
    AND pl.tenant_id = v_project.tenant_id;

  IF COALESCE(v_is_consumer, true)
     AND v_total > COALESCE(v_project.authorized_total, 0) + 0.009 THEN
    RAISE EXCEPTION 'consumer_overage_requires_amendment'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM data.checklist_runs r
    JOIN data.checklist_run_items i ON i.run_id = r.id
    WHERE r.project_id = p_project_id
      AND r.status IS DISTINCT FROM 'superseded'
      AND (i.answer_semantic = 'fail' OR COALESCE(i.answer_blocks_closeout, false))
      AND i.resolution_status = 'deferred'
  ) INTO v_has_deferred;

  SELECT EXISTS (
    SELECT 1
    FROM data.projects fp
    WHERE fp.source_project_id = p_project_id
      AND fp.status IS DISTINCT FROM 'cancelled'
  ) INTO v_has_follow_up;

  v_target_status := CASE
    WHEN v_has_deferred AND NOT v_has_follow_up THEN 'on_hold'
    ELSE 'completed'
  END;

  UPDATE data.projects
  SET status = v_target_status, updated_at = now()
  WHERE id = p_project_id;

  INSERT INTO data.field_operation_receipts (
    tenant_id, client_op_id, kind, project_id, result_id,
    payload_hash, actor_id
  ) VALUES (
    v_project.tenant_id, p_client_op_id, 'project.close_out',
    p_project_id, p_project_id, v_hash, v_uid
  );

  PERFORM data.log_audit_event_strict(
    v_project.tenant_id,
    v_uid,
    v_project.site_id,
    'PROJECT_CLOSE_OUT_COMPLETED',
    'project',
    p_project_id,
    jsonb_build_object(
      'status', v_target_status,
      'client_op_id', p_client_op_id,
      'bypass_reason', NULLIF(btrim(COALESCE(p_bypass_reason, '')), '')
    )
  );

  RETURN jsonb_build_object(
    'status', 'synced',
    'result_id', p_project_id,
    'project_status', v_target_status
  );
END;
$$;

REVOKE ALL ON FUNCTION data.complete_project_close_out_offline(uuid, uuid, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.complete_project_close_out_offline(uuid, uuid, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.complete_project_close_out(
  p_project_id uuid,
  p_client_op_id uuid,
  p_bypass_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT data.complete_project_close_out_offline(
    p_project_id, p_client_op_id, p_bypass_reason
  );
$$;

REVOKE ALL ON FUNCTION api.complete_project_close_out(uuid, uuid, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.complete_project_close_out(uuid, uuid, text)
  TO authenticated, service_role;

-- A stop retry for a log already closed by the same worker is a duplicate,
-- not a permanent rejection. Resolution is tenant-scoped so a reused start
-- client_op_id in another tenant cannot close the wrong log.
DROP FUNCTION IF EXISTS api.stop_work_log(uuid, uuid, timestamptz, jsonb, text, boolean, text);

CREATE OR REPLACE FUNCTION api.stop_work_log(
  p_log_id         uuid        DEFAULT NULL,
  p_client_op_id   uuid        DEFAULT NULL,
  p_check_out      timestamptz DEFAULT now(),
  p_geo            jsonb       DEFAULT NULL,
  p_location_perm  text        DEFAULT 'notrequired',
  p_close_task     boolean     DEFAULT false,
  p_notes          text        DEFAULT NULL,
  p_stop_op_id     uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_tenant_id uuid := data.active_tenant_id();
  v_resolved_id uuid := p_log_id;
  v_match_count int := 0;
  v_log data.work_logs%ROWTYPE;
  v_anomalies text[];
  v_duration_min int;
  v_status text;
BEGIN
  IF v_resolved_id IS NULL AND p_client_op_id IS NOT NULL THEN
    SELECT COUNT(*)
    INTO v_match_count
    FROM data.work_logs wl
    WHERE wl.client_op_id = p_client_op_id
      AND wl.worker_id = v_user_id
      AND (v_tenant_id IS NULL OR wl.tenant_id = v_tenant_id);
    IF COALESCE(v_match_count, 0) > 1 THEN
      RAISE EXCEPTION 'work_log_ambiguous'
        USING ERRCODE = 'unique_violation';
    END IF;
    SELECT wl.id
    INTO v_resolved_id
    FROM data.work_logs wl
    WHERE wl.client_op_id = p_client_op_id
      AND wl.worker_id = v_user_id
      AND (v_tenant_id IS NULL OR wl.tenant_id = v_tenant_id)
    LIMIT 1;
  END IF;
  IF v_resolved_id IS NULL THEN
    RAISE EXCEPTION 'work_log_reference_required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_log
  FROM data.work_logs
  WHERE id = v_resolved_id
    AND worker_id = v_user_id
    AND (v_tenant_id IS NULL OR tenant_id = v_tenant_id)
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'work_log_not_found_or_forbidden'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_log.status = 'closed' THEN
    v_status := 'duplicate';
    v_duration_min := GREATEST(
      0,
      EXTRACT(EPOCH FROM (v_log.check_out - v_log.check_in))::int / 60
    );
  ELSIF v_log.status <> 'open' THEN
    RAISE EXCEPTION 'work_log_not_open' USING ERRCODE = 'check_violation';
  ELSE
    v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);
    SELECT ARRAY(SELECT DISTINCT unnest(v_log.anomaly_codes || v_anomalies))
    INTO v_anomalies;
    v_duration_min := GREATEST(
      0,
      EXTRACT(EPOCH FROM (p_check_out - v_log.check_in))::int / 60
    );

    UPDATE data.work_logs SET
      status = 'closed',
      check_out = p_check_out,
      check_out_geo = p_geo,
      check_out_received_at = now(),
      anomaly_codes = v_anomalies,
      notes = COALESCE(p_notes, notes),
      updated_at = now()
    WHERE id = v_resolved_id;

    IF p_close_task AND v_log.task_id IS NOT NULL THEN
      UPDATE data.tasks SET status = 'done', updated_at = now()
      WHERE id = v_log.task_id;
    END IF;

    PERFORM data.log_audit_event(
      v_log.tenant_id, v_user_id, v_log.site_id,
      'WORK_LOG_STOPPED', 'work_log', v_resolved_id,
      jsonb_build_object(
        'project_id', v_log.project_id,
        'task_id', v_log.task_id,
        'check_out', p_check_out,
        'duration_min', v_duration_min,
        'anomaly_codes', v_anomalies,
        'task_closed', p_close_task AND v_log.task_id IS NOT NULL
      )
    );
    v_status := 'synced';
  END IF;

  PERFORM data.remember_field_op_receipt(
    v_log.tenant_id,
    p_stop_op_id,
    'worklog.stop',
    v_log.project_id,
    v_resolved_id,
    jsonb_build_object(
      'project_id', v_log.project_id,
      'work_log_id', v_resolved_id,
      'start_client_op_id', v_log.client_op_id
    ),
    v_user_id
  );

  RETURN jsonb_build_object(
    'work_log_id', v_resolved_id,
    'duration_minutes', v_duration_min,
    'status', v_status
  );
END;
$$;

REVOKE ALL ON FUNCTION api.stop_work_log(
  uuid, uuid, timestamptz, jsonb, text, boolean, text, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.stop_work_log(
  uuid, uuid, timestamptz, jsonb, text, boolean, text, uuid
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.sync_field_ops(p_batch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_op jsonb;
  v_kind text;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF jsonb_typeof(p_batch) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_batch) > 100 THEN
    RAISE EXCEPTION 'invalid_field_ops_batch' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOR v_op IN SELECT value FROM jsonb_array_elements(p_batch)
  LOOP
    v_kind := v_op->>'kind';
    BEGIN
      IF v_kind = 'worklog.start' THEN
        v_result := api.start_work_log(
          p_client_op_id => (v_op->>'id')::uuid,
          p_project_id => (v_op->'payload'->>'project_id')::uuid,
          p_task_id => (v_op->'payload'->>'task_id')::uuid,
          p_check_in => (v_op->'payload'->>'occurred_at')::timestamptz,
          p_geo => v_op->'payload'->'geo',
          p_location_perm => COALESCE(v_op->'payload'->>'location_permission', 'notrequired'),
          p_notes => v_op->'payload'->>'notes'
        );
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status', v_result->>'status',
          'server_id', v_result->>'work_log_id',
          'message', NULL
        ));
      ELSIF v_kind = 'worklog.stop' THEN
        v_result := api.stop_work_log(
          p_log_id => (v_op->'payload'->>'work_log_id')::uuid,
          p_client_op_id => (v_op->'payload'->>'client_op_id')::uuid,
          p_check_out => (v_op->'payload'->>'occurred_at')::timestamptz,
          p_geo => v_op->'payload'->'geo',
          p_location_perm => COALESCE(v_op->'payload'->>'location_permission', 'notrequired'),
          p_close_task => COALESCE((v_op->'payload'->>'close_task')::boolean, false),
          p_notes => v_op->'payload'->>'notes',
          p_stop_op_id => (v_op->>'id')::uuid
        );
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status', COALESCE(v_result->>'status', 'synced'),
          'server_id', v_result->>'work_log_id',
          'message', NULL
        ));
      ELSIF v_kind = 'project_line.actual' THEN
        v_result := api.set_project_line_actual_quantity(
          p_project_id => (v_op->'payload'->>'project_id')::uuid,
          p_line_id => (v_op->'payload'->>'line_id')::uuid,
          p_unit => v_op->'payload'->>'unit',
          p_quantity => (v_op->'payload'->>'quantity')::numeric,
          p_client_op_id => (v_op->>'id')::uuid
        );
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status', v_result->>'status',
          'server_id', v_result->>'result_id',
          'message', NULL
        ));
      ELSIF v_kind = 'project_material.add' THEN
        v_result := api.add_project_material(
          p_project_id => (v_op->'payload'->>'project_id')::uuid,
          p_name => v_op->'payload'->>'name',
          p_quantity => (v_op->'payload'->>'quantity')::numeric,
          p_unit => v_op->'payload'->>'unit',
          p_work_log_id => (v_op->'payload'->>'work_log_id')::uuid,
          p_work_log_client_op_id => (v_op->'payload'->>'work_log_client_op_id')::uuid,
          p_client_op_id => (v_op->>'id')::uuid
        );
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status', v_result->>'status',
          'server_id', v_result->>'result_id',
          'message', NULL
        ));
      ELSIF v_kind = 'project.close_out' THEN
        v_result := api.complete_project_close_out(
          p_project_id => (v_op->'payload'->>'project_id')::uuid,
          p_client_op_id => (v_op->>'id')::uuid,
          p_bypass_reason => v_op->'payload'->>'bypass_reason'
        );
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status', v_result->>'status',
          'server_id', v_result->>'result_id',
          'message', NULL
        ));
      ELSE
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status', 'rejected',
          'server_id', NULL,
          'message', 'unknown_kind:' || COALESCE(v_kind, 'null')
        ));
      END IF;
    EXCEPTION
      WHEN deadlock_detected OR serialization_failure THEN
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status', 'retryable',
          'server_id', NULL,
          'message', SQLERRM
        ));
      WHEN unique_violation THEN
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status', CASE
            WHEN SQLERRM ILIKE '%client_op_id_conflict%' THEN 'rejected'
            ELSE 'retryable'
          END,
          'server_id', NULL,
          'message', SQLERRM
        ));
      WHEN OTHERS THEN
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status', CASE
            WHEN SQLSTATE LIKE '08%'
              OR SQLSTATE LIKE '53%'
              OR SQLSTATE IN ('55P03', '57014') THEN 'retryable'
            ELSE 'rejected'
          END,
          'server_id', NULL,
          'message', SQLERRM
        ));
    END;
  END LOOP;
  RETURN v_results;
END;
$$;

REVOKE ALL ON FUNCTION api.sync_field_ops(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.sync_field_ops(jsonb)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

