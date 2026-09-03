-- EP-ACC-3b+: ack batch — purge anticipat de secrets quan el manager confirma descàrrega.

-- -----------------------------------------------------------------------------
-- 1. Auditoria: acció batch_ack
-- -----------------------------------------------------------------------------

ALTER TABLE data.employee_portal_access_logs
  DROP CONSTRAINT IF EXISTS employee_portal_access_logs_action_check;

ALTER TABLE data.employee_portal_access_logs
  ADD CONSTRAINT employee_portal_access_logs_action_check CHECK (action IN (
    'view_schedule',
    'view_history',
    'view_monthly_report',
    'monthly_confirm',
    'period_confirm',
    'view_access_logs',
    'request_absence',
    'push_subscribe',
    'punch_in',
    'punch_out',
    'pause_start',
    'pause_end',
    'pin_failed',
    'pin_locked',
    'pin_setup',
    'pin_changed',
    'pin_reset',
    'batch_start',
    'batch_fetch',
    'batch_ack',
    'token_invalid',
    'token_expired',
    'session_create',
    'session_refresh'
  ));

-- -----------------------------------------------------------------------------
-- 2. fetch: rebutjar lots expirats/ack (abans de batch_not_completed)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.fetch_employee_portal_token_batch_results(p_batch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_job record;
  v_rows jsonb;
  v_audit_token uuid;
  v_audit_employee uuid;
BEGIN
  SELECT *
  INTO v_job
  FROM data.employee_portal_token_batch_jobs j
  WHERE j.id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'batch_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    v_job.created_by = auth.uid()
    OR data.jwt_has_permission(v_job.tenant_id, 'attendance.manage', NULL)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_job.status = 'expired' OR v_job.expires_at <= now() THEN
    RAISE EXCEPTION 'batch_expired' USING ERRCODE = 'check_violation';
  END IF;

  IF v_job.status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'batch_not_completed' USING ERRCODE = 'check_violation';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'employee_id', i.employee_id,
      'employee_name', i.employee_name,
      'employee_code', i.employee_code,
      'status', i.status,
      'error_code', i.error_code,
      'portal_url', CASE WHEN i.status = 'created' THEN i.portal_url ELSE NULL END,
      'secret', CASE WHEN i.status = 'created' THEN i.secret_plaintext ELSE NULL END,
      'token_id', i.token_id,
      'superseded_token_id', i.superseded_token_id,
      'label', i.label
    )
    ORDER BY i.employee_name NULLS LAST, i.employee_id
  )
  INTO v_rows
  FROM data.employee_portal_token_batch_items i
  WHERE i.batch_job_id = p_batch_id;

  UPDATE data.employee_portal_token_batch_jobs
  SET last_fetched_at = now(),
      fetch_count = fetch_count + 1
  WHERE id = p_batch_id;

  SELECT i.token_id, i.employee_id
  INTO v_audit_token, v_audit_employee
  FROM data.employee_portal_token_batch_items i
  WHERE i.batch_job_id = p_batch_id
    AND i.status = 'created'
    AND i.token_id IS NOT NULL
  ORDER BY i.created_at ASC
  LIMIT 1;

  IF v_audit_token IS NOT NULL THEN
    INSERT INTO data.employee_portal_access_logs (
      token_id, employee_id, tenant_id, action, metadata
    ) VALUES (
      v_audit_token,
      v_audit_employee,
      v_job.tenant_id,
      'batch_fetch',
      jsonb_build_object(
        'batch_job_id', p_batch_id,
        'fetch_count', v_job.fetch_count + 1
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'batch_id', p_batch_id,
    'expires_at', v_job.expires_at,
    'shared_device', v_job.shared_device,
    'rows', COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. RPC: ack batch (purge secrets + marcar expired)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.ack_employee_portal_token_batch(p_batch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_job record;
  v_audit_token uuid;
  v_audit_employee uuid;
  v_already boolean := false;
BEGIN
  SELECT *
  INTO v_job
  FROM data.employee_portal_token_batch_jobs j
  WHERE j.id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'batch_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    v_job.created_by = auth.uid()
    OR data.jwt_has_permission(v_job.tenant_id, 'attendance.manage', NULL)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_job.status = 'expired' THEN
    v_already := true;
  ELSIF v_job.status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'batch_not_completed' USING ERRCODE = 'check_violation';
  ELSE
    UPDATE data.employee_portal_token_batch_items
    SET secret_plaintext = NULL,
        portal_url = NULL
    WHERE batch_job_id = p_batch_id;

    UPDATE data.employee_portal_token_batch_jobs
    SET status = 'expired'
    WHERE id = p_batch_id;

    SELECT i.token_id, i.employee_id
    INTO v_audit_token, v_audit_employee
    FROM data.employee_portal_token_batch_items i
    WHERE i.batch_job_id = p_batch_id
      AND i.status = 'created'
      AND i.token_id IS NOT NULL
    ORDER BY i.created_at ASC
    LIMIT 1;

    IF v_audit_token IS NOT NULL THEN
      INSERT INTO data.employee_portal_access_logs (
        token_id, employee_id, tenant_id, action, metadata
      ) VALUES (
        v_audit_token,
        v_audit_employee,
        v_job.tenant_id,
        'batch_ack',
        jsonb_build_object(
          'batch_job_id', p_batch_id,
          'fetch_count', v_job.fetch_count
        )
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'batch_id', p_batch_id,
    'status', 'expired',
    'already_acked', v_already
  );
END;
$$;

COMMENT ON FUNCTION api.ack_employee_portal_token_batch IS
  'Confirma descàrrega d''un lot batch: purga secrets/URLs recuperables i marca el job expired. Idempotent si ja ack.';

GRANT EXECUTE ON FUNCTION api.ack_employee_portal_token_batch(uuid) TO authenticated;
