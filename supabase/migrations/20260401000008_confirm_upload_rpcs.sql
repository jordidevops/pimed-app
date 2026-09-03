-- =============================================================================
-- Migration 8: confirm-upload RPCs
-- =============================================================================
-- Two privileged RPCs called exclusively by the confirm-upload Edge Function
-- acting as service_role.  End users (authenticated / anon) can never call
-- these directly.
--
-- api.get_pending_file(p_file_id, p_user_id)
--   • Returns the details the Edge Function needs to verify the upload
--     (tenant_id, storage_key, storage_provider_id, processing_status).
--   • Performs an ownership check: the calling user must be an active member
--     of the tenant that owns the file.  Returns 0 rows (never an error) if
--     the file doesn't exist, isn't pending, or the user has no access —
--     letting the Edge Function return a generic 404 that doesn't leak
--     information about files that belong to other tenants.
--
-- api.mark_file_as_done(p_file_id, p_actual_size)
--   • Atomically sets processing_status = 'done' and size_bytes = p_actual_size.
--   • Only transitions from 'pending'; raises an exception if the row is not
--     found in that state (already confirmed, missing, etc.).
--   • The existing data.update_file_nodes_storage_usage trigger fires on this
--     UPDATE and automatically moves reserved_bytes → committed_bytes,
--     increments file_count, and stores the actual size in committed_bytes.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- api.get_pending_file
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_pending_file(
  p_file_id uuid,
  p_user_id uuid
)
RETURNS TABLE (
  id                  uuid,
  tenant_id           uuid,
  storage_key         text,
  storage_provider_id uuid,
  processing_status   text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  RETURN QUERY
  SELECT
    fn.id,
    fn.tenant_id,
    fn.storage_key,
    fn.storage_provider_id,
    fn.processing_status
  FROM data.file_nodes fn
  WHERE fn.id               = p_file_id
    AND fn.processing_status = 'pending'
    AND fn.is_deleted        = false
    -- Ownership check: the user must be an active member of the owning tenant.
    -- Using EXISTS avoids exposing the tenant_members row to the caller.
    AND EXISTS (
      SELECT 1
      FROM data.tenant_members tm
      WHERE tm.tenant_id  = fn.tenant_id
        AND tm.user_id    = p_user_id
        AND tm.is_active  = true
    );
END;
$$;

-- Both RPCs are service_role-only: the Edge Function orchestrates the whole
-- flow and is the only caller.  PostgREST / authenticated users can never
-- reach these functions.
REVOKE ALL ON FUNCTION api.get_pending_file(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_pending_file(uuid, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_pending_file(uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION api.get_pending_file(uuid, uuid) TO service_role;


-- ---------------------------------------------------------------------------
-- api.mark_file_as_done
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.mark_file_as_done(
  p_file_id    uuid,
  p_actual_size bigint
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_id uuid;
BEGIN
  -- Update only if the file is still in 'pending' status.
  -- The SECURITY DEFINER context bypasses RLS so the UPDATE reaches
  -- data.file_nodes directly (the "no delete directe" policy doesn't
  -- interfere, and the UPDATE policy allows changes from service_role).
  --
  -- Side-effect (handled by existing trigger):
  --   data.update_file_nodes_storage_usage fires on this UPDATE and:
  --     • Adds p_actual_size to committed_bytes
  --     • Subtracts OLD.size_bytes from reserved_bytes
  --     • Increments file_count by 1
  UPDATE data.file_nodes
  SET
    processing_status = 'done',
    size_bytes        = p_actual_size
  WHERE id                = p_file_id
    AND processing_status = 'pending'
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'file_not_found_or_not_pending'
      USING HINT =
        'The file does not exist or is no longer in pending status. '
        'It may have already been confirmed or the upload was cancelled.';
  END IF;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.mark_file_as_done(uuid, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.mark_file_as_done(uuid, bigint) FROM authenticated;
REVOKE ALL ON FUNCTION api.mark_file_as_done(uuid, bigint) FROM anon;
GRANT  EXECUTE ON FUNCTION api.mark_file_as_done(uuid, bigint) TO service_role;
