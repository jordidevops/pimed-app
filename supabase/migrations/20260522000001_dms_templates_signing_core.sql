-- =============================================================================
-- Migration: 20260522000001_dms_templates_signing_core.sql
-- Propòsit:  Model de dades complet per templates documentals i signing flow
--            (Fase 1 del DMS + Templates + Signing Control Center)
--
-- Crea:
--   data.tenant_signing_config       — configuració DocuSeal per tenant (1:1)
--   data.document_templates          — plantilles plataforma + tenant (patró email_templates)
--   data.document_template_locales   — fitxers per locale + variables schema
--   data.signing_submissions         — cicle de vida complet de cada submissió
--   data.signing_events              — timeline detallat d'events (append-only)
--
-- Vistes api.*:
--   api.tenant_signing_status         — mode/credits (SENSE clau vault)
--   api.document_templates
--   api.document_template_locales
--   api.signing_submissions
--   api.signing_events
--
-- RPCs SECURITY DEFINER:
--   api.create_document_template      — crea template de tenant (amb clone opcional)
--   api.consume_signing_credit        — decrement atòmic de crèdits (mode platform)
--   api.get_docuseal_key_for_signing  — llegeix clau BYO de vault
--   api.append_signing_event          — afegeix event + actualitza estat (idempotent)
--   api.save_tenant_docuseal_config   — upsert configuració DocuSeal (clau a vault)
--
-- Seguretat:
--   · La clau DocuSeal BYO MAI s'exposa via api.* ni al client
--   · tenant_signing_config.docuseal_key_secret_id és opac (vault UUID)
--   · append_signing_event és idempotent via webhook_event_id unique index
--
-- Auditoria:
--   · TEMPLATE_CREATED / TEMPLATE_UPDATED / TEMPLATE_ACTIVATED / TEMPLATE_DEACTIVATED / TEMPLATE_DELETED
--   · SIGNING_SUBMISSION_CREATED / SIGNING_SUBMISSION_STATUS_CHANGED
--   · SIGNING_CREDIT_CONSUMED
--   · SIGNING_CONFIG_UPDATED
-- =============================================================================


-- ============================================================================
-- 0. ENUMs
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE data.signing_mode AS ENUM ('platform', 'byo');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE data.signing_submission_status AS ENUM (
    'draft',
    'pending',
    'in_progress',
    'completed',
    'declined',
    'expired',
    'cancelled',
    'error'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE data.signing_source_type AS ENUM (
    'document_existing',
    'template_locale'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE data.signing_event_source AS ENUM ('webhook', 'system', 'user');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ============================================================================
-- 1. data.tenant_signing_config
--    1:1 amb data.tenants. MAI exposada directament via api.* (conté vault ref).
--    Clau DocuSeal BYO → vault.secrets.id (UUID opac).
-- ============================================================================

CREATE TABLE data.tenant_signing_config (
  tenant_id              uuid           PRIMARY KEY
                           REFERENCES data.tenants(id) ON DELETE CASCADE,
  mode                   data.signing_mode NOT NULL DEFAULT 'platform',
  signing_credits        integer        NOT NULL DEFAULT 0
                           CHECK (signing_credits >= 0),
  -- BYO: UUID de la clau a Supabase Vault — SECURITY DEFINER únic que pot llegir-la
  docuseal_key_secret_id uuid,
  docuseal_api_url       text           NOT NULL
                           DEFAULT 'https://api.docuseal.eu',
  is_active              boolean        NOT NULL DEFAULT true,
  metadata               jsonb,
  created_at             timestamptz    NOT NULL DEFAULT now(),
  updated_at             timestamptz    NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.tenant_signing_config
  IS 'Configuració DocuSeal per tenant. Mai exposada via api.* (conté docuseal_key_secret_id).';
COMMENT ON COLUMN data.tenant_signing_config.docuseal_key_secret_id
  IS 'UUID de vault.secrets per a la clau API DocuSeal en mode BYO. SECURITY DEFINER only.';


-- ============================================================================
-- 2. data.document_templates
--    Patró idèntic a data.email_templates: tenant XOR plataforma (XOR estricte).
--    Plataforma: tenant_id IS NULL, is_platform_default = true
--    Tenant:     tenant_id NOT NULL, is_platform_default = false
-- ============================================================================

CREATE TABLE data.document_templates (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid        REFERENCES data.tenants(id) ON DELETE CASCADE,
  name                 text        NOT NULL,
  description          text,
  category             text,
  is_platform_default  boolean     NOT NULL DEFAULT false,
  cloned_from_id       uuid        REFERENCES data.document_templates(id) ON DELETE SET NULL,
  is_active            boolean     NOT NULL DEFAULT true,
  created_by           uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),

  -- XOR estricte: template de tenant XOR de plataforma
  CONSTRAINT chk_doc_template_owner CHECK (
    (tenant_id IS NOT NULL AND is_platform_default = false)
    OR
    (tenant_id IS NULL     AND is_platform_default = true)
  )
);

CREATE INDEX idx_doc_templates_tenant
  ON data.document_templates (tenant_id);

-- Unicitat de nom per plantilles de plataforma actives
CREATE UNIQUE INDEX idx_doc_templates_platform_name
  ON data.document_templates (name)
  WHERE is_platform_default = true AND is_active = true;

COMMENT ON TABLE data.document_templates
  IS 'Plantilles documentals. Patró idèntic email_templates: tenant_id NULL = plataforma.';


-- ============================================================================
-- 3. data.document_template_locales
--    Fitxer (DOCX/PDF) per cada locale d''una plantilla + esquema de variables.
-- ============================================================================

CREATE TABLE data.document_template_locales (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id      uuid        NOT NULL
                     REFERENCES data.document_templates(id) ON DELETE CASCADE,
  locale           text        NOT NULL DEFAULT 'ca',
  -- Ruta al bucket "document-templates" (NULL si el fitxer encara no s'ha pujat)
  storage_path     text,
  mime_type        text        CHECK (
    mime_type IS NULL
    OR mime_type IN (
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/pdf'
    )
  ),
  -- {"key": {"type": "string", "label": "...", "required": true, "default": null}}
  variables_schema jsonb       NOT NULL DEFAULT '{}',
  sample_values    jsonb,
  is_active        boolean     NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  UNIQUE (template_id, locale)
);

CREATE INDEX idx_doc_template_locales_template
  ON data.document_template_locales (template_id);

COMMENT ON TABLE data.document_template_locales
  IS 'Fitxer DOCX/PDF per locale de cada plantilla, amb esquema de variables.';


-- ============================================================================
-- 4. data.signing_submissions
--    Cicle de vida complet de cada enviament a signatura o generació.
--    docuseal_submission_id i external_id: unique parcials (admeten NULL per drafts).
-- ============================================================================

CREATE TABLE data.signing_submissions (
  id                          uuid                         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                   uuid                         NOT NULL
                                REFERENCES data.tenants(id) ON DELETE CASCADE,
  -- Font: document existent del DMS o locale d'una plantilla
  source_type                 data.signing_source_type     NOT NULL,
  source_document_version_id  uuid
                                REFERENCES data.document_versions(id) ON DELETE SET NULL,
  source_template_locale_id   uuid
                                REFERENCES data.document_template_locales(id) ON DELETE SET NULL,
  -- Document resultant (creat en completar o en generate_only)
  result_document_version_id  uuid
                                REFERENCES data.document_versions(id) ON DELETE SET NULL,
  -- Identificadors DocuSeal
  docuseal_submission_id      text,
  external_id                 text,   -- nostra clau idempotent enviada a DocuSeal
  -- Màquina d'estats
  status                      data.signing_submission_status NOT NULL DEFAULT 'draft',
  status_reason               text,
  error_message               text,
  last_event_at               timestamptz,
  -- Snapshot de signants (actualitzat per webhook)
  -- [{email, name, role, status, signing_url, completed_at}]
  signers                     jsonb                        NOT NULL DEFAULT '[]',
  docuseal_signing_url        text,
  -- Timestamps de cicle de vida
  submitted_at                timestamptz,
  completed_at                timestamptz,
  -- Qui ho va iniciar
  initiated_by                uuid
                                REFERENCES data.profiles(id) ON DELETE SET NULL,
  metadata                    jsonb,
  created_at                  timestamptz                  NOT NULL DEFAULT now(),
  updated_at                  timestamptz                  NOT NULL DEFAULT now()
);

-- Idempotència: index parcial que admet múltiples NULLs (drafts)
CREATE UNIQUE INDEX idx_signing_submissions_docuseal_id
  ON data.signing_submissions (docuseal_submission_id)
  WHERE docuseal_submission_id IS NOT NULL;

CREATE UNIQUE INDEX idx_signing_submissions_external_id
  ON data.signing_submissions (external_id)
  WHERE external_id IS NOT NULL;

CREATE INDEX idx_signing_submissions_tenant
  ON data.signing_submissions (tenant_id, created_at DESC);

CREATE INDEX idx_signing_submissions_status
  ON data.signing_submissions (tenant_id, status);

CREATE INDEX idx_signing_submissions_doc_version
  ON data.signing_submissions (source_document_version_id);

CREATE INDEX idx_signing_submissions_template_locale
  ON data.signing_submissions (source_template_locale_id);

COMMENT ON TABLE data.signing_submissions
  IS 'Cicle de vida de cada submissió de signatura o generació. Idempotent via docuseal_submission_id.';


-- ============================================================================
-- 5. data.signing_events
--    Timeline append-only per cada submissió.
--    webhook_event_id: unique parcial per dedup de webhooks repetits.
-- ============================================================================

CREATE TABLE data.signing_events (
  id               uuid                       PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id    uuid                       NOT NULL
                     REFERENCES data.signing_submissions(id) ON DELETE CASCADE,
  tenant_id        uuid                       NOT NULL
                     REFERENCES data.tenants(id) ON DELETE CASCADE,
  event_type       text                       NOT NULL,
  -- Ex: 'form.viewed', 'form.started', 'form.completed', 'submission.completed',
  --     'submission.declined', 'submission.expired', 'email.bounced', 'system.error'
  event_source     data.signing_event_source  NOT NULL DEFAULT 'webhook',
  webhook_event_id text,     -- ID de l'event DocuSeal per idempotència
  signer_email     text,
  signer_name      text,
  status_before    text,
  status_after     text,
  payload          jsonb,
  created_at       timestamptz                NOT NULL DEFAULT now()
);

-- Dedup estricte de webhooks repetits
CREATE UNIQUE INDEX idx_signing_events_webhook_dedup
  ON data.signing_events (webhook_event_id)
  WHERE webhook_event_id IS NOT NULL;

CREATE INDEX idx_signing_events_submission
  ON data.signing_events (submission_id, created_at ASC);

CREATE INDEX idx_signing_events_tenant
  ON data.signing_events (tenant_id, created_at DESC);

COMMENT ON TABLE data.signing_events
  IS 'Timeline append-only de events per submissió. Dedup via webhook_event_id.';


-- ============================================================================
-- 6. Triggers updated_at
--    Reutilitza data.set_updated_at() definit a la migració inicial (core_tables).
-- ============================================================================

CREATE TRIGGER trg_tenant_signing_config_updated_at
  BEFORE UPDATE ON data.tenant_signing_config
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_document_templates_updated_at
  BEFORE UPDATE ON data.document_templates
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_document_template_locales_updated_at
  BEFORE UPDATE ON data.document_template_locales
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_signing_submissions_updated_at
  BEFORE UPDATE ON data.signing_submissions
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- signing_events és append-only: sense trigger updated_at


-- ============================================================================
-- 7. Row Level Security
-- ============================================================================

ALTER TABLE data.tenant_signing_config      ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.document_templates         ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.document_template_locales  ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.signing_submissions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.signing_events             ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- data.tenant_signing_config
--   · SELECT: qualsevol membre del tenant (mode/credits és info operativa)
--   · WRITE: owner/manager globals
--   · NOTA: docuseal_key_secret_id mai surt via api.* (view filtra el camp)
-- ---------------------------------------------------------------------------

CREATE POLICY "tenant_signing_config: tenant members select"
  ON data.tenant_signing_config FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
  );

CREATE POLICY "tenant_signing_config: owner/manager insert"
  ON data.tenant_signing_config FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE POLICY "tenant_signing_config: owner/manager update"
  ON data.tenant_signing_config FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- ---------------------------------------------------------------------------
-- data.document_templates
--   · SELECT: plantilles plataforma visibles a tots; tenant → membres del tenant
--   · WRITE: owner/manager del tenant (no es poden modificar plantilles plataforma)
-- ---------------------------------------------------------------------------

CREATE POLICY "document_templates: select"
  ON data.document_templates FOR SELECT TO authenticated
  USING (
    is_platform_default = true
    OR (
      tenant_id IS NOT NULL
      AND data.jwt_user_tenants() ? tenant_id::text
    )
  );

CREATE POLICY "document_templates: insert"
  ON data.document_templates FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE POLICY "document_templates: update"
  ON data.document_templates FOR UPDATE TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE POLICY "document_templates: delete"
  ON data.document_templates FOR DELETE TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- ---------------------------------------------------------------------------
-- data.document_template_locales: hereda accés del template pare
-- ---------------------------------------------------------------------------

CREATE POLICY "document_template_locales: select"
  ON data.document_template_locales FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.document_templates t
      WHERE t.id = template_id
      -- La RLS de data.document_templates s'aplica automàticament al subquery
    )
  );

CREATE POLICY "document_template_locales: insert"
  ON data.document_template_locales FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.document_templates t
      WHERE t.id = template_id
        AND t.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? t.tenant_id::text
        AND (data.jwt_user_tenants() -> t.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

CREATE POLICY "document_template_locales: update"
  ON data.document_template_locales FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.document_templates t
      WHERE t.id = template_id
        AND t.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? t.tenant_id::text
        AND (data.jwt_user_tenants() -> t.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.document_templates t
      WHERE t.id = template_id
        AND t.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? t.tenant_id::text
        AND (data.jwt_user_tenants() -> t.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

CREATE POLICY "document_template_locales: delete"
  ON data.document_template_locales FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.document_templates t
      WHERE t.id = template_id
        AND t.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? t.tenant_id::text
        AND (data.jwt_user_tenants() -> t.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

-- ---------------------------------------------------------------------------
-- data.signing_submissions
--   · SELECT: tots els membres del tenant
--   · INSERT: owner/manager/member (el flux normal és via edge function)
--   · UPDATE: owner/manager
-- ---------------------------------------------------------------------------

CREATE POLICY "signing_submissions: tenant members select"
  ON data.signing_submissions FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
  );

CREATE POLICY "signing_submissions: owner/manager/member insert"
  ON data.signing_submissions FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

CREATE POLICY "signing_submissions: owner/manager update"
  ON data.signing_submissions FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- ---------------------------------------------------------------------------
-- data.signing_events
--   · SELECT: tots els membres del tenant
--   · INSERT: exclusivament via service_role (webhook) o SECURITY DEFINER RPCs
-- ---------------------------------------------------------------------------

CREATE POLICY "signing_events: tenant members select"
  ON data.signing_events FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
  );

-- No hi ha política INSERT per authenticated: els events es creen via
-- api.append_signing_event (SECURITY DEFINER) o service_role (webhook).


-- ============================================================================
-- 8. Grants per authenticated
-- ============================================================================

-- data.*
GRANT SELECT, INSERT, UPDATE         ON data.tenant_signing_config      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.document_templates         TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.document_template_locales  TO authenticated;
GRANT SELECT, INSERT, UPDATE         ON data.signing_submissions         TO authenticated;
GRANT SELECT                         ON data.signing_events              TO authenticated;

-- service_role: necessita accés directe per edge functions (webhook, worker)
-- service_role ja té BYPASSRLS però necessita GRANTs de taula
GRANT USAGE ON SCHEMA data TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.signing_submissions     TO service_role;
GRANT SELECT, INSERT         ON data.signing_events          TO service_role;
GRANT SELECT                 ON data.tenant_signing_config   TO service_role;
GRANT SELECT                 ON data.document_templates      TO service_role;
GRANT SELECT                 ON data.document_template_locales TO service_role;


-- ============================================================================
-- 9. Triggers d'auditoria
-- ============================================================================

-- ---------------------------------------------------------------------------
-- data.document_templates — TEMPLATE_CREATED/UPDATED/ACTIVATED/DEACTIVATED/DELETED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_document_templates()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NULL), NULL,
      'TEMPLATE_CREATED', 'document_template', NEW.id,
      jsonb_build_object(
        'name',                NEW.name,
        'is_platform_default', NEW.is_platform_default,
        'cloned_from_id',      NEW.cloned_from_id
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.is_active IS DISTINCT FROM NEW.is_active THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, COALESCE(auth.uid(), NULL), NULL,
        CASE WHEN NEW.is_active THEN 'TEMPLATE_ACTIVATED' ELSE 'TEMPLATE_DEACTIVATED' END,
        'document_template', NEW.id,
        jsonb_build_object('name', NEW.name)
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, COALESCE(auth.uid(), NULL), NULL,
        'TEMPLATE_UPDATED', 'document_template', NEW.id,
        jsonb_build_object(
          'old', jsonb_build_object('name', OLD.name, 'category', OLD.category),
          'new', jsonb_build_object('name', NEW.name, 'category', NEW.category)
        )
      );
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, COALESCE(auth.uid(), NULL), NULL,
      'TEMPLATE_DELETED', 'document_template', OLD.id,
      jsonb_build_object('name', OLD.name)
    );
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_document_templates
  AFTER INSERT OR UPDATE OR DELETE ON data.document_templates
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_document_templates();

-- ---------------------------------------------------------------------------
-- data.signing_submissions — SIGNING_SUBMISSION_CREATED / STATUS_CHANGED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_signing_submissions()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NULL), NULL,
      'SIGNING_SUBMISSION_CREATED', 'signing_submission', NEW.id,
      jsonb_build_object(
        'source_type', NEW.source_type,
        'status',      NEW.status
      )
    );
  ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NULL), NULL,
      'SIGNING_SUBMISSION_STATUS_CHANGED', 'signing_submission', NEW.id,
      jsonb_build_object(
        'old_status', OLD.status,
        'new_status', NEW.status,
        'reason',     NEW.status_reason
      )
    );
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_signing_submissions
  AFTER INSERT OR UPDATE ON data.signing_submissions
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_signing_submissions();


-- ============================================================================
-- 10. Vistes API
--
-- IMPORTANT: api.tenant_signing_status exposa ÚNICAMENT camps segurs.
--            docuseal_key_secret_id mai apareix a cap vista api.*.
-- ============================================================================

-- Vista segura de configuració de signatura (SENSE clau vault)
CREATE OR REPLACE VIEW api.tenant_signing_status WITH (security_invoker = true) AS
  SELECT
    tenant_id,
    mode,
    signing_credits,
    docuseal_api_url,
    is_active,
    created_at,
    updated_at
    -- docuseal_key_secret_id: EXCLÒS deliberadament
  FROM data.tenant_signing_config;

CREATE OR REPLACE VIEW api.document_templates WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    name,
    description,
    category,
    is_platform_default,
    cloned_from_id,
    is_active,
    created_by,
    created_at,
    updated_at
  FROM data.document_templates;

CREATE OR REPLACE VIEW api.document_template_locales WITH (security_invoker = true) AS
  SELECT
    id,
    template_id,
    locale,
    storage_path,
    mime_type,
    variables_schema,
    sample_values,
    is_active,
    created_at,
    updated_at
  FROM data.document_template_locales;

CREATE OR REPLACE VIEW api.signing_submissions WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    source_type,
    source_document_version_id,
    source_template_locale_id,
    result_document_version_id,
    docuseal_submission_id,
    external_id,
    status,
    status_reason,
    error_message,
    last_event_at,
    signers,
    docuseal_signing_url,
    submitted_at,
    completed_at,
    initiated_by,
    metadata,
    created_at,
    updated_at
  FROM data.signing_submissions;

CREATE OR REPLACE VIEW api.signing_events WITH (security_invoker = true) AS
  SELECT
    id,
    submission_id,
    tenant_id,
    event_type,
    event_source,
    webhook_event_id,
    signer_email,
    signer_name,
    status_before,
    status_after,
    payload,
    created_at
  FROM data.signing_events;

-- Grants api.* per authenticated
GRANT SELECT         ON api.tenant_signing_status      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_templates        TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_template_locales TO authenticated;
GRANT SELECT, INSERT, UPDATE         ON api.signing_submissions        TO authenticated;
GRANT SELECT                         ON api.signing_events             TO authenticated;

-- Grants api.* per service_role (edge functions: webhook, sign-document-router)
GRANT SELECT         ON api.tenant_signing_status      TO service_role;
GRANT SELECT         ON api.document_templates         TO service_role;
GRANT SELECT         ON api.document_template_locales  TO service_role;
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO service_role;
GRANT SELECT, INSERT         ON api.signing_events      TO service_role;


-- ============================================================================
-- 11. RPCs SECURITY DEFINER
-- ============================================================================

-- ---------------------------------------------------------------------------
-- api.create_document_template
-- Crea una nova plantilla de tenant (clone opcional de plataforma o pròpia).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_document_template(
  p_tenant_id      uuid,
  p_name           text,
  p_description    text    DEFAULT NULL,
  p_category       text    DEFAULT NULL,
  p_cloned_from_id uuid    DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_template data.document_templates%ROWTYPE;
BEGIN
  -- Validació d'accés: cal ser owner o manager global del tenant
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  -- Si és un clone, validar que la font existeix i és accessible
  IF p_cloned_from_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.document_templates src
      WHERE src.id = p_cloned_from_id
        AND (src.is_platform_default = true OR src.tenant_id = p_tenant_id)
        AND src.is_active = true
    ) THEN
      RAISE EXCEPTION 'Source template % not found or not accessible', p_cloned_from_id;
    END IF;
  END IF;

  INSERT INTO data.document_templates (
    tenant_id, name, description, category,
    is_platform_default, cloned_from_id, is_active, created_by
  ) VALUES (
    p_tenant_id, p_name, p_description, p_category,
    false, p_cloned_from_id, true, auth.uid()
  )
  RETURNING * INTO v_template;

  RETURN row_to_json(v_template);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_document_template TO authenticated;


-- ---------------------------------------------------------------------------
-- api.consume_signing_credit
-- Decrement atòmic de crèdits (mode platform). Retorna crèdits restants.
-- Cridat per l'edge function sign-document-router abans d'enviar a DocuSeal.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.consume_signing_credit(
  p_tenant_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_mode    data.signing_mode;
  v_credits integer;
BEGIN
  -- Validació d'accés: cal ser membre del tenant
  IF NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  UPDATE data.tenant_signing_config
  SET
    signing_credits = signing_credits - 1,
    updated_at      = now()
  WHERE tenant_id = p_tenant_id
    AND mode = 'platform'
    AND signing_credits > 0
  RETURNING signing_credits INTO v_credits;

  IF FOUND THEN
    PERFORM data.log_audit_event(
      p_tenant_id, auth.uid(), NULL,
      'SIGNING_CREDIT_CONSUMED', 'tenant_signing_config', p_tenant_id,
      jsonb_build_object('remaining_credits', v_credits)
    );

    RETURN v_credits;
  END IF;

  SELECT mode
  INTO v_mode
  FROM data.tenant_signing_config
  WHERE tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No signing configuration found for tenant %', p_tenant_id;
  END IF;

  IF v_mode <> 'platform' THEN
    RAISE EXCEPTION 'Tenant is in BYO mode; credit consumption does not apply';
  END IF;

  RAISE EXCEPTION 'Insufficient signing credits for tenant %', p_tenant_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.consume_signing_credit TO authenticated;
GRANT EXECUTE ON FUNCTION api.consume_signing_credit TO service_role;


-- ---------------------------------------------------------------------------
-- api.compensate_signing_credit
-- Compensació idempotent de crèdit (mode platform) quan la signatura falla.
-- Retorna TRUE si s'ha incrementat 1 crèdit; FALSE si ja s'havia compensat.
-- Cridat per l'edge function sign-document-router en errors de DocuSeal.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.compensate_signing_credit(
  p_tenant_id     uuid,
  p_submission_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_mode            data.signing_mode;
  v_submission_meta jsonb;
  v_applied         boolean := false;
BEGIN
  -- Validació d'accés: service_role o membre del tenant
  IF auth.role() <> 'service_role'
     AND NOT (data.jwt_user_tenants() ? p_tenant_id::text)
  THEN
    RAISE EXCEPTION 'Access denied for tenant %', p_tenant_id;
  END IF;

  -- Validar mode del tenant
  SELECT mode INTO v_mode
  FROM data.tenant_signing_config
  WHERE tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No signing configuration found for tenant %', p_tenant_id;
  END IF;

  IF v_mode <> 'platform' THEN
    RETURN FALSE;
  END IF;

  -- Guard idempotent atòmic: marcam la submissió només una vegada
  UPDATE data.signing_submissions
  SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
    'credit_compensated_at', now(),
    'credit_compensated_by', COALESCE(auth.uid()::text, auth.role()),
    'credit_compensated_reason', 'docuseal_error'
  ),
      updated_at = now()
  WHERE id = p_submission_id
    AND tenant_id = p_tenant_id
    AND status = 'error'
    AND COALESCE(metadata, '{}'::jsonb) ? 'credit_compensated_at' = FALSE
  RETURNING metadata INTO v_submission_meta;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  -- Compensació de crèdit (exactament una vegada si el guard anterior aplica)
  UPDATE data.tenant_signing_config
  SET signing_credits = signing_credits + 1,
      updated_at      = now()
  WHERE tenant_id = p_tenant_id
    AND mode = 'platform';

  IF FOUND THEN
    v_applied := TRUE;
    PERFORM data.log_audit_event(
      p_tenant_id, auth.uid(), NULL,
      'SIGNING_CREDIT_COMPENSATED', 'signing_submissions', p_submission_id,
      jsonb_build_object('submission_id', p_submission_id, 'reason', 'docuseal_error')
    );
  END IF;

  RETURN v_applied;
END;
$$;

GRANT EXECUTE ON FUNCTION api.compensate_signing_credit TO authenticated;
GRANT EXECUTE ON FUNCTION api.compensate_signing_credit TO service_role;


-- ---------------------------------------------------------------------------
-- api.get_docuseal_key_for_signing
-- Llegeix la clau API DocuSeal BYO de Supabase Vault.
-- SECURITY DEFINER obligatori per accedir a vault.decrypted_secrets.
-- Resultat: retorna la clau en text pla — NO emmagatzemar al client.
-- Cridat exclusivament per l'edge function sign-document-router.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_docuseal_key_for_signing(
  p_tenant_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_mode       data.signing_mode;
  v_secret_id  uuid;
  v_secret_val text;
BEGIN
  -- Validació d'accés: owner o manager (edge functions criden amb context d'usuari)
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  SELECT mode, docuseal_key_secret_id
  INTO v_mode, v_secret_id
  FROM data.tenant_signing_config
  WHERE tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No signing configuration found for tenant %', p_tenant_id;
  END IF;

  IF v_mode <> 'byo' THEN
    RAISE EXCEPTION 'Tenant is not in BYO mode; use platform key from environment';
  END IF;

  IF v_secret_id IS NULL THEN
    RAISE EXCEPTION 'No DocuSeal API key configured for tenant %', p_tenant_id;
  END IF;

  SELECT decrypted_secret
  INTO v_secret_val
  FROM vault.decrypted_secrets
  WHERE id = v_secret_id;

  IF v_secret_val IS NULL THEN
    RAISE EXCEPTION 'DocuSeal API key not found in vault for tenant %', p_tenant_id;
  END IF;

  RETURN v_secret_val;
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_docuseal_key_for_signing TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_docuseal_key_for_signing TO service_role;


-- ---------------------------------------------------------------------------
-- api.append_signing_event
-- Afegeix un event al timeline + actualitza estat de la submissió.
-- Idempotent: si webhook_event_id ja existeix, retorna l'event existent.
-- Cridat per: edge function docuseal-webhook (service_role) i sign-document-router.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.append_signing_event(
  p_submission_id    uuid,
  p_event_type       text,
  p_event_source     data.signing_event_source DEFAULT 'system',
  p_webhook_event_id text    DEFAULT NULL,
  p_signer_email     text    DEFAULT NULL,
  p_signer_name      text    DEFAULT NULL,
  p_status_before    text    DEFAULT NULL,
  p_status_after     text    DEFAULT NULL,
  p_payload          jsonb   DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_event_id  uuid;
BEGIN
  -- Obtenir tenant_id de la submissió
  SELECT tenant_id INTO v_tenant_id
  FROM data.signing_submissions
  WHERE id = p_submission_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Signing submission % not found', p_submission_id;
  END IF;

  -- Validació d'accés: service_role o membre del tenant de la submissió
  IF auth.role() <> 'service_role'
     AND NOT (data.jwt_user_tenants() ? v_tenant_id::text)
  THEN
    RAISE EXCEPTION 'Access denied for tenant %', v_tenant_id;
  END IF;

  -- Inserir event amb idempotència atòmica (evita race condition)
  INSERT INTO data.signing_events (
    submission_id, tenant_id, event_type, event_source,
    webhook_event_id, signer_email, signer_name,
    status_before, status_after, payload
  ) VALUES (
    p_submission_id, v_tenant_id, p_event_type, p_event_source,
    p_webhook_event_id, p_signer_email, p_signer_name,
    p_status_before, p_status_after, p_payload
  )
  ON CONFLICT (webhook_event_id) WHERE webhook_event_id IS NOT NULL
  DO NOTHING
  RETURNING id INTO v_event_id;

  -- Si conflicte d'idempotència, retornem l'event existent i no reprocessam l'estat
  IF v_event_id IS NULL AND p_webhook_event_id IS NOT NULL THEN
    SELECT id INTO v_event_id
    FROM data.signing_events
    WHERE webhook_event_id = p_webhook_event_id;

    RETURN v_event_id;
  END IF;

  -- Actualitzar estat de la submissió si p_status_after proporcionat
  IF p_status_after IS NOT NULL THEN
    UPDATE data.signing_submissions
    SET
      status        = p_status_after::data.signing_submission_status,
      status_reason = COALESCE(p_payload ->>'reason', status_reason),
      last_event_at = now(),
      completed_at  = CASE
        WHEN p_status_after IN ('completed', 'declined', 'expired', 'cancelled', 'error')
        THEN COALESCE(completed_at, now())
        ELSE completed_at
      END,
      updated_at    = now()
    WHERE id = p_submission_id;
  ELSE
    UPDATE data.signing_submissions
    SET last_event_at = now(), updated_at = now()
    WHERE id = p_submission_id;
  END IF;

  RETURN v_event_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.append_signing_event FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.append_signing_event FROM authenticated;
GRANT EXECUTE ON FUNCTION api.append_signing_event TO service_role;


-- ---------------------------------------------------------------------------
-- api.save_tenant_docuseal_config
-- Upsert de la configuració DocuSeal. Clau BYO → Supabase Vault.
-- Cridat des del frontend (settings de signatura) per owner/manager.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.save_tenant_docuseal_config(
  p_tenant_id uuid,
  p_mode      text,
  p_api_key   text    DEFAULT NULL,
  p_api_url   text    DEFAULT 'https://api.docuseal.eu',
  p_credits   integer DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_existing    data.tenant_signing_config%ROWTYPE;
  v_secret_id   uuid;
  v_secret_name text;
  v_secret_desc text;
BEGIN
  -- Validació d'accés: owner o manager global
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  -- Validació del mode
  IF p_mode NOT IN ('platform', 'byo') THEN
    RAISE EXCEPTION 'Invalid mode: must be ''platform'' or ''byo''';
  END IF;

  -- BYO requereix clau API
  IF p_mode = 'byo' AND (p_api_key IS NULL OR trim(p_api_key) = '') THEN
    RAISE EXCEPTION 'BYO mode requires a valid DocuSeal API key';
  END IF;

  v_secret_name := 'docuseal_' || replace(p_tenant_id::text, '-', '');
  v_secret_desc := 'DocuSeal BYO API key for tenant ' || p_tenant_id::text;

  SELECT * INTO v_existing
  FROM data.tenant_signing_config
  WHERE tenant_id = p_tenant_id;

  IF FOUND THEN
    -- Gestionar el secret vault si es BYO i s'ha proporcionat clau nova
    IF p_mode = 'byo' AND p_api_key IS NOT NULL AND trim(p_api_key) <> '' THEN
      IF v_existing.docuseal_key_secret_id IS NOT NULL THEN
        PERFORM vault.update_secret(
          v_existing.docuseal_key_secret_id,
          p_api_key,
          v_secret_name,
          v_secret_desc
        );
        v_secret_id := v_existing.docuseal_key_secret_id;
      ELSE
        v_secret_id := vault.create_secret(p_api_key, v_secret_name, v_secret_desc);
      END IF;
    ELSE
      v_secret_id := v_existing.docuseal_key_secret_id;
    END IF;

    UPDATE data.tenant_signing_config
    SET
      mode                   = p_mode::data.signing_mode,
      docuseal_key_secret_id = v_secret_id,
      docuseal_api_url       = COALESCE(p_api_url, docuseal_api_url),
      signing_credits        = CASE
                                 WHEN p_credits IS NOT NULL THEN p_credits
                                 ELSE signing_credits
                               END,
      updated_at             = now()
    WHERE tenant_id = p_tenant_id;
  ELSE
    -- Nova configuració
    IF p_mode = 'byo' THEN
      v_secret_id := vault.create_secret(p_api_key, v_secret_name, v_secret_desc);
    END IF;

    INSERT INTO data.tenant_signing_config (
      tenant_id, mode, docuseal_key_secret_id,
      docuseal_api_url, signing_credits, is_active
    ) VALUES (
      p_tenant_id, p_mode::data.signing_mode, v_secret_id,
      COALESCE(p_api_url, 'https://api.docuseal.eu'),
      COALESCE(p_credits, 0),
      true
    );
  END IF;

  PERFORM data.log_audit_event(
    p_tenant_id, auth.uid(), NULL,
    'SIGNING_CONFIG_UPDATED', 'tenant_signing_config', p_tenant_id,
    jsonb_build_object('mode', p_mode)
  );

  RETURN json_build_object(
    'tenant_id', p_tenant_id,
    'mode',      p_mode,
    'success',   true
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.save_tenant_docuseal_config TO authenticated;


-- ============================================================================
-- 12. Bucket Storage "document-templates"
--     Fitxers DOCX/PDF de les plantilles. Privat, 50 MB màxim per fitxer.
-- ============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('document-templates', 'document-templates', false, 52428800)
ON CONFLICT (id) DO NOTHING;

-- Membres del tenant poden llegir les plantilles del seu tenant
DROP POLICY IF EXISTS "document-templates bucket: tenant members can read" ON storage.objects;
CREATE POLICY "document-templates bucket: tenant members can read"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'document-templates'
    AND data.jwt_user_tenants() ? (storage.foldername(name))[1]::text
  );

-- Només owner/manager poden pujar fitxers de plantilla
DROP POLICY IF EXISTS "document-templates bucket: owner/manager can upload" ON storage.objects;
CREATE POLICY "document-templates bucket: owner/manager can upload"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'document-templates'
    AND (
      (data.jwt_user_tenants() -> (storage.foldername(name))[1]::text ->> 'global_role')
        IN ('owner', 'manager')
    )
  );

-- Owner/manager poden actualitzar fitxers (re-upload)
DROP POLICY IF EXISTS "document-templates bucket: owner/manager can update" ON storage.objects;
CREATE POLICY "document-templates bucket: owner/manager can update"
  ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'document-templates'
    AND (
      (data.jwt_user_tenants() -> (storage.foldername(name))[1]::text ->> 'global_role')
        IN ('owner', 'manager')
    )
  );

-- Owner/manager poden eliminar fitxers de plantilla
DROP POLICY IF EXISTS "document-templates bucket: owner/manager can delete" ON storage.objects;
CREATE POLICY "document-templates bucket: owner/manager can delete"
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'document-templates'
    AND (
      (data.jwt_user_tenants() -> (storage.foldername(name))[1]::text ->> 'global_role')
        IN ('owner', 'manager')
    )
  );


-- ============================================================================
-- 13. PostgREST schema cache reload
-- ============================================================================
NOTIFY pgrst, 'reload schema';
