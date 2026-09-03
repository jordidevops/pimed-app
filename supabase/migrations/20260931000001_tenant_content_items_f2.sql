-- =============================================================================
-- Migration: 20260931000001_tenant_content_items_f2.sql
-- TCMS-1 Fase F2 — tenant_content_items, sync public_pages, RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Taula tenant_content_items
-- ---------------------------------------------------------------------------
CREATE TABLE data.tenant_content_items (
  id                               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                        uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,

  content_type                     text        NOT NULL DEFAULT 'page'
                                   CHECK (content_type IN ('page', 'announcement')),

  slug                             text        NOT NULL
                                   CHECK (slug ~ '^[a-z0-9][a-z0-9\-]{0,99}$'),

  title                            text        NOT NULL,
  excerpt                          text,
  content                          jsonb       NOT NULL DEFAULT '{"html":""}',
  translations                     jsonb       NOT NULL DEFAULT '{}',

  status                           text        NOT NULL DEFAULT 'draft'
                                   CHECK (status IN ('draft', 'published', 'archived')),

  publish_start_at                 timestamptz,
  publish_end_at                   timestamptz,
  published_at                     timestamptz,
  is_sticky                        boolean     NOT NULL DEFAULT false,
  sort_order                       int         NOT NULL DEFAULT 0,
  featured_image_url               text,

  employee_channel_enabled         boolean     NOT NULL DEFAULT false,
  employee_audience_scope          text        NOT NULL DEFAULT 'tenant'
                                   CHECK (employee_audience_scope IN ('tenant', 'site', 'departments')),
  employee_audience_site_id        uuid        REFERENCES data.sites(id) ON DELETE SET NULL,
  employee_audience_department_ids uuid[]      NOT NULL DEFAULT '{}',

  public_channel_enabled           boolean     NOT NULL DEFAULT false,
  public_site_id                   uuid        REFERENCES data.public_sites(id) ON DELETE SET NULL,
  public_show_in_nav               boolean     NOT NULL DEFAULT true,
  public_show_lead_form            boolean     NOT NULL DEFAULT false,
  seo_title                        text,
  seo_description                  text,
  public_page_id                   uuid        REFERENCES data.public_pages(id) ON DELETE SET NULL,

  created_by                       uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at                       timestamptz NOT NULL DEFAULT now(),
  updated_at                       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_tenant_content_at_least_one_channel
    CHECK (employee_channel_enabled OR public_channel_enabled),
  CONSTRAINT chk_employee_audience_site
    CHECK (employee_audience_scope <> 'site' OR employee_audience_site_id IS NOT NULL),
  CONSTRAINT chk_employee_audience_departments
    CHECK (employee_audience_scope <> 'departments' OR cardinality(employee_audience_department_ids) > 0),
  CONSTRAINT chk_public_channel_site
    CHECK (NOT public_channel_enabled OR public_site_id IS NOT NULL)
);

CREATE UNIQUE INDEX uq_tci_public_site_slug
  ON data.tenant_content_items (tenant_id, public_site_id, slug)
  WHERE public_channel_enabled = true AND public_site_id IS NOT NULL;

CREATE UNIQUE INDEX uq_tci_employee_only_slug
  ON data.tenant_content_items (tenant_id, slug)
  WHERE employee_channel_enabled = true AND NOT public_channel_enabled;

CREATE INDEX idx_tci_tenant_status ON data.tenant_content_items (tenant_id, status);
CREATE INDEX idx_tci_tenant_employee ON data.tenant_content_items (tenant_id, employee_channel_enabled)
  WHERE employee_channel_enabled = true;
CREATE INDEX idx_tci_tenant_public ON data.tenant_content_items (tenant_id, public_channel_enabled)
  WHERE public_channel_enabled = true;

CREATE TRIGGER trg_tenant_content_items_updated_at
  BEFORE UPDATE ON data.tenant_content_items
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

COMMENT ON TABLE data.tenant_content_items IS
  'Font de veritat TCMS-1 per contingut portal empleat + projecció web pública.';

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.tcms_api_error(p_code text, p_message text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'ok', false,
    'code', p_code,
    'message', COALESCE(p_message, p_code)
  );
$$;

CREATE OR REPLACE FUNCTION data.tcms_parse_error_code(p_sqlerrm text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(NULLIF(split_part(COALESCE(p_sqlerrm, ''), ':', 1), ''), 'internal_error');
$$;

CREATE OR REPLACE FUNCTION data.tcms_require_tenant_manager(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = data, public
AS $$
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context' USING ERRCODE = 'P0001';
  END IF;

  IF data.active_tenant_id() IS NOT NULL
     AND data.active_tenant_id() IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'forbidden_tenant' USING ERRCODE = 'P0001';
  END IF;

  IF NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'forbidden_tenant' USING ERRCODE = 'P0001';
  END IF;

  IF (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden_role' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION data.tcms_cms_tier_sufficient(p_tier text, p_min text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT data.portal_cms_tier_rank(COALESCE(p_tier, 'none'))
      >= data.portal_cms_tier_rank(COALESCE(p_min, 'none'));
$$;

-- ---------------------------------------------------------------------------
-- 3. Trigger tier enforcement
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.validate_tenant_content_tier(p_row data.tenant_content_items)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = data, public
AS $$
DECLARE
  v_ent      jsonb;
  v_emp_tier text;
  v_pub_tier text;
BEGIN
  v_ent := data.resolve_portal_entitlements(p_row.tenant_id);
  v_emp_tier := COALESCE(v_ent->'employee_portal'->>'cms_tier', 'none');
  v_pub_tier := COALESCE(v_ent->'public_portal'->>'cms_tier', 'none');

  IF p_row.employee_channel_enabled THEN
    IF p_row.employee_audience_scope <> 'tenant'
       AND NOT data.tcms_cms_tier_sufficient(v_emp_tier, 'advanced') THEN
      RAISE EXCEPTION 'cms_tier_insufficient:employee audience scope requires advanced'
        USING ERRCODE = 'P0001';
    END IF;

    IF p_row.is_sticky
       AND NOT data.tcms_cms_tier_sufficient(v_emp_tier, 'advanced') THEN
      RAISE EXCEPTION 'cms_tier_insufficient:sticky requires advanced employee tier'
        USING ERRCODE = 'P0001';
    END IF;

    IF (p_row.publish_start_at IS NOT NULL OR p_row.publish_end_at IS NOT NULL)
       AND NOT data.tcms_cms_tier_sufficient(v_emp_tier, 'advanced') THEN
      RAISE EXCEPTION 'cms_tier_insufficient:scheduled publish requires advanced employee tier'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF p_row.public_channel_enabled THEN
    IF p_row.public_show_lead_form
       AND NOT data.tcms_cms_tier_sufficient(v_pub_tier, 'advanced') THEN
      RAISE EXCEPTION 'cms_tier_insufficient:lead form requires advanced public tier'
        USING ERRCODE = 'P0001';
    END IF;

    IF p_row.translations IS NOT NULL
       AND p_row.translations <> '{}'::jsonb
       AND NOT data.tcms_cms_tier_sufficient(v_pub_tier, 'advanced') THEN
      RAISE EXCEPTION 'cms_tier_insufficient:public translations require advanced tier'
        USING ERRCODE = 'P0001';
    END IF;

    IF (p_row.publish_start_at IS NOT NULL OR p_row.publish_end_at IS NOT NULL)
       AND NOT data.tcms_cms_tier_sufficient(v_pub_tier, 'advanced') THEN
      RAISE EXCEPTION 'cms_tier_insufficient:scheduled publish requires advanced public tier'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION data.enforce_tenant_content_tier()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = data, public
AS $$
BEGIN
  IF current_role IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  PERFORM data.validate_tenant_content_tier(NEW);
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_tenant_content_tier
  BEFORE INSERT OR UPDATE ON data.tenant_content_items
  FOR EACH ROW EXECUTE FUNCTION data.enforce_tenant_content_tier();

-- ---------------------------------------------------------------------------
-- 4. Trigger field limits (reutilitza límits del pla)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.enforce_tenant_content_field_limits()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = data, public
AS $$
DECLARE
  v_limits   jsonb;
  v_locale   text;
  v_html_lim integer;
  v_ttl_lim  integer;
  v_seo_t    integer;
  v_seo_d    integer;
BEGIN
  IF current_role IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(p.portal_field_limits, '{}')
    INTO v_limits
    FROM data.tenants t
    JOIN data.plans p ON p.id = t.plan_id
   WHERE t.id = NEW.tenant_id;

  v_html_lim := COALESCE((v_limits->>'page_html_max_chars')::integer, 0);
  v_ttl_lim  := COALESCE((v_limits->>'page_title_max_chars')::integer, 0);
  v_seo_t    := COALESCE((v_limits->>'page_seo_title_max_chars')::integer, 0);
  v_seo_d    := COALESCE((v_limits->>'page_seo_description_max_chars')::integer, 0);

  IF v_ttl_lim > 0 AND char_length(NEW.title) > v_ttl_lim THEN
    RAISE EXCEPTION 'field_limit_exceeded:title: % caràcters (màxim %)',
      char_length(NEW.title), v_ttl_lim USING ERRCODE = 'P0001';
  END IF;

  IF v_seo_t > 0 AND NEW.seo_title IS NOT NULL AND char_length(NEW.seo_title) > v_seo_t THEN
    RAISE EXCEPTION 'field_limit_exceeded:seo_title' USING ERRCODE = 'P0001';
  END IF;

  IF v_seo_d > 0 AND NEW.seo_description IS NOT NULL AND char_length(NEW.seo_description) > v_seo_d THEN
    RAISE EXCEPTION 'field_limit_exceeded:seo_description' USING ERRCODE = 'P0001';
  END IF;

  IF v_html_lim > 0
     AND (NEW.content->>'html') IS NOT NULL
     AND char_length(NEW.content->>'html') > v_html_lim THEN
    RAISE EXCEPTION 'field_limit_exceeded:content.html' USING ERRCODE = 'P0001';
  END IF;

  IF NEW.translations IS NOT NULL AND NEW.translations <> '{}'::jsonb THEN
    FOR v_locale IN SELECT jsonb_object_keys(NEW.translations) LOOP
      IF v_ttl_lim > 0
         AND (NEW.translations->v_locale->>'title') IS NOT NULL
         AND char_length(NEW.translations->v_locale->>'title') > v_ttl_lim THEN
        RAISE EXCEPTION 'field_limit_exceeded:translations.%.title', v_locale USING ERRCODE = 'P0001';
      END IF;
      IF v_html_lim > 0
         AND (NEW.translations->v_locale->'content'->>'html') IS NOT NULL
         AND char_length(NEW.translations->v_locale->'content'->>'html') > v_html_lim THEN
        RAISE EXCEPTION 'field_limit_exceeded:translations.%.content.html', v_locale USING ERRCODE = 'P0001';
      END IF;
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_tenant_content_field_limits
  BEFORE INSERT OR UPDATE ON data.tenant_content_items
  FOR EACH ROW EXECUTE FUNCTION data.enforce_tenant_content_field_limits();

-- ---------------------------------------------------------------------------
-- 5. Audit trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_tenant_content_items()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_action text;
  v_payload jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := 'TENANT_CONTENT_CREATED';
    v_payload := jsonb_build_object(
      'channel', CASE
        WHEN NEW.employee_channel_enabled AND NEW.public_channel_enabled THEN 'dual'
        WHEN NEW.public_channel_enabled THEN 'public'
        ELSE 'employee'
      END,
      'content_type', NEW.content_type,
      'slug', NEW.slug,
      'new_status', NEW.status
    );
    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NULL, v_action, 'tenant_content_item', NEW.id, v_payload
    );
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      v_action := CASE NEW.status
        WHEN 'published' THEN 'TENANT_CONTENT_PUBLISHED'
        WHEN 'archived'  THEN 'TENANT_CONTENT_ARCHIVED'
        ELSE 'TENANT_CONTENT_UPDATED'
      END;
    ELSIF NEW.public_page_id IS DISTINCT FROM OLD.public_page_id
       OR NEW.public_channel_enabled IS DISTINCT FROM OLD.public_channel_enabled THEN
      v_action := 'TENANT_CONTENT_CHANNEL_SYNCED';
    ELSE
      v_action := 'TENANT_CONTENT_UPDATED';
    END IF;

    v_payload := jsonb_build_object(
      'channel', CASE
        WHEN NEW.employee_channel_enabled AND NEW.public_channel_enabled THEN 'dual'
        WHEN NEW.public_channel_enabled THEN 'public'
        ELSE 'employee'
      END,
      'content_type', NEW.content_type,
      'slug', NEW.slug,
      'old_status', OLD.status,
      'new_status', NEW.status,
      'char_delta', char_length(COALESCE(NEW.content->>'html', ''))
                  - char_length(COALESCE(OLD.content->>'html', ''))
    );

    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NULL, v_action, 'tenant_content_item', NEW.id, v_payload
    );
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_tenant_content_items
  AFTER INSERT OR UPDATE ON data.tenant_content_items
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_tenant_content_items();

-- ---------------------------------------------------------------------------
-- 6. Sync a public_pages
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.sync_content_item_to_public_page(p_item_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_item    data.tenant_content_items%ROWTYPE;
  v_content jsonb;
  v_check   jsonb;
  v_page_id uuid;
BEGIN
  SELECT * INTO v_item FROM data.tenant_content_items WHERE id = p_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'item_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF NOT v_item.public_channel_enabled
     OR v_item.status <> 'published'
     OR v_item.public_site_id IS NULL THEN
    IF v_item.public_page_id IS NOT NULL THEN
      UPDATE data.public_pages
         SET status = 'draft', updated_at = now()
       WHERE id = v_item.public_page_id;
    END IF;
    RETURN v_item.public_page_id;
  END IF;

  v_check := api.can_publish_content(
    v_item.tenant_id, 'public', 'publish', v_item.public_site_id
  );
  IF NOT COALESCE((v_check->>'allowed')::boolean, false) THEN
    RAISE EXCEPTION '%', COALESCE(v_check->>'code', 'publish_not_allowed') USING ERRCODE = 'P0001';
  END IF;

  v_content := COALESCE(v_item.content, '{}'::jsonb)
    || jsonb_build_object('show_lead_form', v_item.public_show_lead_form);

  INSERT INTO data.public_pages (
    public_site_id, tenant_id, slug, title, content, translations,
    status, seo_title, seo_description, sort_order, show_in_nav
  ) VALUES (
    v_item.public_site_id,
    v_item.tenant_id,
    v_item.slug,
    v_item.title,
    v_content,
    COALESCE(v_item.translations, '{}'::jsonb),
    'published',
    v_item.seo_title,
    v_item.seo_description,
    v_item.sort_order,
    v_item.public_show_in_nav
  )
  ON CONFLICT (public_site_id, slug)
  DO UPDATE SET
    title           = EXCLUDED.title,
    content         = EXCLUDED.content,
    translations    = EXCLUDED.translations,
    status          = 'published',
    seo_title       = EXCLUDED.seo_title,
    seo_description = EXCLUDED.seo_description,
    sort_order      = EXCLUDED.sort_order,
    show_in_nav     = EXCLUDED.show_in_nav,
    updated_at      = now()
  RETURNING id INTO v_page_id;

  UPDATE data.tenant_content_items
     SET public_page_id = v_page_id, updated_at = now()
   WHERE id = p_item_id;

  RETURN v_page_id;
END;
$$;

REVOKE ALL ON FUNCTION data.sync_content_item_to_public_page(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.sync_content_item_to_public_page(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. RLS
-- ---------------------------------------------------------------------------
ALTER TABLE data.tenant_content_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tci: membres del tenant poden veure"
  ON data.tenant_content_items FOR SELECT
  USING (data.jwt_user_tenants() ? tenant_id::text);

CREATE POLICY "tci: owner/manager pot crear"
  ON data.tenant_content_items FOR INSERT
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE POLICY "tci: owner/manager pot modificar"
  ON data.tenant_content_items FOR UPDATE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE POLICY "tci: owner/manager pot eliminar"
  ON data.tenant_content_items FOR DELETE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.tenant_content_items TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Vista api
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.tenant_content_items
  WITH (security_invoker = true)
AS
SELECT tci.*
FROM data.tenant_content_items tci
WHERE data.jwt_user_tenants() ? tci.tenant_id::text
  AND (
    data.active_tenant_id() IS NULL
    OR tci.tenant_id = data.active_tenant_id()
  );

GRANT SELECT ON api.tenant_content_items TO authenticated;

-- ---------------------------------------------------------------------------
-- 9. RPCs admin tenant
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_tenant_content_items(
  p_tenant_id uuid,
  p_filters   jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_rows jsonb;
BEGIN
  PERFORM data.tcms_require_tenant_manager(p_tenant_id);

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.updated_at DESC), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT *
        FROM data.tenant_content_items tci
       WHERE tci.tenant_id = p_tenant_id
         AND (p_filters->>'status' IS NULL OR tci.status = p_filters->>'status')
         AND (p_filters->>'content_type' IS NULL OR tci.content_type = p_filters->>'content_type')
         AND (
           p_filters->>'public_site_id' IS NULL
           OR tci.public_site_id = (p_filters->>'public_site_id')::uuid
         )
         AND (
           p_filters->>'channel' IS NULL
           OR (p_filters->>'channel' = 'employee' AND tci.employee_channel_enabled AND NOT tci.public_channel_enabled)
           OR (p_filters->>'channel' = 'public' AND tci.public_channel_enabled AND NOT tci.employee_channel_enabled)
           OR (p_filters->>'channel' = 'dual' AND tci.employee_channel_enabled AND tci.public_channel_enabled)
         )
         AND (
           p_filters->>'search' IS NULL
           OR tci.title ILIKE '%' || (p_filters->>'search') || '%'
           OR tci.slug ILIKE '%' || (p_filters->>'search') || '%'
         )
    ) t;

  RETURN jsonb_build_object('ok', true, 'items', v_rows);
END;
$$;

CREATE OR REPLACE FUNCTION api.get_tenant_content_item(
  p_tenant_id uuid,
  p_item_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row data.tenant_content_items%ROWTYPE;
BEGIN
  PERFORM data.tcms_require_tenant_manager(p_tenant_id);

  SELECT * INTO v_row
    FROM data.tenant_content_items
   WHERE id = p_item_id AND tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN data.tcms_api_error('not_found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'item', to_jsonb(v_row));
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_tenant_content_item(
  p_tenant_id uuid,
  p_payload   jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_id      uuid;
  v_row     data.tenant_content_items%ROWTYPE;
  v_next    data.tenant_content_items%ROWTYPE;
  v_emp_on  boolean;
  v_pub_on  boolean;
BEGIN
  PERFORM data.tcms_require_tenant_manager(p_tenant_id);

  v_id := NULLIF(p_payload->>'id', '')::uuid;

  IF v_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.tenant_content_items
     WHERE id = v_id AND tenant_id = p_tenant_id;
    IF NOT FOUND THEN
      RETURN data.tcms_api_error('not_found');
    END IF;

    v_emp_on := COALESCE((p_payload->>'employee_channel_enabled')::boolean, v_row.employee_channel_enabled);
    v_pub_on := COALESCE((p_payload->>'public_channel_enabled')::boolean, v_row.public_channel_enabled);
  ELSE
    v_emp_on := COALESCE((p_payload->>'employee_channel_enabled')::boolean, false);
    v_pub_on := COALESCE((p_payload->>'public_channel_enabled')::boolean, false);
  END IF;

  IF NOT v_emp_on AND NOT v_pub_on THEN
    RETURN data.tcms_api_error('last_channel_required', 'At least one channel must remain enabled');
  END IF;

  IF v_pub_on AND COALESCE(
    (p_payload->>'public_site_id')::uuid,
    CASE WHEN v_id IS NOT NULL THEN v_row.public_site_id ELSE NULL END
  ) IS NULL THEN
    RETURN data.tcms_api_error('public_site_required');
  END IF;

  IF v_id IS NOT NULL THEN
    UPDATE data.tenant_content_items SET
      content_type                     = COALESCE(p_payload->>'content_type', content_type),
      slug                             = COALESCE(p_payload->>'slug', slug),
      title                            = COALESCE(p_payload->>'title', title),
      excerpt                          = COALESCE(p_payload->>'excerpt', excerpt),
      content                          = COALESCE(p_payload->'content', content),
      translations                     = COALESCE(p_payload->'translations', translations),
      publish_start_at                 = COALESCE((p_payload->>'publish_start_at')::timestamptz, publish_start_at),
      publish_end_at                   = COALESCE((p_payload->>'publish_end_at')::timestamptz, publish_end_at),
      is_sticky                        = COALESCE((p_payload->>'is_sticky')::boolean, is_sticky),
      sort_order                       = COALESCE((p_payload->>'sort_order')::integer, sort_order),
      featured_image_url               = COALESCE(p_payload->>'featured_image_url', featured_image_url),
      employee_channel_enabled         = v_emp_on,
      employee_audience_scope          = COALESCE(p_payload->>'employee_audience_scope', employee_audience_scope),
      employee_audience_site_id        = COALESCE((p_payload->>'employee_audience_site_id')::uuid, employee_audience_site_id),
      employee_audience_department_ids = COALESCE(
        ARRAY(SELECT jsonb_array_elements_text(p_payload->'employee_audience_department_ids'))::uuid[],
        employee_audience_department_ids
      ),
      public_channel_enabled           = v_pub_on,
      public_site_id                   = COALESCE((p_payload->>'public_site_id')::uuid, public_site_id),
      public_show_in_nav               = COALESCE((p_payload->>'public_show_in_nav')::boolean, public_show_in_nav),
      public_show_lead_form            = COALESCE((p_payload->>'public_show_lead_form')::boolean, public_show_lead_form),
      seo_title                        = COALESCE(p_payload->>'seo_title', seo_title),
      seo_description                  = COALESCE(p_payload->>'seo_description', seo_description),
      updated_at                       = now()
    WHERE id = v_id
    RETURNING * INTO v_next;
  ELSE
    INSERT INTO data.tenant_content_items (
      tenant_id, content_type, slug, title, excerpt, content, translations,
      publish_start_at, publish_end_at, is_sticky, sort_order, featured_image_url,
      employee_channel_enabled, employee_audience_scope, employee_audience_site_id,
      employee_audience_department_ids, public_channel_enabled, public_site_id,
      public_show_in_nav, public_show_lead_form, seo_title, seo_description, created_by
    ) VALUES (
      p_tenant_id,
      COALESCE(p_payload->>'content_type', 'page'),
      p_payload->>'slug',
      p_payload->>'title',
      p_payload->>'excerpt',
      COALESCE(p_payload->'content', '{"html":""}'::jsonb),
      COALESCE(p_payload->'translations', '{}'::jsonb),
      (p_payload->>'publish_start_at')::timestamptz,
      (p_payload->>'publish_end_at')::timestamptz,
      COALESCE((p_payload->>'is_sticky')::boolean, false),
      COALESCE((p_payload->>'sort_order')::integer, 0),
      p_payload->>'featured_image_url',
      v_emp_on,
      COALESCE(p_payload->>'employee_audience_scope', 'tenant'),
      (p_payload->>'employee_audience_site_id')::uuid,
      COALESCE(
        ARRAY(SELECT jsonb_array_elements_text(p_payload->'employee_audience_department_ids'))::uuid[],
        '{}'::uuid[]
      ),
      v_pub_on,
      (p_payload->>'public_site_id')::uuid,
      COALESCE((p_payload->>'public_show_in_nav')::boolean, true),
      COALESCE((p_payload->>'public_show_lead_form')::boolean, false),
      p_payload->>'seo_title',
      p_payload->>'seo_description',
      auth.uid()
    )
    RETURNING * INTO v_next;
  END IF;

  PERFORM data.validate_tenant_content_tier(v_next);
  RETURN jsonb_build_object('ok', true, 'item', to_jsonb(v_next));

EXCEPTION WHEN OTHERS THEN
  RETURN data.tcms_api_error(
    data.tcms_parse_error_code(SQLERRM),
    SQLERRM
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.publish_tenant_content_item(
  p_tenant_id uuid,
  p_item_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row   data.tenant_content_items%ROWTYPE;
  v_check jsonb;
  v_page  uuid;
BEGIN
  PERFORM data.tcms_require_tenant_manager(p_tenant_id);

  SELECT * INTO v_row FROM data.tenant_content_items
   WHERE id = p_item_id AND tenant_id = p_tenant_id;
  IF NOT FOUND THEN
    RETURN data.tcms_api_error('not_found');
  END IF;

  IF v_row.employee_channel_enabled THEN
    v_check := api.can_publish_content(p_tenant_id, 'employee', 'publish');
    IF NOT COALESCE((v_check->>'allowed')::boolean, false) THEN
      RETURN data.tcms_api_error(COALESCE(v_check->>'code', 'publish_not_allowed'));
    END IF;
  END IF;

  IF v_row.public_channel_enabled THEN
    v_check := api.can_publish_content(p_tenant_id, 'public', 'publish', v_row.public_site_id);
    IF NOT COALESCE((v_check->>'allowed')::boolean, false) THEN
      RETURN data.tcms_api_error(COALESCE(v_check->>'code', 'publish_not_allowed'));
    END IF;
  END IF;

  UPDATE data.tenant_content_items
     SET status = 'published',
         published_at = COALESCE(published_at, now()),
         updated_at = now()
   WHERE id = p_item_id;

  IF v_row.public_channel_enabled THEN
    v_page := data.sync_content_item_to_public_page(p_item_id);
  END IF;

  SELECT * INTO v_row FROM data.tenant_content_items WHERE id = p_item_id;

  RETURN jsonb_build_object(
    'ok', true,
    'item', to_jsonb(v_row),
    'public_page_id', v_page,
    'revalidate', jsonb_build_object(
      'public_site_id', v_row.public_site_id,
      'slug', v_row.slug
    )
  );

EXCEPTION WHEN OTHERS THEN
  RETURN data.tcms_api_error(data.tcms_parse_error_code(SQLERRM), SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION api.archive_tenant_content_item(
  p_tenant_id uuid,
  p_item_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row data.tenant_content_items%ROWTYPE;
BEGIN
  PERFORM data.tcms_require_tenant_manager(p_tenant_id);

  SELECT * INTO v_row FROM data.tenant_content_items
   WHERE id = p_item_id AND tenant_id = p_tenant_id;
  IF NOT FOUND THEN
    RETURN data.tcms_api_error('not_found');
  END IF;

  UPDATE data.tenant_content_items
     SET status = 'archived', updated_at = now()
   WHERE id = p_item_id;

  PERFORM data.sync_content_item_to_public_page(p_item_id);

  SELECT * INTO v_row FROM data.tenant_content_items WHERE id = p_item_id;
  RETURN jsonb_build_object('ok', true, 'item', to_jsonb(v_row));

EXCEPTION WHEN OTHERS THEN
  RETURN data.tcms_api_error(data.tcms_parse_error_code(SQLERRM), SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION api.get_tenant_content_usage(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_ent jsonb;
BEGIN
  PERFORM data.tcms_require_tenant_manager(p_tenant_id);
  v_ent := data.resolve_portal_entitlements(p_tenant_id);

  RETURN jsonb_build_object(
    'ok', true,
    'entitlements', v_ent,
    'usage', jsonb_build_object(
      'content_items_total',
        (SELECT COUNT(*)::integer FROM data.tenant_content_items WHERE tenant_id = p_tenant_id AND status <> 'archived'),
      'content_items_employee_channel',
        (SELECT COUNT(*)::integer FROM data.tenant_content_items
          WHERE tenant_id = p_tenant_id AND employee_channel_enabled AND status <> 'archived'),
      'content_items_public_channel',
        (SELECT COUNT(*)::integer FROM data.tenant_content_items
          WHERE tenant_id = p_tenant_id AND public_channel_enabled AND status <> 'archived')
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.preview_tenant_content_reach(
  p_tenant_id uuid,
  p_item_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_item data.tenant_content_items%ROWTYPE;
  v_count integer;
BEGIN
  PERFORM data.tcms_require_tenant_manager(p_tenant_id);

  SELECT * INTO v_item FROM data.tenant_content_items
   WHERE id = p_item_id AND tenant_id = p_tenant_id;
  IF NOT FOUND THEN
    RETURN data.tcms_api_error('not_found');
  END IF;

  SELECT COUNT(*)::integer INTO v_count
    FROM data.employees e
   WHERE e.tenant_id = p_tenant_id
     AND e.status = 'active'
     AND (
       v_item.employee_audience_scope = 'tenant'
       OR (v_item.employee_audience_scope = 'site'
           AND e.site_id = v_item.employee_audience_site_id)
       OR (v_item.employee_audience_scope = 'departments'
           AND e.department_id = ANY(v_item.employee_audience_department_ids))
     );

  RETURN jsonb_build_object('ok', true, 'employee_count', v_count);
END;
$$;

-- ---------------------------------------------------------------------------
-- 10. RPCs portal empleat (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.employee_portal_list_content(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp  data.employees%ROWTYPE;
  v_ent  jsonb;
  v_rows jsonb;
BEGIN
  SELECT * INTO v_emp FROM data.employees
   WHERE id = p_employee_id AND tenant_id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  v_ent := data.resolve_portal_entitlements(p_tenant_id);
  IF NOT COALESCE((v_ent->'employee_portal'->>'effective')::boolean, false)
     OR COALESCE(v_ent->'employee_portal'->>'cms_tier', 'none') = 'none' THEN
    RAISE EXCEPTION 'content_module_disabled';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', t.id,
    'slug', t.slug,
    'title', t.title,
    'excerpt', t.excerpt,
    'content_type', t.content_type,
    'is_sticky', t.is_sticky,
    'published_at', t.published_at
  ) ORDER BY t.is_sticky DESC, t.sort_order ASC, t.published_at DESC NULLS LAST), '[]'::jsonb)
  INTO v_rows
  FROM data.tenant_content_items t
  WHERE t.tenant_id = p_tenant_id
    AND t.status = 'published'
    AND t.employee_channel_enabled = true
    AND (t.publish_start_at IS NULL OR t.publish_start_at <= now())
    AND (t.publish_end_at IS NULL OR t.publish_end_at > now())
    AND (
      t.employee_audience_scope = 'tenant'
      OR (t.employee_audience_scope = 'site' AND t.employee_audience_site_id = v_emp.site_id)
      OR (t.employee_audience_scope = 'departments'
          AND v_emp.department_id IS NOT NULL
          AND v_emp.department_id = ANY(t.employee_audience_department_ids))
    );

  RETURN jsonb_build_object('items', v_rows);
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_get_content_by_slug(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_slug        text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp data.employees%ROWTYPE;
  v_ent jsonb;
  v_row data.tenant_content_items%ROWTYPE;
BEGIN
  SELECT * INTO v_emp FROM data.employees
   WHERE id = p_employee_id AND tenant_id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  v_ent := data.resolve_portal_entitlements(p_tenant_id);
  IF NOT COALESCE((v_ent->'employee_portal'->>'effective')::boolean, false)
     OR COALESCE(v_ent->'employee_portal'->>'cms_tier', 'none') = 'none' THEN
    RAISE EXCEPTION 'content_module_disabled';
  END IF;

  SELECT * INTO v_row
    FROM data.tenant_content_items t
   WHERE t.tenant_id = p_tenant_id
     AND t.slug = p_slug
     AND t.status = 'published'
     AND t.employee_channel_enabled = true
     AND (t.publish_start_at IS NULL OR t.publish_start_at <= now())
     AND (t.publish_end_at IS NULL OR t.publish_end_at > now())
     AND (
       t.employee_audience_scope = 'tenant'
       OR (t.employee_audience_scope = 'site' AND t.employee_audience_site_id = v_emp.site_id)
       OR (t.employee_audience_scope = 'departments'
           AND v_emp.department_id IS NOT NULL
           AND v_emp.department_id = ANY(t.employee_audience_department_ids))
     )
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'content_not_found';
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'slug', v_row.slug,
    'title', v_row.title,
    'content_type', v_row.content_type,
    'content', v_row.content,
    'published_at', v_row.published_at
  );
END;
$$;

REVOKE ALL ON FUNCTION api.list_tenant_content_items(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_tenant_content_item(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.upsert_tenant_content_item(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.publish_tenant_content_item(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.archive_tenant_content_item(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_tenant_content_usage(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.preview_tenant_content_reach(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_list_content(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_get_content_by_slug(uuid, uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.list_tenant_content_items(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_tenant_content_item(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.upsert_tenant_content_item(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION api.publish_tenant_content_item(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.archive_tenant_content_item(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_tenant_content_usage(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.preview_tenant_content_reach(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.employee_portal_list_content(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_content_by_slug(uuid, uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 11. Backfill public_pages → tenant_content_items
-- ---------------------------------------------------------------------------
INSERT INTO data.tenant_content_items (
  tenant_id,
  content_type,
  slug,
  title,
  content,
  translations,
  status,
  sort_order,
  employee_channel_enabled,
  public_channel_enabled,
  public_site_id,
  public_show_in_nav,
  public_show_lead_form,
  seo_title,
  seo_description,
  public_page_id,
  published_at
)
SELECT
  pp.tenant_id,
  'page',
  pp.slug,
  pp.title,
  COALESCE(pp.content, '{"html":""}'::jsonb),
  COALESCE(pp.translations, '{}'::jsonb),
  CASE pp.status WHEN 'published' THEN 'published' ELSE 'draft' END,
  pp.sort_order,
  false,
  true,
  pp.public_site_id,
  COALESCE(pp.show_in_nav, true),
  COALESCE((pp.content->>'show_lead_form')::boolean, false),
  pp.seo_title,
  pp.seo_description,
  pp.id,
  CASE WHEN pp.status = 'published' THEN pp.updated_at ELSE NULL END
FROM data.public_pages pp
WHERE NOT EXISTS (
  SELECT 1 FROM data.tenant_content_items t WHERE t.public_page_id = pp.id
);
