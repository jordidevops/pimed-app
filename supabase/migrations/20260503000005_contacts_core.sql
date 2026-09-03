-- =============================================================================
-- Migration: 20260503000005_contacts_core.sql
-- Propòsit : Mòdul de Contactes (CRM bàsic). Gestió d'individus i empreses
--            externes al tenant (clients, proveïdors, pacients, animals, etc.)
--            amb consentiments RGPD, vincles familiars/empresarials i adreces
--            d'intervenció. Connecta projectes i events de calendari existents.
--
-- Conté:
--   1.  ENUM : data.contact_kind ('person' | 'company')
--   2.  DDL  : data.contacts (taula mestra de contactes)
--   3.  DDL  : data.contact_sites (adreces d'intervenció del contacte)
--   4a. ALTER: data.projects  → FK real sobre client_id → data.contacts
--   4b. ALTER: data.calendar_events → nova columna contact_id
--   5.  RLS  : data.contacts
--   6.  RLS  : data.contact_sites
--   7.  Audit: triggers AFTER INSERT/UPDATE/DELETE per contacts i contact_sites
--   8.  Vista: api.contacts (security_invoker = true, filtre tenant actiu)
--   9.  Vista: api.contact_sites (security_invoker = true)
--   10. RPC  : api.create_contact (INSERT transaccional)
--   11. RPC  : api.archive_contact (UPDATE is_archived)
--   12. Grants
--
-- Patró RLS aplicat:
--   · Pertinença tenant  : data.jwt_user_tenants() ? tenant_id::text
--   · Rol global escriptura: data.jwt_user_tenants() -> tenant_id::text ->> 'global_role'
--                            IN ('owner', 'manager', 'member')
--   · Rol global DELETE  : IN ('owner', 'manager')
--   · Filtre UX          : data.active_tenant_id() a les vistes api.*
--
-- Auditoria:
--   CONTACT_CREATED, CONTACT_UPDATED, CONTACT_ARCHIVED, CONTACT_UNARCHIVED,
--   CONTACT_DELETED, CONTACT_SITE_CREATED, CONTACT_SITE_UPDATED,
--   CONTACT_SITE_DELETED
-- =============================================================================

-- =============================================================================
-- 1. ENUM: data.contact_kind
-- =============================================================================

CREATE TYPE data.contact_kind AS ENUM (
  'person',   -- Persona física (individu, pacient, animal amb tutor, etc.)
  'company'   -- Persona jurídica (empresa, associació, etc.)
);

-- =============================================================================
-- 2. DDL: data.contacts
-- =============================================================================

CREATE TABLE data.contacts (
  id                    uuid               PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid               NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  -- NULL = contacte global del tenant; NOT NULL = contacte d'un site concret
  site_id               uuid                        REFERENCES data.sites(id)    ON DELETE SET NULL,

  kind                  data.contact_kind  NOT NULL DEFAULT 'person',

  -- Nom visible (calculat manualment o derivat de given_name + family_name)
  display_name          text               NOT NULL,

  -- Camps específics per kind='person'
  given_name            text,
  family_name           text,

  -- Camps específics per kind='company'
  legal_name            text,
  tax_id                text,   -- NIF/CIF/VAT

  -- Contacte
  email                 text,
  phone                 text,       -- E.164 quan és possible (ex: +34612345678)
  phone_alt             text,
  preferred_channel     text        NOT NULL DEFAULT 'email'
                                    CHECK (preferred_channel IN ('email', 'sms', 'whatsapp', 'none')),

  -- Classificació i metadades
  tags                  text[]      NOT NULL DEFAULT '{}',
  metadata              jsonb       NOT NULL DEFAULT '{}',   -- camps sectorials (JSON Schema extern)
  source                text,       -- 'web', 'import', 'referral', 'manual'

  -- Responsable intern
  owner_user_id         uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,

  -- Vincles entre contactes
  -- Per a menors/animals: apunta al tutor/propietari
  -- Per a empresa filial: apunta a l'empresa mare
  primary_contact_id    uuid        REFERENCES data.contacts(id) ON DELETE SET NULL,
  -- Qui rep les factures (pot diferir del contacte principal)
  billing_contact_id    uuid        REFERENCES data.contacts(id) ON DELETE SET NULL,

  -- Consentiments RGPD
  consent_marketing     bool        NOT NULL DEFAULT false,
  consent_marketing_at  timestamptz,
  consent_reminders     bool        NOT NULL DEFAULT true,
  consent_reminders_at  timestamptz,

  -- Estat
  is_archived           bool        NOT NULL DEFAULT false,

  -- Traçabilitat
  created_by            uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

-- Índexs operacionals
CREATE INDEX idx_contacts_tenant_id      ON data.contacts (tenant_id);
CREATE INDEX idx_contacts_tenant_kind    ON data.contacts (tenant_id, kind);
CREATE INDEX idx_contacts_owner_user_id  ON data.contacts (owner_user_id);
CREATE INDEX idx_contacts_tags           ON data.contacts USING gin (tags);
CREATE INDEX idx_contacts_email          ON data.contacts (tenant_id, email);
CREATE INDEX idx_contacts_archived       ON data.contacts (tenant_id, is_archived);

COMMENT ON TABLE data.contacts
  IS 'CRM bàsic multi-tenant. Individus i empreses externes al tenant '
     '(clients, pacients, animals, proveïdors...). '
     'site_id NULL = contacte global del tenant; NOT NULL = contacte d''un site.';

COMMENT ON COLUMN data.contacts.display_name
  IS 'Nom visible per la UI. Pot ser calculat (given_name + family_name) o entrat manualment.';

COMMENT ON COLUMN data.contacts.tax_id
  IS 'NIF/CIF/VAT del contacte empresa. Opcional; no s''exposa en la vista api.contacts per defecte.';

COMMENT ON COLUMN data.contacts.phone
  IS 'Telèfon normalitzat E.164 quan és possible. Ex: +34612345678.';

COMMENT ON COLUMN data.contacts.preferred_channel
  IS 'Canal preferit per enviar comunicacions: email, sms, whatsapp o none (sense preferència).';

COMMENT ON COLUMN data.contacts.tags
  IS 'Etiquetes lliures per a filtratge i agrupació. GIN index per a cerca ràpida.';

COMMENT ON COLUMN data.contacts.metadata
  IS 'Camps sectorials (veterinària, educació, etc.) validats per JSON Schema extern. '
     'No s''exposa sencer en la vista api.contacts per privacitat (cal consulta directa).';

COMMENT ON COLUMN data.contacts.primary_contact_id
  IS 'Per a menors/animals: apunta al tutor/propietari. '
     'Per a empresa filial: apunta a l''empresa mare. NULL = contacte independent.';

COMMENT ON COLUMN data.contacts.billing_contact_id
  IS 'Qui rep les factures. NULL = el propi contacte rep les factures.';

COMMENT ON COLUMN data.contacts.consent_marketing
  IS 'true = ha consentit rebre comunicacions de màrqueting (RGPD).';

COMMENT ON COLUMN data.contacts.consent_reminders
  IS 'true = ha consentit rebre recordatoris de cita/servei (RGPD). Per defecte true.';

COMMENT ON COLUMN data.contacts.is_archived
  IS 'true = contacte arxivat (no actiu). La vista api.contacts filtra is_archived=false per defecte.';

-- Trigger updated_at (reutilitza data.set_updated_at() de la migració inicial)
CREATE TRIGGER trg_contacts_updated_at
  BEFORE UPDATE ON data.contacts
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- =============================================================================
-- 3. DDL: data.contact_sites
-- Adreces on l'equip del tenant va a intervenir (locals del client, domicilis, etc.).
-- DIFERENT de data.sites (seus del tenant). Aquí és on VIVE o TREBALLA el contacte.
-- =============================================================================

CREATE TABLE data.contact_sites (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  contact_id    uuid        NOT NULL REFERENCES data.contacts(id)  ON DELETE CASCADE,

  name          text        NOT NULL,   -- Ex: "Local Gràcia", "Oficina central", "Domicili"
  address       text,
  city          text,
  postal_code   text,
  country_code  char(2)     DEFAULT 'ES',
  notes         text,
  is_active     bool        NOT NULL DEFAULT true,

  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_contact_sites_contact_id ON data.contact_sites (contact_id);
CREATE INDEX idx_contact_sites_tenant_id  ON data.contact_sites (tenant_id);

COMMENT ON TABLE data.contact_sites
  IS 'Adreces d''intervenció del contacte (local del client, domicili, etc.). '
     'Diferent de data.sites, que són les seus del tenant. '
     'Un contacte pot tenir N adreces (ex: seu central + delegació).';

COMMENT ON COLUMN data.contact_sites.name
  IS 'Nom descriptiu de l''adreça. Ex: "Local Gràcia", "Domicili", "Oficina central".';

COMMENT ON COLUMN data.contact_sites.country_code
  IS 'Codi ISO 3166-1 alpha-2 del país. Per defecte ''ES'' (Espanya).';

-- Trigger updated_at
CREATE TRIGGER trg_contact_sites_updated_at
  BEFORE UPDATE ON data.contact_sites
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- =============================================================================
-- 4a. ALTER data.projects: afegir FK real sobre client_id → data.contacts
-- El camp client_id (uuid) ja existia des de 20260502000001 com a reservat.
-- =============================================================================

ALTER TABLE data.projects
  ADD CONSTRAINT fk_projects_contact
    FOREIGN KEY (client_id) REFERENCES data.contacts(id) ON DELETE SET NULL;

COMMENT ON COLUMN data.projects.client_id
  IS 'Contacte client del projecte (empresa o persona). FK sobre data.contacts.';

-- =============================================================================
-- 4b. ALTER data.calendar_events: nova columna contact_id
-- Permet vincular events de calendari (visites, intervencions) a un contacte.
-- =============================================================================

ALTER TABLE data.calendar_events
  ADD COLUMN contact_id uuid REFERENCES data.contacts(id) ON DELETE SET NULL;

CREATE INDEX idx_calendar_events_contact_id ON data.calendar_events (contact_id);

COMMENT ON COLUMN data.calendar_events.contact_id
  IS 'Contacte associat a l''event (ex: visita a client, cita de pacient). '
     'NULL = event no vinculat a cap contacte concret.';

-- =============================================================================
-- 5. Row Level Security: data.contacts
-- =============================================================================

ALTER TABLE data.contacts ENABLE ROW LEVEL SECURITY;

-- SELECT: qualsevol membre del tenant pot veure els contactes
CREATE POLICY "contacts: membres del tenant poden veure"
  ON data.contacts FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- INSERT: owner, manager o member (no viewer)
CREATE POLICY "contacts: owner/manager/member pot crear"
  ON data.contacts FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

-- UPDATE: owner, manager o member
CREATE POLICY "contacts: owner/manager/member pot modificar"
  ON data.contacts FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

-- DELETE: owner o manager global únicament
CREATE POLICY "contacts: owner/manager pot eliminar"
  ON data.contacts FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );

-- =============================================================================
-- 6. Row Level Security: data.contact_sites
-- =============================================================================

ALTER TABLE data.contact_sites ENABLE ROW LEVEL SECURITY;

-- SELECT: qualsevol membre del tenant
CREATE POLICY "contact_sites: membres del tenant poden veure"
  ON data.contact_sites FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- INSERT: owner, manager o member
CREATE POLICY "contact_sites: owner/manager/member pot crear"
  ON data.contact_sites FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

-- UPDATE: owner, manager o member
CREATE POLICY "contact_sites: owner/manager/member pot modificar"
  ON data.contact_sites FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

-- DELETE: owner o manager global
CREATE POLICY "contact_sites: owner/manager pot eliminar"
  ON data.contact_sites FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager')
  );

-- =============================================================================
-- 7. Triggers d'auditoria
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Audit: data.contacts
-- Accions: CONTACT_CREATED, CONTACT_UPDATED, CONTACT_ARCHIVED,
--          CONTACT_UNARCHIVED, CONTACT_DELETED
-- actor: COALESCE(auth.uid(), created_by) a INSERT; auth.uid() als altres.
-- Payload: {display_name, kind, email} — mai el camp metadata complet.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_contacts()
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
      NEW.site_id,
      'CONTACT_CREATED',
      'contact',
      NEW.id,
      jsonb_build_object(
        'display_name', NEW.display_name,
        'kind',         NEW.kind,
        'email',        NEW.email
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    -- Prioritat: detectar canvi d'estat d'arxivat
    IF OLD.is_archived IS DISTINCT FROM NEW.is_archived THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        CASE WHEN NEW.is_archived THEN 'CONTACT_ARCHIVED' ELSE 'CONTACT_UNARCHIVED' END,
        'contact', NEW.id,
        jsonb_build_object(
          'display_name', NEW.display_name,
          'kind',         NEW.kind,
          'email',        NEW.email
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NEW.site_id,
        'CONTACT_UPDATED',
        'contact', NEW.id,
        jsonb_build_object(
          'old', jsonb_build_object(
            'display_name', OLD.display_name,
            'kind',         OLD.kind,
            'email',        OLD.email
          ),
          'new', jsonb_build_object(
            'display_name', NEW.display_name,
            'kind',         NEW.kind,
            'email',        NEW.email
          )
        )
      );
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, auth.uid(), OLD.site_id,
      'CONTACT_DELETED',
      'contact', OLD.id,
      jsonb_build_object(
        'display_name', OLD.display_name,
        'kind',         OLD.kind,
        'email',        OLD.email
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_contacts
  AFTER INSERT OR UPDATE OR DELETE ON data.contacts
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_contacts();

-- ---------------------------------------------------------------------------
-- Audit: data.contact_sites
-- Accions: CONTACT_SITE_CREATED, CONTACT_SITE_UPDATED, CONTACT_SITE_DELETED
-- Payload: {contact_id, name}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_contact_sites()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NULL,
      'CONTACT_SITE_CREATED',
      'contact_site', NEW.id,
      jsonb_build_object(
        'contact_id', NEW.contact_id,
        'name',       NEW.name
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, auth.uid(), NULL,
      'CONTACT_SITE_UPDATED',
      'contact_site', NEW.id,
      jsonb_build_object(
        'contact_id', NEW.contact_id,
        'name',       NEW.name
      )
    );

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, auth.uid(), NULL,
      'CONTACT_SITE_DELETED',
      'contact_site', OLD.id,
      jsonb_build_object(
        'contact_id', OLD.contact_id,
        'name',       OLD.name
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_contact_sites
  AFTER INSERT OR UPDATE OR DELETE ON data.contact_sites
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_contact_sites();

-- =============================================================================
-- 8. Vista api.contacts
-- Filtre: tenant actiu (data.active_tenant_id()) + is_archived=false
-- Camps calculats: owner_display_name (full_name del perfil intern),
--                  primary_contact_display_name (display_name del contacte pare)
-- NOT updatable (JOIN): les escriptures van per RPC o directament a data.contacts.
-- =============================================================================

CREATE OR REPLACE VIEW api.contacts
  WITH (security_invoker = true)
AS
SELECT
  c.id,
  c.tenant_id,
  c.site_id,
  c.kind,
  c.display_name,
  c.given_name,
  c.family_name,
  c.legal_name,
  c.tax_id,
  c.email,
  c.phone,
  c.phone_alt,
  c.preferred_channel,
  c.tags,
  c.metadata,
  c.source,
  c.owner_user_id,
  c.primary_contact_id,
  c.billing_contact_id,
  c.consent_marketing,
  c.consent_marketing_at,
  c.consent_reminders,
  c.consent_reminders_at,
  c.is_archived,
  c.created_by,
  c.created_at,
  c.updated_at,
  -- Camps calculats (JOIN)
  p.full_name              AS owner_display_name,
  pc.display_name          AS primary_contact_display_name
FROM data.contacts c
LEFT JOIN data.profiles  p  ON p.id  = c.owner_user_id
LEFT JOIN data.contacts  pc ON pc.id = c.primary_contact_id
WHERE c.tenant_id   = data.active_tenant_id()
  AND c.is_archived = false;

GRANT SELECT ON api.contacts TO authenticated;

-- =============================================================================
-- 9. Vista api.contact_sites
-- Filtre: tenant actiu
-- Updatable: sí (taula única, sense camps virtuals)
-- =============================================================================

CREATE OR REPLACE VIEW api.contact_sites
  WITH (security_invoker = true)
AS
SELECT
  cs.id,
  cs.tenant_id,
  cs.contact_id,
  cs.name,
  cs.address,
  cs.city,
  cs.postal_code,
  cs.country_code,
  cs.notes,
  cs.is_active,
  cs.created_at,
  cs.updated_at
FROM data.contact_sites cs
WHERE cs.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.contact_sites TO authenticated;

-- =============================================================================
-- 10. RPC api.create_contact
-- Crea un contacte al tenant actiu. SECURITY INVOKER: la política RLS valida
-- que l'usuari tingui rol owner/manager/member al tenant.
-- Retorna: uuid del contacte creat.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_contact(
  p_kind              text,
  p_display_name      text,
  p_given_name        text        DEFAULT NULL,
  p_family_name       text        DEFAULT NULL,
  p_legal_name        text        DEFAULT NULL,
  p_tax_id            text        DEFAULT NULL,
  p_email             text        DEFAULT NULL,
  p_phone             text        DEFAULT NULL,
  p_phone_alt         text        DEFAULT NULL,
  p_preferred_channel text        DEFAULT 'email',
  p_tags              text[]      DEFAULT '{}',
  p_metadata          jsonb       DEFAULT '{}',
  p_source            text        DEFAULT 'manual',
  p_owner_user_id     uuid        DEFAULT NULL
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
  INSERT INTO data.contacts (
    tenant_id,
    kind,
    display_name,
    given_name,
    family_name,
    legal_name,
    tax_id,
    email,
    phone,
    phone_alt,
    preferred_channel,
    tags,
    metadata,
    source,
    owner_user_id,
    created_by
  ) VALUES (
    v_tenant_id,
    p_kind::data.contact_kind,
    p_display_name,
    p_given_name,
    p_family_name,
    p_legal_name,
    p_tax_id,
    p_email,
    p_phone,
    p_phone_alt,
    p_preferred_channel,
    p_tags,
    p_metadata,
    p_source,
    COALESCE(p_owner_user_id, auth.uid()),
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- =============================================================================
-- 11. RPC api.archive_contact
-- Arxiva (soft-delete) un contacte del tenant actiu. La vista api.contacts
-- filtra is_archived=false, de manera que el contacte deixa de ser visible.
-- SECURITY INVOKER: el UPDATE ha de passar les polítiques RLS de UPDATE.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.archive_contact(p_contact_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.contacts
  SET
    is_archived = true,
    updated_at  = now()
  WHERE id        = p_contact_id
    AND tenant_id = data.active_tenant_id();
END;
$$;

-- =============================================================================
-- 12. Grants
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON data.contacts      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.contact_sites TO authenticated;

GRANT SELECT ON api.contacts      TO authenticated;
GRANT SELECT ON api.contact_sites TO authenticated;

GRANT EXECUTE ON FUNCTION api.create_contact(
  text, text, text, text, text, text, text, text, text, text,
  text[], jsonb, text, uuid
) TO authenticated;

GRANT EXECUTE ON FUNCTION api.archive_contact(uuid) TO authenticated;
