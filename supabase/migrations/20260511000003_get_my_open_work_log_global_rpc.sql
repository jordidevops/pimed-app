-- =============================================================================
-- Migration: 20260511000003_get_my_open_work_log_global_rpc.sql
-- Propòsit : Exposar lectura segura del work_log obert de l'usuari autenticat
--            a qualsevol projecte accessible (tenant actiu).
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_my_open_work_log_global()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_row record;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = '28000';
  END IF;

  SELECT
    wl.id,
    wl.project_id,
    p.name AS project_name,
    wl.check_in,
    wl.client_op_id,
    wl.status
  INTO v_row
  FROM data.work_logs wl
  JOIN data.projects p ON p.id = wl.project_id
  WHERE wl.worker_id = v_user_id
    AND wl.status = 'open'
    AND data.can_access_project(wl.project_id)
  ORDER BY wl.check_in DESC
  LIMIT 1;

  IF v_row.id IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'project_id', v_row.project_id,
    'project_name', v_row.project_name,
    'check_in', v_row.check_in,
    'client_op_id', v_row.client_op_id,
    'status', v_row.status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_my_open_work_log_global() TO authenticated;

COMMENT ON FUNCTION api.get_my_open_work_log_global() IS
  'Retorna el work_log obert més recent de l''usuari autenticat dins del tenant actiu (projecte inclòs).';

NOTIFY pgrst, 'reload schema';
