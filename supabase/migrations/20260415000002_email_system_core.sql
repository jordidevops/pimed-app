-- =============================================================================
-- Migracio: Sistema d'Email SaaS Asincron (Core)
-- =============================================================================
--
-- SQUASH: Incorpora les funcionalitats de les migracions patch:
--   • 20260417000001_email_templates_events_layouts.sql
--       – Plantilles de layout/wrapper, cerca per event_type i slug,
--         plantilles de plataforma (is_platform_default), XOR estricte,
--         RLS endurit, validació de layout_id.
--   • 20260421000001_enqueue_email_sender_profile.sql
--       – Suport per sender_profile_id a api.enqueue_email().
--   • 20260421000002_from_name_validation.sql
--       – NULLIF(BTRIM(v_from_name), '') a enqueue_email,
--         nova funció api.get_platform_email_defaults().
--
-- ARQUITECTURA (Egress Rate Limiting):
--   Frontend -> api.enqueue_email() RPC -> email_logs (queued) + pgmq
--   Worker   -> pgmq.read() lotes -> CHECK RATE LIMITS -> Provider -> status update
--   Webhook  -> Provider callback -> api.process_email_webhook() -> status update
--
--   La ingesta es rapida i sense bloquejos: la funcio enqueue_email valida
--   tenant, domini i idempotencia, pero NO frena per rate limits.
--   El Worker (dissenyat per separat) verifica els rate_limit_per_hour/day
--   de email_configs i aplica visibility timeout a pgmq si el tenant va
--   superar la seva quota (egress throttling).
--
-- PRINCIPIS:
--   1. Idempotencia estricta: UNIQUE(tenant_id, idempotency_key) en email_logs
--   2. Maquina d'estats segura: trigger valida transicions
--   3. Concurrencia: locked_at + attempt_count + next_retry_at
--   4. Feedback loop: index unic parcial en provider_message_id
--   5. Control d'insercio: frontend NO insereix directament a email_logs
--   6. Validacio de domini: from_email vs email_domains verificats + fallback plataforma
--   7. Retencio: index en created_at per purga via pg_cron
--   8. Rate limits: camps a email_configs, enforcement al Worker (no a SQL)
--
-- ACTORS:
--   • authenticated: enqueue (via RPC) + SELECT propi historial (RLS)
--   • service_role:  worker + webhooks (mou estats)
--   • prisma_admin:  BYPASSRLS (backoffice admin-portal)
-- =============================================================================


-- ============================================================================
-- 0. ENUMS
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE data.email_status AS ENUM (
    'queued',      -- encuat, esperant worker
    'processing',  -- worker l'ha agafat, enviant
    'sent',        -- provider ha acceptat el missatge
    'delivered',   -- webhook confirma entrega
    'bounced',     -- webhook confirma rebot
    'failed',      -- error definitiu o temporal (mirar attempt_count)
    'complained',  -- l'usuari ha marcat com a spam (Resend complaint)
    'suppressed'   -- adreca suprimida pel proveïdor
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Assegura retrocompatibilitat si la BD ja existia sense els nous valors
ALTER TYPE data.email_status ADD VALUE IF NOT EXISTS 'complained';
ALTER TYPE data.email_status ADD VALUE IF NOT EXISTS 'suppressed';

DO $$ BEGIN
  CREATE TYPE data.email_type AS ENUM ('transactional', 'bulk');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE data.email_provider AS ENUM ('resend', 'sendgrid');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE data.domain_verification_status AS ENUM ('pending', 'verified', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


-- ============================================================================
-- 1. email_configs — Configuracio d'email per tenant (1:1)
-- ============================================================================

CREATE TABLE IF NOT EXISTS data.email_configs (
  tenant_id           uuid        PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  default_provider    data.email_provider NOT NULL DEFAULT 'resend',
  -- default_from_email eliminat: el domini ha d'estar verificat, usar email_domains.default_from_email
  default_from_name   text,                                 -- p.ex. "La Meva Empresa" (fallback si no configurat al domini)
  default_reply_to    text,                                 -- p.ex. support@empresa.cat (fallback si no configurat al domini)
  default_layout_id   uuid,                                 -- layout per defecte del tenant (FK resolem despres)
  layout_variables    jsonb,                                -- {"logo_url": "...", "footer_text": "..."} — injectat a tots els layouts
  rate_limit_per_hour integer     NOT NULL DEFAULT 100,
  rate_limit_per_day  integer     NOT NULL DEFAULT 1000,
  max_retries         integer     NOT NULL DEFAULT 3        CHECK (max_retries BETWEEN 0 AND 10),
  retention_days      integer     NOT NULL DEFAULT 90       CHECK (retention_days >= 1),
  metadata            jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);


-- ============================================================================
-- 2. email_domains — Dominis verificats per tenant
-- ============================================================================

CREATE TABLE IF NOT EXISTS data.email_domains (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  domain                text        NOT NULL,               -- p.ex. "empresa.cat"
  verification_status   data.domain_verification_status NOT NULL DEFAULT 'pending',
  dns_records           jsonb,                              -- registres DNS requerits (TXT, CNAME, etc.)
  provider_domain_id    text,                               -- ID del domini al provider (Resend/Sendgrid)
  verified_at           timestamptz,
  -- Camps de remitent per defecte d'aquest domini
  is_primary            boolean     NOT NULL DEFAULT false, -- domini principal del tenant (UNIQUE WHERE is_primary)
  default_from_email    text,                               -- p.ex. noreply@empresa.cat (ha de pertanyer a aquest domini)
  default_from_name     text,                               -- p.ex. "La Meva Empresa"
  default_reply_to      text,                               -- p.ex. support@empresa.cat
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, domain),
  -- Validacio: default_from_email ha de pertanyer al domini
  CONSTRAINT chk_domain_from_email CHECK (
    default_from_email IS NULL OR
    split_part(default_from_email, '@', 2) = domain
  )
);

-- Unicitat: un sol domini primary per tenant
CREATE UNIQUE INDEX IF NOT EXISTS idx_email_domains_primary
  ON data.email_domains (tenant_id)
  WHERE is_primary = true;

CREATE INDEX IF NOT EXISTS idx_email_domains_tenant
  ON data.email_domains (tenant_id);


-- ============================================================================
-- 3. email_templates — Plantilles d'email per tenant i de plataforma
-- ============================================================================
--
-- Dues classes de plantilles:
--   • Tenant:    tenant_id NOT NULL, is_platform_default = false
--   • Plataforma: tenant_id NULL,    is_platform_default = true
-- XOR estricte garantit per chk_template_owner.
--
-- Tipus de plantilla:
--   • is_layout = false: plantilla de contingut (la que rep el client)
--   • is_layout = true:  wrapper HTML que embolcalla el contingut via {{content}}
--
-- Resolucio de layout per api.enqueue_email():
--   template.layout_id → email_configs.default_layout_id → NULL (sense layout)
-- ============================================================================

CREATE TABLE IF NOT EXISTS data.email_templates (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        REFERENCES data.tenants(id) ON DELETE CASCADE,  -- NULL si is_platform_default
  name                text        NOT NULL,                 -- nom intern descriptiu
  slug                text        NOT NULL,                 -- referencia per API (p.ex. "welcome-email")
  event_type          text,                                 -- tipus d'event logic (p.ex. "user.registered")
  subject_template    text        NOT NULL,                 -- "Benvingut/da, {{name}}!"
  html_body_template  text,                                 -- cos HTML amb {{variables}}
  text_body_template  text,                                 -- cos text pla amb {{variables}}
  variables_schema    jsonb,                                -- esquema esperat: {"name": "string", "link": "string"}
  is_platform_default boolean     NOT NULL DEFAULT false,   -- true: plantilla global de la plataforma
  is_layout           boolean     NOT NULL DEFAULT false,   -- true: aquest template ES un layout (wrapper)
  layout_id           uuid        REFERENCES data.email_templates(id) ON DELETE SET NULL, -- layout que usa
  use_layout          boolean     NOT NULL DEFAULT true,    -- false: envia sense layout encara que n'hi hagi un
  is_active           boolean     NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  -- XOR estricte: plantilla de tenant XOR plantilla de plataforma
  CONSTRAINT chk_template_owner CHECK (
    (tenant_id IS NOT NULL AND is_platform_default = false)
    OR
    (tenant_id IS NULL AND is_platform_default = true)
  )
);

-- Index general per tenant (FK lookup)
CREATE INDEX IF NOT EXISTS idx_email_templates_tenant
  ON data.email_templates (tenant_id);

-- Index unic per slug dins d'un tenant (substitueix UNIQUE(tenant_id, slug)
-- que no funciona correctament amb NULLs a PostgreSQL)
CREATE UNIQUE INDEX IF NOT EXISTS idx_email_templates_tenant_slug
  ON data.email_templates (tenant_id, slug)
  WHERE tenant_id IS NOT NULL;

-- Index unic per slug de les plantilles de plataforma
CREATE UNIQUE INDEX IF NOT EXISTS idx_email_templates_platform_slug
  ON data.email_templates (slug)
  WHERE is_platform_default = true;

-- Un sol template de contingut actiu per (tenant, event_type)
CREATE UNIQUE INDEX IF NOT EXISTS idx_email_templates_tenant_event_type
  ON data.email_templates (tenant_id, event_type)
  WHERE event_type IS NOT NULL
    AND tenant_id  IS NOT NULL
    AND is_layout   = false
    AND is_active   = true;

-- Un sol template de plataforma actiu per event_type
CREATE UNIQUE INDEX IF NOT EXISTS idx_email_templates_platform_event_type
  ON data.email_templates (event_type)
  WHERE event_type        IS NOT NULL
    AND is_platform_default = true
    AND is_layout           = false
    AND is_active           = true;


-- ============================================================================
-- 4. email_logs — Cicle de vida complet del correu
-- ============================================================================
--
-- Regles:
--   • UNIQUE(tenant_id, idempotency_key) -> impedeix duplicats
--   • Estat gestionat EXCLUSIVAMENT per worker/webhooks (service_role)
--   • Frontend nomes pot SELECT (via RLS)
--   • Trigger valida transicions d'estat
-- ============================================================================

CREATE TABLE IF NOT EXISTS data.email_logs (
  id                    uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid              NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id               uuid,
  idempotency_key       text              NOT NULL,

  -- Estat
  status                data.email_status NOT NULL DEFAULT 'queued',
  email_type            data.email_type   NOT NULL DEFAULT 'transactional',
  priority              integer           NOT NULL DEFAULT 0,  -- 0 = normal, valors alts = mes prioritat

  -- Remitent / Destinataris
  from_email            text              NOT NULL,
  from_name             text,
  to_emails             text[]            NOT NULL,
  cc_emails             text[],
  bcc_emails            text[],
  reply_to              text,

  -- Contingut (resolt pel worker si es template-based)
  template_id           uuid              REFERENCES data.email_templates(id) ON DELETE SET NULL,
  template_variables    jsonb,
  subject               text,                                 -- resolt despres de processar template
  html_body             text,
  text_body             text,

  -- Layout (resolt per api.enqueue_email; renderitzat pel Worker)
  layout_id             uuid              REFERENCES data.email_templates(id) ON DELETE SET NULL,

  -- Adjunts (referencia a storage)
  attachments           jsonb,                                -- [{"filename": "...", "storage_path": "..."}]

  -- Provider
  provider              data.email_provider,
  provider_message_id   text,                                 -- ID retornat pel provider (Resend/Sendgrid)

  -- Concurrencia i Retries
  attempt_count         integer           NOT NULL DEFAULT 0,
  max_retries           integer           NOT NULL DEFAULT 3,
  locked_at             timestamptz,                          -- lock del worker (seguretat extra sobre pgmq VT)
  locked_by             text,                                 -- identificador del worker instance
  next_retry_at         timestamptz,

  -- Dead Letter Queue
  is_dead_letter        boolean           NOT NULL DEFAULT false,

  -- Errors
  last_error            text,
  error_history         jsonb             DEFAULT '[]'::jsonb, -- [{"at": "...", "error": "...", "attempt": N}]

  -- Metadades
  metadata              jsonb,
  tags                  text[],
  scheduled_at          timestamptz,                          -- envio programat (NULL = immediat)

  -- Timestamps
  created_at            timestamptz       NOT NULL DEFAULT now(),
  updated_at            timestamptz       NOT NULL DEFAULT now(),
  sent_at               timestamptz,
  delivered_at          timestamptz,

  -- Constraints
  CONSTRAINT uq_email_logs_idempotency UNIQUE (tenant_id, idempotency_key),
  CONSTRAINT chk_email_content CHECK (
    template_id IS NOT NULL OR subject IS NOT NULL
  )
);

-- Index parcial unic per provider_message_id (feedback loop)
CREATE UNIQUE INDEX IF NOT EXISTS idx_email_logs_provider_msg_id
  ON data.email_logs (provider_message_id)
  WHERE provider_message_id IS NOT NULL;

-- Index per retencio (purga via pg_cron)
CREATE INDEX IF NOT EXISTS idx_email_logs_created_at
  ON data.email_logs (created_at);

-- Index per worker: trobar missatges pendents de reintent
CREATE INDEX IF NOT EXISTS idx_email_logs_pending_retry
  ON data.email_logs (next_retry_at)
  WHERE status IN ('queued', 'failed') AND is_dead_letter = false;

-- Index per tenant + status (historial filtrat al frontend)
CREATE INDEX IF NOT EXISTS idx_email_logs_tenant_status
  ON data.email_logs (tenant_id, status, created_at DESC);

-- Index per tenant (FK lookup)
CREATE INDEX IF NOT EXISTS idx_email_logs_tenant
  ON data.email_logs (tenant_id);

-- ---------------------------------------------------------------------------
-- FK diferides: email_configs.default_layout_id → email_templates(id)
-- (no es pot declarar inline perque email_templates es crea despres de
-- email_configs; la referencia circular layout_id a email_templates.id
-- ja esta dins la mateixa taula i funciona perque es la mateixa taula)
-- ---------------------------------------------------------------------------
ALTER TABLE data.email_configs
  ADD CONSTRAINT fk_email_configs_default_layout_id
    FOREIGN KEY (default_layout_id)
    REFERENCES data.email_templates(id)
    ON DELETE SET NULL;


-- ============================================================================
-- 5. AUTO-UPDATE updated_at TRIGGERS
-- ============================================================================

CREATE OR REPLACE FUNCTION data.touch_email_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_email_configs_updated_at
  BEFORE UPDATE ON data.email_configs
  FOR EACH ROW EXECUTE FUNCTION data.touch_email_updated_at();

CREATE TRIGGER trg_email_domains_updated_at
  BEFORE UPDATE ON data.email_domains
  FOR EACH ROW EXECUTE FUNCTION data.touch_email_updated_at();

CREATE TRIGGER trg_email_templates_updated_at
  BEFORE UPDATE ON data.email_templates
  FOR EACH ROW EXECUTE FUNCTION data.touch_email_updated_at();

CREATE TRIGGER trg_email_logs_updated_at
  BEFORE UPDATE ON data.email_logs
  FOR EACH ROW EXECUTE FUNCTION data.touch_email_updated_at();


-- ============================================================================
-- 6. MAQUINA D'ESTATS — Trigger de transicions valides
-- ============================================================================
--
-- Transicions permeses:
--   queued      -> processing
--   processing  -> sent, failed
--   sent        -> delivered, bounced
--   failed      -> queued      (retry — nomes si attempt_count < max_retries)
--   sent        -> complained   (Resend complaint webhook)
--   sent        -> suppressed   (adreca suprimida pel proveïdor)
--
-- Estats terminals: delivered, bounced, failed (is_dead_letter=true), complained, suppressed
-- ============================================================================

CREATE OR REPLACE FUNCTION data.enforce_email_status_transition()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Si l'estat no canvia, permetre (actualitzacio d'altres camps)
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- Validar transicions
  CASE OLD.status::text
    WHEN 'queued' THEN
      IF NEW.status::text NOT IN ('processing') THEN
        RAISE EXCEPTION 'Transicio d''estat invalida: % -> %', OLD.status, NEW.status;
      END IF;

    WHEN 'processing' THEN
      IF NEW.status::text NOT IN ('sent', 'failed') THEN
        RAISE EXCEPTION 'Transicio d''estat invalida: % -> %', OLD.status, NEW.status;
      END IF;

    WHEN 'sent' THEN
      IF NEW.status::text NOT IN ('delivered', 'bounced', 'complained', 'suppressed') THEN
        RAISE EXCEPTION 'Transicio d''estat invalida: % -> %', OLD.status, NEW.status;
      END IF;

    WHEN 'failed' THEN
      -- Retry: failed -> queued nomes si NO es dead letter i hi ha intents restants
      IF NEW.status::text = 'queued' AND OLD.is_dead_letter = false AND OLD.attempt_count < OLD.max_retries THEN
        -- OK, permetre retry
        NULL;
      ELSE
        RAISE EXCEPTION 'Transicio d''estat invalida: % -> % (dead_letter=%, attempts=%/%)',
          OLD.status, NEW.status, OLD.is_dead_letter, OLD.attempt_count, OLD.max_retries;
      END IF;

    WHEN 'delivered' THEN
      -- Cas especial: un correu lliurat pot rebre una queixa de spam posterior
      IF NEW.status::text = 'complained' THEN
        NULL; -- permetre delivered -> complained
      ELSE
        RAISE EXCEPTION 'Estat terminal: no es pot canviar des de "delivered" excepte a "complained"';
      END IF;

    WHEN 'bounced' THEN
      RAISE EXCEPTION 'Estat terminal: no es pot canviar des de "bounced"';

    WHEN 'complained' THEN
      RAISE EXCEPTION 'Estat terminal: no es pot canviar des de "complained"';

    WHEN 'suppressed' THEN
      RAISE EXCEPTION 'Estat terminal: no es pot canviar des de "suppressed"';

    ELSE
      RAISE EXCEPTION 'Estat desconegut: %', OLD.status;
  END CASE;

  -- Auto-set timestamps per transicions especifiques
  IF NEW.status = 'sent' THEN
    NEW.sent_at = COALESCE(NEW.sent_at, now());
    NEW.locked_at = NULL;
    NEW.locked_by = NULL;
  ELSIF NEW.status = 'delivered' THEN
    NEW.delivered_at = COALESCE(NEW.delivered_at, now());
  ELSIF NEW.status = 'processing' THEN
    NEW.locked_at = COALESCE(NEW.locked_at, now());
  ELSIF NEW.status = 'queued' AND OLD.status = 'failed' THEN
    -- Retry: netejar lock
    NEW.locked_at = NULL;
    NEW.locked_by = NULL;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_email_logs_status_transition
  BEFORE UPDATE ON data.email_logs
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION data.enforce_email_status_transition();


-- ============================================================================
-- 7. TRIGGERS DE VALIDACIÓ DE LAYOUT
-- ============================================================================

-- ---------------------------------------------------------------------------
-- data.validate_email_template_layout_id()
--
-- Garanteix que layout_id d'un template apunta a un template is_layout = true,
-- i que la visibilitat és correcta (tenant pot usar layouts del seu tenant
-- o de plataforma; plataforma nomes layouts de plataforma).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.validate_email_template_layout_id()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_layout data.email_templates%ROWTYPE;
BEGIN
  IF NEW.layout_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_layout
  FROM data.email_templates
  WHERE id = NEW.layout_id;

  IF v_layout.id IS NULL THEN
    RAISE EXCEPTION 'layout_id % no existeix', NEW.layout_id;
  END IF;

  IF v_layout.is_layout IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'layout_id % no apunta a una plantilla de layout', NEW.layout_id;
  END IF;

  -- Un template de tenant pot usar layout del mateix tenant o de plataforma.
  IF NEW.tenant_id IS NOT NULL THEN
    IF NOT (v_layout.tenant_id = NEW.tenant_id OR v_layout.is_platform_default = true) THEN
      RAISE EXCEPTION 'layout_id % no es accessible per aquest tenant', NEW.layout_id;
    END IF;
  END IF;

  -- Un template de plataforma nomes pot apuntar a layout de plataforma.
  IF NEW.is_platform_default = true THEN
    IF v_layout.is_platform_default IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'Les plantilles de plataforma nomes poden usar layouts de plataforma';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_email_template_layout_id ON data.email_templates;
CREATE TRIGGER trg_validate_email_template_layout_id
  BEFORE INSERT OR UPDATE OF layout_id, tenant_id, is_platform_default
  ON data.email_templates
  FOR EACH ROW
  EXECUTE FUNCTION data.validate_email_template_layout_id();

-- ---------------------------------------------------------------------------
-- data.validate_email_config_default_layout_id()
--
-- Garanteix que default_layout_id d'email_configs apunta a un layout
-- accessible pel tenant (del seu tenant o de plataforma).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.validate_email_config_default_layout_id()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_layout data.email_templates%ROWTYPE;
BEGIN
  IF NEW.default_layout_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_layout
  FROM data.email_templates
  WHERE id = NEW.default_layout_id;

  IF v_layout.id IS NULL THEN
    RAISE EXCEPTION 'default_layout_id % no existeix', NEW.default_layout_id;
  END IF;

  IF v_layout.is_layout IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'default_layout_id % no es un layout', NEW.default_layout_id;
  END IF;

  -- El tenant pot usar layout del mateix tenant o de plataforma.
  IF NOT (v_layout.tenant_id = NEW.tenant_id OR v_layout.is_platform_default = true) THEN
    RAISE EXCEPTION 'default_layout_id % no es accessible per al tenant %',
      NEW.default_layout_id, NEW.tenant_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_email_config_default_layout_id ON data.email_configs;
CREATE TRIGGER trg_validate_email_config_default_layout_id
  BEFORE INSERT OR UPDATE OF default_layout_id
  ON data.email_configs
  FOR EACH ROW
  EXECUTE FUNCTION data.validate_email_config_default_layout_id();


-- ============================================================================
-- 8. ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE data.email_configs   ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.email_domains   ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.email_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.email_logs      ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- email_configs — owner/manager pot gestionar, tots els membres poden llegir
-- ---------------------------------------------------------------------------

CREATE POLICY "email_configs: lectura per membres"
  ON data.email_configs FOR SELECT TO authenticated
  USING (tenant_id = ANY(data.my_tenant_ids()));

CREATE POLICY "email_configs: escriptura per owner/manager"
  ON data.email_configs FOR INSERT TO authenticated
  WITH CHECK (data.my_role_in(tenant_id) IN ('owner', 'manager'));

CREATE POLICY "email_configs: actualitzacio per owner/manager"
  ON data.email_configs FOR UPDATE TO authenticated
  USING      (data.my_role_in(tenant_id) IN ('owner', 'manager'))
  WITH CHECK (data.my_role_in(tenant_id) IN ('owner', 'manager'));

CREATE POLICY "email_configs: service_role full access"
  ON data.email_configs FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- email_domains — owner/manager pot gestionar, tots els membres poden llegir
-- ---------------------------------------------------------------------------

CREATE POLICY "email_domains: lectura per membres"
  ON data.email_domains FOR SELECT TO authenticated
  USING (tenant_id = ANY(data.my_tenant_ids()));

CREATE POLICY "email_domains: insercio per owner/manager"
  ON data.email_domains FOR INSERT TO authenticated
  WITH CHECK (data.my_role_in(tenant_id) IN ('owner', 'manager'));

CREATE POLICY "email_domains: actualitzacio per owner/manager"
  ON data.email_domains FOR UPDATE TO authenticated
  USING      (data.my_role_in(tenant_id) IN ('owner', 'manager'))
  WITH CHECK (data.my_role_in(tenant_id) IN ('owner', 'manager'));

CREATE POLICY "email_domains: eliminacio per owner/manager"
  ON data.email_domains FOR DELETE TO authenticated
  USING (data.my_role_in(tenant_id) IN ('owner', 'manager'));

CREATE POLICY "email_domains: service_role full access"
  ON data.email_domains FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- email_templates — RLS endurit:
--   lectura: tenant propi + plantilles de plataforma (fallback global)
--   inserció/actualització: només tenant propi amb is_platform_default = false
--   (cap autenticat pot crear plantilles de plataforma; cal service_role/prisma_admin)
-- ---------------------------------------------------------------------------

CREATE POLICY "email_templates: lectura per membres"
  ON data.email_templates FOR SELECT TO authenticated
  USING (
    (tenant_id IS NOT NULL AND data.my_role_in(tenant_id) IS NOT NULL)
    OR
    (is_platform_default = true)
  );

CREATE POLICY "email_templates: insercio per owner/manager"
  ON data.email_templates FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id IS NOT NULL
    AND is_platform_default = false
    AND data.my_role_in(tenant_id) IN ('owner', 'manager')
  );

CREATE POLICY "email_templates: actualitzacio per owner/manager"
  ON data.email_templates FOR UPDATE TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND is_platform_default = false
    AND data.my_role_in(tenant_id) IN ('owner', 'manager')
  )
  WITH CHECK (
    tenant_id IS NOT NULL
    AND is_platform_default = false
    AND data.my_role_in(tenant_id) IN ('owner', 'manager')
  );

CREATE POLICY "email_templates: eliminacio per owner/manager"
  ON data.email_templates FOR DELETE TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND is_platform_default = false
    AND data.my_role_in(tenant_id) IN ('owner', 'manager')
  );

CREATE POLICY "email_templates: service_role full access"
  ON data.email_templates FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- email_logs — NOMES lectura per membres. Escriptura EXCLUSIVA per service_role.
-- El frontend NO insereix directament: ho fa api.enqueue_email() (SECURITY DEFINER).
-- ---------------------------------------------------------------------------

CREATE POLICY "email_logs: lectura per membres"
  ON data.email_logs FOR SELECT TO authenticated
  USING (
    tenant_id = ANY(data.my_tenant_ids())
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- Cap politica INSERT/UPDATE/DELETE per authenticated -> bloquejat per defecte

CREATE POLICY "email_logs: service_role full access"
  ON data.email_logs FOR ALL TO service_role
  USING (true) WITH CHECK (true);


-- ============================================================================
-- 9. GRANTS (capa de permisos a nivell de taula, complementa RLS)
-- ============================================================================

GRANT SELECT, INSERT, UPDATE
  ON data.email_configs TO authenticated;
GRANT ALL ON data.email_configs TO service_role, prisma_admin;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON data.email_domains TO authenticated;
GRANT ALL ON data.email_domains TO service_role, prisma_admin;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON data.email_templates TO authenticated;
GRANT ALL ON data.email_templates TO service_role, prisma_admin;

-- email_logs: authenticated NOMES pot SELECT (l'INSERT es fa via SECURITY DEFINER RPC)
GRANT SELECT
  ON data.email_logs TO authenticated;
GRANT ALL ON data.email_logs TO service_role, prisma_admin;


-- ============================================================================
-- 9. CUA PGMQ
-- ============================================================================

SELECT pgmq.create('email_send_queue');


-- ============================================================================
-- 10. RPCs — Funcions exposades a l'schema api
-- ============================================================================

-- ---------------------------------------------------------------------------
-- api.enqueue_email(payload jsonb) -> uuid
--
-- Punt d'entrada UNIC del frontend per enviar emails.
-- Funcionalitats:
--   • Resolucio del remitent: cascada Payload > Sender Profile > Domini > Configs > Plataforma
--   • Resolucio de plantilla: event_type → template_slug → template_id (UUID) → inline
--   • Resolucio de layout: template.layout_id → config.default_layout_id → NULL
--   • Idempotencia: ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
--   • Encua a pgmq amb delay si scheduled_at es al futur
--
-- El frontend crida:
--   supabase.rpc('enqueue_email', { payload: { ... } })
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.enqueue_email(payload jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id          uuid;
  v_site_id            uuid;
  v_role               text;
  v_idempotency_key    text;
  v_email_type         data.email_type;
  v_from_email         text;
  v_from_name          text;
  v_to_emails          text[];
  v_template_id        uuid;
  v_template_slug      text;
  v_event_type         text;
  v_template_row       data.email_templates%ROWTYPE;
  v_layout_id          uuid;
  v_subject            text;
  v_log_id             uuid;
  v_domain             text;
  v_config             data.email_configs%ROWTYPE;
  v_domain_config      data.email_domains%ROWTYPE;
  v_primary_domain     data.email_domains%ROWTYPE;
  v_priority           integer;
  v_scheduled_at       timestamptz;
  v_delay_seconds      integer;
  v_reply_to           text;
  v_platform_settings  jsonb;
  v_platform_domain    text;
  -- Sender Profile
  v_sender_profile_id  text;
  v_profile_from_name  text;
  v_profile_reply_to   text;
BEGIN
  -- ── Extreure parametres ──
  v_tenant_id           := (payload ->> 'tenant_id')::uuid;
  v_site_id             := (payload ->> 'site_id')::uuid;
  v_idempotency_key     := payload ->> 'idempotency_key';
  v_from_email          := payload ->> 'from_email';
  v_to_emails           := ARRAY(SELECT jsonb_array_elements_text(payload -> 'to'));
  v_email_type          := COALESCE((payload ->> 'email_type')::data.email_type, 'transactional');
  v_priority            := COALESCE((payload ->> 'priority')::integer, 0);
  v_scheduled_at        := (payload ->> 'scheduled_at')::timestamptz;
  v_sender_profile_id   := payload ->> 'sender_profile_id';

  -- Validacio basica
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_id es obligatori';
  END IF;
  IF v_idempotency_key IS NULL OR v_idempotency_key = '' THEN
    RAISE EXCEPTION 'idempotency_key es obligatori';
  END IF;
  IF v_to_emails IS NULL OR array_length(v_to_emails, 1) IS NULL THEN
    RAISE EXCEPTION 'cal indicar almenys un destinatari a "to"';
  END IF;

  -- ── Validar membresia del tenant ──
  -- Aquest bypass és per a "System automations & Admin scripts"
  IF auth.role() = 'service_role' THEN
    v_role := 'admin';
  ELSE
    v_role := data.my_role_in(v_tenant_id);
  END IF;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'No tens acces al tenant %', v_tenant_id;
  END IF;
  IF v_role = 'viewer' THEN
    RAISE EXCEPTION 'El rol "viewer" no pot enviar emails';
  END IF;

  -- ── Carregar configuracio del tenant ──
  SELECT * INTO v_config FROM data.email_configs WHERE tenant_id = v_tenant_id;

  -- ── Resoldre Sender Profile (si n'hi ha) ──
  -- Busca dins metadata->'sender_profiles' el perfil amb l'id indicat.
  -- Les variables v_profile_from_name i v_profile_reply_to s'usaran als COALESCE
  -- de les branques A2 i B2 (entre el payload i el domini).
  IF v_sender_profile_id IS NOT NULL AND v_config.metadata IS NOT NULL
     AND jsonb_typeof(v_config.metadata -> 'sender_profiles') = 'array' THEN
    SELECT
      elem ->> 'from_name',
      elem ->> 'reply_to'
    INTO v_profile_from_name, v_profile_reply_to
    FROM jsonb_array_elements(v_config.metadata -> 'sender_profiles') AS elem
    WHERE elem ->> 'id' = v_sender_profile_id
    LIMIT 1;
  END IF;

  -- ── Llegir configuracio de plataforma (fallback final) ──
  SELECT settings INTO v_platform_settings
  FROM data.system_settings WHERE module = 'email';
  v_platform_domain := v_platform_settings ->> 'platform_default_domain';

  -- ════════════════════════════════════════════════════════════════════════
  -- CASCADA DE RESOLUCIO DEL REMITENT
  --
  -- from_name i reply_to segueixen:
  --   Payload > Sender Profile > Default del Domini > email_configs > Plataforma
  --
  -- BRANCA A: from_email NO ve al payload
  --   A1. Sense dominis verificats → plataforma
  --   A2. Amb domini primary verificat → usar-lo
  --
  -- BRANCA B: from_email VE al payload
  --   B1. Domini NO verificat → plataforma
  --   B2. Domini verificat → cascada completa
  -- ════════════════════════════════════════════════════════════════════════

  IF v_from_email IS NULL THEN
    -- ── BRANCA A: sense from_email al payload ──
    SELECT * INTO v_primary_domain
    FROM data.email_domains
    WHERE tenant_id = v_tenant_id
      AND is_primary = true
      AND verification_status = 'verified'
    LIMIT 1;

    IF v_primary_domain IS NULL THEN
      -- A1: sense dominis verificats → plataforma
      IF v_platform_domain IS NULL OR v_platform_domain = '' THEN
        RAISE EXCEPTION
          'El tenant no te dominis verificats i no hi ha domini de plataforma configurat. '
          'Configureu platform_default_domain a system_settings.';
      END IF;
      v_from_email := COALESCE(
        v_platform_settings ->> 'platform_default_from_email',
        'noreply@' || v_platform_domain
      );
      v_from_name := COALESCE(
        payload ->> 'from_name',
        v_profile_from_name,
        v_config.default_from_name,
        v_platform_settings ->> 'platform_default_from_name'
      );
      v_reply_to := COALESCE(
        payload ->> 'reply_to',
        v_profile_reply_to,
        v_config.default_reply_to
      );

    ELSE
      -- A2: te domini primary verificat
      v_from_email := COALESCE(
        v_primary_domain.default_from_email,
        'noreply@' || v_primary_domain.domain
      );
      v_from_name := COALESCE(
        payload ->> 'from_name',
        v_profile_from_name,
        v_primary_domain.default_from_name,
        v_config.default_from_name,
        v_platform_settings ->> 'platform_default_from_name'
      );
      v_reply_to := COALESCE(
        payload ->> 'reply_to',
        v_profile_reply_to,
        v_primary_domain.default_reply_to,
        v_config.default_reply_to
      );
    END IF;

  ELSE
    -- ── BRANCA B: from_email ve al payload ──
    v_domain := split_part(v_from_email, '@', 2);

    SELECT * INTO v_domain_config
    FROM data.email_domains
    WHERE tenant_id = v_tenant_id
      AND domain = v_domain
      AND verification_status = 'verified'
    LIMIT 1;

    IF v_domain_config IS NULL THEN
      -- B1: domini NO verificat → plataforma
      IF v_platform_domain IS NULL OR v_platform_domain = '' THEN
        RAISE EXCEPTION
          'El domini "%" no esta verificat per al tenant i no hi ha domini de plataforma configurat. '
          'Verifiqueu el domini a email_domains o configureu platform_default_domain a system_settings.',
          v_domain;
      END IF;
      v_from_email := COALESCE(
        v_platform_settings ->> 'platform_default_from_email',
        'noreply@' || v_platform_domain
      );
      v_from_name := COALESCE(
        payload ->> 'from_name',
        v_profile_from_name,
        v_config.default_from_name,
        v_platform_settings ->> 'platform_default_from_name'
      );
      v_reply_to := COALESCE(
        payload ->> 'reply_to',
        v_profile_reply_to,
        v_config.default_reply_to
      );

    ELSE
      -- B2: domini verificat → cascada completa
      v_from_name := COALESCE(
        payload ->> 'from_name',
        v_profile_from_name,
        v_domain_config.default_from_name,
        v_config.default_from_name,
        v_platform_settings ->> 'platform_default_from_name'
      );
      v_reply_to := COALESCE(
        payload ->> 'reply_to',
        v_profile_reply_to,
        v_domain_config.default_reply_to,
        v_config.default_reply_to
      );
    END IF;
  END IF;

  -- ── Netejar espais en blanc: " <email>" seria invàlid per Resend ──
  v_from_name := NULLIF(BTRIM(v_from_name), '');

  -- ── NOTA: Rate Limits NO es comproven aqui. ──
  -- Els camps rate_limit_per_hour/day d'email_configs son llegits pel Worker
  -- (egress throttling). La ingesta accepta correus a maxima velocitat.

  -- ════════════════════════════════════════════════════════════════════════
  -- RESOLUCIO DE LA PLANTILLA
  -- Prioritat: event_type → template_slug → template_id (UUID) → inline
  -- En cada cas: plantilla del tenant → fallback a plataforma si n'hi ha.
  -- ════════════════════════════════════════════════════════════════════════

  v_template_id   := (payload ->> 'template_id')::uuid;
  v_template_slug := payload ->> 'template_slug';
  v_event_type    := payload ->> 'event_type';
  v_subject       := payload ->> 'subject';

  -- 1. Cerca per event_type
  IF v_event_type IS NOT NULL AND v_template_id IS NULL THEN
    SELECT * INTO v_template_row
    FROM data.email_templates
    WHERE tenant_id  = v_tenant_id
      AND event_type = v_event_type
      AND is_layout  = false
      AND is_active  = true
    LIMIT 1;

    IF v_template_row.id IS NULL THEN
      SELECT * INTO v_template_row
      FROM data.email_templates
      WHERE is_platform_default = true
        AND event_type = v_event_type
        AND is_layout  = false
        AND is_active  = true
      LIMIT 1;
    END IF;

    IF v_template_row.id IS NOT NULL THEN
      v_template_id := v_template_row.id;
    END IF;
  END IF;

  -- 2. Cerca per slug
  IF v_template_slug IS NOT NULL AND v_template_id IS NULL THEN
    SELECT * INTO v_template_row
    FROM data.email_templates
    WHERE tenant_id = v_tenant_id
      AND slug      = v_template_slug
      AND is_layout = false
      AND is_active = true
    LIMIT 1;

    IF v_template_row.id IS NULL THEN
      SELECT * INTO v_template_row
      FROM data.email_templates
      WHERE is_platform_default = true
        AND slug      = v_template_slug
        AND is_layout = false
        AND is_active = true
      LIMIT 1;
    END IF;

    IF v_template_row.id IS NOT NULL THEN
      v_template_id := v_template_row.id;
    END IF;
  END IF;

  -- 3. Cerca per template_id (UUID directe)
  IF v_template_id IS NOT NULL AND v_template_row.id IS NULL THEN
    SELECT * INTO v_template_row
    FROM data.email_templates
    WHERE id = v_template_id
      AND (tenant_id = v_tenant_id OR is_platform_default = true)
      AND is_layout = false
      AND is_active = true;

    IF v_template_row.id IS NULL THEN
      RAISE EXCEPTION 'Plantilla % no trobada o no accessible per al tenant %',
        v_template_id, v_tenant_id;
    END IF;
  END IF;

  -- 4. Inline: cal "subject" si no hi ha plantilla
  IF v_template_id IS NULL AND v_subject IS NULL THEN
    RAISE EXCEPTION
      'Cal indicar "event_type", "template_slug", "template_id" o "subject" (contingut directe)';
  END IF;

  -- ── Resolucio del layout ──
  IF v_template_row.id IS NOT NULL AND v_template_row.use_layout = true THEN
    v_layout_id := COALESCE(v_template_row.layout_id, v_config.default_layout_id);
  END IF;

  -- ── Inserir a email_logs (idempotent) ──
  INSERT INTO data.email_logs (
    tenant_id, site_id, idempotency_key, status, email_type, priority,
    from_email, from_name, to_emails, cc_emails, bcc_emails, reply_to,
    template_id, template_variables, subject, html_body, text_body,
    attachments, max_retries, metadata, tags, scheduled_at, layout_id
  ) VALUES (
    v_tenant_id,
    v_site_id,
    v_idempotency_key,
    'queued',
    v_email_type,
    v_priority,
    v_from_email,
    v_from_name,
    v_to_emails,
    CASE WHEN payload ? 'cc'  THEN ARRAY(SELECT jsonb_array_elements_text(payload -> 'cc'))  END,
    CASE WHEN payload ? 'bcc' THEN ARRAY(SELECT jsonb_array_elements_text(payload -> 'bcc')) END,
    v_reply_to,
    v_template_id,
    payload -> 'template_variables',
    v_subject,
    payload ->> 'html_body',
    payload ->> 'text_body',
    payload -> 'attachments',
    COALESCE(v_config.max_retries, 3),
    payload -> 'metadata',
    CASE WHEN payload ? 'tags' THEN ARRAY(SELECT jsonb_array_elements_text(payload -> 'tags')) END,
    v_scheduled_at,
    v_layout_id
  )
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_log_id;

  -- Si ja existia (duplicat idempotent): retornar l'ID existent
  IF v_log_id IS NULL THEN
    SELECT id INTO v_log_id
    FROM data.email_logs
    WHERE tenant_id = v_tenant_id AND idempotency_key = v_idempotency_key;
    RETURN v_log_id;
  END IF;

  -- ── Encuar a pgmq amb delay si scheduled_at es al futur ──
  v_delay_seconds := CASE
    WHEN v_scheduled_at IS NULL THEN 0
    ELSE GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (v_scheduled_at - now())))::int)
  END;

  PERFORM pgmq.send(
    'email_send_queue',
    jsonb_build_object(
      'email_log_id',     v_log_id,
      'tenant_id',        v_tenant_id,
      'idempotency_key',  v_idempotency_key,
      'priority',         v_priority,
      'scheduled_at',     v_scheduled_at
    ),
    v_delay_seconds
  );

  RETURN v_log_id;
END;
$$;

-- Accessible per authenticated (el check de membresia es intern)
GRANT EXECUTE ON FUNCTION api.enqueue_email(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- api.pop_email_messages(p_batch_size integer) -> TABLE
--
-- Worker llegeix un lot de missatges de la cua.
-- Cada missatge es bloqueja per 5 minuts (VT = 300 s).
-- Nomes service_role pot cridar aquesta funcio.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.pop_email_messages(
  p_batch_size integer DEFAULT 10
)
RETURNS TABLE (
  msg_id          bigint,
  email_log_id    uuid,
  tenant_id       uuid,
  idempotency_key text,
  priority        integer,
  scheduled_at    timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT
    m.msg_id,
    (m.message ->> 'email_log_id')::uuid       AS email_log_id,
    (m.message ->> 'tenant_id')::uuid           AS tenant_id,
    m.message ->> 'idempotency_key'             AS idempotency_key,
    COALESCE((m.message ->> 'priority')::int,0) AS priority,
    (m.message ->> 'scheduled_at')::timestamptz AS scheduled_at
  FROM pgmq.read(
    'email_send_queue',
    300,                                     -- visibility timeout: 5 minuts
    LEAST(GREATEST(p_batch_size, 1), 50)     -- limitat a [1, 50]
  ) AS m;
$$;

REVOKE ALL ON FUNCTION api.pop_email_messages(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.pop_email_messages(integer) FROM authenticated;
REVOKE ALL ON FUNCTION api.pop_email_messages(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION api.pop_email_messages(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- api.archive_email_message(p_msg_id bigint) -> boolean
--
-- Arxiva un missatge processat (mou-lo a la taula d'arxiu de pgmq).
-- Nomes service_role.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.archive_email_message(p_msg_id bigint)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT pgmq.archive('email_send_queue', p_msg_id);
$$;

REVOKE ALL ON FUNCTION api.archive_email_message(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.archive_email_message(bigint) FROM authenticated;
REVOKE ALL ON FUNCTION api.archive_email_message(bigint) FROM anon;
GRANT  EXECUTE ON FUNCTION api.archive_email_message(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- api.process_email_webhook(p_provider_message_id text, p_new_status text, p_metadata jsonb)
--
-- Entrada unica per als webhooks de Resend/Sendgrid.
-- Actualitza l'estat del email_log basat en el provider_message_id.
-- El trigger de transicions valida que el canvi sigui legal.
-- Nomes service_role.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.process_email_webhook(
  p_provider_message_id text,
  p_new_status          text,
  p_metadata            jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_log_id uuid;
  v_status data.email_status;
BEGIN
  -- Validar que l'estat sigui valid
  BEGIN
    v_status := p_new_status::data.email_status;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Estat invalid: %', p_new_status;
  END;

  -- Actualitzar email_log (el trigger validara la transicio)
  UPDATE data.email_logs
  SET
    status       = v_status,
    metadata     = COALESCE(metadata, '{}'::jsonb) || COALESCE(p_metadata, '{}'::jsonb)
  WHERE provider_message_id = p_provider_message_id
  RETURNING id INTO v_log_id;

  IF v_log_id IS NULL THEN
    RAISE EXCEPTION 'LogNotFound: provider_message_id "%" no trobat', p_provider_message_id;
  END IF;

  RETURN v_log_id;
END;
$$;

REVOKE ALL ON FUNCTION api.process_email_webhook(text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.process_email_webhook(text, text, jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION api.process_email_webhook(text, text, jsonb) FROM anon;
GRANT  EXECUTE ON FUNCTION api.process_email_webhook(text, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- api.get_platform_email_defaults() -> jsonb
--
-- Exposa els valors de fallback de plataforma als tenants autenticats.
-- Util al tenant-portal per mostrar/pre-omplir el from_email i from_name
-- quan el tenant encara no te domini verificat.
-- No filtra per tenant: es informacio publica de la plataforma.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_platform_email_defaults()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_settings jsonb;
BEGIN
  SELECT settings INTO v_settings
  FROM data.system_settings
  WHERE module = 'email';

  RETURN jsonb_build_object(
    'from_email', COALESCE(v_settings ->> 'platform_default_from_email', ''),
    'from_name',  COALESCE(v_settings ->> 'platform_default_from_name', '')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_platform_email_defaults() TO authenticated;


-- ============================================================================
-- 11. VISTES API — Exposar a PostgREST
-- ============================================================================

-- ---------------------------------------------------------------------------
-- api.email_logs — Historial d'emails filtrat per RLS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.email_logs
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    site_id,
    idempotency_key,
    status,
    email_type,
    from_email,
    from_name,
    to_emails,
    subject,
    provider,
    provider_message_id,
    attempt_count,
    is_dead_letter,
    last_error,
    tags,
    scheduled_at,
    created_at,
    sent_at,
    delivered_at
  FROM data.email_logs;

GRANT SELECT ON api.email_logs TO authenticated;

-- ---------------------------------------------------------------------------
-- api.email_templates — Plantilles del tenant i de plataforma
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.email_templates
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    name,
    slug,
    event_type,
    subject_template,
    html_body_template,
    text_body_template,
    variables_schema,
    is_layout,
    layout_id,
    use_layout,
    is_platform_default,
    is_active,
    created_at,
    updated_at
  FROM data.email_templates;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.email_templates TO authenticated;
-- El Worker (service_role) llegeix plantilles de layout directament
GRANT SELECT ON api.email_templates TO service_role;

-- ---------------------------------------------------------------------------
-- api.email_domains — Dominis d'email del tenant
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.email_domains
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    domain,
    verification_status,
    dns_records,
    provider_domain_id,
    verified_at,
    is_primary,
    default_from_email,
    default_from_name,
    default_reply_to,
    created_at,
    updated_at
  FROM data.email_domains;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.email_domains TO authenticated;

-- ---------------------------------------------------------------------------
-- api.email_configs — Configuracio email del tenant
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.email_configs
  WITH (security_invoker = true) AS
  SELECT
    tenant_id,
    default_provider,
    default_from_name,
    default_reply_to,
    default_layout_id,
    layout_variables,
    rate_limit_per_hour,
    rate_limit_per_day,
    max_retries,
    retention_days,
    created_at,
    updated_at,
    metadata
  FROM data.email_configs;

GRANT SELECT, INSERT, UPDATE ON api.email_configs TO authenticated;


-- ============================================================================
-- 12. VISTA PEL WORKER: api.worker_email_logs (SECURITY DEFINER)
-- ============================================================================
--
-- Aquesta vista s'executa com a superusuari (SENSE security_invoker = true)
-- per garantir que els triggers de transicio d'estat funcionen correctament
-- quan el Worker (service_role) modifica email_logs via PostgREST.
--
-- Sense aquesta vista, PostgREST (schema 'api') no pot accedir directament
-- a 'data.email_logs' perque l'esquema 'data' no esta exposat a config.toml.
-- ============================================================================

CREATE OR REPLACE VIEW api.worker_email_logs AS
  SELECT * FROM data.email_logs;

-- Restringir acces: EXCLUSIU per a service_role (el Worker)
REVOKE ALL ON api.worker_email_logs FROM PUBLIC;
REVOKE ALL ON api.worker_email_logs FROM authenticated;
REVOKE ALL ON api.worker_email_logs FROM anon;
GRANT ALL ON api.worker_email_logs TO service_role;

-- Permetre a service_role accedir a l'esquema data (necessari per als triggers)
GRANT USAGE ON SCHEMA data TO service_role;

-- ---------------------------------------------------------------------------
-- api.system_settings — View per exposar data.system_settings via PostgREST
-- ---------------------------------------------------------------------------
--
-- data.system_settings no és accessible via PostgREST perquè l'schema "data"
-- no és exposat (config.toml). Els Edge Functions que usen createAdminClient()
-- (schema "api") han d'usar aquesta view.
--
-- Exemple: _shared/rate-limiter.ts → admin.from("system_settings")
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW api.system_settings AS
  SELECT * FROM data.system_settings;

REVOKE ALL ON api.system_settings FROM PUBLIC;
GRANT SELECT ON api.system_settings TO anon, authenticated;
GRANT ALL    ON api.system_settings TO service_role;


-- ============================================================================
-- 12. SEED: Modul 'email' a system_settings (domini per defecte plataforma)
-- ============================================================================

INSERT INTO data.system_settings (module, settings) VALUES
  ('email', '{
    "platform_default_domain":     null,
    "platform_default_from_email": null,
    "platform_default_from_name":  null
  }'::jsonb)
ON CONFLICT (module) DO NOTHING;


-- =============================================================================
-- Migracio: Worker Rate Limits (Pla B Postgres) + System Settings seed
-- =============================================================================
--
-- El Worker utilitza una estrategia de cascada per rate limiting:
--   1. Si rate_limiting_enabled = false -> passa directament
--   2. Si engine = 'redis' -> Upstash REST API (primari)
--   3. Si Redis falla + fallback_to_postgres = true -> taula Postgres (pla B)
--
-- Aquesta migracio crea el Pla B: una taula lleugera de comptadors amb una
-- funcio RPC que fa UPSERT atomic i retorna si l'enviament esta permis.
-- =============================================================================


-- ============================================================================
-- 13. TAULA: data.worker_rate_limits (Pla B Postgres)
-- ============================================================================
--
-- Disseny deliberadament lleuger:
--   • PK composta: una fila per (tenant, window_type, window_start)
--   • L'UPSERT (ON CONFLICT DO UPDATE) adquireix row lock implicit
--     -> serialitza concurrencia del mateix tenant/finestra sense FOR UPDATE
--   • Purga eficient de finestres antigues via pg_cron
-- ============================================================================

CREATE TABLE IF NOT EXISTS data.worker_rate_limits (
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  window_type   text        NOT NULL CHECK (window_type IN ('hour', 'day')),
  window_start  timestamptz NOT NULL,
  count         integer     NOT NULL DEFAULT 0,
  PRIMARY KEY (tenant_id, window_type, window_start)
);

-- Index per purga eficient de finestres antigues
CREATE INDEX IF NOT EXISTS idx_worker_rate_limits_window_start
  ON data.worker_rate_limits (window_start);

-- RLS: nomes service_role (worker) i prisma_admin (backoffice)
ALTER TABLE data.worker_rate_limits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "worker_rate_limits: service_role full access"
  ON data.worker_rate_limits FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- No cal politica per authenticated — el frontend no hi accedeix
GRANT ALL ON data.worker_rate_limits TO service_role, prisma_admin;


-- ============================================================================
-- 14. RPC: api.check_and_increment_worker_limit
-- ============================================================================
--
-- Crida EXCLUSIVA del Worker (service_role). Logica:
--
--   1. UPSERT +1 al comptador de la finestra d'hora actual
--   2. UPSERT +1 al comptador de la finestra de dia actual
--   3. Si qualsevol dels dos supera el limit -> retorna FALSE
--      (l'UPSERT ja ha incrementat, pero el Worker no enviara el correu
--       i aplicara un VT llarg a pgmq perque reaparegui mes tard)
--   4. Si cap supera -> retorna TRUE (enviar)
--
-- IMPORTANT sobre el +1 si retorna FALSE:
--   El comptador queda +1 malgrat no enviar. Aixo es correcte perque:
--   - El missatge reapareixera a la cua a la finestra seguent (nova hora/dia)
--   - A la finestra seguent el comptador comenca a 0
--   - L'exces del +1 a la finestra actual es negligible (1 sobre 100-10000)
--   - L'alternativa (restar si falla) afegeix complexitat i punts de fallada
-- ============================================================================

CREATE OR REPLACE FUNCTION api.check_and_increment_worker_limit(
  p_tenant_id uuid,
  p_max_hour  integer,
  p_max_day   integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_hour_window  timestamptz := date_trunc('hour', now());
  v_day_window   timestamptz := date_trunc('day', now());
  v_hour_count   integer;
  v_day_count    integer;
BEGIN
  -- Increment atomic finestra hora (row lock implicit via ON CONFLICT)
  INSERT INTO data.worker_rate_limits (tenant_id, window_type, window_start, count)
  VALUES (p_tenant_id, 'hour', v_hour_window, 1)
  ON CONFLICT (tenant_id, window_type, window_start)
  DO UPDATE SET count = data.worker_rate_limits.count + 1
  RETURNING count INTO v_hour_count;

  -- Check limit per hora
  IF p_max_hour > 0 AND v_hour_count > p_max_hour THEN
    RETURN FALSE;
  END IF;

  -- Increment atomic finestra dia (row lock implicit via ON CONFLICT)
  INSERT INTO data.worker_rate_limits (tenant_id, window_type, window_start, count)
  VALUES (p_tenant_id, 'day', v_day_window, 1)
  ON CONFLICT (tenant_id, window_type, window_start)
  DO UPDATE SET count = data.worker_rate_limits.count + 1
  RETURNING count INTO v_day_count;

  -- Check limit per dia
  IF p_max_day > 0 AND v_day_count > p_max_day THEN
    RETURN FALSE;
  END IF;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION api.check_and_increment_worker_limit(uuid, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.check_and_increment_worker_limit(uuid, integer, integer) FROM authenticated;
REVOKE ALL ON FUNCTION api.check_and_increment_worker_limit(uuid, integer, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION api.check_and_increment_worker_limit(uuid, integer, integer) TO service_role;


-- ============================================================================
-- 15. SEED: Modul 'rate_limiting' a system_settings
-- ============================================================================

INSERT INTO data.system_settings (module, settings) VALUES
  ('rate_limiting', '{
    "rate_limiting_enabled": true,
    "rate_limit_engine":     "postgres",
    "fallback_to_postgres":  true
  }'::jsonb)
ON CONFLICT (module) DO NOTHING;


-- =============================================================================
-- Migracio: Database Webhook per al Worker d'Email
-- =============================================================================
--
-- ARQUITECTURA — Singleton / Debounced Worker
-- ────────────────────────────────────────────
-- Quan s'insereix un missatge a la cua pgmq (email_send_queue), un trigger
-- dispara una crida HTTP asincrona (pg_net) al Worker Edge Function.
--
-- El Worker implementa un lock singleton via Redis (SET NX, TTL 45s):
--   • Si el lock s'adquireix -> processa la cua en bucle fins que estigui buida
--   • Si el lock no s'adquireix -> retorna 200 OK immediatament (un altre
--     worker ja esta corrent)
--
-- Aixo preven el "Thundering Herd": si 1000 emails s'encuen alhora, es
-- disparen 1000 triggers, pero nomes el primer adquireix el lock. Els 999
-- restants reben 200 OK sense cost. El worker que te el lock drena tota
-- la cua en un sol cicle.
--
-- DEBOUNCE ADDICIONAL (FOR EACH STATEMENT)
-- ──────────────────────────────────────────
-- Usem FOR EACH STATEMENT en lloc de FOR EACH ROW perque:
--   • Si un futur bulk enqueue insereix N files en un sol statement,
--     nomes es dispara UN trigger (no N)
--   • Cada enqueue_email() fa un pgmq.send() individual, pero si algun dia
--     es fa batch insert, el debounce ja esta
--
-- CREDENCIALS — Vault (mateix patro que migration 000010)
-- ──────────────────────────────────────────────────────
-- Secrets requerits (provisionats manualment, no a Git):
--   name: 'app_supabase_url'          value: https://<project-ref>.supabase.co
--   name: 'app_service_role_key'      value: <service_role_key>
--
-- Sense secrets -> RAISE WARNING i no fa res (graceful degradation en local dev)
--
-- LOCAL DEV NOTE
-- ──────────────
-- pg_net en local dev no pot fer HTTP a Edge Functions (container network).
-- Opcions per testejar:
--   1. curl manual:
--      curl -X POST http://127.0.0.1:54321/functions/v1/process-email-queue \
--           -H "Authorization: Bearer <service_role_key>" \
--           -H "Content-Type: application/json"
--   2. pg_cron (afegit al final com a fallback/complement)
-- =============================================================================


-- ============================================================================
-- 16. FUNCIO: data.invoke_email_queue_worker()
--
-- Crida HTTP asincrona al Worker via pg_net. Llegeix URL i key del Vault.
-- Patro idenic a data.invoke_deletion_queue_worker() (migration 000010).
-- ============================================================================

CREATE OR REPLACE FUNCTION data.invoke_email_queue_worker()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_supabase_url  text;
  v_service_key   text;
BEGIN
  -- Guard: pg_net must be installed
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING
      'invoke_email_queue_worker: pg_net extension not installed. Skipping.';
    RETURN;
  END IF;

  -- Read credentials from Vault (same secrets as deletion worker)
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'app_supabase_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'app_service_role_key'
  LIMIT 1;

  -- Graceful degradation: no secrets -> no HTTP call (local dev)
  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING
      'invoke_email_queue_worker: vault secrets not configured '
      '(app_supabase_url and/or app_service_role_key missing). '
      'Trigger notification skipped.';
    RETURN;
  END IF;

  -- Async HTTP POST via pg_net (returns immediately)
  BEGIN
    PERFORM extensions.http_post(
      url     := v_supabase_url || '/functions/v1/process-email-queue',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body    := '{}'::jsonb,
      timeout_milliseconds := 5000  -- 5s: el worker fa 200 OK instantani si locked
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING
      'invoke_email_queue_worker: http_post failed: %', SQLERRM;
  END;
END;
$$;

-- Restrict: only callable internally (trigger + cron)
REVOKE ALL ON FUNCTION data.invoke_email_queue_worker() FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_email_queue_worker() FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_email_queue_worker() FROM anon;


-- ============================================================================
-- 17. TRIGGER: Notificar el Worker cada cop que s'encua un email
--
-- FOR EACH STATEMENT: un sol trigger per INSERT statement (debounce natiu).
-- AFTER INSERT: no bloqueja l'operacio d'enqueue.
-- ============================================================================

CREATE OR REPLACE FUNCTION data.trg_notify_email_worker()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  PERFORM data.invoke_email_queue_worker();
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_email_queue_notify
  AFTER INSERT ON pgmq.q_email_send_queue
  FOR EACH STATEMENT
  EXECUTE FUNCTION data.trg_notify_email_worker();


-- ============================================================================
-- 18. pg_cron FALLBACK (complement al trigger)
--
-- El trigger cobreix el cas normal (email nou -> worker immediatament).
-- El cron cobreix edge cases:
--   • Missatges amb Visibility Timeout expirat (retries)
--   • Missatges rate-limited que tornen a la cua
--   • Qualsevol missatge "orfe" que el trigger no va poder notificar
--
-- Frequencia: cada 2 minuts — suficient per als retries sense ser agressiu.
-- ============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN

    -- Netejar schedule existent (idempotent)
    PERFORM cron.unschedule('process-email-queue-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-email-queue-worker'
    );

    PERFORM cron.schedule(
      'process-email-queue-worker',
      '*/2 * * * *',
      'SELECT data.invoke_email_queue_worker()'
    );

  END IF;
END;
$$;


-- ============================================================================
-- 19. Edge Function config (verify_jwt = false per a triggers interns)
-- ============================================================================
-- NOTA: Afegir a supabase/config.toml:
--
--   [functions."process-email-queue"]
--   verify_jwt = false
--
-- Aixo es necessari perque el trigger envia el JWT manualment
-- via Authorization header (Bearer service_role_key), no via
-- el mecanisme estandard de Supabase Auth.
-- ============================================================================


-- ============================================================================
-- 20. REALTIME — Subscripcio al frontend
-- ============================================================================
--
-- El frontend es subscriu a data.email_logs (no a la view api.email_logs)
-- perque les views no emeten events de Realtime.
-- Util per mostrar notificacions toast quan un email passa a 'bounced'/'failed'.
-- ============================================================================

ALTER PUBLICATION supabase_realtime ADD TABLE data.email_logs;

-- ============================================================================
-- 21. PERMISOS ADMIN-PORTAL (pgmq)
-- ============================================================================
-- Permetem al rol 'prisma_admin' accedir EXCLUSIVAMENT a les mètriques i
-- funcions de manteniment de la cua per al Dashboard de l'Admin-Portal.
-- ============================================================================

-- 1. Permetre l'entrada a l'esquema pgmq
GRANT USAGE ON SCHEMA pgmq TO prisma_admin;

-- 2. Permetre la lectura de les taules de la cua (per comptar arxivats i veure actius)
GRANT SELECT ON TABLE pgmq.q_email_send_queue TO prisma_admin;
GRANT SELECT ON TABLE pgmq.a_email_send_queue TO prisma_admin;

-- 3. Permetre la lectura de les seqüències (necessari per a la funció metrics)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgmq TO prisma_admin;

-- 4. Permetre només les funcions estrictament necessàries per al Dashboard
GRANT EXECUTE ON FUNCTION pgmq.metrics(text) TO prisma_admin;
GRANT EXECUTE ON FUNCTION pgmq.purge_queue(text) TO prisma_admin;