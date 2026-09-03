-- En eliminar un comentari, esborrar fitxers adjunts (source=entity_comment) i buidar attachments.

CREATE OR REPLACE FUNCTION api.delete_entity_comment(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row data.entity_comments%ROWTYPE;
  v_item jsonb;
  v_file_id uuid;
BEGIN
  SELECT * INTO v_row
  FROM data.entity_comments
  WHERE id = p_id AND tenant_id = data.active_tenant_id() AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_row.user_id IS DISTINCT FROM auth.uid()
     AND (data.jwt_user_tenants() -> v_row.tenant_id::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(coalesce(v_row.attachments, '[]'::jsonb)) AS t(value)
  LOOP
    v_file_id := (v_item ->> 'file_id')::uuid;
    IF v_file_id IS NULL THEN
      CONTINUE;
    END IF;

    BEGIN
      IF EXISTS (
        SELECT 1
        FROM data.file_nodes fn
        WHERE fn.id = v_file_id
          AND fn.tenant_id = v_row.tenant_id
          AND fn.node_type = 'file'
          AND fn.is_deleted = false
          AND coalesce(fn.metadata ->> 'source', '') = 'entity_comment'
      ) THEN
        PERFORM data.hard_delete_node(v_file_id, v_row.tenant_id);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING 'delete_entity_comment attachment %: %', v_file_id, SQLERRM;
    END;
  END LOOP;

  UPDATE data.entity_comments
  SET deleted_at = now(), content = '', attachments = '[]'::jsonb
  WHERE id = p_id;
END;
$$;
