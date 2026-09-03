-- =============================================================================
-- Migration: 20260513000001_public_portal_core.sql
-- Propòsit : Mòdul de Portal Públic (Public Portal V1). Model de dades base per
--            exposar webs públiques multi-tenant amb suport de dominis propis,
--            pàgines i captació de leads.
--
-- Conté:
--   1.  ALTER: data.tenants → camp public_portal_enabled (feature flag)
--   2.  DDL  : data.public_sites (portals web dels tenants)
--   3.  DDL  : data.public_pages (pàgines de cada portal)
--   4.  DDL  : data.public_domains (dominis propis i verificació)
--   5.  DDL  : data.public_leads (leads captats via formulari públic)
--   6.  DDL  : data.public_domain_events (historial d'events de domini, append-only)
--   7.  ALTER: data.public_sites → FK circular primary_domain_id → data.public_domains
--   8.  Índexs operacionals
--   9.  Triggers updated_at (reutilitza data.set_updated_at())
--  10.  RLS  : ENABLE a totes les taules noves (policies a migració 000002)
--  11.  Triggers d'auditoria:
--         PUBLIC_SITE_CREATED, PUBLIC_SITE_PUBLISHED, PUBLIC_SITE_UNPUBLISHED,
--         PUBLIC_SITE_SUSPENDED, PUBLIC_SITE_DELETED
--         PUBLIC_PAGE_CREATED, PUBLIC_PAGE_PUBLISHED, PUBLIC_PAGE_UNPUBLISHED,
--         PUBLIC_PAGE_DELETED
--         PUBLIC_DOMAIN_ATTACHED, PUBLIC_DOMAIN_DNS_VERIFIED,
--         PUBLIC_DOMAIN_SSL_ACTIVE, PUBLIC_DOMAIN_FAILED, PUBLIC_DOMAIN_DELETED
--         PUBLIC_LEAD_CREATED, PUBLIC_LEAD_CONVERTED, PUBLIC_LEAD_DELETED
--
-- Patró public_site ↔ tenant/site:
--   · site_id NULL  → public_site global del tenant (un per tenant)
--   · site_id NOT NULL → public_site d'un site físic concret
--   UNIQUE(slug): el slug de subdomini és únic globalment (routing per host)
--   UNIQUE(tenant_id, site_id) WHERE site_id IS NOT NULL: un site concret
--   té com a molt un public_site
--   UNIQUE(tenant_id) WHERE site_id IS NULL: un únic public_site global per tenant
--
-- RLS policy pattern (implementat a migració 000002):
--   · SELECT autenticat : jwt_user_tenants() ? tenant_id + active_tenant_id
--   · INSERT/UPDATE     : global_role IN ('owner', 'manager')
--   · SELECT anon       : public_sites/public_pages si status='published'
--                         i public_portal_enabled=true (via vista api.*)
--   · public_leads      : mai llegibles per anon
--
-- Dependències:
--   · data.tenants          (20260401000002)
--   · data.sites            (20260401000002)
--   · data.contacts         (20260503000005)
--   · data.profiles         (20260401000002)
--   · data.log_audit_event  (20260503000002)
--   · data.set_updated_at   (20260401000002)
-- =============================================================================


-- =============================================================================
-- 1. ALTER: data.tenants — feature flag public portal
-- =============================================================================

ALTER TABLE data.tenants
  ADD COLUMN IF NOT EXISTS public_portal_enabled BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN data.tenants.public_portal_enabled
  IS 'true = el tenant té el mòdul de portal públic activat. '
     'Activat per l''admin des del backoffice. Per defecte desactivat.';


-- =============================================================================
-- 2. DDL: data.public_sites
--    Portal web d'un tenant. Pot ser global (site_id NULL) o
--    específic d'un site físic del tenant (site_id NOT NULL).
-- =============================================================================

CREATE TABLE data.public_sites (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  -- NULL = portal global del tenant; NOT NULL = portal d'un site físic concret
  site_id             uuid                    REFERENCES data.sites(id) ON DELETE SET NULL,

  -- Slug de subdomini: ex. 'clinica-barcelo' → clinica-barcelo.public.example.com
  slug                text        NOT NULL
                                  CHECK (slug ~ '^[a-z0-9][a-z0-9\-]{0,61}[a-z0-9]$'),

  name                text        NOT NULL,

  status              text        NOT NULL DEFAULT 'draft'
                                  CHECK (status IN ('draft', 'published', 'suspended')),

  -- FK circular cap a data.public_domains (s'afegeix amb ALTER post-creació)
  -- primary_domain_id: domini canònic per a redirecció 301
  primary_domain_id   uuid,

  -- SEO bàsic
  seo_title           text,
  seo_description     text,
  seo_keywords        text[]      NOT NULL DEFAULT '{}',

  -- Contingut i tema (JSON flexible per V1; estructura evoluciona amb el builder)
  content             jsonb       NOT NULL DEFAULT '{}',
  theme_config        jsonb       NOT NULL DEFAULT '{}',

  created_by          uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- Slug únic globalment per evitar ambigüitat en el routing per host
CREATE UNIQUE INDEX uidx_public_sites_slug
  ON data.public_sites (slug);

-- Un site físic concret pot tenir com a molt un public_site
CREATE UNIQUE INDEX uidx_public_sites_tenant_site_id
  ON data.public_sites (tenant_id, site_id)
  WHERE site_id IS NOT NULL;

-- Un únic public_site global per tenant (site_id IS NULL)
CREATE UNIQUE INDEX uidx_public_sites_tenant_global
  ON data.public_sites (tenant_id)
  WHERE site_id IS NULL;

-- Suport per a FKs compostes de consistència tenant
ALTER TABLE data.public_sites
  ADD CONSTRAINT uq_public_sites_id_tenant UNIQUE (id, tenant_id);

-- Índexs operacionals
CREATE INDEX idx_public_sites_tenant_id ON data.public_sites (tenant_id);
CREATE INDEX idx_public_sites_status    ON data.public_sites (status);
CREATE INDEX idx_public_sites_tenant_status ON data.public_sites (tenant_id, status);

COMMENT ON TABLE data.public_sites
  IS 'Portal web públic d''un tenant. site_id NULL = portal global del tenant; '
     'site_id NOT NULL = portal d''un site físic concret. '
  'El slug determina el subdomini (slug.public.<domini>) i és únic globalment. '
     'primary_domain_id apunta al domini canònic per a redirecció 301.';

COMMENT ON COLUMN data.public_sites.slug
  IS 'Identificador de subdomini (ex: "clinica-barcelo"). '
     'Ha de ser únic per tenant. Pattern: ^[a-z0-9][a-z0-9\-]{0,61}[a-z0-9]$.';

COMMENT ON COLUMN data.public_sites.site_id
  IS 'NULL = portal global del tenant. NOT NULL = portal d''un site físic concret '
     '(data.sites). Un site físic no pot tenir més d''un public_site.';

COMMENT ON COLUMN data.public_sites.primary_domain_id
  IS 'Domini canònic del portal. NULL = usa el subdomini per defecte. '
     'Quan s''estableix, les visites al subdomini fan redirect 301 al domini propi.';

COMMENT ON COLUMN data.public_sites.content
  IS 'Contingut estructurat del portal en format JSON. '
     'Estructura evoluciona amb el builder visual. V1: camps bàsics de landing.';

COMMENT ON COLUMN data.public_sites.theme_config
  IS 'Configuració de tema (colors, fonts, layout). JSON flexible per V1.';

-- Trigger updated_at
CREATE TRIGGER trg_public_sites_updated_at
  BEFORE UPDATE ON data.public_sites
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();


-- =============================================================================
-- 3. DDL: data.public_pages
--    Pàgines individuals dins d'un public_site (home, contacte, serveis...).
--    La pàgina home té slug = 'home' per convenció.
-- =============================================================================

CREATE TABLE data.public_pages (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  public_site_id  uuid        NOT NULL REFERENCES data.public_sites(id) ON DELETE CASCADE,
  -- Desnormalitzat per eficiència de RLS (evita JOIN a public_sites en cada fila)
  tenant_id       uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,

  slug            text        NOT NULL
                              CHECK (slug ~ '^[a-z0-9][a-z0-9\-]{0,99}$|^home$'),
  title           text        NOT NULL,

  status          text        NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft', 'published')),

  content         jsonb       NOT NULL DEFAULT '{}',
  seo_title       text,
  seo_description text,

  -- Ordre de navegació (0 = home, 1+ = ordre a la nav)
  sort_order      int         NOT NULL DEFAULT 0,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Un slug és únic dins d'un public_site
CREATE UNIQUE INDEX uidx_public_pages_site_slug
  ON data.public_pages (public_site_id, slug);

CREATE INDEX idx_public_pages_public_site_id ON data.public_pages (public_site_id);
CREATE INDEX idx_public_pages_tenant_id      ON data.public_pages (tenant_id);
CREATE INDEX idx_public_pages_status         ON data.public_pages (public_site_id, status);
CREATE INDEX idx_public_pages_site_status_order ON data.public_pages (public_site_id, status, sort_order);

ALTER TABLE data.public_pages
  ADD CONSTRAINT fk_public_pages_site_tenant
    FOREIGN KEY (public_site_id, tenant_id)
    REFERENCES data.public_sites(id, tenant_id)
    ON DELETE CASCADE;

COMMENT ON TABLE data.public_pages
  IS 'Pàgines individuals d''un public_site. slug=''home'' és la pàgina principal. '
     'tenant_id desnormalitzat per a eficiència de RLS sense JOIN.';

COMMENT ON COLUMN data.public_pages.slug
  IS 'Ruta de la pàgina (ex: "serveis", "contacte"). ''home'' és la pàgina arrel. '
     'Únic dins del seu public_site.';

COMMENT ON COLUMN data.public_pages.sort_order
  IS 'Ordre de navegació. 0 = home (primer element). '
     'Valors menors apareixen primers al menú.';

-- Trigger updated_at
CREATE TRIGGER trg_public_pages_updated_at
  BEFORE UPDATE ON data.public_pages
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();


-- =============================================================================
-- 4. DDL: data.public_domains
--    Dominis propis associats a un public_site. Inclou el token de verificació
--    DNS TXT i l'estat del procés d'aprovisionament SSL.
-- =============================================================================

CREATE TABLE data.public_domains (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  public_site_id      uuid        NOT NULL REFERENCES data.public_sites(id) ON DELETE CASCADE,
  -- Desnormalitzat per RLS
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,

  -- Domain name complet (ex: 'clinica.cat', 'www.clinicaexemple.com')
  domain              text        NOT NULL
                                  CHECK (domain ~ '^[a-z0-9][a-z0-9\-\.]{0,251}[a-z0-9]$'),

  status              text        NOT NULL DEFAULT 'pending'
                                  CHECK (status IN ('pending', 'dns_verified', 'ssl_active', 'failed')),

  -- Token TXT per a verificació DNS (ex: _portal-verify.clinica.cat TXT "<token>")
  verification_token  text        NOT NULL DEFAULT encode(gen_random_bytes(32), 'hex'),

  -- Control del worker de verificació periòdica
  last_checked_at     timestamptz,
  ssl_provisioned_at  timestamptz,

  -- Motiu de fallida (per diagnosi)
  failure_reason      text,

  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- Domain global únic: el mateix domini no pot apuntar a dos public_sites
CREATE UNIQUE INDEX uidx_public_domains_domain
  ON data.public_domains (domain);

CREATE INDEX idx_public_domains_public_site_id ON data.public_domains (public_site_id);
CREATE INDEX idx_public_domains_tenant_id      ON data.public_domains (tenant_id);
CREATE INDEX idx_public_domains_status         ON data.public_domains (status);
CREATE INDEX idx_public_domains_status_last_checked ON data.public_domains (status, last_checked_at);

ALTER TABLE data.public_domains
  ADD CONSTRAINT uq_public_domains_id_tenant UNIQUE (id, tenant_id);

ALTER TABLE data.public_domains
  ADD CONSTRAINT fk_public_domains_site_tenant
    FOREIGN KEY (public_site_id, tenant_id)
    REFERENCES data.public_sites(id, tenant_id)
    ON DELETE CASCADE;

-- Validació de coherència: site_id i primary_domain_id han de pertànyer al mateix tenant/public_site
CREATE OR REPLACE FUNCTION data.trg_validate_public_sites_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.site_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM data.sites s
      WHERE s.id = NEW.site_id
        AND s.tenant_id = NEW.tenant_id
    ) THEN
      RAISE EXCEPTION 'invalid_site_tenant: site_id % no pertany al tenant %', NEW.site_id, NEW.tenant_id
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.primary_domain_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM data.public_domains d
      WHERE d.id = NEW.primary_domain_id
        AND d.public_site_id = NEW.id
        AND d.tenant_id = NEW.tenant_id
    ) THEN
      RAISE EXCEPTION 'invalid_primary_domain: primary_domain_id % no pertany a public_site % del tenant %',
        NEW.primary_domain_id, NEW.id, NEW.tenant_id
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_public_sites_integrity
  BEFORE INSERT OR UPDATE ON data.public_sites
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_public_sites_integrity();

COMMENT ON TABLE data.public_domains
  IS 'Dominis propis associats a un public_site. '
     'Workflow: pending → dns_verified → ssl_active. '
     'failure_reason informa del motiu si status=failed. '
     'domain és globalment únic: un domini no pot apuntar a dos portals.';

COMMENT ON COLUMN data.public_domains.verification_token
  IS 'Token secret per a verificació DNS TXT. '
  'El tenant ha d''afegir un registre TXT: _portal-verify.<domain> = "<token>".';

COMMENT ON COLUMN data.public_domains.last_checked_at
  IS 'Darrera vegada que el worker de verificació ha comprovat l''estat DNS/SSL.';

COMMENT ON COLUMN data.public_domains.failure_reason
  IS 'Motiu de fallida (ex: "DNS TXT record not found", "SSL provisioning timeout"). '
     'NULL si status != failed.';

-- Trigger updated_at
CREATE TRIGGER trg_public_domains_updated_at
  BEFORE UPDATE ON data.public_domains
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();


-- =============================================================================
-- 5. DDL: data.public_leads
--    Leads captats via formulari públic del portal. Mai llegibles per anon.
--    idempotency_key prevé duplicats per reintent de formulari.
-- =============================================================================

CREATE TABLE data.public_leads (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  public_site_id      uuid        NOT NULL REFERENCES data.public_sites(id) ON DELETE CASCADE,
  -- Desnormalitzat per RLS
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,

  -- Clau d'idempotència (hash determinista del costat del client per evitar duplicats)
  idempotency_key     text        NOT NULL,

  -- Dades del lead (totes opcionals; almenys una ha de ser present — validació al RPC)
  name                text,
  email               text,
  phone               text,
  message             text,

  -- Context de captació
  source_url          text,
  source_page_slug    text,

  -- Metadades tècniques (ex: user-agent, country) sense PII addicional
  metadata            jsonb       NOT NULL DEFAULT '{}',

  -- Qualitat mínima: almenys un camp de contacte ha d'estar informat
  CONSTRAINT public_leads_has_contact_info CHECK (
    COALESCE(
      NULLIF(btrim(name), ''),
      NULLIF(btrim(email), ''),
      NULLIF(btrim(phone), ''),
      NULLIF(btrim(message), '')
    ) IS NOT NULL
  ),

  status              text        NOT NULL DEFAULT 'new'
                                  CHECK (status IN ('new', 'contacted', 'converted', 'rejected')),

  -- Quan el lead es converteix a contacte (via api.promote_lead_to_contact)
  contact_id          uuid        REFERENCES data.contacts(id) ON DELETE SET NULL,

  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- Idempotència global (no per site: la key ja inclou el site_id)
CREATE UNIQUE INDEX uidx_public_leads_tenant_idempotency_key
  ON data.public_leads (tenant_id, idempotency_key);

CREATE INDEX idx_public_leads_public_site_id ON data.public_leads (public_site_id);
CREATE INDEX idx_public_leads_tenant_id      ON data.public_leads (tenant_id);
CREATE INDEX idx_public_leads_status         ON data.public_leads (tenant_id, status);
CREATE INDEX idx_public_leads_tenant_created_at ON data.public_leads (tenant_id, created_at DESC);
CREATE INDEX idx_public_leads_contact_id     ON data.public_leads (contact_id)
  WHERE contact_id IS NOT NULL;

ALTER TABLE data.contacts
  ADD CONSTRAINT uq_contacts_id_tenant UNIQUE (id, tenant_id);

ALTER TABLE data.public_leads
  ADD CONSTRAINT fk_public_leads_site_tenant
    FOREIGN KEY (public_site_id, tenant_id)
    REFERENCES data.public_sites(id, tenant_id)
    ON DELETE CASCADE;

CREATE OR REPLACE FUNCTION data.trg_validate_public_leads_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.contact_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM data.contacts c
      WHERE c.id = NEW.contact_id
        AND c.tenant_id = NEW.tenant_id
    ) THEN
      RAISE EXCEPTION 'invalid_contact_tenant: contact_id % no pertany al tenant %', NEW.contact_id, NEW.tenant_id
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON TABLE data.public_leads
  IS 'Leads captats via formularis públics del portal. '
     'Només llegibles per membres autenticats del tenant. '
     'idempotency_key prevé duplicats per reintent o atac de replay. '
     'contact_id s''omple quan el lead es promou a contacte CRM.';

COMMENT ON COLUMN data.public_leads.idempotency_key
  IS 'Hash determinista generat al costat servidor (Route Handler Next.js) '
     'per a deduplicació. Format suggerit: sha256(email|public_site_id|<window>).';

COMMENT ON COLUMN data.public_leads.metadata
  IS 'Metadades tècniques de captació sense PII addicional. '
     'Ex: {country_code, user_agent_truncated, referrer_domain}. '
     'No inclou IP completa (RGPD).';

COMMENT ON COLUMN data.public_leads.contact_id
  IS 'FK a data.contacts quan el lead s''ha promogut a contacte CRM. '
     'NULL = lead no convertit. S''omple via api.promote_lead_to_contact().';

-- Trigger updated_at
CREATE TRIGGER trg_public_leads_updated_at
  BEFORE UPDATE ON data.public_leads
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_validate_public_leads_integrity
  BEFORE INSERT OR UPDATE ON data.public_leads
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_public_leads_integrity();


-- =============================================================================
-- 6. DDL: data.public_domain_events
--    Historial append-only d'events del cicle de vida d'un domini.
--    Mai s'actualitzen ni s'eliminen (auditoria de domini).
-- =============================================================================

CREATE TABLE data.public_domain_events (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  public_domain_id  uuid        NOT NULL REFERENCES data.public_domains(id) ON DELETE CASCADE,
  -- Desnormalitzat per RLS
  tenant_id         uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,

  -- Ex: 'dns_check_passed', 'ssl_provisioned', 'dns_check_failed', 'domain_verified'
  event_type        text        NOT NULL,

  payload           jsonb       NOT NULL DEFAULT '{}',

  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_public_domain_events_domain_id ON data.public_domain_events (public_domain_id);
CREATE INDEX idx_public_domain_events_tenant_id  ON data.public_domain_events (tenant_id);
CREATE INDEX idx_public_domain_events_event_type ON data.public_domain_events (public_domain_id, event_type);
CREATE INDEX idx_public_domain_events_tenant_created_at ON data.public_domain_events (tenant_id, created_at DESC);

ALTER TABLE data.public_domain_events
  ADD CONSTRAINT fk_public_domain_events_domain_tenant
    FOREIGN KEY (public_domain_id, tenant_id)
    REFERENCES data.public_domains(id, tenant_id)
    ON DELETE CASCADE;

CREATE OR REPLACE FUNCTION data.trg_prevent_public_domain_events_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  RAISE EXCEPTION 'append_only_violation: data.public_domain_events no permet %', TG_OP
    USING ERRCODE = '23514';
END;
$$;

CREATE TRIGGER trg_no_update_delete_public_domain_events
  BEFORE UPDATE OR DELETE ON data.public_domain_events
  FOR EACH ROW EXECUTE FUNCTION data.trg_prevent_public_domain_events_mutation();

COMMENT ON TABLE data.public_domain_events
  IS 'Historial append-only d''events del cicle de vida d''un domini propi. '
     'No s''actualitzen ni s''eliminen. Ex: dns_check_passed, ssl_provisioned, '
     'dns_check_failed, domain_verified. Útil per a diagnosi i observabilitat.';


-- =============================================================================
-- 7. ALTER: data.public_sites → FK circular a primary_domain_id
--    S'afegeix post-creació de data.public_domains per evitar dependència circular.
-- =============================================================================

ALTER TABLE data.public_sites
  ADD CONSTRAINT fk_public_sites_primary_domain
    FOREIGN KEY (primary_domain_id) REFERENCES data.public_domains(id) ON DELETE SET NULL;

COMMENT ON COLUMN data.public_sites.primary_domain_id
  IS 'Domini canònic del portal (FK a data.public_domains). '
     'NULL = usa el subdomini per defecte. NOT NULL = les visites al subdomini '
     'fan redirect 301 a aquest domini. S''estableix via api.attach_public_domain() '
     'quan el domini arriba a status=ssl_active.';


-- =============================================================================
-- 8. RLS: ENABLE a totes les taules noves
--    Les policies es defineixen a 20260513000002_public_portal_rls.sql
-- =============================================================================

ALTER TABLE data.public_sites         ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.public_pages         ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.public_domains       ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.public_leads         ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.public_domain_events ENABLE ROW LEVEL SECURITY;


-- =============================================================================
-- 9. Triggers d'auditoria
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 9.1 Audit: data.public_sites
-- Accions: PUBLIC_SITE_CREATED, PUBLIC_SITE_PUBLISHED, PUBLIC_SITE_UNPUBLISHED,
--          PUBLIC_SITE_SUSPENDED, PUBLIC_SITE_DELETED
-- Payload: {name, slug, status} — sense content ni theme_config (massa gran)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_public_sites()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by),
      NULL,
      'PUBLIC_SITE_CREATED',
      'public_site',
      NEW.id,
      jsonb_build_object(
        'name',    NEW.name,
        'slug',    NEW.slug,
        'site_id', NEW.site_id,
        'status',  NEW.status
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    -- Detectar canvi d'estat (published/unpublished/suspended)
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        auth.uid(),
        NULL,
        CASE NEW.status
          WHEN 'published'  THEN 'PUBLIC_SITE_PUBLISHED'
          WHEN 'draft'      THEN 'PUBLIC_SITE_UNPUBLISHED'
          WHEN 'suspended'  THEN 'PUBLIC_SITE_SUSPENDED'
        END,
        'public_site',
        NEW.id,
        jsonb_build_object(
          'name',       NEW.name,
          'slug',       NEW.slug,
          'old_status', OLD.status,
          'new_status', NEW.status
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
      'PUBLIC_SITE_DELETED',
      'public_site',
      OLD.id,
      jsonb_build_object(
        'name', OLD.name,
        'slug', OLD.slug
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_public_sites
  AFTER INSERT OR UPDATE OR DELETE ON data.public_sites
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_public_sites();


-- ---------------------------------------------------------------------------
-- 9.2 Audit: data.public_pages
-- Accions: PUBLIC_PAGE_CREATED, PUBLIC_PAGE_PUBLISHED, PUBLIC_PAGE_UNPUBLISHED,
--          PUBLIC_PAGE_DELETED
-- Payload: {public_site_id, slug, title, status}
-- ---------------------------------------------------------------------------
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
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        auth.uid(),
        NULL,
        CASE NEW.status
          WHEN 'published' THEN 'PUBLIC_PAGE_PUBLISHED'
          WHEN 'draft'     THEN 'PUBLIC_PAGE_UNPUBLISHED'
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

CREATE TRIGGER trg_audit_public_pages
  AFTER INSERT OR UPDATE OR DELETE ON data.public_pages
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_public_pages();


-- ---------------------------------------------------------------------------
-- 9.3 Audit: data.public_domains
-- Accions: PUBLIC_DOMAIN_ATTACHED, PUBLIC_DOMAIN_DNS_VERIFIED,
--          PUBLIC_DOMAIN_SSL_ACTIVE, PUBLIC_DOMAIN_FAILED, PUBLIC_DOMAIN_DELETED
-- Payload: {domain, status} — sense verification_token (dada sensible)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_public_domains()
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
      'PUBLIC_DOMAIN_ATTACHED',
      'public_domain',
      NEW.id,
      jsonb_build_object(
        'public_site_id', NEW.public_site_id,
        'domain',         NEW.domain,
        'status',         NEW.status
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        COALESCE(auth.uid(), NULL),   -- pot ser NULL si el worker (service_role) fa la transició
        NULL,
        CASE NEW.status
          WHEN 'dns_verified' THEN 'PUBLIC_DOMAIN_DNS_VERIFIED'
          WHEN 'ssl_active'   THEN 'PUBLIC_DOMAIN_SSL_ACTIVE'
          WHEN 'failed'       THEN 'PUBLIC_DOMAIN_FAILED'
        END,
        'public_domain',
        NEW.id,
        jsonb_build_object(
          'domain',          NEW.domain,
          'old_status',      OLD.status,
          'new_status',      NEW.status,
          'failure_reason',  NEW.failure_reason
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
      'PUBLIC_DOMAIN_DELETED',
      'public_domain',
      OLD.id,
      jsonb_build_object(
        'domain', OLD.domain,
        'status', OLD.status
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_public_domains
  AFTER INSERT OR UPDATE OR DELETE ON data.public_domains
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_public_domains();


-- ---------------------------------------------------------------------------
-- 9.4 Audit: data.public_leads
-- Accions: PUBLIC_LEAD_CREATED, PUBLIC_LEAD_CONVERTED, PUBLIC_LEAD_DELETED
-- IMPORTANT RGPD: el payload NO inclou name, email, phone, message (PII).
-- Payload: {public_site_id, status, source_page_slug}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_public_leads()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      NULL,    -- INSERT ve de servei anon (Route Handler); user_id NULL és acceptable
      NULL,
      'PUBLIC_LEAD_CREATED',
      'public_lead',
      NEW.id,
      jsonb_build_object(
        'public_site_id',   NEW.public_site_id,
        'status',           NEW.status,
        'source_page_slug', NEW.source_page_slug
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    -- Detectar conversió a contacte CRM
    IF OLD.contact_id IS NULL AND NEW.contact_id IS NOT NULL THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        auth.uid(),
        NULL,
        'PUBLIC_LEAD_CONVERTED',
        'public_lead',
        NEW.id,
        jsonb_build_object(
          'public_site_id', NEW.public_site_id,
          'contact_id',     NEW.contact_id,
          'old_status',     OLD.status,
          'new_status',     NEW.status
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
      'PUBLIC_LEAD_DELETED',
      'public_lead',
      OLD.id,
      jsonb_build_object(
        'public_site_id', OLD.public_site_id,
        'status',         OLD.status
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_public_leads
  AFTER INSERT OR UPDATE OR DELETE ON data.public_leads
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_public_leads();
