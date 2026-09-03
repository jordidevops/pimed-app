-- =============================================================================
-- REC-8 hotfix — tenant mismatch on set_ai_assist + guard cv_structured
-- =============================================================================

-- 1) set_recruitment_ai_assist_enabled: refuse p_tenant_id ≠ active header
CREATE OR REPLACE FUNCTION api.set_recruitment_ai_assist_enabled(
  p_tenant_id uuid,
  p_enabled boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := COALESCE(p_tenant_id, data.active_tenant_id());
  v_uid uuid := auth.uid();
  v_settings data.recruitment_settings%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_tenant IS DISTINCT FROM data.active_tenant_id()
     AND data.active_tenant_id() IS NOT NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Tenant mismatch';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage';
  END IF;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant)
  ON CONFLICT (tenant_id) DO NOTHING;

  SELECT * INTO v_settings
  FROM data.recruitment_settings
  WHERE tenant_id = v_tenant;

  IF COALESCE(p_enabled, false) THEN
    IF v_settings.ai_dpa_accepted_at IS NULL
       OR v_settings.ai_transfer_accepted_at IS NULL THEN
      RAISE EXCEPTION 'checklist_incomplete'
        USING HINT = 'Cal acceptar primer la checklist DPA i transferència';
    END IF;

    IF NOT data.tenant_ai_is_configured(v_tenant) THEN
      RAISE EXCEPTION 'ai_not_configured'
        USING HINT = 'Cal configurar una clau IA del tenant (BYOK) i verificar-la';
    END IF;
  END IF;

  UPDATE data.recruitment_settings
  SET
    ai_assist_enabled = COALESCE(p_enabled, false),
    updated_at = now()
  WHERE tenant_id = v_tenant;

  RETURN jsonb_build_object(
    'ok', true,
    'ai_assist_enabled', COALESCE(p_enabled, false)
  );
END;
$$;

-- 2) Direct UPDATE of cv_structured must respect AI assist gate (same as RPC)
CREATE OR REPLACE FUNCTION data.trg_applications_cv_structured_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_settings data.recruitment_settings%ROWTYPE;
BEGIN
  IF NEW.cv_structured IS NOT DISTINCT FROM OLD.cv_structured
     AND NEW.cv_structured_at IS NOT DISTINCT FROM OLD.cv_structured_at
     AND NEW.cv_structured_by IS NOT DISTINCT FROM OLD.cv_structured_by THEN
    RETURN NEW;
  END IF;

  -- Clearing structured data is always allowed
  IF NEW.cv_structured IS NULL THEN
    NEW.cv_structured_at := NULL;
    NEW.cv_structured_by := NULL;
    RETURN NEW;
  END IF;

  SELECT * INTO v_settings
  FROM data.recruitment_settings
  WHERE tenant_id = NEW.tenant_id;

  IF NOT FOUND
     OR NOT COALESCE(v_settings.ai_assist_enabled, false)
     OR v_settings.ai_dpa_accepted_at IS NULL
     OR v_settings.ai_transfer_accepted_at IS NULL THEN
    RAISE EXCEPTION 'ai_assist_disabled'
      USING ERRCODE = '42501',
            HINT = 'Cal IA en reclutament activada amb checklist per desar cv_structured';
  END IF;

  IF NEW.cv_structured_at IS NULL THEN
    NEW.cv_structured_at := now();
  END IF;
  IF NEW.cv_structured_by IS NULL AND auth.uid() IS NOT NULL THEN
    NEW.cv_structured_by := auth.uid();
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_applications_cv_structured_guard ON data.applications;
CREATE TRIGGER trg_applications_cv_structured_guard
  BEFORE UPDATE OF cv_structured, cv_structured_at, cv_structured_by
  ON data.applications
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_applications_cv_structured_guard();

COMMENT ON FUNCTION data.trg_applications_cv_structured_guard() IS
  'REC-8 hotfix: impedeix escriure cv_structured sense IA assist + checklist (bypass PostgREST).';

NOTIFY pgrst, 'reload schema';
