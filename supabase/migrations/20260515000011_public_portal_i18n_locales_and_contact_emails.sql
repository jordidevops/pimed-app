-- =============================================================================
-- Migració: 20260515000011_public_portal_i18n_locales_and_contact_emails.sql
-- Propòsit : Public Portal V1 — suport multi-idioma i correus de contacte
--            per portal. Afegeix localitzacions (supported_locales/default_locale),
--            traduccions de pàgina (translations JSONB overlay), correus
--            configurables per portal (contact_email_public, lead_ack_copy_email),
--            i restricció de slugs reservats per al routing de locale.
--
-- Conté:
--   1.  ALTER data.public_sites  — supported_locales, default_locale,
--                                  contact_email_public, lead_ack_copy_email
--   2.  ALTER data.public_pages  — translations jsonb + constraint slug reservat
--   3.  UPDATE vistes api.*      — afegir nous camps a public_sites/_full,
--                                  public_pages/_full
--   4.  UPDATE RPC create_public_site  — inicialitza locales amb defaults
--   5.  UPDATE RPC update_public_site  — nous params locale + correus
--   6.  UPDATE RPC upsert_public_page  — nou param p_translations
--   7.  UPDATE tipus api.portal_site_row + RPCs resolve_*_for_portal
--                                  — afegir supported_locales, default_locale,
--                                    contact_email_public (mai lead_ack_copy_email)
--
-- Restriccions de disseny:
--   · lead_ack_copy_email MAI exposat a RPCs anon (resolve_*_for_portal).
--     És un camp intern per al worker de leads.
--   · Catàleg de locales V1: {ca, es, en}. El constraint valida el subconjunt.
--   · slug NOT IN ('ca','es','en'): evita col·lisió routing /{slug}/{locale}.
--     Decisió de producte + tècnica simultàniament.
-- =============================================================================


-- =============================================================================
-- 1. ALTER data.public_sites — locales i correus de contacte
-- =============================================================================

ALTER TABLE data.public_sites
  ADD COLUMN IF NOT EXISTS supported_locales    text[]  NOT NULL DEFAULT '{ca}',
  ADD COLUMN IF NOT EXISTS default_locale       text    NOT NULL DEFAULT 'ca',
  ADD COLUMN IF NOT EXISTS contact_email_public text,
  ADD COLUMN IF NOT EXISTS lead_ack_copy_email  text;

-- Locales han de ser un subconjunt del catàleg V1 i no buits
ALTER TABLE data.public_sites
  ADD CONSTRAINT chk_public_sites_supported_locales
    CHECK (
      supported_locales <@ ARRAY['ca','es','en']::text[]
      AND cardinality(supported_locales) > 0
    );

-- default_locale ha d'estar dins de supported_locales
ALTER TABLE data.public_sites
  ADD CONSTRAINT chk_public_sites_default_locale
    CHECK (default_locale = ANY(supported_locales));

-- Format email bàsic
ALTER TABLE data.public_sites
  ADD CONSTRAINT chk_public_sites_contact_email_public
    CHECK (contact_email_public ~* '^[^@]+@[^@]+$' OR contact_email_public IS NULL);

ALTER TABLE data.public_sites
  ADD CONSTRAINT chk_public_sites_lead_ack_copy_email
    CHECK (lead_ack_copy_email ~* '^[^@]+@[^@]+$' OR lead_ack_copy_email IS NULL);


-- =============================================================================
-- 2. ALTER data.public_pages — traduccions + constraint slug reservat
-- =============================================================================

ALTER TABLE data.public_pages
  ADD COLUMN IF NOT EXISTS translations jsonb NOT NULL DEFAULT '{}';

-- Evita col·lisió de routing amb prefixos de locale (/{slug}/ca, /{slug}/es, etc.)
ALTER TABLE data.public_pages
  ADD CONSTRAINT chk_public_pages_slug_not_reserved
    CHECK (slug NOT IN ('ca', 'es', 'en'));

COMMENT ON COLUMN data.public_pages.translations IS
  'Traduccions per locale com a JSON overlay. Estructura: '
  '{"es": {"title":"...", "content":{...}, "seo_title":"..."}, "en": {...}}. '
  'Camps absents fan fallback als camps base (locale ca).';


-- =============================================================================
-- 3. UPDATE vistes api.* — exposar nous camps
--    DROP + CREATE (PostgreSQL no permet INSERT de columnes al mig en OR REPLACE)
-- =============================================================================

DROP VIEW IF EXISTS api.public_sites CASCADE;
DROP VIEW IF EXISTS api.public_sites_full CASCADE;
DROP VIEW IF EXISTS api.public_pages CASCADE;
DROP VIEW IF EXISTS api.public_pages_full CASCADE;

-- api.public_sites: llista lleugera (sense JSONB pesat) — afegir locales
CREATE VIEW api.public_sites
  WITH (security_invoker = true)
AS
SELECT
  ps.id,
  ps.tenant_id,
  ps.site_id,
  ps.slug,
  ps.name,
  ps.status,
  ps.primary_domain_id,
  ps.seo_title,
  ps.seo_description,
  ps.seo_keywords,
  ps.supported_locales,
  ps.default_locale,
  ps.contact_email_public,
  ps.created_by,
  ps.created_at,
  ps.updated_at,
  data.public_portal_enabled_for_tenant(ps.tenant_id) AS public_portal_enabled
FROM data.public_sites ps
WHERE (data.active_tenant_id() IS NULL OR ps.tenant_id = data.active_tenant_id());

GRANT SELECT ON api.public_sites TO authenticated, anon;


-- api.public_sites_full: editor autenticat (inclou JSONB i camps sensibles com lead_ack_copy_email)
CREATE VIEW api.public_sites_full
  WITH (security_invoker = true)
AS
SELECT
  ps.id,
  ps.tenant_id,
  ps.site_id,
  ps.slug,
  ps.name,
  ps.status,
  ps.primary_domain_id,
  ps.seo_title,
  ps.seo_description,
  ps.seo_keywords,
  ps.content,
  ps.theme_config,
  ps.supported_locales,
  ps.default_locale,
  ps.contact_email_public,
  ps.lead_ack_copy_email,
  ps.created_by,
  ps.created_at,
  ps.updated_at,
  data.public_portal_enabled_for_tenant(ps.tenant_id) AS public_portal_enabled
FROM data.public_sites ps
WHERE ps.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.public_sites_full TO authenticated;


-- api.public_pages: llista lleugera — afegir translations queda fora (és JSONB pesat)
-- El llistat no necessita traduccions; les obté a api.public_pages_full (editor).
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
  pp.created_at,
  pp.updated_at
FROM data.public_pages pp
WHERE (data.active_tenant_id() IS NULL OR pp.tenant_id = data.active_tenant_id());

GRANT SELECT ON api.public_pages TO authenticated, anon;


-- api.public_pages_full: editor autenticat — afegir camp translations
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
  pp.created_at,
  pp.updated_at
FROM data.public_pages pp
WHERE pp.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.public_pages_full TO authenticated;


-- =============================================================================
-- 4. UPDATE RPC api.create_public_site
--    Compat enrere: la signatura no canvia (locales s'inicialitzen amb defaults).
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_public_site(
  p_slug      text,
  p_name      text,
  p_site_id   uuid  DEFAULT NULL
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

  INSERT INTO data.public_sites (
    tenant_id,
    site_id,
    slug,
    name,
    status,
    supported_locales,
    default_locale,
    created_by
  ) VALUES (
    v_tenant_id,
    p_site_id,
    p_slug,
    p_name,
    'draft',
    '{ca}',
    'ca',
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_public_site(text, text, uuid) TO authenticated;


-- =============================================================================
-- 5. UPDATE RPC api.update_public_site
--    TRENCA LA SIGNATURA ANTERIOR: cal DROP + recreació.
--    Nous params: p_supported_locales, p_default_locale,
--                 p_contact_email_public, p_lead_ack_copy_email.
--
--    Convenció de buidat de camp email:
--      NULL  → no canvia el valor actual
--      ''    → estableix a NULL (esborrar l'email)
--      'x@y' → actualitza amb el nou valor
-- =============================================================================

DROP FUNCTION IF EXISTS api.update_public_site(uuid, text, text, text, text[], jsonb, jsonb);

CREATE FUNCTION api.update_public_site(
  p_id                   uuid,
  p_name                 text    DEFAULT NULL,
  p_seo_title            text    DEFAULT NULL,
  p_seo_description      text    DEFAULT NULL,
  p_seo_keywords         text[]  DEFAULT NULL,
  p_content              jsonb   DEFAULT NULL,
  p_theme_config         jsonb   DEFAULT NULL,
  p_supported_locales    text[]  DEFAULT NULL,
  p_default_locale       text    DEFAULT NULL,
  p_contact_email_public text    DEFAULT NULL,
  p_lead_ack_copy_email  text    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context'
      USING HINT = 'Envia la capçalera x-tenant-id amb el UUID del tenant.';
  END IF;

  UPDATE data.public_sites
  SET
    name              = COALESCE(p_name,              name),
    seo_title         = COALESCE(p_seo_title,         seo_title),
    seo_description   = COALESCE(p_seo_description,   seo_description),
    seo_keywords      = COALESCE(p_seo_keywords,      seo_keywords),
    content           = COALESCE(p_content,           content),
    theme_config      = COALESCE(p_theme_config,      theme_config),
    supported_locales = COALESCE(p_supported_locales, supported_locales),
    default_locale    = COALESCE(p_default_locale,    default_locale),
    -- '' = esborrar email; NULL = no canviar; 'x@y' = actualitzar
    contact_email_public = CASE
      WHEN p_contact_email_public IS NULL THEN contact_email_public
      WHEN p_contact_email_public = ''    THEN NULL
      ELSE p_contact_email_public
    END,
    lead_ack_copy_email = CASE
      WHEN p_lead_ack_copy_email IS NULL THEN lead_ack_copy_email
      WHEN p_lead_ack_copy_email = ''    THEN NULL
      ELSE p_lead_ack_copy_email
    END,
    updated_at        = now()
  WHERE id        = p_id
    AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El public_site no existeix o no pertany al tenant actiu.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_public_site(
  uuid, text, text, text, text[], jsonb, jsonb, text[], text, text, text
) TO authenticated;


-- =============================================================================
-- 6. UPDATE RPC api.upsert_public_page
--    Afegit: p_translations jsonb DEFAULT '{}'
--    TRENCA LA SIGNATURA ANTERIOR: cal DROP + recreació.
-- =============================================================================

DROP FUNCTION IF EXISTS api.upsert_public_page(uuid, text, text, jsonb, text, text, text, integer);

CREATE FUNCTION api.upsert_public_page(
  p_public_site_id  uuid,
  p_slug            text,
  p_title           text,
  p_content         jsonb   DEFAULT '{}',
  p_status          text    DEFAULT 'draft',
  p_seo_title       text    DEFAULT NULL,
  p_seo_description text    DEFAULT NULL,
  p_sort_order      integer DEFAULT 0,
  p_translations    jsonb   DEFAULT '{}'
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
    sort_order
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
    p_sort_order
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
    updated_at       = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_public_page(
  uuid, text, text, jsonb, text, text, text, integer, jsonb
) TO authenticated;


-- =============================================================================
-- 7. UPDATE tipus api.portal_site_row + RPCs resolve_*_for_portal
--    Afegir: supported_locales, default_locale, contact_email_public
--    IMPORTANT: lead_ack_copy_email MAI s'exposa en RPCs accessibles per anon.
-- =============================================================================

-- Drop dependent functions first, then the type
DROP FUNCTION IF EXISTS api.resolve_site_for_portal(text);
DROP FUNCTION IF EXISTS api.resolve_domain_for_portal(text);
DROP TYPE    IF EXISTS api.portal_site_row CASCADE;

CREATE TYPE api.portal_site_row AS (
  id                  uuid,
  tenant_id           uuid,
  site_id             uuid,
  slug                text,
  name                text,
  status              text,
  primary_domain_id   uuid,
  canonical_domain    text,
  seo_title           text,
  seo_description     text,
  seo_keywords        text[],
  content             jsonb,
  theme_config        jsonb,
  supported_locales   text[],
  default_locale      text,
  contact_email_public text,
  created_at          timestamptz,
  updated_at          timestamptz
);


CREATE OR REPLACE FUNCTION api.resolve_site_for_portal(p_slug text)
RETURNS api.portal_site_row
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_result api.portal_site_row;
BEGIN
  SELECT
    ps.id,
    ps.tenant_id,
    ps.site_id,
    ps.slug,
    ps.name,
    ps.status,
    ps.primary_domain_id,
    pd.domain             AS canonical_domain,
    ps.seo_title,
    ps.seo_description,
    ps.seo_keywords,
    ps.content,
    ps.theme_config,
    ps.supported_locales,
    ps.default_locale,
    ps.contact_email_public,
    ps.created_at,
    ps.updated_at
  INTO v_result
  FROM data.public_sites ps
  LEFT JOIN data.public_domains pd
    ON pd.id = ps.primary_domain_id
   AND pd.status = 'ssl_active'
  WHERE ps.slug = lower(trim(p_slug))
    AND ps.status = 'published'
    AND data.public_portal_enabled_for_tenant(ps.tenant_id);

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_site_for_portal(text) TO anon, authenticated;

COMMENT ON FUNCTION api.resolve_site_for_portal IS
  'Retorna les dades del site per al SSR del portal públic via slug. '
  'SECURITY DEFINER: accessible per anon. Aplica validació de negoci manual '
  '(published + public_portal_enabled). Inclou canonical_domain si ssl_active, '
  'supported_locales, default_locale i contact_email_public. '
  'MAI exposa lead_ack_copy_email. '
  'Retorna NULL si el site no existeix, no és published o el portal no està habilitat.';


CREATE OR REPLACE FUNCTION api.resolve_domain_for_portal(p_domain text)
RETURNS api.portal_site_row
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_result api.portal_site_row;
BEGIN
  SELECT
    ps.id,
    ps.tenant_id,
    ps.site_id,
    ps.slug,
    ps.name,
    ps.status,
    ps.primary_domain_id,
    pd_primary.domain     AS canonical_domain,
    ps.seo_title,
    ps.seo_description,
    ps.seo_keywords,
    ps.content,
    ps.theme_config,
    ps.supported_locales,
    ps.default_locale,
    ps.contact_email_public,
    ps.created_at,
    ps.updated_at
  INTO v_result
  FROM data.public_domains pd
  JOIN data.public_sites ps ON ps.id = pd.public_site_id
  LEFT JOIN data.public_domains pd_primary
    ON pd_primary.id = ps.primary_domain_id
   AND pd_primary.status = 'ssl_active'
  WHERE pd.domain = lower(trim(p_domain))
    AND pd.status IN ('dns_verified', 'ssl_active')
    AND ps.status = 'published'
    AND data.public_portal_enabled_for_tenant(ps.tenant_id);

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_domain_for_portal(text) TO anon, authenticated;

COMMENT ON FUNCTION api.resolve_domain_for_portal IS
  'Retorna les dades del site per al SSR del portal públic via custom domain. '
  'SECURITY DEFINER: accessible per anon. Busca dominis dns_verified o ssl_active. '
  'Aplica validació de negoci manual (published + public_portal_enabled). '
  'Inclou supported_locales, default_locale i contact_email_public. '
  'MAI exposa lead_ack_copy_email. '
  'Retorna NULL si el domini no existeix, no és verificat o el portal no està habilitat.';
