-- =============================================================================
-- Migration: 20260520000001_public_portal_content_v1.sql
-- Propòsit:  Public Portal Content V1 — editor de contingut, header/footer,
--            logo, límits per pla i mètriques de consum.
--
-- Conté:
--   1.  ALTER data.plans   → max_portal_pages, portal_field_limits jsonb
--   2.  ALTER data.public_pages → show_in_nav boolean
--   3.  Trigger enforce_portal_page_quota  (quota de pàgines per pla)
--   4.  Trigger enforce_portal_field_limits (límit per camp editable, BD-side)
--   5.  RPC api.patch_public_site_theme    (deep-merge de theme_config)
--   6.  UPDATE RPC api.upsert_public_page  → afegit p_show_in_nav
--   7.  UPDATE vistes api.public_pages / api.public_pages_full → show_in_nav
--   8.  Vista api.portal_usage             (consum DB per portal)
--   9.  Audit: PUBLIC_PAGE_CONTENT_UPDATED, PUBLIC_SITE_THEME_UPDATED,
--              PUBLIC_SITE_LOGO_UPDATED (via trigger existent ampliat)
--
-- Nota sobre Storage (logo):
--   El bucket 'public-assets' (public=true, 2 MB, imatges) ja existeix des de
--   20260427000007. Path per al logo del portal: {tenant_id}/portal/logo.{ext}
--   Les policies d'Storage existents cobreixen qualsevol path sota {tenant_id}/.
--   Cap nova policy de Storage és necessària en aquesta migració.
--
-- Dependències:
--   · data.plans                   (20260401000002)
--   · data.public_pages            (20260513000001)
--   · data.public_sites            (20260513000001)
--   · data.log_audit_event         (20260503000002)
--   · data.trg_audit_public_sites  (20260513000001)
--   · data.trg_audit_public_pages  (20260513000001)
--   · api.public_pages             (20260515000011)
--   · api.public_pages_full        (20260515000014)
-- =============================================================================


-- =============================================================================
-- 1. ALTER data.plans — quota de portal i límits per camp
-- =============================================================================

ALTER TABLE data.plans
  ADD COLUMN IF NOT EXISTS max_portal_pages    integer NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS portal_field_limits jsonb   NOT NULL DEFAULT '{}';

COMMENT ON COLUMN data.plans.max_portal_pages
  IS 'Màxim de pàgines al portal públic per site. 0 = il·limitat.';

COMMENT ON COLUMN data.plans.portal_field_limits
  IS 'Límits per camp editable del portal (chars). Claus: page_html_max_chars, '
     'page_title_max_chars, page_seo_title_max_chars, page_seo_description_max_chars, '
     'footer_text_max_chars, header_cta_label_max_chars. 0 = il·limitat per a aquell camp.';


-- =============================================================================
-- 2. ALTER data.public_pages — visibilitat a la navegació
-- =============================================================================

ALTER TABLE data.public_pages
  ADD COLUMN IF NOT EXISTS show_in_nav boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN data.public_pages.show_in_nav
  IS 'Si true, la pàgina apareix a la nav automàtica del header i footer del portal. '
     'La pàgina home sempre s''inclou independentment d''aquest flag.';


-- =============================================================================
-- 3. Trigger: enforce_portal_page_quota
--    Impedeix crear pàgines per sobre del límit del pla.
--    Model: data.enforce_site_quota() (20260401000002).
--    Bypass: max_portal_pages = 0 (il·limitat) o rol privilegiat.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.enforce_portal_page_quota()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_limit   integer;
  v_current integer;
BEGIN
  -- Bypass per a rols privilegiats (admin-portal via Prisma, scripts)
  IF current_role IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  -- Obtenir límit del pla actiu del tenant
  SELECT p.max_portal_pages
    INTO v_limit
    FROM data.tenants t
    JOIN data.plans   p ON p.id = t.plan_id
   WHERE t.id = NEW.tenant_id;

  -- Sense pla o límit 0 = sense restricció
  IF v_limit IS NULL OR v_limit = 0 THEN
    RETURN NEW;
  END IF;

  -- Comptar pàgines existents del portal (sense la fila nova)
  SELECT COUNT(*)::integer
    INTO v_current
    FROM data.public_pages
   WHERE public_site_id = NEW.public_site_id;

  IF v_current >= v_limit THEN
    RAISE EXCEPTION 'quota_exceeded: El pla d''aquest tenant permet un màxim de % pàgines al portal. Millora el pla per afegir-ne més.',
      v_limit
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

-- Només a INSERT (no UPDATE: no reduïm quota en modificar pàgines existents)
DROP TRIGGER IF EXISTS trg_enforce_portal_page_quota ON data.public_pages;
CREATE TRIGGER trg_enforce_portal_page_quota
  BEFORE INSERT ON data.public_pages
  FOR EACH ROW EXECUTE FUNCTION data.enforce_portal_page_quota();


-- =============================================================================
-- 4. Trigger: enforce_portal_field_limits
--    Valida mida per camp editable en INSERT i UPDATE.
--    Límits llegits de plans.portal_field_limits per tenant.
--    Bypass: límit 0 per aquell camp = sense restricció.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.enforce_portal_field_limits()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_limits   jsonb;
  v_locale   text;
  v_html_lim integer;
  v_ttl_lim  integer;
  v_seo_t    integer;
  v_seo_d    integer;
BEGIN
  -- Bypass per a rols privilegiats
  IF current_role IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  -- Llegir límits del pla
  SELECT COALESCE(p.portal_field_limits, '{}')
    INTO v_limits
    FROM data.tenants t
    JOIN data.plans   p ON p.id = t.plan_id
   WHERE t.id = NEW.tenant_id;

  v_html_lim := COALESCE((v_limits->>'page_html_max_chars')::integer,          0);
  v_ttl_lim  := COALESCE((v_limits->>'page_title_max_chars')::integer,         0);
  v_seo_t    := COALESCE((v_limits->>'page_seo_title_max_chars')::integer,     0);
  v_seo_d    := COALESCE((v_limits->>'page_seo_description_max_chars')::integer, 0);

  -- title (camp base, obligatori)
  IF v_ttl_lim > 0 AND char_length(NEW.title) > v_ttl_lim THEN
    RAISE EXCEPTION 'field_limit_exceeded:title: % caràcters (màxim %)',
      char_length(NEW.title), v_ttl_lim
      USING ERRCODE = 'P0001';
  END IF;

  -- seo_title (opcional)
  IF v_seo_t > 0
     AND NEW.seo_title IS NOT NULL
     AND char_length(NEW.seo_title) > v_seo_t
  THEN
    RAISE EXCEPTION 'field_limit_exceeded:seo_title: % caràcters (màxim %)',
      char_length(NEW.seo_title), v_seo_t
      USING ERRCODE = 'P0001';
  END IF;

  -- seo_description (opcional)
  IF v_seo_d > 0
     AND NEW.seo_description IS NOT NULL
     AND char_length(NEW.seo_description) > v_seo_d
  THEN
    RAISE EXCEPTION 'field_limit_exceeded:seo_description: % caràcters (màxim %)',
      char_length(NEW.seo_description), v_seo_d
      USING ERRCODE = 'P0001';
  END IF;

  -- content.html (base locale)
  IF v_html_lim > 0
     AND (NEW.content->>'html') IS NOT NULL
     AND char_length(NEW.content->>'html') > v_html_lim
  THEN
    RAISE EXCEPTION 'field_limit_exceeded:content.html: % caràcters (màxim %)',
      char_length(NEW.content->>'html'), v_html_lim
      USING ERRCODE = 'P0001';
  END IF;

  -- Traduccions per locale
  IF NEW.translations IS NOT NULL AND NEW.translations != '{}'::jsonb THEN
    FOR v_locale IN SELECT jsonb_object_keys(NEW.translations) LOOP

      -- title per locale
      IF v_ttl_lim > 0
         AND (NEW.translations->v_locale->>'title') IS NOT NULL
         AND char_length(NEW.translations->v_locale->>'title') > v_ttl_lim
      THEN
        RAISE EXCEPTION 'field_limit_exceeded:translations.%.title: % caràcters (màxim %)',
          v_locale, char_length(NEW.translations->v_locale->>'title'), v_ttl_lim
          USING ERRCODE = 'P0001';
      END IF;

      -- seo_title per locale
      IF v_seo_t > 0
         AND (NEW.translations->v_locale->>'seoTitle') IS NOT NULL
         AND char_length(NEW.translations->v_locale->>'seoTitle') > v_seo_t
      THEN
        RAISE EXCEPTION 'field_limit_exceeded:translations.%.seoTitle: % caràcters (màxim %)',
          v_locale, char_length(NEW.translations->v_locale->>'seoTitle'), v_seo_t
          USING ERRCODE = 'P0001';
      END IF;

      -- seo_description per locale
      IF v_seo_d > 0
         AND (NEW.translations->v_locale->>'seoDescription') IS NOT NULL
         AND char_length(NEW.translations->v_locale->>'seoDescription') > v_seo_d
      THEN
        RAISE EXCEPTION 'field_limit_exceeded:translations.%.seoDescription: % caràcters (màxim %)',
          v_locale, char_length(NEW.translations->v_locale->>'seoDescription'), v_seo_d
          USING ERRCODE = 'P0001';
      END IF;

      -- content.html per locale
      IF v_html_lim > 0
         AND (NEW.translations->v_locale->'content'->>'html') IS NOT NULL
         AND char_length(NEW.translations->v_locale->'content'->>'html') > v_html_lim
      THEN
        RAISE EXCEPTION 'field_limit_exceeded:translations.%.content.html: % caràcters (màxim %)',
          v_locale, char_length(NEW.translations->v_locale->'content'->>'html'), v_html_lim
          USING ERRCODE = 'P0001';
      END IF;

    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_portal_field_limits ON data.public_pages;
CREATE TRIGGER trg_enforce_portal_field_limits
  BEFORE INSERT OR UPDATE ON data.public_pages
  FOR EACH ROW EXECUTE FUNCTION data.enforce_portal_field_limits();


-- =============================================================================
-- 5. RPC api.patch_public_site_theme
--    Deep-merge d'una secció de theme_config sense esborrar les altres.
--    Sections suportades: 'header' | 'footer' | 'colors' | 'branding'
--    El merge és superficial a nivell de secció (jsonb ||).
--    Auditoria: PUBLIC_SITE_THEME_UPDATED / PUBLIC_SITE_LOGO_UPDATED.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.patch_public_site_theme(
  p_id      uuid,
  p_section text,   -- 'header' | 'footer' | 'colors' | 'branding'
  p_patch   jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id       uuid := data.active_tenant_id();
  v_current_section jsonb;
  v_merged_section  jsonb;
  v_action          text;
  v_changed_keys    jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context'
      USING HINT = 'Envia la capçalera x-tenant-id amb el UUID del tenant.';
  END IF;

  -- Validació de secció permesa
  IF p_section NOT IN ('header', 'footer', 'colors', 'branding') THEN
    RAISE EXCEPTION 'invalid_section: Secció "%" no permesa. Usa: header, footer, colors, branding.',
      p_section
      USING ERRCODE = 'P0001';
  END IF;

  -- Llegir secció actual
  SELECT COALESCE(theme_config->p_section, '{}'::jsonb)
    INTO v_current_section
    FROM data.public_sites
   WHERE id = p_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El public_site no existeix o no pertany al tenant actiu.';
  END IF;

  -- Merge superficial: claus de p_patch sobreescriuen les existents, la resta es conserva
  v_merged_section := v_current_section || p_patch;

  -- Claus canviades per al log d'auditoria (sense valors, per privacitat)
  SELECT jsonb_agg(k)
    INTO v_changed_keys
    FROM jsonb_object_keys(p_patch) k;

  -- Aplicar patch: actualitza NOMÉS la secció, no el jsonb complet
  UPDATE data.public_sites
     SET theme_config = jsonb_set(
           COALESCE(theme_config, '{}'),
           ARRAY[p_section],
           v_merged_section
         ),
         updated_at   = now()
   WHERE id        = p_id
     AND tenant_id = v_tenant_id;

  -- Auditoria: distingueix logo (canvi de branding.logo_url) de tema genèric
  v_action := CASE
    WHEN p_section = 'branding' AND (p_patch ? 'logo_url') THEN 'PUBLIC_SITE_LOGO_UPDATED'
    ELSE 'PUBLIC_SITE_THEME_UPDATED'
  END;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    NULL,
    v_action,
    'public_site',
    p_id,
    jsonb_build_object(
      'section',      p_section,
      'changed_keys', v_changed_keys
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.patch_public_site_theme(uuid, text, jsonb) TO authenticated;


-- =============================================================================
-- 6. UPDATE RPC api.upsert_public_page — afegit p_show_in_nav
--    Trenca signatura anterior → DROP + CREATE.
-- =============================================================================

DROP FUNCTION IF EXISTS api.upsert_public_page(uuid, text, text, jsonb, text, text, text, integer, jsonb);

CREATE OR REPLACE FUNCTION api.upsert_public_page(
  p_public_site_id  uuid,
  p_slug            text,
  p_title           text,
  p_content         jsonb   DEFAULT '{}',
  p_status          text    DEFAULT 'draft',
  p_seo_title       text    DEFAULT NULL,
  p_seo_description text    DEFAULT NULL,
  p_sort_order      integer DEFAULT 0,
  p_translations    jsonb   DEFAULT '{}',
  p_show_in_nav     boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id        uuid;
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context'
      USING HINT = 'Envia la capçalera x-tenant-id amb el UUID del tenant.';
  END IF;

  -- Valida que el public_site pertany al tenant actiu
  IF NOT EXISTS (
    SELECT 1 FROM data.public_sites
    WHERE id = p_public_site_id AND tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El public_site no existeix o no pertany al tenant actiu.';
  END IF;

  INSERT INTO data.public_pages (
    public_site_id,
    tenant_id,
    slug,
    title,
    content,
    translations,
    status,
    seo_title,
    seo_description,
    sort_order,
    show_in_nav
  ) VALUES (
    p_public_site_id,
    v_tenant_id,
    p_slug,
    p_title,
    p_content,
    p_translations,
    p_status,
    p_seo_title,
    p_seo_description,
    p_sort_order,
    p_show_in_nav
  )
  ON CONFLICT (public_site_id, slug)
  DO UPDATE SET
    title            = EXCLUDED.title,
    content          = EXCLUDED.content,
    translations     = EXCLUDED.translations,
    status           = EXCLUDED.status,
    seo_title        = EXCLUDED.seo_title,
    seo_description  = EXCLUDED.seo_description,
    sort_order       = EXCLUDED.sort_order,
    show_in_nav      = EXCLUDED.show_in_nav,
    updated_at       = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_public_page(
  uuid, text, text, jsonb, text, text, text, integer, jsonb, boolean
) TO authenticated;


-- =============================================================================
-- 7. UPDATE vistes api.public_pages i api.public_pages_full
--    Afegir camp show_in_nav.
--    DROP + CREATE per incloure el nou camp.
-- =============================================================================

DROP VIEW IF EXISTS api.public_pages CASCADE;

CREATE VIEW api.public_pages
  WITH (security_invoker = true)
AS
SELECT
  pp.id,
  pp.public_site_id,
  pp.tenant_id,
  pp.slug,
  pp.title,
  pp.status,
  pp.seo_title,
  pp.seo_description,
  pp.sort_order,
  pp.show_in_nav,
  pp.created_at,
  pp.updated_at
FROM data.public_pages pp
WHERE (data.active_tenant_id() IS NULL OR pp.tenant_id = data.active_tenant_id());

GRANT SELECT ON api.public_pages TO authenticated;

-- public_pages_full: inclou content i translations (per a editors i SSR)
DROP VIEW IF EXISTS api.public_pages_full CASCADE;

CREATE VIEW api.public_pages_full
  WITH (security_invoker = true)
AS
SELECT
  pp.id,
  pp.public_site_id,
  pp.tenant_id,
  pp.slug,
  pp.title,
  pp.status,
  pp.content,
  pp.translations,
  pp.seo_title,
  pp.seo_description,
  pp.sort_order,
  pp.show_in_nav,
  pp.created_at,
  pp.updated_at
FROM data.public_pages pp
WHERE (data.active_tenant_id() IS NULL OR pp.tenant_id = data.active_tenant_id());

GRANT SELECT ON api.public_pages_full TO authenticated, anon;


-- =============================================================================
-- 8. Vista api.portal_usage
--    Mètriques de consum DB del portal per site.
--    Els bytes de Storage (logo, imatges) es consulten via api.storage_usage.
-- =============================================================================

CREATE OR REPLACE VIEW api.portal_usage
  WITH (security_invoker = true)
AS
SELECT
  pp.public_site_id,
  pp.tenant_id,
  COUNT(*)::integer                                                     AS page_count,
  -- Bytes de contingut: content + translations de totes les pàgines
  SUM(
    octet_length(pp.content::text) +
    octet_length(pp.translations::text)
  )::bigint                                                             AS db_content_bytes,
  -- Bytes totals portal: afegeix theme_config (1 per site, no per pàgina)
  (
    SUM(
      octet_length(pp.content::text) +
      octet_length(pp.translations::text)
    ) + MAX(octet_length(ps.theme_config::text))
  )::bigint                                                             AS db_total_bytes
FROM data.public_pages pp
JOIN data.public_sites ps ON ps.id = pp.public_site_id
WHERE (data.active_tenant_id() IS NULL OR pp.tenant_id = data.active_tenant_id())
GROUP BY pp.public_site_id, pp.tenant_id;

GRANT SELECT ON api.portal_usage TO authenticated;


-- =============================================================================
-- 9. Audit: ampliar trigger trg_audit_public_pages per detectar canvis de contingut
--    i trg_audit_public_sites per detectar canvis de theme (logo inclòs).
--    S'actualitzen les funcions existents afegint els blocs de detecció.
--    Les accions THEME/LOGO les gestiona api.patch_public_site_theme directament;
--    aquí afegim PUBLIC_PAGE_CONTENT_UPDATED per canvis de content/translations.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_audit_public_pages()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      NULL,
      'PUBLIC_PAGE_CREATED',
      'public_page',
      NEW.id,
      jsonb_build_object(
        'public_site_id', NEW.public_site_id,
        'slug',           NEW.slug,
        'title',          NEW.title,
        'status',         NEW.status
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    -- Canvi d'estat (publish/unpublish)
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        auth.uid(),
        NULL,
        CASE NEW.status
          WHEN 'published' THEN 'PUBLIC_PAGE_PUBLISHED'
          WHEN 'draft'     THEN 'PUBLIC_PAGE_UNPUBLISHED'
          ELSE 'PUBLIC_PAGE_STATUS_CHANGED'
        END,
        'public_page',
        NEW.id,
        jsonb_build_object(
          'public_site_id', NEW.public_site_id,
          'slug',           NEW.slug,
          'title',          NEW.title,
          'old_status',     OLD.status,
          'new_status',     NEW.status
        )
      );
    END IF;

    -- Canvi de contingut o traduccions
    IF OLD.content IS DISTINCT FROM NEW.content
       OR OLD.translations IS DISTINCT FROM NEW.translations
    THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        auth.uid(),
        NULL,
        'PUBLIC_PAGE_CONTENT_UPDATED',
        'public_page',
        NEW.id,
        jsonb_build_object(
          'slug',              NEW.slug,
          'old_html_chars',    char_length(COALESCE(OLD.content->>'html', '')),
          'new_html_chars',    char_length(COALESCE(NEW.content->>'html', '')),
          -- Llista de locales amb traduccions canviades
          'locales_changed',   (
            SELECT COALESCE(jsonb_agg(k), '[]'::jsonb)
            FROM jsonb_object_keys(NEW.translations) k
            WHERE NEW.translations->k IS DISTINCT FROM OLD.translations->k
          )
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      CASE
        WHEN EXISTS (SELECT 1 FROM data.tenants t WHERE t.id = OLD.tenant_id) THEN OLD.tenant_id
        ELSE NULL
      END,
      auth.uid(),
      NULL,
      'PUBLIC_PAGE_DELETED',
      'public_page',
      OLD.id,
      jsonb_build_object(
        'public_site_id', OLD.public_site_id,
        'slug',           OLD.slug,
        'title',          OLD.title
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;
-- El trigger trg_audit_public_pages ja existeix; la funció es recrea via CREATE OR REPLACE.


-- =============================================================================
-- 10. Actualitzar valors de plans a seed (via UPDATE directe per idempotència)
--     NOTA: seed.sql s'actualitza separadament; aquesta migració actualitza
--     la BD local directament per tenir coherència sense re-seed.
-- =============================================================================

-- Free: 3 pàgines màxim, contingut HTML limitat a 10.000 chars
UPDATE data.plans
SET
  max_portal_pages    = 3,
  portal_field_limits = jsonb_build_object(
    'page_title_max_chars',             120,
    'page_seo_title_max_chars',          70,
    'page_seo_description_max_chars',   160,
    'page_html_max_chars',            10000,
    'footer_text_max_chars',            150,
    'header_cta_label_max_chars',        50
  )
WHERE name = 'free';

-- Pro: 20 pàgines màxim, HTML fins a 50.000 chars
UPDATE data.plans
SET
  max_portal_pages    = 20,
  portal_field_limits = jsonb_build_object(
    'page_title_max_chars',             120,
    'page_seo_title_max_chars',          70,
    'page_seo_description_max_chars',   160,
    'page_html_max_chars',            50000,
    'footer_text_max_chars',            300,
    'header_cta_label_max_chars',        50
  )
WHERE name = 'pro';

-- Enterprise: il·limitat (0 = sense límit per convenció)
UPDATE data.plans
SET
  max_portal_pages    = 0,
  portal_field_limits = jsonb_build_object(
    'page_title_max_chars',           0,
    'page_seo_title_max_chars',       0,
    'page_seo_description_max_chars', 0,
    'page_html_max_chars',            0,
    'footer_text_max_chars',          0,
    'header_cta_label_max_chars',     0
  )
WHERE name = 'enterprise';

-- =============================================================================
-- 10b. UPDATE api.plans — exposa max_portal_pages, portal_field_limits i max_sites
-- =============================================================================
CREATE OR REPLACE VIEW api.plans WITH (security_invoker = true) AS
SELECT
  id,
  name,
  display_name,
  max_members,
  max_storage_mb,
  price_monthly,
  max_sites,
  max_portal_pages,
  portal_field_limits
FROM data.plans
WHERE is_active = true;

GRANT SELECT ON api.plans TO authenticated, anon;
