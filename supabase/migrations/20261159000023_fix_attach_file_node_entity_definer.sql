-- attach_file_node_entity was SECURITY INVOKER and called data.is_active_tenant_member,
-- which has REVOKE ALL FROM PUBLIC and no EXECUTE for authenticated → 42501.
-- Make attach SECURITY DEFINER (same pattern as ensure_field_project_folders).

CREATE OR REPLACE FUNCTION api.attach_file_node_entity(
  p_node_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_site_id uuid DEFAULT NULL,
  p_metadata jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_node data.file_nodes%ROWTYPE;
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_node FROM data.file_nodes WHERE id = p_node_id AND is_deleted = false;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'node_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.is_active_tenant_member(v_node.tenant_id, v_uid) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.file_nodes
  SET entity_type = p_entity_type,
      entity_id = p_entity_id,
      site_id = COALESCE(p_site_id, site_id),
      metadata = CASE
        WHEN p_metadata IS NULL THEN metadata
        ELSE COALESCE(metadata, '{}'::jsonb) || p_metadata
      END,
      updated_at = now()
  WHERE id = p_node_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.attach_file_node_entity(uuid, text, uuid, uuid, jsonb)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
