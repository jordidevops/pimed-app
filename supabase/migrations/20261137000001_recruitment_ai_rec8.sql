-- =============================================================================
-- REC-8 — Recruitment AI assist (DPA checklist + cv_structured)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Settings columns
-- ---------------------------------------------------------------------------
ALTER TABLE data.recruitment_settings
  ADD COLUMN IF NOT EXISTS ai_assist_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS ai_dpa_accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS ai_dpa_accepted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ai_transfer_accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS ai_transfer_accepted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ai_checklist_version text;

COMMENT ON COLUMN data.recruitment_settings.ai_assist_enabled IS
  'REC-8: IA assistiva en reclutament (estructurar CV). Requereix checklist DPA+transfer.';
COMMENT ON COLUMN data.recruitment_settings.ai_dpa_accepted_at IS
  'REC-8: moment d''acceptació del recordatori DPA amb proveïdor LLM.';
COMMENT ON COLUMN data.recruitment_settings.ai_transfer_accepted_at IS
  'REC-8: acceptació de transferència internacional / SCC del proveïdor BYOK.';
COMMENT ON COLUMN data.recruitment_settings.ai_checklist_version IS
  'REC-8: versió del text de checklist acceptat (ex. rec8-v1).';

ALTER TABLE data.recruitment_settings
  DROP CONSTRAINT IF EXISTS recruitment_settings_ai_assist_ck;

ALTER TABLE data.recruitment_settings
  ADD CONSTRAINT recruitment_settings_ai_assist_ck CHECK (
    ai_assist_enabled = false
    OR (
      ai_dpa_accepted_at IS NOT NULL
      AND ai_transfer_accepted_at IS NOT NULL
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Applications: confirmed structured CV
-- ---------------------------------------------------------------------------
ALTER TABLE data.applications
  ADD COLUMN IF NOT EXISTS cv_structured jsonb,
  ADD COLUMN IF NOT EXISTS cv_structured_at timestamptz,
  ADD COLUMN IF NOT EXISTS cv_structured_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN data.applications.cv_structured IS
  'REC-8: proposta CV confirmada per humà (skills/experience/education/languages).';

DROP VIEW IF EXISTS api.applications;
CREATE VIEW api.applications
WITH (security_invoker = true) AS
SELECT * FROM data.applications;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.applications TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Refresh recruitment_settings view (expose AI fields; no direct UPDATE)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.recruitment_settings;
CREATE VIEW api.recruitment_settings
WITH (security_invoker = true) AS
SELECT
  tenant_id,
  default_max_retention_months,
  expire_closes_process,
  rights_sla_days,
  rejection_notify_policy,
  privacy_policy_url,
  import_legal_basis,
  import_legal_basis_note,
  enforce_department_scope,
  analytics_min_cohort,
  candidate_portal_base_url,
  rights_sla_notify_emails,
  inbound_enabled,
  inbound_address_hint,
  ai_assist_enabled,
  ai_dpa_accepted_at,
  ai_dpa_accepted_by,
  ai_transfer_accepted_at,
  ai_transfer_accepted_by,
  ai_checklist_version,
  created_at,
  updated_at
FROM data.recruitment_settings;

GRANT SELECT, UPDATE ON api.recruitment_settings TO authenticated;

REVOKE ALL ON data.recruitment_settings FROM authenticated;

GRANT SELECT (
  tenant_id,
  default_max_retention_months,
  expire_closes_process,
  rights_sla_days,
  rejection_notify_policy,
  privacy_policy_url,
  import_legal_basis,
  import_legal_basis_note,
  enforce_department_scope,
  analytics_min_cohort,
  candidate_portal_base_url,
  rights_sla_notify_emails,
  inbound_enabled,
  inbound_address_hint,
  ai_assist_enabled,
  ai_dpa_accepted_at,
  ai_dpa_accepted_by,
  ai_transfer_accepted_at,
  ai_transfer_accepted_by,
  ai_checklist_version,
  created_at,
  updated_at
) ON data.recruitment_settings TO authenticated;

GRANT UPDATE (
  default_max_retention_months,
  expire_closes_process,
  rights_sla_days,
  rejection_notify_policy,
  privacy_policy_url,
  import_legal_basis,
  import_legal_basis_note,
  enforce_department_scope,
  analytics_min_cohort,
  candidate_portal_base_url,
  rights_sla_notify_emails,
  inbound_enabled,
  inbound_address_hint,
  updated_at
) ON data.recruitment_settings TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.tenant_ai_is_configured(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.tenant_ai_provider_config pc
    WHERE pc.tenant_id = p_tenant_id
      AND pc.ai_key_secret_id IS NOT NULL
      AND pc.key_verified_at IS NOT NULL
  );
$$;

REVOKE ALL ON FUNCTION data.tenant_ai_is_configured(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.tenant_ai_is_configured(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.normalize_cv_structured(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_skills jsonb := '[]'::jsonb;
  v_experience jsonb := '[]'::jsonb;
  v_education jsonb := '[]'::jsonb;
  v_languages jsonb := '[]'::jsonb;
  v_item jsonb;
  v_out jsonb;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'invalid_cv_structured'
      USING HINT = 'El payload ha de ser un objecte JSON';
  END IF;

  IF p_payload ? 'skills' THEN
    IF jsonb_typeof(p_payload->'skills') = 'array' THEN
      v_skills := '[]'::jsonb;
      FOR v_item IN SELECT * FROM jsonb_array_elements(p_payload->'skills')
      LOOP
        IF jsonb_typeof(v_item) = 'string' AND length(btrim(v_item #>> '{}')) > 0 THEN
          v_skills := v_skills || jsonb_build_array(btrim(v_item #>> '{}'));
        ELSIF jsonb_typeof(v_item) = 'object' AND NULLIF(btrim(COALESCE(v_item->>'name', '')), '') IS NOT NULL THEN
          v_skills := v_skills || jsonb_build_array(btrim(v_item->>'name'));
        END IF;
      END LOOP;
    END IF;
  END IF;

  IF p_payload ? 'experience' AND jsonb_typeof(p_payload->'experience') = 'array' THEN
    v_experience := p_payload->'experience';
  END IF;
  IF p_payload ? 'education' AND jsonb_typeof(p_payload->'education') = 'array' THEN
    v_education := p_payload->'education';
  END IF;
  IF p_payload ? 'languages' AND jsonb_typeof(p_payload->'languages') = 'array' THEN
    v_languages := p_payload->'languages';
  END IF;

  v_out := jsonb_build_object(
    'skills', v_skills,
    'experience', v_experience,
    'education', v_education,
    'languages', v_languages
  );

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION data.normalize_cv_structured(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.normalize_cv_structured(jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. accept_recruitment_ai_checklist
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.accept_recruitment_ai_checklist(
  p_tenant_id uuid,
  p_accept_dpa boolean,
  p_accept_transfer boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := COALESCE(p_tenant_id, data.active_tenant_id());
  v_uid uuid := auth.uid();
  v_now timestamptz := now();
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

  IF NOT COALESCE(p_accept_dpa, false) OR NOT COALESCE(p_accept_transfer, false) THEN
    RAISE EXCEPTION 'checklist_incomplete'
      USING HINT = 'Cal acceptar DPA i transferència/SCC';
  END IF;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant)
  ON CONFLICT (tenant_id) DO NOTHING;

  UPDATE data.recruitment_settings
  SET
    ai_dpa_accepted_at = v_now,
    ai_dpa_accepted_by = v_uid,
    ai_transfer_accepted_at = v_now,
    ai_transfer_accepted_by = v_uid,
    ai_checklist_version = 'rec8-v1',
    updated_at = v_now
  WHERE tenant_id = v_tenant;

  RETURN jsonb_build_object(
    'ok', true,
    'ai_checklist_version', 'rec8-v1',
    'ai_dpa_accepted_at', v_now,
    'ai_transfer_accepted_at', v_now
  );
END;
$$;

REVOKE ALL ON FUNCTION api.accept_recruitment_ai_checklist(uuid, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.accept_recruitment_ai_checklist(uuid, boolean, boolean)
  TO authenticated;

COMMENT ON FUNCTION api.accept_recruitment_ai_checklist(uuid, boolean, boolean) IS
  'REC-8: registra acceptació checklist DPA + transfer/SCC per IA en reclutament.';

-- ---------------------------------------------------------------------------
-- 6. set_recruitment_ai_assist_enabled
-- ---------------------------------------------------------------------------
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

REVOKE ALL ON FUNCTION api.set_recruitment_ai_assist_enabled(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_recruitment_ai_assist_enabled(uuid, boolean)
  TO authenticated;

COMMENT ON FUNCTION api.set_recruitment_ai_assist_enabled(uuid, boolean) IS
  'REC-8: activa/desactiva IA assist en reclutament (requereix checklist + IA configurada).';

-- ---------------------------------------------------------------------------
-- 7. save_application_cv_structured
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.save_application_cv_structured(
  p_application_id uuid,
  p_payload jsonb
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
  v_norm jsonb;
  v_now timestamptz := now();
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

  IF NOT FOUND OR NOT COALESCE(v_settings.ai_assist_enabled, false) THEN
    RAISE EXCEPTION 'ai_assist_disabled'
      USING HINT = 'IA en reclutament no està activada';
  END IF;

  IF v_settings.ai_dpa_accepted_at IS NULL
     OR v_settings.ai_transfer_accepted_at IS NULL THEN
    RAISE EXCEPTION 'checklist_incomplete';
  END IF;

  SELECT * INTO v_app
  FROM data.applications
  WHERE id = p_application_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  v_norm := data.normalize_cv_structured(p_payload);

  UPDATE data.applications
  SET
    cv_structured = v_norm,
    cv_structured_at = v_now,
    cv_structured_by = v_uid,
    updated_at = v_now
  WHERE id = v_app.id;

  RETURN jsonb_build_object(
    'ok', true,
    'application_id', v_app.id,
    'cv_structured', v_norm,
    'cv_structured_at', v_now
  );
END;
$$;

REVOKE ALL ON FUNCTION api.save_application_cv_structured(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.save_application_cv_structured(uuid, jsonb)
  TO authenticated;

COMMENT ON FUNCTION api.save_application_cv_structured(uuid, jsonb) IS
  'REC-8: desa CV estructurat confirmat per humà (post-proposta IA).';

NOTIFY pgrst, 'reload schema';
