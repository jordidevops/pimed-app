-- =============================================================================
-- Migration: 20260511000002_bulk_task_status.sql
--
-- Pas 6: api.bulk_update_task_status
--
-- Permet actualitzar l'estat de múltiples tasques en una sola crida RPC.
-- Filtre per tenant_id garanteix aïllament multi-tenant (no cross-tenant).
-- Retorna (updated_count, skipped_count) per feedback precís al frontend.
-- L'auditoria queda coberta pel trigger TASK_STATUS_CHANGED existent sobre data.tasks.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.bulk_update_task_status(
  p_task_ids   uuid[],
  p_new_status text,
  p_tenant_id  uuid
)
RETURNS TABLE(updated_count int, skipped_count int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_user_id     uuid := auth.uid();
  v_global_role text;
  v_updated     int := 0;
  v_total       int;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- NULL-safe: owner o manager global del tenant
  v_global_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_global_role IS NULL OR v_global_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden: cal ser owner o manager per actualitzar tasques en bloc'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validar que l'array no és buit
  IF p_task_ids IS NULL OR array_length(p_task_ids, 1) IS NULL THEN
    RETURN QUERY SELECT 0, 0;
    RETURN;
  END IF;

  -- Validar status
  IF p_new_status NOT IN ('pending', 'in_progress', 'done', 'blocked') THEN
    RAISE EXCEPTION 'invalid_task_status: %', p_new_status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_total := array_length(p_task_ids, 1);

  -- Update: filtre per tenant_id garanteix aïllament cross-tenant
  -- Skipped: tasques que ja tenien l'estat (status <> p_new_status)
  WITH updated AS (
    UPDATE data.tasks
    SET status = p_new_status
    WHERE id = ANY(p_task_ids)
      AND tenant_id = p_tenant_id
      AND status <> p_new_status
    RETURNING id
  )
  SELECT COUNT(*) INTO v_updated FROM updated;

  RETURN QUERY SELECT v_updated, GREATEST(v_total - v_updated, 0);
END;
$$;

REVOKE ALL ON FUNCTION api.bulk_update_task_status(uuid[], text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.bulk_update_task_status(uuid[], text, uuid) TO authenticated;

COMMENT ON FUNCTION api.bulk_update_task_status(uuid[], text, uuid) IS
  'Actualitza l''estat de múltiples tasques en una sola operació.
   Autorització: owner/manager global (NULL-safe).
   Skipped: tasques que ja tenien l''estat o no pertanyen al tenant.
   Auditoria: trigger TASK_STATUS_CHANGED sobre data.tasks.';

NOTIFY pgrst, 'reload schema';
