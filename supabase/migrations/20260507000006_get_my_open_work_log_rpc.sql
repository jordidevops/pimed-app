-- =============================================================================
-- Migration: 20260507000006_get_my_open_work_log_rpc.sql
-- Propòsit : Exposar lectura segura del work_log obert de l'usuari autenticat
--            sense requerir SELECT directe sobre data.work_logs.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_my_open_work_log(
  p_project_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_row data.work_logs%ROWTYPE;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = '28000';
  END IF;

  -- L'usuari ha de poder accedir al projecte.
  IF NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_project_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT wl.*
    INTO v_row
  FROM data.work_logs wl
  WHERE wl.project_id = p_project_id
    AND wl.worker_id = v_user_id
    AND wl.status = 'open'
  ORDER BY wl.check_in DESC
  LIMIT 1;

  IF v_row.id IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'check_in', v_row.check_in,
    'client_op_id', v_row.client_op_id,
    'status', v_row.status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_my_open_work_log(uuid) TO authenticated;

COMMENT ON FUNCTION api.get_my_open_work_log(uuid) IS
  'Retorna el work_log obert de l''usuari autenticat per projecte. '
  'Lectura via SECURITY DEFINER per evitar SELECT directe sobre data.work_logs.';

NOTIFY pgrst, 'reload schema';
