-- LC-1 cont.: publish edited versions + remaining platform templates + preview

CREATE OR REPLACE FUNCTION api.preview_my_tenant_legal_document(
  p_code text,
  p_locale text DEFAULT 'es'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);
  RETURN api.resolve_public_legal_document(p_code, p_locale, v_tenant, NULL);
END;
$$;

REVOKE ALL ON FUNCTION api.preview_my_tenant_legal_document(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.preview_my_tenant_legal_document(text, text) TO authenticated;

CREATE OR REPLACE FUNCTION api.publish_my_tenant_legal_document_version(
  p_code text,
  p_locale text,
  p_title text,
  p_body_html text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_doc data.tenant_legal_documents%ROWTYPE;
  v_next int;
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);
  PERFORM data.ensure_tenant_legal_profile(v_tenant);

  IF p_locale NOT IN ('ca', 'es', 'en') THEN
    RAISE EXCEPTION 'invalid_locale' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(btrim(p_title), '') IS NULL OR NULLIF(btrim(p_body_html), '') IS NULL THEN
    RAISE EXCEPTION 'title_and_body_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.tenant_legal_documents
  WHERE tenant_id = v_tenant AND code = p_code
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.tenant_legal_documents
  SET mode = 'edited', external_url = NULL, updated_at = now()
  WHERE id = v_doc.id;

  UPDATE data.tenant_legal_document_versions
  SET status = 'superseded'
  WHERE document_id = v_doc.id AND locale = p_locale AND status = 'published';

  SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_next
  FROM data.tenant_legal_document_versions
  WHERE document_id = v_doc.id AND locale = p_locale;

  INSERT INTO data.tenant_legal_document_versions (
    document_id, tenant_id, locale, version_number, status,
    title, body_html, effective_at, published_at, published_by
  ) VALUES (
    v_doc.id, v_tenant, p_locale, v_next, 'published',
    btrim(p_title), p_body_html, now(), now(), auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'version_id', v_id,
    'version_number', v_next,
    'code', p_code,
    'locale', p_locale
  );
END;
$$;

REVOKE ALL ON FUNCTION api.publish_my_tenant_legal_document_version(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.publish_my_tenant_legal_document_version(text, text, text, text)
  TO authenticated;

-- Remaining catalog templates (placeholders)
DO $$
DECLARE
  v_code text;
  v_locale text;
  v_title text;
  v_body text;
  v_codes text[] := ARRAY[
    'portal_terms_customers',
    'privacy_employees',
    'employee_portal_terms',
    'privacy_candidates',
    'dpa_platform'
  ];
BEGIN
  FOREACH v_code IN ARRAY v_codes LOOP
    FOREACH v_locale IN ARRAY ARRAY['ca', 'es', 'en'] LOOP
      IF EXISTS (
        SELECT 1 FROM data.platform_legal_templates
        WHERE code = v_code AND locale = v_locale AND is_current
      ) THEN
        CONTINUE;
      END IF;

      v_title := CASE v_code
        WHEN 'portal_terms_customers' THEN CASE v_locale
          WHEN 'ca' THEN 'Condicions d''ús del portal'
          WHEN 'es' THEN 'Condiciones de uso del portal'
          ELSE 'Portal terms of use' END
        WHEN 'privacy_employees' THEN CASE v_locale
          WHEN 'ca' THEN 'Privacitat (empleats)'
          WHEN 'es' THEN 'Privacidad (empleados)'
          ELSE 'Employee privacy' END
        WHEN 'employee_portal_terms' THEN CASE v_locale
          WHEN 'ca' THEN 'Condicions del portal d''empleat'
          WHEN 'es' THEN 'Condiciones del portal de empleado'
          ELSE 'Employee portal terms' END
        WHEN 'privacy_candidates' THEN CASE v_locale
          WHEN 'ca' THEN 'Privacitat (candidats)'
          WHEN 'es' THEN 'Privacidad (candidatos)'
          ELSE 'Candidate privacy' END
        ELSE CASE v_locale
          WHEN 'ca' THEN 'Acord d''encàrrec (DPA)'
          WHEN 'es' THEN 'Acuerdo de encargo (DPA)'
          ELSE 'Data processing agreement (DPA)' END
      END;

      v_body := '{{disclaimer_html}}<h1>' || v_title || '</h1>'
        || '<p><strong>{{legal_name}}</strong> ({{nif}})</p>'
        || '<p>Contacte: {{privacy_email}}</p>'
        || CASE WHEN v_code = 'dpa_platform' THEN
             '<p>Aquest document regula l''encàrrec de tractament entre el responsable ({{legal_name}}) i la plataforma (encarregat).</p>'
             || '<p>Subprocessadors:</p><ul>{{subprocessors_html}}</ul>'
           WHEN v_code LIKE 'privacy_%' THEN
             '<p>Informació Art. 13 / tractament de dades. Conservació: {{retention_summary}}</p>'
             || '<ul>{{subprocessors_html}}</ul>'
           ELSE
             '<p>Condicions d''ús del servei digital indicat. Text orientatiu.</p>'
           END;

      INSERT INTO data.platform_legal_templates (
        code, locale, version, title, body_html, merge_keys, is_current
      ) VALUES (
        v_code, v_locale, 1, v_title, v_body,
        ARRAY['legal_name','nif','privacy_email','dpo_email','postal_address','website_url','retention_summary','subprocessors_html','disclaimer_html','registry_info','trade_name'],
        true
      );
    END LOOP;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
