-- Presentational date fields for commercial full-body HTML.
-- ISO context keys stay; templates (platform + clones) switch to *_display.
-- Formats come from tenant settings (api schema — data REST is not exposed).

CREATE OR REPLACE FUNCTION api.get_commercial_display_formats(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_is_service boolean := COALESCE(auth.role(), '') = 'service_role';
  v_settings jsonb;
  v_date text;
  v_time text;
BEGIN
  IF p_tenant_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT v_is_service
     AND NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'access_denied' USING ERRCODE = 'P0001';
  END IF;

  v_settings := data.merge_effective_settings_for_service(p_tenant_id, NULL);
  v_date := NULLIF(btrim(COALESCE(v_settings->>'default_date_format', '')), '');
  v_time := NULLIF(btrim(COALESCE(v_settings->>'default_time_format', '')), '');

  RETURN jsonb_build_object(
    'date_format', COALESCE(v_date, 'dd/MM/yyyy'),
    'time_format', COALESCE(v_time, 'HH:mm')
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_commercial_display_formats(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_commercial_display_formats(uuid)
  TO authenticated, service_role;

UPDATE data.document_template_locales l
SET html_content = replace(
      replace(l.html_content, '{{ document.issued_at }}', '{{ document.issued_at_display }}'),
      '{{ document.valid_until }}',
      '{{ document.valid_until_display }}'
    )
FROM data.document_templates t
WHERE l.template_id = t.id
  AND t.category IN ('quote', 'delivery_note')
  AND COALESCE(l.html_content, '') <> ''
  AND (
    position('{{ document.issued_at }}' in l.html_content) > 0
    OR position('{{ document.valid_until }}' in l.html_content) > 0
  );

UPDATE data.document_template_locales l
SET sample_values = jsonb_set(
      jsonb_set(
        jsonb_set(
          COALESCE(l.sample_values, '{}'::jsonb),
          '{document,issued_at_display}',
          to_jsonb('17/09/2026 12:00'::text),
          true
        ),
        '{document,valid_until_display}',
        to_jsonb('17/10/2026'::text),
        true
      ),
      '{document,created_at_display}',
      to_jsonb('17/09/2026 11:00'::text),
      true
    )
FROM data.document_templates t
WHERE l.template_id = t.id
  AND t.category IN ('quote', 'delivery_note');

UPDATE data.commercial_documents
SET rendered_document_id = NULL,
    pdf_job_id = NULL
WHERE full_body_template_id IS NOT NULL
  AND (rendered_document_id IS NOT NULL OR pdf_job_id IS NOT NULL);

NOTIFY pgrst, 'reload schema';
