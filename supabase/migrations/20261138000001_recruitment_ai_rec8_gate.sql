-- =============================================================================
-- REC-8 follow-up — gate RPC for structure-recruitment-cv Edge
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_recruitment_cv_structure_gate(
  p_application_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_uid uuid := auth.uid();
  v_app data.applications%ROWTYPE;
  v_settings data.recruitment_settings%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage';
  END IF;

  SELECT * INTO v_settings
  FROM data.recruitment_settings
  WHERE tenant_id = v_tenant;

  IF NOT FOUND
     OR NOT COALESCE(v_settings.ai_assist_enabled, false)
     OR v_settings.ai_dpa_accepted_at IS NULL
     OR v_settings.ai_transfer_accepted_at IS NULL THEN
    RAISE EXCEPTION 'ai_assist_disabled'
      USING HINT = 'Cal activar IA en reclutament amb checklist DPA/transfer';
  END IF;

  IF NOT data.tenant_ai_is_configured(v_tenant) THEN
    RAISE EXCEPTION 'ai_not_configured';
  END IF;

  SELECT * INTO v_app
  FROM data.applications
  WHERE id = p_application_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF NULLIF(btrim(COALESCE(v_app.cv_storage_path, '')), '') IS NULL THEN
    RAISE EXCEPTION 'no_cv'
      USING HINT = 'La candidatura no té CV';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'application_id', v_app.id,
    'tenant_id', v_tenant,
    'cv_storage_path', v_app.cv_storage_path,
    'ai_checklist_version', v_settings.ai_checklist_version
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_recruitment_cv_structure_gate(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_recruitment_cv_structure_gate(uuid)
  TO authenticated;

COMMENT ON FUNCTION api.get_recruitment_cv_structure_gate(uuid) IS
  'REC-8: valida permisos + IA assist abans d''estructurar CV (Edge).';

NOTIFY pgrst, 'reload schema';
