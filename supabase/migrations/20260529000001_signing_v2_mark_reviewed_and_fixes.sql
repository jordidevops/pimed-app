-- =============================================================================
-- 20260529000001_signing_v2_mark_reviewed_and_fixes.sql
--
-- 1. BUG FIX: octet_length() per mida HTML real (bytes UTF-8, no caràcters)
--    · api.upsert_document_template_locale
--    · data.trg_audit_document_template_locales
--
-- 2. Signing V2 — mark-reviewed:
--    · reviewed_at timestamptz, reviewed_by uuid a data.signing_submissions
--    · Reconstrueix api.signing_submissions amb els nous camps
--    · api.mark_signing_submission_reviewed(p_submission_id uuid)
--      - Permís: global_role owner o manager del tenant
--      - Idempotent: si ja estava revisat retorna sense modificar
--      - Audit: SIGNING_SUBMISSION_REVIEWED
-- =============================================================================

-- =============================================================================
-- 1. BUG FIX: octet_length() per mida HTML real
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1a. api.upsert_document_template_locale — usa octet_length per bytes reals
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.upsert_document_template_locale(
  p_template_id          uuid,
  p_locale               text,
  p_mime_type            text,
  p_storage_path         text    DEFAULT NULL,
  p_html_content         text    DEFAULT NULL,
  p_variables_schema     jsonb   DEFAULT '{}',
  p_signing_roles_schema jsonb   DEFAULT '{}',
  p_sample_values        jsonb   DEFAULT NULL,
  p_is_active            boolean DEFAULT true
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_template      data.document_templates%ROWTYPE;
  v_locale_record data.document_template_locales%ROWTYPE;
  v_max_kb        integer;
BEGIN
  IF p_mime_type NOT IN (
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'text/html'
  ) THEN
    RAISE EXCEPTION 'Invalid mime_type: %. Must be docx or text/html', p_mime_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_mime_type = 'text/html' AND (p_html_content IS NULL OR p_html_content = '') THEN
    RAISE EXCEPTION 'html_content is required for text/html locales'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_mime_type != 'text/html' AND p_storage_path IS NULL THEN
    RAISE EXCEPTION 'storage_path is required for DOCX locales'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT t.* INTO v_template
  FROM data.document_templates t
  WHERE t.id = p_template_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Template % not found', p_template_id;
  END IF;

  IF v_template.tenant_id IS NOT NULL THEN
    IF NOT (
      data.jwt_user_tenants() ? v_template.tenant_id::text
      AND (data.jwt_user_tenants() -> v_template.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Access denied: owner or manager role required';
    END IF;

    -- CORRECCIÓ: octet_length() mesura bytes UTF-8 reals, no caràcters
    IF p_mime_type = 'text/html' THEN
      SELECT p.max_html_template_size_kb INTO v_max_kb
      FROM data.tenants t
      JOIN data.plans   p ON p.id = t.plan_id
      WHERE t.id = v_template.tenant_id;

      IF v_max_kb IS NOT NULL AND v_max_kb > 0
         AND octet_length(p_html_content) > v_max_kb * 1024 THEN
        RAISE EXCEPTION 'HTML template exceeds plan limit of % KB (content: % KB)',
          v_max_kb, round(octet_length(p_html_content) / 1024.0, 1)
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;

  ELSE
    RAISE EXCEPTION 'Platform templates must be managed via admin portal';
  END IF;

  INSERT INTO data.document_template_locales (
    template_id, locale, mime_type, storage_path, html_content,
    variables_schema, signing_roles_schema, sample_values, is_active
  ) VALUES (
    p_template_id, p_locale, p_mime_type,
    CASE WHEN p_mime_type = 'text/html' THEN NULL ELSE p_storage_path END,
    CASE WHEN p_mime_type = 'text/html' THEN p_html_content ELSE NULL END,
    p_variables_schema, p_signing_roles_schema, p_sample_values, p_is_active
  )
  ON CONFLICT (template_id, locale) DO UPDATE SET
    mime_type              = EXCLUDED.mime_type,
    storage_path           = EXCLUDED.storage_path,
    html_content           = EXCLUDED.html_content,
    variables_schema       = EXCLUDED.variables_schema,
    signing_roles_schema   = EXCLUDED.signing_roles_schema,
    sample_values          = EXCLUDED.sample_values,
    is_active              = EXCLUDED.is_active,
    updated_at             = now()
  RETURNING * INTO v_locale_record;

  RETURN row_to_json(v_locale_record);
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_document_template_locale TO authenticated;

-- ---------------------------------------------------------------------------
-- 1b. data.trg_audit_document_template_locales — octet_length per html_size_bytes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_document_template_locales()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT tenant_id INTO v_tenant_id FROM data.document_templates WHERE id = OLD.template_id;
  ELSE
    SELECT tenant_id INTO v_tenant_id FROM data.document_templates WHERE id = NEW.template_id;
  END IF;

  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      v_tenant_id, COALESCE(auth.uid(), NULL), NULL,
      'TEMPLATE_LOCALE_CREATED', 'document_template_locale', NEW.id,
      jsonb_build_object(
        'template_id',     NEW.template_id,
        'locale',          NEW.locale,
        'mime_type',       NEW.mime_type,
        'is_active',       NEW.is_active,
        'html_size_bytes', CASE WHEN NEW.mime_type = 'text/html'
                             THEN octet_length(NEW.html_content)
                             ELSE NULL END
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      v_tenant_id, COALESCE(auth.uid(), NULL), NULL,
      'TEMPLATE_LOCALE_UPDATED', 'document_template_locale', NEW.id,
      jsonb_build_object(
        'template_id', NEW.template_id,
        'locale',      NEW.locale,
        'old', jsonb_strip_nulls(jsonb_build_object(
          'is_active',
            CASE WHEN OLD.is_active IS DISTINCT FROM NEW.is_active
              THEN to_jsonb(OLD.is_active) ELSE NULL END,
          'mime_type',
            CASE WHEN OLD.mime_type IS DISTINCT FROM NEW.mime_type
              THEN to_jsonb(OLD.mime_type) ELSE NULL END,
          'storage_path',
            CASE WHEN OLD.storage_path IS DISTINCT FROM NEW.storage_path
              THEN to_jsonb(OLD.storage_path) ELSE NULL END,
          'html_content_sha256',
            CASE WHEN OLD.html_content IS DISTINCT FROM NEW.html_content
              THEN to_jsonb(encode(sha256(OLD.html_content::bytea), 'hex')) ELSE NULL END
        )),
        'new', jsonb_strip_nulls(jsonb_build_object(
          'is_active',
            CASE WHEN OLD.is_active IS DISTINCT FROM NEW.is_active
              THEN to_jsonb(NEW.is_active) ELSE NULL END,
          'mime_type',
            CASE WHEN OLD.mime_type IS DISTINCT FROM NEW.mime_type
              THEN to_jsonb(NEW.mime_type) ELSE NULL END,
          'storage_path',
            CASE WHEN OLD.storage_path IS DISTINCT FROM NEW.storage_path
              THEN to_jsonb(NEW.storage_path) ELSE NULL END,
          'html_content_sha256',
            CASE WHEN OLD.html_content IS DISTINCT FROM NEW.html_content
              THEN to_jsonb(encode(sha256(NEW.html_content::bytea), 'hex')) ELSE NULL END
        )),
        'html_size_bytes',
          CASE WHEN NEW.mime_type = 'text/html' THEN octet_length(NEW.html_content) ELSE NULL END
      )
    );

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      v_tenant_id, COALESCE(auth.uid(), NULL), NULL,
      'TEMPLATE_LOCALE_DELETED', 'document_template_locale', OLD.id,
      jsonb_build_object(
        'template_id', OLD.template_id,
        'locale',      OLD.locale,
        'mime_type',   OLD.mime_type
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- =============================================================================
-- 2. mark-reviewed: columnes + vista + RPC
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 2a. Columnes reviewed_at / reviewed_by
-- ---------------------------------------------------------------------------
ALTER TABLE data.signing_submissions
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS reviewed_by uuid
    REFERENCES data.profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN data.signing_submissions.reviewed_at
  IS 'Quan un owner/manager ha marcat la submissió com a revisada manualment.';
COMMENT ON COLUMN data.signing_submissions.reviewed_by
  IS 'Profile que ha marcat la submissió com a revisada.';

-- ---------------------------------------------------------------------------
-- 2b. Reconstruir api.signing_submissions per exposar els nous camps
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.signing_submissions;

CREATE VIEW api.signing_submissions WITH (security_invoker = true) AS
  SELECT
    ss.id,
    ss.tenant_id,
    ss.source_type,
    ss.source_document_id,
    ss.source_document_version_id,
    ss.source_template_locale_id,
    ss.result_document_version_id,
    rv.file_path_or_url   AS result_file_path_or_url,
    rv.storage_type       AS result_storage_type,
    ss.docuseal_submission_id,
    ss.external_id,
    ss.status,
    ss.status_reason,
    ss.error_message,
    ss.last_event_at,
    ss.signers,
    ss.docuseal_signing_url,
    ss.submitted_at,
    ss.completed_at,
    ss.reviewed_at,
    ss.reviewed_by,
    ss.document_title,
    ss.audit_trail_storage_path,
    ss.audit_log_url,
    ss.initiated_by,
    ss.metadata,
    ss.created_at,
    ss.updated_at
  FROM data.signing_submissions ss
  LEFT JOIN data.document_versions rv ON rv.id = ss.result_document_version_id;

GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO service_role;

-- ---------------------------------------------------------------------------
-- 2c. RPC api.mark_signing_submission_reviewed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.mark_signing_submission_reviewed(
  p_submission_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_sub data.signing_submissions%ROWTYPE;
  v_uid uuid := auth.uid();
BEGIN
  SELECT * INTO v_sub
  FROM data.signing_submissions
  WHERE id = p_submission_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission % not found', p_submission_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Cal ser membre del tenant
  IF NOT (data.jwt_user_tenants() ? v_sub.tenant_id::text) THEN
    RAISE EXCEPTION 'Access denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Cal rol owner o manager
  IF (data.jwt_user_tenants() -> v_sub.tenant_id::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Idempotent: si ja estava revisat retornem sense modificar
  IF v_sub.reviewed_at IS NOT NULL THEN
    RETURN row_to_json(v_sub);
  END IF;

  UPDATE data.signing_submissions
  SET reviewed_at = now(),
      reviewed_by = v_uid,
      updated_at  = now()
  WHERE id = p_submission_id
  RETURNING * INTO v_sub;

  PERFORM data.log_audit_event(
    v_sub.tenant_id, v_uid, NULL,
    'SIGNING_SUBMISSION_REVIEWED', 'signing_submission', v_sub.id,
    jsonb_build_object(
      'reviewed_at', v_sub.reviewed_at,
      'status',      v_sub.status
    )
  );

  RETURN row_to_json(v_sub);
END;
$$;

GRANT EXECUTE ON FUNCTION api.mark_signing_submission_reviewed(uuid) TO authenticated;
