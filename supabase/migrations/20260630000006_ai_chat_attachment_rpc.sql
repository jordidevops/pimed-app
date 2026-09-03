-- M2 fix: Edge (service_role) no pot SELECT api.file_nodes — RPC interna per adjunts del xat

CREATE OR REPLACE FUNCTION api.get_ai_chat_attachment_file_service(
  p_file_id   uuid,
  p_tenant_id uuid,
  p_user_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row data.file_nodes%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_row
  FROM data.file_nodes fn
  WHERE fn.id = p_file_id
    AND fn.tenant_id = p_tenant_id
    AND fn.is_deleted = false
    AND fn.node_type = 'file'
    AND fn.processing_status = 'done'
    AND fn.created_by = p_user_id
    AND EXISTS (
      SELECT 1
      FROM data.tenant_members tm
      WHERE tm.tenant_id = p_tenant_id
        AND tm.user_id = p_user_id
        AND tm.is_active = true
    );

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_row.storage_key IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'tenant_id', v_row.tenant_id,
    'created_by', v_row.created_by,
    'storage_key', v_row.storage_key,
    'storage_provider_id', v_row.storage_provider_id,
    'mime_type', v_row.mime_type,
    'name', v_row.name,
    'size_bytes', v_row.size_bytes,
    'processing_status', v_row.processing_status,
    'node_type', v_row.node_type
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_ai_chat_attachment_file_service(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_ai_chat_attachment_file_service(uuid, uuid, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_ai_chat_attachment_file_service(uuid, uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_ai_chat_attachment_file_service(uuid, uuid, uuid) TO service_role;
