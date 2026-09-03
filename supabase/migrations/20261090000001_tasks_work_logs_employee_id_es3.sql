-- =============================================================================
-- ES-3 — Desacoblament tasks/work_logs → employee_id (additiu + dual-write)
-- M-ES-07
--
-- - data.tasks.assignee_employee_id (nou)
-- - data.work_logs.employee_id ja existeix (Track G); re-backfill + dual-write
-- - Helper resolve user→employee
-- - Triggers dual-write (tasks + work_logs safety net)
-- - api.start_work_log escriu employee_id
-- - Vistes api.tasks / api.work_logs exposen columnes noves
-- NO elimina assignee_id / worker_id (retirada = fase posterior)
-- =============================================================================

-- ─── 1. Helper ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.resolve_employee_id_for_user(
  p_tenant_id uuid,
  p_user_id   uuid
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT e.id
  FROM data.employees e
  WHERE e.tenant_id = p_tenant_id
    AND e.user_id = p_user_id
    AND e.status <> 'terminated'
  ORDER BY e.created_at ASC
  LIMIT 1;
$$;

COMMENT ON FUNCTION data.resolve_employee_id_for_user(uuid, uuid) IS
  'ES-3: resol employees.id des de profiles/auth user_id dins el tenant (exclou terminated).';

REVOKE ALL ON FUNCTION data.resolve_employee_id_for_user(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.resolve_employee_id_for_user(uuid, uuid) TO service_role;
-- Intern: cridat des de triggers/RPCs SECURITY DEFINER; authenticated no cal GRANT.

-- ─── 2. DDL tasks.assignee_employee_id ───────────────────────────────────────

ALTER TABLE data.tasks
  ADD COLUMN IF NOT EXISTS assignee_employee_id uuid
    REFERENCES data.employees(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_tasks_assignee_employee_id
  ON data.tasks (assignee_employee_id)
  WHERE assignee_employee_id IS NOT NULL;

COMMENT ON COLUMN data.tasks.assignee_employee_id IS
  'ES-3 dual-write: FK a employees. assignee_id (profiles) es manté fins retirada.';

-- work_logs.employee_id ja existeix; assegurem índex
CREATE INDEX IF NOT EXISTS idx_work_logs_employee_date
  ON data.work_logs (employee_id, check_in DESC)
  WHERE employee_id IS NOT NULL;

COMMENT ON COLUMN data.work_logs.employee_id IS
  'ES-3 dual-write: FK a employees. worker_id (profiles) es manté fins retirada.';

-- ─── 3. Backfill + report ────────────────────────────────────────────────────

UPDATE data.work_logs wl
SET employee_id = e.id
FROM data.employees e
WHERE wl.employee_id IS NULL
  AND e.user_id = wl.worker_id
  AND e.tenant_id = wl.tenant_id;

UPDATE data.tasks t
SET assignee_employee_id = e.id
FROM data.employees e
WHERE t.assignee_employee_id IS NULL
  AND t.assignee_id IS NOT NULL
  AND e.user_id = t.assignee_id
  AND e.tenant_id = t.tenant_id;

DO $$
DECLARE
  v_wl_total     int;
  v_wl_mapped    int;
  v_wl_unmapped  int;
  v_t_with_user  int;
  v_t_mapped     int;
  v_t_unmapped   int;
BEGIN
  SELECT count(*) INTO v_wl_total FROM data.work_logs;
  SELECT count(*) INTO v_wl_mapped FROM data.work_logs WHERE employee_id IS NOT NULL;
  SELECT count(*) INTO v_wl_unmapped FROM data.work_logs WHERE employee_id IS NULL;

  SELECT count(*) INTO v_t_with_user
  FROM data.tasks WHERE assignee_id IS NOT NULL;
  SELECT count(*) INTO v_t_mapped
  FROM data.tasks WHERE assignee_employee_id IS NOT NULL;
  SELECT count(*) INTO v_t_unmapped
  FROM data.tasks
  WHERE assignee_id IS NOT NULL AND assignee_employee_id IS NULL;

  RAISE NOTICE
    'ES-3 backfill work_logs: total=% mapped=% unmapped=%',
    v_wl_total, v_wl_mapped, v_wl_unmapped;
  RAISE NOTICE
    'ES-3 backfill tasks: with_assignee=% mapped=% unmapped_no_employee=%',
    v_t_with_user, v_t_mapped, v_t_unmapped;
END;
$$;

-- ─── 4. Triggers dual-write ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.trg_tasks_sync_assignee_employee()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.assignee_id IS NULL THEN
    NEW.assignee_employee_id := NULL;
  ELSIF TG_OP = 'INSERT'
     OR NEW.assignee_id IS DISTINCT FROM OLD.assignee_id
     OR NEW.assignee_employee_id IS NULL THEN
    NEW.assignee_employee_id :=
      data.resolve_employee_id_for_user(NEW.tenant_id, NEW.assignee_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tasks_sync_assignee_employee ON data.tasks;
CREATE TRIGGER trg_tasks_sync_assignee_employee
  BEFORE INSERT OR UPDATE OF assignee_id, assignee_employee_id ON data.tasks
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_tasks_sync_assignee_employee();

CREATE OR REPLACE FUNCTION data.trg_work_logs_sync_employee()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  -- Només omple si manca; no sobrescriu un employee_id ja posat (field_punch).
  IF NEW.employee_id IS NULL AND NEW.worker_id IS NOT NULL THEN
    NEW.employee_id :=
      data.resolve_employee_id_for_user(NEW.tenant_id, NEW.worker_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_logs_sync_employee ON data.work_logs;
CREATE TRIGGER trg_work_logs_sync_employee
  BEFORE INSERT OR UPDATE OF worker_id, employee_id ON data.work_logs
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_work_logs_sync_employee();

-- ─── 5. start_work_log: dual-write explícit + gate amb mateix resolve ─────────

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
SET search_path = data, api
AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_tenant_id    uuid;
  v_site_id      uuid;
  v_log_id       uuid;
  v_anomalies    text[];
  v_employee_id  uuid;
BEGIN
  SELECT p.tenant_id, p.site_id
    INTO v_tenant_id, v_site_id
  FROM data.projects p
  WHERE p.id = p_project_id
    AND data.can_access_project(p_project_id);

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_project_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_site_id IS NULL THEN
    RAISE EXCEPTION
      'El projecte % no té site_id. work_logs requereixen ubicació física.',
      p_project_id
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT id INTO v_log_id
  FROM data.work_logs
  WHERE tenant_id    = v_tenant_id
    AND client_op_id = p_client_op_id;

  IF v_log_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'work_log_id', v_log_id,
      'status',      'duplicate'
    );
  END IF;

  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);

  -- ES-3: sempre resol employee_id quan hi ha mapping (dual-write)
  v_employee_id := data.resolve_employee_id_for_user(v_tenant_id, v_user_id);

  -- ES-1 pilot: gate opcional (flag off = zero regressió)
  IF data.is_feature_enabled(v_tenant_id, 'employee_readiness_gate_enabled') THEN
    -- Sense mapping user→employee: no es bloqueja (empleats sense compte)
    IF v_employee_id IS NOT NULL THEN
      PERFORM data.assert_employee_dispatch_eligible(
        v_employee_id,
        COALESCE((p_check_in AT TIME ZONE 'UTC')::date, CURRENT_DATE)
      );
    END IF;
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
      'project_id',    p_project_id,
      'task_id',       p_task_id,
      'employee_id',   v_employee_id,
      'check_in',      p_check_in,
      'anomaly_codes', v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'work_log_id', v_log_id,
    'status',      'created',
    'employee_id', v_employee_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.start_work_log(uuid, uuid, uuid, timestamptz, jsonb, text, text)
  TO authenticated;

-- ─── 6. Vistes API ───────────────────────────────────────────────────────────

-- Columnes noves al FINAL (CREATE OR REPLACE no pot inserir al mig)
CREATE OR REPLACE VIEW api.tasks
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    project_id,
    title,
    status,
    assignee_id,
    position,
    due_date,
    created_at,
    updated_at,
    assignee_employee_id
  FROM data.tasks;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.tasks TO authenticated;

CREATE OR REPLACE VIEW api.work_logs
  WITH (security_invoker = true) AS
  SELECT
    wl.id,
    wl.tenant_id,
    wl.site_id,
    wl.project_id,
    wl.task_id,
    wl.worker_id,
    wl.client_op_id,
    wl.status,
    wl.check_in,
    wl.check_out,
    wl.check_in_geo,
    wl.check_out_geo,
    wl.check_in_received_at,
    wl.check_out_received_at,
    wl.location_permission,
    wl.anomaly_codes,
    wl.notes,
    wl.created_at,
    wl.updated_at,
    CASE
      WHEN wl.check_out IS NOT NULL
      THEN EXTRACT(EPOCH FROM (wl.check_out - wl.check_in))::int / 60
      ELSE NULL
    END AS duration_minutes,
    wl.employee_id,
    wl.entry_mode,
    wl.time_punch_in_id,
    wl.time_punch_out_id
  FROM data.work_logs wl;

GRANT SELECT ON api.work_logs TO authenticated;

NOTIFY pgrst, 'reload schema';
