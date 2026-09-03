-- =============================================================================
-- REC-7 hotfix — discard only unassigned inbox items
-- =============================================================================

CREATE OR REPLACE FUNCTION api.discard_recruitment_inbox_item(
  p_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_row data.recruitment_email_inbox%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM data.recruitment_email_inbox
  WHERE id = p_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_row.status = 'discarded' THEN
    RETURN jsonb_build_object('inbox_id', p_id, 'already_discarded', true);
  END IF;

  -- Assigned items keep their application; do not soft-hide them via discard
  IF v_row.status = 'assigned' THEN
    RAISE EXCEPTION 'already_assigned'
      USING HINT = 'No es pot descartar un correu ja assignat a una oferta';
  END IF;

  UPDATE data.recruitment_email_inbox
  SET status = 'discarded',
      discarded_at = now(),
      discarded_by = auth.uid(),
      discard_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
      updated_at = now()
  WHERE id = p_id;

  PERFORM data.log_audit_event(
    v_tenant,
    auth.uid(),
    NULL,
    'recruitment.inbound_discard',
    'recruitment_email_inbox',
    p_id,
    jsonb_build_object('reason', p_reason)
  );

  RETURN jsonb_build_object('inbox_id', p_id, 'already_discarded', false);
END;
$$;

COMMENT ON FUNCTION api.discard_recruitment_inbox_item(uuid, text) IS
  'REC-7: discard unassigned inbound email only (assigned → already_assigned).';
