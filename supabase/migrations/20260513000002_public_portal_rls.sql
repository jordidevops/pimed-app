-- =============================================================================
-- Migration: 20260513000002_public_portal_rls.sql
-- Propòsit : Mòdul de Portal Públic V1 — RLS, vistes api.* i RPCs lifecycle.
--
-- Conté:
--   1.  RLS  : data.public_sites
--   2.  RLS  : data.public_pages
--   3.  RLS  : data.public_domains
--   4.  RLS  : data.public_leads
--   5.  RLS  : data.public_domain_events
--   6.  Vista: api.public_sites  (security_invoker = true)
--   7.  Vista: api.public_pages  (security_invoker = true)
--   8.  Vista: api.public_domains (security_invoker = true)
--   9.  Vista: api.public_leads  (security_invoker = true)
--  10.  RPC  : api.create_public_site
--  11.  RPC  : api.update_public_site
--  12.  RPC  : api.publish_public_site
--  13.  RPC  : api.unpublish_public_site
--  14.  RPC  : api.delete_public_site
--  15.  RPC  : api.upsert_public_page
--  16.  RPC  : api.delete_public_page
--  17.  RPC  : api.attach_public_domain
--  18.  RPC  : api.detach_public_domain
--  19.  RPC  : api.set_primary_domain
--  20.  RPC  : api.submit_public_lead  (SECURITY DEFINER — accessible per anon)
--  21.  RPC  : api.promote_lead_to_contact
--  22.  Grants
--
-- Patró RLS aplicat:
--   · SELECT autenticat : data.jwt_user_tenants() ? tenant_id::text
--                         + data.active_tenant_id() filter quan present
--   · INSERT/UPDATE     : global_role IN ('owner', 'manager')
--   · DELETE            : global_role IN ('owner', 'manager')
--   · SELECT anon       : public_sites / public_pages si status = 'published'
--                         i data.tenants.public_portal_enabled = true
--   · public_leads      : MAI llegibles per anon. INSERT via RPC SECURITY DEFINER.
--   · public_domain_events: SELECT a qualsevol membre del tenant (read-only log)
--
-- Dependències:
--   · 20260513000001_public_portal_core.sql (taules i triggers ja existents)
--   · data.jwt_user_tenants()   (20260401000003)
--   · data.active_tenant_id()   (20260401000003)
--   · data.log_audit_event()    (20260503000002)
--   · data.contacts             (20260503000005)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Helper: comprova si el mòdul public portal està habilitat al tenant.
-- SECURITY DEFINER evita dependències de permisos/RLS sobre data.tenants
-- quan la policy s'executa per anon.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.public_portal_enabled_for_tenant(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(
    (SELECT t.public_portal_enabled FROM data.tenants t WHERE t.id = p_tenant_id),
    false
  );
$$;

GRANT EXECUTE ON FUNCTION data.public_portal_enabled_for_tenant(uuid) TO authenticated, anon;


-- =============================================================================
-- 1. RLS: data.public_sites
-- =============================================================================

-- SELECT: qualsevol membre autenticat del tenant (backoffice tenant-portal)
CREATE POLICY "public_sites: membres del tenant poden veure"
  ON data.public_sites FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- SELECT anon: lectura pública per a Next.js SSR — només sites publicats
-- i amb public_portal_enabled activat al tenant.
-- La vista api.public_sites ja filtrarà per slug/domini, però la policy
-- és la línia de defensa real si algú accedeix directament via PostgREST.
CREATE POLICY "public_sites: lectura pública de sites publicats"
  ON data.public_sites FOR SELECT
  TO anon
  USING (
    status = 'published'
    AND data.public_portal_enabled_for_tenant(tenant_id)
  );

-- INSERT: owner o manager global del tenant
CREATE POLICY "public_sites: owner/manager pot crear"
  ON data.public_sites FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );

-- UPDATE: owner o manager global del tenant
CREATE POLICY "public_sites: owner/manager pot modificar"
  ON data.public_sites FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );

-- DELETE: owner o manager global
CREATE POLICY "public_sites: owner/manager pot eliminar"
  ON data.public_sites FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );


-- =============================================================================
-- 2. RLS: data.public_pages
-- =============================================================================

-- SELECT: qualsevol membre autenticat del tenant
CREATE POLICY "public_pages: membres del tenant poden veure"
  ON data.public_pages FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- SELECT anon: pàgines publicades (el site ja ha de ser published i amb portal enabled)
CREATE POLICY "public_pages: lectura pública de pàgines publicades"
  ON data.public_pages FOR SELECT
  TO anon
  USING (
    status = 'published'
    AND EXISTS (
      SELECT 1 FROM data.public_sites ps
      WHERE ps.id = public_site_id
        AND ps.status = 'published'
        AND data.public_portal_enabled_for_tenant(ps.tenant_id)
    )
  );

-- INSERT: owner o manager
CREATE POLICY "public_pages: owner/manager pot crear"
  ON data.public_pages FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );

-- UPDATE: owner o manager
CREATE POLICY "public_pages: owner/manager pot modificar"
  ON data.public_pages FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );

-- DELETE: owner o manager
CREATE POLICY "public_pages: owner/manager pot eliminar"
  ON data.public_pages FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );


-- =============================================================================
-- 3. RLS: data.public_domains
-- =============================================================================

-- SELECT: membres autenticats del tenant (tota informació de domini)
CREATE POLICY "public_domains: membres del tenant poden veure"
  ON data.public_domains FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- INSERT: owner o manager
CREATE POLICY "public_domains: owner/manager pot afegir domini"
  ON data.public_domains FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );

-- UPDATE: owner o manager
-- (el worker de verificació actualitza via service_role que bypassa RLS)
CREATE POLICY "public_domains: owner/manager pot modificar"
  ON data.public_domains FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );

-- DELETE: owner o manager
CREATE POLICY "public_domains: owner/manager pot eliminar"
  ON data.public_domains FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );


-- =============================================================================
-- 4. RLS: data.public_leads
-- SEGURETAT CRÍTICA: MAI llegible per anon.
-- INSERT: únicament via RPC api.submit_public_lead (SECURITY DEFINER).
--         Cap política INSERT authenticated → les escriptures directes via
--         PostgREST estan bloquejades.
-- =============================================================================

-- SELECT: owner, manager o member del tenant (equip que gestiona leads)
CREATE POLICY "public_leads: owner/manager/member del tenant poden veure"
  ON data.public_leads FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

-- UPDATE: owner o manager (canviar status, assignar contact_id)
CREATE POLICY "public_leads: owner/manager pot modificar"
  ON data.public_leads FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );

-- DELETE: owner o manager (per esborrar leads de prova o RGPD)
CREATE POLICY "public_leads: owner/manager pot eliminar"
  ON data.public_leads FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );
-- NOTA: Sense política INSERT per a authenticated ni anon.
--       Tots els inserts passen per api.submit_public_lead (SECURITY DEFINER).


-- =============================================================================
-- 5. RLS: data.public_domain_events (log append-only)
-- El trigger trg_prevent_public_domain_events_mutation de 000001 ja impedeix
-- UPDATE/DELETE a nivell de trigger. Les policies confirmen la intenció.
-- =============================================================================

-- SELECT: qualsevol membre autenticat del tenant (log d'events visible)
CREATE POLICY "public_domain_events: membres del tenant poden veure"
  ON data.public_domain_events FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- INSERT: únicament service_role (worker de verificació DNS/SSL)
-- Cap política INSERT authenticated → els inserts directes d'usuaris estan bloquejats.
-- (service_role bypassa RLS, cap policy necessària per a ell)


-- =============================================================================
-- 6. Vista: api.public_sites
-- Vista lleugera de llistat (sense JSONB pesat) per escalar millor.
-- Autenticat: filtra tenant actiu.
-- Anon: permet lectura pública sense x-tenant-id (la RLS aplica published+enabled).
-- Inclou public_portal_enabled per evitar un segon fetch al frontend.
-- security_invoker = true: la RLS de data.public_sites s'aplica com a
-- l'usuari que fa la crida (autenticat o anon).
-- =============================================================================

CREATE OR REPLACE VIEW api.public_sites
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
  ps.created_by,
  ps.created_at,
  ps.updated_at,
  -- Camp derivat: estat del mòdul per al tenant (evita un segon fetch al frontend)
  data.public_portal_enabled_for_tenant(ps.tenant_id) AS public_portal_enabled
FROM data.public_sites ps
WHERE (data.active_tenant_id() IS NULL OR ps.tenant_id = data.active_tenant_id());

GRANT SELECT ON api.public_sites TO authenticated, anon;

-- Detall de portal (inclou JSONB) per editor autenticat
CREATE OR REPLACE VIEW api.public_sites_full
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
  ps.created_by,
  ps.created_at,
  ps.updated_at,
  data.public_portal_enabled_for_tenant(ps.tenant_id) AS public_portal_enabled
FROM data.public_sites ps
WHERE ps.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.public_sites_full TO authenticated;


-- =============================================================================
-- 7. Vista: api.public_pages
-- Vista lleugera de llistat (sense content JSONB) per escalar millor.
-- Autenticat: filtre tenant actiu.
-- Anon: permet lectura pública sense x-tenant-id (la RLS ja filtra published).
-- =============================================================================

CREATE OR REPLACE VIEW api.public_pages
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

-- Detall de pàgina (inclou content JSONB) per editor autenticat
CREATE OR REPLACE VIEW api.public_pages_full
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
  pp.seo_title,
  pp.seo_description,
  pp.sort_order,
  pp.created_at,
  pp.updated_at
FROM data.public_pages pp
WHERE pp.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.public_pages_full TO authenticated;


-- =============================================================================
-- 8. Vista: api.public_domains
-- Inclou el nom del site per context. Mai accessible per anon.
-- =============================================================================

CREATE OR REPLACE VIEW api.public_domains
  WITH (security_invoker = true)
AS
SELECT
  pd.id,
  pd.public_site_id,
  pd.tenant_id,
  pd.domain,
  pd.status,
  pd.verification_token,
  pd.last_checked_at,
  pd.ssl_provisioned_at,
  pd.failure_reason,
  pd.created_at,
  pd.updated_at,
  -- Context: nom del site al que pertany el domini
  ps.name AS public_site_name,
  ps.slug AS public_site_slug
FROM data.public_domains pd
JOIN data.public_sites ps ON ps.id = pd.public_site_id
WHERE pd.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.public_domains TO authenticated;


-- =============================================================================
-- 9. Vista: api.public_leads
-- MAI accessible per anon. Inclou slug de la pàgina origen per context.
-- =============================================================================

CREATE OR REPLACE VIEW api.public_leads
  WITH (security_invoker = true)
AS
SELECT
  pl.id,
  pl.public_site_id,
  pl.tenant_id,
  pl.idempotency_key,
  pl.name,
  pl.email,
  pl.phone,
  pl.message,
  pl.source_url,
  pl.source_page_slug,
  pl.metadata,
  pl.status,
  pl.contact_id,
  pl.created_at,
  pl.updated_at,
  -- Context: nom del site origen
  ps.name AS public_site_name,
  ps.slug AS public_site_slug
FROM data.public_leads pl
JOIN data.public_sites ps ON ps.id = pl.public_site_id
WHERE pl.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.public_leads TO authenticated;


-- =============================================================================
-- 10. RPC: api.create_public_site
-- Crea un portal públic per al tenant actiu.
-- SECURITY INVOKER: la policy INSERT de data.public_sites valida el rol.
-- Retorna: uuid del public_site creat.
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
    created_by
  ) VALUES (
    v_tenant_id,
    p_site_id,
    p_slug,
    p_name,
    'draft',
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_public_site(text, text, uuid) TO authenticated;


-- =============================================================================
-- 11. RPC: api.update_public_site
-- Actualitza camps editables del portal (nom, SEO, contingut, tema).
-- SECURITY INVOKER: la policy UPDATE de data.public_sites valida el rol.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.update_public_site(
  p_id              uuid,
  p_name            text    DEFAULT NULL,
  p_seo_title       text    DEFAULT NULL,
  p_seo_description text    DEFAULT NULL,
  p_seo_keywords    text[]  DEFAULT NULL,
  p_content         jsonb   DEFAULT NULL,
  p_theme_config    jsonb   DEFAULT NULL
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
    name             = COALESCE(p_name,             name),
    seo_title        = COALESCE(p_seo_title,        seo_title),
    seo_description  = COALESCE(p_seo_description,  seo_description),
    seo_keywords     = COALESCE(p_seo_keywords,     seo_keywords),
    content          = COALESCE(p_content,          content),
    theme_config     = COALESCE(p_theme_config,     theme_config),
    updated_at       = now()
  WHERE id        = p_id
    AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El public_site no existeix o no pertany al tenant actiu.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_public_site(uuid, text, text, text, text[], jsonb, jsonb) TO authenticated;


-- =============================================================================
-- 12. RPC: api.publish_public_site
-- Canvia status a 'published'. Valida que el tenant tingui el mòdul activat.
-- SECURITY INVOKER: la policy UPDATE valida el rol.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.publish_public_site(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id      uuid := data.active_tenant_id();
  v_portal_enabled bool;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context'
      USING HINT = 'Envia la capçalera x-tenant-id amb el UUID del tenant.';
  END IF;

  -- Valida que el mòdul estigui activat per a aquest tenant
  SELECT public_portal_enabled INTO v_portal_enabled
  FROM data.tenants
  WHERE id = v_tenant_id;

  IF NOT COALESCE(v_portal_enabled, false) THEN
    RAISE EXCEPTION 'module_not_enabled'
      USING HINT = 'El mòdul de portal públic no està activat per a aquest tenant.';
  END IF;

  UPDATE data.public_sites
  SET
    status     = 'published',
    updated_at = now()
  WHERE id        = p_id
    AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El public_site no existeix o no pertany al tenant actiu.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.publish_public_site(uuid) TO authenticated;


-- =============================================================================
-- 13. RPC: api.unpublish_public_site
-- Canvia status a 'draft'.
-- SECURITY INVOKER: la policy UPDATE valida el rol.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.unpublish_public_site(p_id uuid)
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
    status     = 'draft',
    updated_at = now()
  WHERE id        = p_id
    AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El public_site no existeix o no pertany al tenant actiu.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.unpublish_public_site(uuid) TO authenticated;


-- =============================================================================
-- 14. RPC: api.delete_public_site
-- Elimina un portal públic. El CASCADE de BD eliminarà pages, domains i leads.
-- SECURITY INVOKER: la policy DELETE valida el rol.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.delete_public_site(p_id uuid)
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

  DELETE FROM data.public_sites
  WHERE id        = p_id
    AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El public_site no existeix o no pertany al tenant actiu.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_public_site(uuid) TO authenticated;


-- =============================================================================
-- 15. RPC: api.upsert_public_page
-- Crea o actualitza una pàgina d'un portal públic.
-- SECURITY INVOKER: la policy INSERT/UPDATE valida el rol.
-- Retorna: uuid de la pàgina.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.upsert_public_page(
  p_public_site_id  uuid,
  p_slug            text,
  p_title           text,
  p_content         jsonb   DEFAULT '{}',
  p_status          text    DEFAULT 'draft',
  p_seo_title       text    DEFAULT NULL,
  p_seo_description text    DEFAULT NULL,
  p_sort_order      integer DEFAULT 0
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
    p_status,
    p_seo_title,
    p_seo_description,
    p_sort_order
  )
  ON CONFLICT (public_site_id, slug)
  DO UPDATE SET
    title            = EXCLUDED.title,
    content          = EXCLUDED.content,
    status           = EXCLUDED.status,
    seo_title        = EXCLUDED.seo_title,
    seo_description  = EXCLUDED.seo_description,
    sort_order       = EXCLUDED.sort_order,
    updated_at       = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_public_page(uuid, text, text, jsonb, text, text, text, integer) TO authenticated;


-- =============================================================================
-- 16. RPC: api.delete_public_page
-- Elimina una pàgina d'un portal.
-- SECURITY INVOKER: la policy DELETE valida el rol.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.delete_public_page(p_id uuid)
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

  DELETE FROM data.public_pages
  WHERE id        = p_id
    AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'La pàgina no existeix o no pertany al tenant actiu.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_public_page(uuid) TO authenticated;


-- =============================================================================
-- 17. RPC: api.attach_public_domain
-- Afegeix un domini propi a un portal públic.
-- Genera token de verificació DNS determinista per facilitar debugging.
-- SECURITY INVOKER: la policy INSERT de data.public_domains valida el rol.
-- NOTE: NO escriu a data.public_domain_events per evitar fallada RLS en mode
-- SECURITY INVOKER. El log d'auditoria de domini el cobreix trg_audit_public_domains.
-- Retorna: uuid del domini creat.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.attach_public_domain(
  p_public_site_id  uuid,
  p_domain          text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id               uuid;
  v_tenant_id        uuid := data.active_tenant_id();
  v_verification_tok text;
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

  -- Genera token: prefix 'example-site-verify=' + hash determinista (site+domain)
  v_verification_tok := 'example-site-verify='
    || encode(
         extensions.digest(
           p_public_site_id::text || '.' || lower(trim(p_domain)),
           'sha256'
         ),
         'hex'
       );

  INSERT INTO data.public_domains (
    public_site_id,
    tenant_id,
    domain,
    status,
    verification_token
  ) VALUES (
    p_public_site_id,
    v_tenant_id,
    lower(trim(p_domain)),
    'pending',
    v_verification_tok
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.attach_public_domain(uuid, text) TO authenticated;


-- =============================================================================
-- 18. RPC: api.detach_public_domain
-- Elimina un domini d'un portal. Si era el domini primari, el camp
-- primary_domain_id queda NULL (per ON DELETE SET NULL del FK de 000001).
-- SECURITY INVOKER: la policy DELETE de data.public_domains valida el rol.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.detach_public_domain(p_domain_id uuid)
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

  DELETE FROM data.public_domains
  WHERE id        = p_domain_id
    AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El domini no existeix o no pertany al tenant actiu.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.detach_public_domain(uuid) TO authenticated;


-- =============================================================================
-- 19. RPC: api.set_primary_domain
-- Estableix un domini verificat (dns_verified o ssl_active) com a primari.
-- Valida que el domini pertanyi al public_site indicat.
-- SECURITY INVOKER: la policy UPDATE de data.public_sites valida el rol.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.set_primary_domain(
  p_public_site_id  uuid,
  p_domain_id       uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id    uuid := data.active_tenant_id();
  v_domain_status text;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context'
      USING HINT = 'Envia la capçalera x-tenant-id amb el UUID del tenant.';
  END IF;

  -- Valida que el domini pertanyi al site i al tenant, i que estigui verificat
  SELECT status INTO v_domain_status
  FROM data.public_domains
  WHERE id            = p_domain_id
    AND public_site_id = p_public_site_id
    AND tenant_id     = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El domini no existeix, no pertany a aquest portal o no pertany al tenant actiu.';
  END IF;

  IF v_domain_status NOT IN ('dns_verified', 'ssl_active') THEN
    RAISE EXCEPTION 'domain_not_verified'
      USING HINT = 'Només es pot establir com a primari un domini amb status dns_verified o ssl_active.';
  END IF;

  UPDATE data.public_sites
  SET
    primary_domain_id = p_domain_id,
    updated_at        = now()
  WHERE id        = p_public_site_id
    AND tenant_id = v_tenant_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_primary_domain(uuid, uuid) TO authenticated;


-- =============================================================================
-- 20. RPC: api.submit_public_lead
-- Captura un lead des del formulari públic del portal.
-- SECURITY DEFINER: s'executa amb privilegis de postgres per inserir a
-- data.public_leads sense que anon tingui policy INSERT.
-- Seguretat implementada aquí (no via RLS):
--   · Valida que el public_site existeix i status = 'published'
--   · Valida que el tenant té public_portal_enabled = true
--   · Deduplicació per idempotency_key (upsert silent en duplicats)
--   · El caller és anon: NO pot accedir a informació del tenant ni leads
-- Retorna: uuid del lead (o l'existent si duplicat per idempotency_key)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.submit_public_lead(
  p_public_site_id  uuid,
  p_idempotency_key text,
  p_name            text    DEFAULT NULL,
  p_email           text    DEFAULT NULL,
  p_phone           text    DEFAULT NULL,
  p_message         text    DEFAULT NULL,
  p_source_url      text    DEFAULT NULL,
  p_source_page_slug text   DEFAULT NULL,
  p_metadata        jsonb   DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id          uuid;
  v_tenant_id   uuid;
  v_site_status text;
  v_enabled     bool;
BEGIN
  -- 1. Obté el tenant i valida que el site és públic i el mòdul actiu
  SELECT ps.tenant_id, ps.status, t.public_portal_enabled
  INTO v_tenant_id, v_site_status, v_enabled
  FROM data.public_sites ps
  JOIN data.tenants t ON t.id = ps.tenant_id
  WHERE ps.id = p_public_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El portal públic no existeix.';
  END IF;

  IF v_site_status <> 'published' THEN
    RAISE EXCEPTION 'site_not_published'
      USING HINT = 'El portal públic no accepta submissions en aquest moment.';
  END IF;

  IF NOT COALESCE(v_enabled, false) THEN
    RAISE EXCEPTION 'module_not_enabled'
      USING HINT = 'El portal públic no accepta submissions en aquest moment.';
  END IF;

  -- 2. Valida que hi ha almenys un camp de contacte (CHECK de BD hauria de
  --    capturar-ho, però validem aquí per retornar missatge clar)
  IF COALESCE(trim(p_name), '') = ''
    AND COALESCE(trim(p_email), '') = ''
    AND COALESCE(trim(p_phone), '') = ''
    AND COALESCE(trim(p_message), '') = ''
  THEN
    RAISE EXCEPTION 'empty_lead'
      USING HINT = 'Cal proporcionar almenys nom, email, telèfon o missatge.';
  END IF;

  -- 3. Upsert amb deduplicació per idempotency_key (scoped al tenant)
  INSERT INTO data.public_leads (
    public_site_id,
    tenant_id,
    idempotency_key,
    name,
    email,
    phone,
    message,
    source_url,
    source_page_slug,
    metadata,
    status
  ) VALUES (
    p_public_site_id,
    v_tenant_id,
    p_idempotency_key,
    nullif(trim(p_name), ''),
    nullif(lower(trim(p_email)), ''),
    nullif(trim(p_phone), ''),
    nullif(trim(p_message), ''),
    p_source_url,
    p_source_page_slug,
    COALESCE(p_metadata, '{}'),
    'new'
  )
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  -- Si era duplicat, retorna l'id existent
  IF v_id IS NULL THEN
    SELECT id INTO v_id
    FROM data.public_leads
    WHERE tenant_id = v_tenant_id
      AND idempotency_key = p_idempotency_key;
  END IF;

  RETURN v_id;
END;
$$;

-- Accessible per anon (formulari públic) i authenticated (tests/backoffice)
GRANT EXECUTE ON FUNCTION api.submit_public_lead(uuid, text, text, text, text, text, text, text, jsonb) TO anon, authenticated;


-- =============================================================================
-- 21. RPC: api.promote_lead_to_contact
-- Converteix un lead en un contacte del CRM.
-- SECURITY INVOKER: la policy UPDATE de public_leads valida el rol (owner/manager).
-- Crea un contact a data.contacts, vincula lead.contact_id i actualitza status.
-- Usa row-lock per evitar duplicats sota concurrència.
-- Retorna: uuid del contacte creat.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.promote_lead_to_contact(p_lead_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id  uuid := data.active_tenant_id();
  v_lead       data.public_leads%ROWTYPE;
  v_contact_id uuid;
  v_display_name text;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context'
      USING HINT = 'Envia la capçalera x-tenant-id amb el UUID del tenant.';
  END IF;

  -- Carrega i bloqueja el lead per evitar dobles conversions concurrents
  SELECT * INTO v_lead
  FROM data.public_leads
  WHERE id        = p_lead_id
    AND tenant_id = v_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El lead no existeix o no pertany al tenant actiu.';
  END IF;

  IF v_lead.contact_id IS NOT NULL THEN
    RAISE EXCEPTION 'already_converted'
      USING HINT = 'Aquest lead ja ha estat convertit a contacte.';
  END IF;

  -- Construeix el display_name des dels camps disponibles del lead
  v_display_name := COALESCE(
    NULLIF(trim(v_lead.name), ''),
    NULLIF(v_lead.email, ''),
    NULLIF(v_lead.phone, ''),
    'Lead #' || p_lead_id::text
  );

  -- Crea el contacte
  INSERT INTO data.contacts (
    tenant_id,
    kind,
    display_name,
    email,
    phone,
    source,
    created_by
  ) VALUES (
    v_tenant_id,
    'person',
    v_display_name,
    v_lead.email,
    v_lead.phone,
    'public_portal',
    auth.uid()
  )
  RETURNING id INTO v_contact_id;

  -- Vincula el lead al contacte i canvia l'estat
  UPDATE data.public_leads
  SET
    contact_id = v_contact_id,
    status     = 'converted',
    updated_at = now()
  WHERE id        = p_lead_id
    AND tenant_id = v_tenant_id
    AND contact_id IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'already_converted'
      USING HINT = 'Aquest lead ja ha estat convertit per una altra transacció.';
  END IF;

  RETURN v_contact_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.promote_lead_to_contact(uuid) TO authenticated;


-- =============================================================================
-- 22. Grants de taules (PostgREST necessita SELECT per introspectió de vistes)
-- Les polítiques RLS limiten quines files es retornen.
-- =============================================================================

-- Les vistes api.* ja han rebut GRANT SELECT a dalt.
-- Grants de SELECT necessaris per a vistes SECURITY INVOKER:
GRANT SELECT ON data.public_sites, data.public_pages, data.public_domains, data.public_leads TO authenticated;
GRANT SELECT ON data.public_sites, data.public_pages TO anon;

-- Grants adicionals per a les RPCs SECURITY INVOKER que escriuen directament:
GRANT INSERT, UPDATE, DELETE ON data.public_sites         TO authenticated;
GRANT INSERT, UPDATE, DELETE ON data.public_pages         TO authenticated;
GRANT INSERT, UPDATE, DELETE ON data.public_domains       TO authenticated;
GRANT        UPDATE, DELETE  ON data.public_leads         TO authenticated;
-- INSERT a public_leads ÚNICAMENT via api.submit_public_lead (SECURITY DEFINER).
-- No es concedeix INSERT directe a authenticated per evitar bypass de la validació.

-- public_domain_events: únicament el worker (service_role bypassa RLS)
-- Cap GRANT d'escriptura a authenticated ni anon.
GRANT SELECT ON data.public_domain_events TO authenticated;
