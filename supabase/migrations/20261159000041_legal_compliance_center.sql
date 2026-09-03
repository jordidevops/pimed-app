-- LC-1: Legal Center — schema base (perfil tenant, documents versionats, plantilles, subprocessadors)
-- Producte: docs/plans/legal-compliance/

-- ---------------------------------------------------------------------------
-- 1. Platform subprocessors (merged into Art.13 / DPA templates)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.platform_legal_subprocessors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL,
  name text NOT NULL,
  purpose text NOT NULL,
  location text,
  url text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT platform_legal_subprocessors_code_key UNIQUE (code)
);

COMMENT ON TABLE data.platform_legal_subprocessors IS
  'LC: llista central de subprocessadors de la plataforma (merge a plantilles).';

-- ---------------------------------------------------------------------------
-- 2. Platform templates (versioned by code + locale + version)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.platform_legal_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL,
  locale text NOT NULL,
  version int NOT NULL DEFAULT 1,
  title text NOT NULL,
  body_html text NOT NULL,
  merge_keys text[] NOT NULL DEFAULT '{}',
  is_current boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT platform_legal_templates_code_locale_version_key UNIQUE (code, locale, version),
  CONSTRAINT platform_legal_templates_locale_chk CHECK (locale IN ('ca', 'es', 'en')),
  CONSTRAINT platform_legal_templates_code_chk CHECK (
    code IN (
      'privacy_customers',
      'legal_notice',
      'portal_terms_customers',
      'cookie_notice',
      'privacy_website',
      'privacy_employees',
      'employee_portal_terms',
      'privacy_candidates',
      'dpa_platform'
    )
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_platform_legal_templates_current
  ON data.platform_legal_templates (code, locale)
  WHERE is_current;

COMMENT ON TABLE data.platform_legal_templates IS
  'LC: plantilles plataforma. Placeholders {{legal_name}}, {{nif}}, {{privacy_email}}, {{dpo_email}}, {{subprocessors_html}}, etc.';

-- ---------------------------------------------------------------------------
-- 3. Tenant legal profile (merge fields)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.tenant_legal_profiles (
  tenant_id uuid PRIMARY KEY REFERENCES data.tenants (id) ON DELETE CASCADE,
  legal_name text,
  trade_name text,
  nif text,
  registry_info text,
  privacy_email text,
  dpo_email text,
  dpo_name text,
  postal_address text,
  website_url text,
  retention_summary text,
  incomplete_banner_dismissed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users (id)
);

COMMENT ON TABLE data.tenant_legal_profiles IS
  'LC: camps merge del responsable (tenant). Incompletesa = banner, no bloqueig publicació butlletí.';

-- ---------------------------------------------------------------------------
-- 4. Tenant documents (one row per code)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.tenant_legal_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants (id) ON DELETE CASCADE,
  code text NOT NULL,
  mode text NOT NULL DEFAULT 'template',
  external_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tenant_legal_documents_tenant_code_key UNIQUE (tenant_id, code),
  CONSTRAINT tenant_legal_documents_mode_chk CHECK (mode IN ('template', 'edited', 'external_url')),
  CONSTRAINT tenant_legal_documents_code_chk CHECK (
    code IN (
      'privacy_customers',
      'legal_notice',
      'portal_terms_customers',
      'cookie_notice',
      'privacy_website',
      'privacy_employees',
      'employee_portal_terms',
      'privacy_candidates',
      'dpa_platform'
    )
  ),
  CONSTRAINT tenant_legal_documents_external_url_chk CHECK (
    mode <> 'external_url' OR (external_url IS NOT NULL AND length(btrim(external_url)) > 0)
  )
);

CREATE INDEX IF NOT EXISTS idx_tenant_legal_documents_tenant
  ON data.tenant_legal_documents (tenant_id);

-- ---------------------------------------------------------------------------
-- 5. Versions (draft / published per locale)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.tenant_legal_document_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id uuid NOT NULL REFERENCES data.tenant_legal_documents (id) ON DELETE CASCADE,
  tenant_id uuid NOT NULL REFERENCES data.tenants (id) ON DELETE CASCADE,
  locale text NOT NULL,
  version_number int NOT NULL DEFAULT 1,
  status text NOT NULL DEFAULT 'draft',
  title text NOT NULL,
  body_html text NOT NULL,
  source_template_id uuid REFERENCES data.platform_legal_templates (id),
  effective_at timestamptz,
  published_at timestamptz,
  published_by uuid REFERENCES auth.users (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tenant_legal_document_versions_locale_chk CHECK (locale IN ('ca', 'es', 'en')),
  CONSTRAINT tenant_legal_document_versions_status_chk CHECK (status IN ('draft', 'published', 'superseded')),
  CONSTRAINT tenant_legal_document_versions_doc_locale_version_key
    UNIQUE (document_id, locale, version_number)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_tenant_legal_doc_published
  ON data.tenant_legal_document_versions (document_id, locale)
  WHERE status = 'published';

CREATE INDEX IF NOT EXISTS idx_tenant_legal_doc_versions_tenant
  ON data.tenant_legal_document_versions (tenant_id);

-- ---------------------------------------------------------------------------
-- 6. RLS
-- ---------------------------------------------------------------------------
ALTER TABLE data.platform_legal_subprocessors ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.platform_legal_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.tenant_legal_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.tenant_legal_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.tenant_legal_document_versions ENABLE ROW LEVEL SECURITY;

CREATE POLICY platform_legal_subprocessors_select_authenticated
  ON data.platform_legal_subprocessors FOR SELECT TO authenticated
  USING (is_active = true);

CREATE POLICY platform_legal_templates_select_authenticated
  ON data.platform_legal_templates FOR SELECT TO authenticated
  USING (true);

CREATE POLICY tenant_legal_profiles_select
  ON data.tenant_legal_profiles FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id());

CREATE POLICY tenant_legal_profiles_write
  ON data.tenant_legal_profiles FOR ALL TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND data.member_has_live_permission(data.active_tenant_id(), auth.uid(), 'settings.manage', NULL)
  )
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND data.member_has_live_permission(data.active_tenant_id(), auth.uid(), 'settings.manage', NULL)
  );

CREATE POLICY tenant_legal_documents_select
  ON data.tenant_legal_documents FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id());

CREATE POLICY tenant_legal_documents_write
  ON data.tenant_legal_documents FOR ALL TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND data.member_has_live_permission(data.active_tenant_id(), auth.uid(), 'settings.manage', NULL)
  )
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND data.member_has_live_permission(data.active_tenant_id(), auth.uid(), 'settings.manage', NULL)
  );

CREATE POLICY tenant_legal_document_versions_select
  ON data.tenant_legal_document_versions FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id());

CREATE POLICY tenant_legal_document_versions_write
  ON data.tenant_legal_document_versions FOR ALL TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND data.member_has_live_permission(data.active_tenant_id(), auth.uid(), 'settings.manage', NULL)
  )
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND data.member_has_live_permission(data.active_tenant_id(), auth.uid(), 'settings.manage', NULL)
  );

-- service_role full access for seeds / BFF resolve
CREATE POLICY platform_legal_subprocessors_service
  ON data.platform_legal_subprocessors FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY platform_legal_templates_service
  ON data.platform_legal_templates FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY tenant_legal_profiles_service
  ON data.tenant_legal_profiles FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY tenant_legal_documents_service
  ON data.tenant_legal_documents FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY tenant_legal_document_versions_service
  ON data.tenant_legal_document_versions FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- 7. API views (SELECT-only for staff UI)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.platform_legal_subprocessors
WITH (security_invoker = true) AS
SELECT * FROM data.platform_legal_subprocessors WHERE is_active;

CREATE OR REPLACE VIEW api.platform_legal_templates
WITH (security_invoker = true) AS
SELECT * FROM data.platform_legal_templates;

CREATE OR REPLACE VIEW api.tenant_legal_profiles
WITH (security_invoker = true) AS
SELECT * FROM data.tenant_legal_profiles;

CREATE OR REPLACE VIEW api.tenant_legal_documents
WITH (security_invoker = true) AS
SELECT * FROM data.tenant_legal_documents;

CREATE OR REPLACE VIEW api.tenant_legal_document_versions
WITH (security_invoker = true) AS
SELECT * FROM data.tenant_legal_document_versions;

GRANT SELECT ON api.platform_legal_subprocessors TO authenticated;
GRANT SELECT ON api.platform_legal_templates TO authenticated;
GRANT SELECT ON api.tenant_legal_profiles TO authenticated;
GRANT SELECT ON api.tenant_legal_documents TO authenticated;
GRANT SELECT ON api.tenant_legal_document_versions TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Ensure profile + seed document shells (idempotent)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.ensure_tenant_legal_profile(p_tenant_id uuid)
RETURNS data.tenant_legal_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row data.tenant_legal_profiles%ROWTYPE;
  v_code text;
  v_codes text[] := ARRAY[
    'privacy_customers',
    'legal_notice',
    'portal_terms_customers',
    'cookie_notice',
    'privacy_website',
    'privacy_employees',
    'employee_portal_terms',
    'privacy_candidates',
    'dpa_platform'
  ];
BEGIN
  INSERT INTO data.tenant_legal_profiles (tenant_id)
  VALUES (p_tenant_id)
  ON CONFLICT (tenant_id) DO NOTHING;

  SELECT * INTO v_row FROM data.tenant_legal_profiles WHERE tenant_id = p_tenant_id;

  FOREACH v_code IN ARRAY v_codes LOOP
    INSERT INTO data.tenant_legal_documents (tenant_id, code, mode)
    VALUES (p_tenant_id, v_code, 'template')
    ON CONFLICT (tenant_id, code) DO NOTHING;
  END LOOP;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION data.ensure_tenant_legal_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.ensure_tenant_legal_profile(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Merge helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.legal_subprocessors_html()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(
    string_agg(
      '<li><strong>' || name || '</strong>'
        || CASE WHEN purpose IS NOT NULL AND purpose <> '' THEN ' — ' || purpose ELSE '' END
        || CASE WHEN location IS NOT NULL AND location <> '' THEN ' (' || location || ')' ELSE '' END
        || '</li>',
      ''
      ORDER BY sort_order, name
    ),
    '<li>(Cap subprocessador publicat)</li>'
  )
  FROM data.platform_legal_subprocessors
  WHERE is_active;
$$;

CREATE OR REPLACE FUNCTION data.render_legal_template_body(
  p_body text,
  p_tenant_id uuid
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_profile data.tenant_legal_profiles%ROWTYPE;
  v_tenant_name text;
  v_out text := COALESCE(p_body, '');
BEGIN
  v_profile := data.ensure_tenant_legal_profile(p_tenant_id);
  SELECT name INTO v_tenant_name FROM data.tenants WHERE id = p_tenant_id;

  v_out := replace(v_out, '{{legal_name}}', COALESCE(NULLIF(btrim(v_profile.legal_name), ''), v_tenant_name, ''));
  v_out := replace(v_out, '{{trade_name}}', COALESCE(NULLIF(btrim(v_profile.trade_name), ''), v_tenant_name, ''));
  v_out := replace(v_out, '{{nif}}', COALESCE(v_profile.nif, ''));
  v_out := replace(v_out, '{{registry_info}}', COALESCE(v_profile.registry_info, ''));
  v_out := replace(v_out, '{{privacy_email}}', COALESCE(v_profile.privacy_email, ''));
  v_out := replace(v_out, '{{dpo_email}}', COALESCE(v_profile.dpo_email, ''));
  v_out := replace(v_out, '{{dpo_name}}', COALESCE(v_profile.dpo_name, ''));
  v_out := replace(v_out, '{{postal_address}}', COALESCE(v_profile.postal_address, ''));
  v_out := replace(v_out, '{{website_url}}', COALESCE(v_profile.website_url, ''));
  v_out := replace(v_out, '{{retention_summary}}', COALESCE(v_profile.retention_summary, ''));
  v_out := replace(v_out, '{{subprocessors_html}}', data.legal_subprocessors_html());
  v_out := replace(
    v_out,
    '{{disclaimer_html}}',
    '<p><em>Text orientatiu de la plataforma. Valideu-lo amb la vostra assessoria. El responsable del tractament és l''organització indicada com a legal_name / tenant.</em></p>'
  );
  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION data.legal_subprocessors_html() FROM PUBLIC;
REVOKE ALL ON FUNCTION data.render_legal_template_body(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.legal_subprocessors_html() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION data.render_legal_template_body(text, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. Staff RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_my_tenant_legal_center()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_profile data.tenant_legal_profiles%ROWTYPE;
  v_docs jsonb;
  v_incomplete boolean;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);
  v_profile := data.ensure_tenant_legal_profile(v_tenant);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', d.id,
      'code', d.code,
      'mode', d.mode,
      'external_url', d.external_url,
      'updated_at', d.updated_at
    )
    ORDER BY d.code
  ), '[]'::jsonb)
  INTO v_docs
  FROM data.tenant_legal_documents d
  WHERE d.tenant_id = v_tenant;

  v_incomplete :=
    NULLIF(btrim(COALESCE(v_profile.legal_name, '')), '') IS NULL
    OR NULLIF(btrim(COALESCE(v_profile.privacy_email, '')), '') IS NULL;

  RETURN jsonb_build_object(
    'profile', to_jsonb(v_profile),
    'documents', v_docs,
    'incomplete', v_incomplete,
    'disclaimer',
      'Les plantilles són orientatives. El tenant és el responsable del tractament; la plataforma és l''encarregat sota DPA.'
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_my_tenant_legal_center() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_my_tenant_legal_center() TO authenticated;

CREATE OR REPLACE FUNCTION api.upsert_my_tenant_legal_profile(
  p_legal_name text DEFAULT NULL,
  p_trade_name text DEFAULT NULL,
  p_nif text DEFAULT NULL,
  p_registry_info text DEFAULT NULL,
  p_privacy_email text DEFAULT NULL,
  p_dpo_email text DEFAULT NULL,
  p_dpo_name text DEFAULT NULL,
  p_postal_address text DEFAULT NULL,
  p_website_url text DEFAULT NULL,
  p_retention_summary text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
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
  PERFORM data.ensure_tenant_legal_profile(v_tenant);

  UPDATE data.tenant_legal_profiles SET
    legal_name = COALESCE(p_legal_name, legal_name),
    trade_name = COALESCE(p_trade_name, trade_name),
    nif = COALESCE(p_nif, nif),
    registry_info = COALESCE(p_registry_info, registry_info),
    privacy_email = COALESCE(p_privacy_email, privacy_email),
    dpo_email = COALESCE(p_dpo_email, dpo_email),
    dpo_name = COALESCE(p_dpo_name, dpo_name),
    postal_address = COALESCE(p_postal_address, postal_address),
    website_url = COALESCE(p_website_url, website_url),
    retention_summary = COALESCE(p_retention_summary, retention_summary),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE tenant_id = v_tenant;

  RETURN api.get_my_tenant_legal_center();
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_my_tenant_legal_profile(
  text, text, text, text, text, text, text, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_my_tenant_legal_profile(
  text, text, text, text, text, text, text, text, text, text
) TO authenticated;

CREATE OR REPLACE FUNCTION api.set_my_tenant_legal_document_mode(
  p_code text,
  p_mode text,
  p_external_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
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
  PERFORM data.ensure_tenant_legal_profile(v_tenant);

  IF p_mode NOT IN ('template', 'edited', 'external_url') THEN
    RAISE EXCEPTION 'invalid_mode' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.tenant_legal_documents
  SET
    mode = p_mode,
    external_url = CASE WHEN p_mode = 'external_url' THEN NULLIF(btrim(p_external_url), '') ELSE NULL END,
    updated_at = now()
  WHERE tenant_id = v_tenant AND code = p_code;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'P0001';
  END IF;

  RETURN api.get_my_tenant_legal_center();
END;
$$;

REVOKE ALL ON FUNCTION api.set_my_tenant_legal_document_mode(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_my_tenant_legal_document_mode(text, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 11. Public resolve (anon + authenticated) — no PII beyond published legal text
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.resolve_public_legal_document(
  p_code text,
  p_locale text DEFAULT 'es',
  p_tenant_id uuid DEFAULT NULL,
  p_public_site_slug text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid;
  v_doc data.tenant_legal_documents%ROWTYPE;
  v_ver data.tenant_legal_document_versions%ROWTYPE;
  v_tpl data.platform_legal_templates%ROWTYPE;
  v_locale text := lower(COALESCE(NULLIF(btrim(p_locale), ''), 'es'));
  v_title text;
  v_body text;
  v_try text;
BEGIN
  IF p_tenant_id IS NOT NULL THEN
    v_tenant := p_tenant_id;
  ELSIF p_public_site_slug IS NOT NULL THEN
    SELECT ps.tenant_id INTO v_tenant
    FROM data.public_sites ps
    WHERE ps.slug = p_public_site_slug
      AND ps.status = 'published'
    LIMIT 1;
  END IF;

  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'tenant_not_found');
  END IF;

  PERFORM data.ensure_tenant_legal_profile(v_tenant);

  SELECT * INTO v_doc
  FROM data.tenant_legal_documents
  WHERE tenant_id = v_tenant AND code = p_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'document_not_found');
  END IF;

  IF v_doc.mode = 'external_url' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'mode', 'external_url',
      'code', p_code,
      'external_url', v_doc.external_url,
      'tenant_id', v_tenant
    );
  END IF;

  -- Locale fallback: requested → es → ca → en → any published
  FOREACH v_try IN ARRAY ARRAY[v_locale, 'es', 'ca', 'en'] LOOP
    SELECT * INTO v_ver
    FROM data.tenant_legal_document_versions
    WHERE document_id = v_doc.id AND locale = v_try AND status = 'published'
    LIMIT 1;
    EXIT WHEN FOUND;
  END LOOP;

  IF v_doc.mode = 'edited' AND FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'mode', 'edited',
      'code', p_code,
      'locale', v_ver.locale,
      'title', v_ver.title,
      'body_html', v_ver.body_html,
      'version_number', v_ver.version_number,
      'effective_at', v_ver.effective_at,
      'tenant_id', v_tenant
    );
  END IF;

  -- template mode (or edited without published version yet)
  FOREACH v_try IN ARRAY ARRAY[v_locale, 'es', 'ca', 'en'] LOOP
    SELECT * INTO v_tpl
    FROM data.platform_legal_templates
    WHERE code = p_code AND locale = v_try AND is_current
    LIMIT 1;
    EXIT WHEN FOUND;
  END LOOP;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'template_missing', 'code', p_code);
  END IF;

  v_title := v_tpl.title;
  v_body := data.render_legal_template_body(v_tpl.body_html, v_tenant);

  RETURN jsonb_build_object(
    'ok', true,
    'mode', 'template',
    'code', p_code,
    'locale', v_tpl.locale,
    'title', v_title,
    'body_html', v_body,
    'template_version', v_tpl.version,
    'tenant_id', v_tenant,
    'disclaimer', true
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_public_legal_document(text, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_public_legal_document(text, text, uuid, text)
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 12. Seed subprocessors + minimal templates (placeholder; texts refine in LC-1 UI)
-- ---------------------------------------------------------------------------
INSERT INTO data.platform_legal_subprocessors (code, name, purpose, location, sort_order)
VALUES
  ('supabase', 'Supabase', 'Hosting de base de dades, autenticació i emmagatzematge', 'UE / proveïdor cloud', 10),
  ('vercel', 'Vercel', 'Hosting d''aplicacions web', 'UE / proveïdor cloud', 20)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  purpose = EXCLUDED.purpose,
  location = EXCLUDED.location,
  sort_order = EXCLUDED.sort_order,
  updated_at = now(),
  is_active = true;

-- Minimal bilingual placeholders (ca/es/en) for core surface docs
DO $$
DECLARE
  r record;
  v_codes text[] := ARRAY['privacy_customers', 'cookie_notice', 'legal_notice', 'privacy_website'];
  v_code text;
  v_locale text;
  v_title text;
  v_body text;
BEGIN
  FOREACH v_code IN ARRAY v_codes LOOP
    FOREACH v_locale IN ARRAY ARRAY['ca', 'es', 'en'] LOOP
      v_title := CASE v_code
        WHEN 'privacy_customers' THEN CASE v_locale
          WHEN 'ca' THEN 'Política de privacitat (clients)'
          WHEN 'es' THEN 'Política de privacidad (clientes)'
          ELSE 'Privacy policy (customers)' END
        WHEN 'cookie_notice' THEN CASE v_locale
          WHEN 'ca' THEN 'Avís de cookies'
          WHEN 'es' THEN 'Aviso de cookies'
          ELSE 'Cookie notice' END
        WHEN 'legal_notice' THEN CASE v_locale
          WHEN 'ca' THEN 'Avís legal'
          WHEN 'es' THEN 'Aviso legal'
          ELSE 'Legal notice' END
        ELSE CASE v_locale
          WHEN 'ca' THEN 'Privacitat (web)'
          WHEN 'es' THEN 'Privacidad (web)'
          ELSE 'Website privacy' END
      END;

      v_body := '{{disclaimer_html}}'
        || '<h1>' || v_title || '</h1>'
        || '<p><strong>{{legal_name}}</strong> (NIF {{nif}})</p>'
        || '<p>Contacte privacitat: {{privacy_email}}</p>'
        || CASE WHEN v_code = 'cookie_notice' THEN
             '<p>Aquest lloc utilitza cookies tècniques essencials per a la sessió i la seguretat. No s''utilitzen cookies de màrqueting mentre no s''activi un CMP.</p>'
           WHEN v_code IN ('privacy_customers', 'privacy_website') THEN
             '<p>El responsable del tractament és {{legal_name}}. La plataforma actua com a encarregat del tractament.</p>'
             || '<p>Finalitat: prestar el servei / portal / formulari corresponent.</p>'
             || '<p>Conservació: {{retention_summary}}</p>'
             || '<p>Encarregats / subprocessadors:</p><ul>{{subprocessors_html}}</ul>'
             || '<p>Podeu exercir els vostres drets adreçant-vos a {{privacy_email}}.</p>'
           ELSE
             '<p>Dades identificatives: {{legal_name}}, {{nif}}, {{postal_address}}, {{website_url}}.</p>'
             || '<p>{{registry_info}}</p>'
           END;

      UPDATE data.platform_legal_templates SET is_current = false
      WHERE code = v_code AND locale = v_locale AND is_current;

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
