-- Full-body commercial HTML cannot be loaded from Edge via schema data
-- (PostgREST only exposes api). SECURITY DEFINER RPC for render + print.

CREATE OR REPLACE FUNCTION api.get_commercial_full_body_locale(
  p_tenant_id uuid,
  p_template_id uuid,
  p_locale text DEFAULT 'ca'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_is_service boolean := COALESCE(auth.role(), '') = 'service_role';
  v_locale text := COALESCE(NULLIF(btrim(p_locale), ''), 'ca');
  v_tpl data.document_templates%ROWTYPE;
  v_html text;
  v_type text;
BEGIN
  IF p_tenant_id IS NULL OR p_template_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT v_is_service
     AND NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'access_denied' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
    INTO v_tpl
  FROM data.document_templates t
  WHERE t.id = p_template_id
    AND t.is_active
    AND (
      t.tenant_id = p_tenant_id
      OR (t.tenant_id IS NULL AND t.is_platform_default)
    );

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_type := v_tpl.template_type;

  SELECT l.html_content
    INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id
    AND l.is_active
    AND l.locale = v_locale
  LIMIT 1;

  IF v_html IS NULL OR v_html = '' THEN
    SELECT l.html_content
      INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id
      AND l.is_active
      AND COALESCE(l.html_content, '') <> ''
    ORDER BY CASE WHEN l.locale = 'ca' THEN 0 ELSE 1 END, l.locale
    LIMIT 1;
  END IF;

  IF v_html IS NULL OR v_html = '' THEN
    RETURN jsonb_build_object(
      'template_type', v_type,
      'html_content', NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'template_type', v_type,
    'html_content', v_html
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_commercial_full_body_locale(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_commercial_full_body_locale(uuid, uuid, text)
  TO authenticated, service_role;

-- PDFs emitted before this RPC used fallback HTML despite full_body_template_id.
UPDATE data.commercial_documents
SET rendered_document_id = NULL,
    pdf_job_id = NULL
WHERE full_body_template_id IS NOT NULL
  AND (rendered_document_id IS NOT NULL OR pdf_job_id IS NOT NULL);

NOTIFY pgrst, 'reload schema';
