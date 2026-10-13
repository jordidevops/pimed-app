-- Optional free-text reason when an office user cancels an orphan quote draft.
-- The actor stays in commercial_document_events.actor_id.

DROP FUNCTION IF EXISTS api.cancel_orphan_quote_draft(uuid);

CREATE OR REPLACE FUNCTION api.cancel_orphan_quote_draft(
  p_document_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_reason text := NULLIF(left(btrim(COALESCE(p_reason, '')), 500), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.doc_type <> 'quote' OR v_doc.project_id IS NOT NULL OR v_doc.status <> 'draft' THEN
    RAISE EXCEPTION 'orphan_draft_cancel_not_allowed' USING ERRCODE = 'P0001';
  END IF;
  IF NOT data.can_edit_commercial_pricing(v_doc.tenant_id, NULL) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET status = 'cancelled', updated_at = now()
  WHERE id = p_document_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, 'cancelled', v_uid, extensions.gen_random_uuid(),
    jsonb_build_object(
      'kind', 'orphan_draft_discard',
      'reason', v_reason
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.cancel_orphan_quote_draft(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.cancel_orphan_quote_draft(uuid, text)
  TO authenticated, service_role;
