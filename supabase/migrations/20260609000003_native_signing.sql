-- =============================================================================
-- Migration: 20260609000003_native_signing.sql
-- Purpose : Infraestructura de firma digital pròpia (presencial i remota)
--
-- Conté:
--   1. data.document_signing_sessions    — sessions de signatura
--   2. data.document_signature_evidences — evidències per event
--   3. data.document_signatures_audit    — registre final per signatura
--   4. RLS + índexs
--   5. Vistes api.*
--   6. RPC api.create_signing_session    — crea sessió (presencial o remota)
--   7. RPC api.get_signing_session_public — per a la pàgina pública /sign/[token]
--   8. RPC api.log_signing_evidence      — afegir evidència a sessió
--   9. RPC api.expire_signing_sessions   — purga sessions caducades (pg_cron)
--  10. pg_cron entry per purga
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. data.document_signing_sessions
-- ---------------------------------------------------------------------------

CREATE TABLE data.document_signing_sessions (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  document_version_id   uuid        NOT NULL,  -- FK implícita (document_versions)
  signing_token         text        UNIQUE NOT NULL,
  signing_type          text        NOT NULL CHECK (signing_type IN ('presential', 'remote')),
  status                text        NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'opened', 'viewed', 'signed', 'expired', 'cancelled')),

  -- Signant
  signer_name           text,
  signer_email          text,
  signer_role           text,

  -- Operari que inicia (presencial)
  operator_user_id      uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,

  -- Caducitat
  expires_at            timestamptz NOT NULL DEFAULT (now() + interval '7 days'),

  -- Evidències capturades en el moment de signatura
  ip_address            text,
  user_agent            text,
  geolocation           jsonb,

  -- Timestamps d'events principals (resum ràpid; detall a evidences)
  timestamps            jsonb       DEFAULT '{}'::jsonb,

  -- Imatge de signatura (Storage path, no pública)
  signature_image_path  text,

  -- Resultat
  result_version_id     uuid,           -- PDF estampat (document_versions)
  audit_version_id      uuid,           -- PDF auditoria (document_versions)

  -- PDF job asociat (per saber quan el PDF inicial està llest)
  pdf_job_id            uuid        REFERENCES data.document_pdf_jobs(id) ON DELETE SET NULL,

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_document_signing_sessions_updated_at
  BEFORE UPDATE ON data.document_signing_sessions
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

CREATE INDEX idx_signing_sessions_token      ON data.document_signing_sessions (signing_token);
CREATE INDEX idx_signing_sessions_tenant     ON data.document_signing_sessions (tenant_id, status);
CREATE INDEX idx_signing_sessions_expires    ON data.document_signing_sessions (expires_at) WHERE status NOT IN ('signed', 'cancelled', 'expired');

-- ---------------------------------------------------------------------------
-- 2. data.document_signature_evidences
-- ---------------------------------------------------------------------------

CREATE TABLE data.document_signature_evidences (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id  uuid        NOT NULL REFERENCES data.document_signing_sessions(id) ON DELETE CASCADE,
  event_type  text        NOT NULL
              CHECK (event_type IN (
                'link_sent', 'link_opened', 'document_viewed',
                'signature_drawn', 'signed'
              )),
  ip_address  inet,
  user_agent  text,
  geolocation jsonb,
  metadata    jsonb       DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sig_evidences_session ON data.document_signature_evidences (session_id);

-- ---------------------------------------------------------------------------
-- 3. data.document_signatures_audit
-- ---------------------------------------------------------------------------

CREATE TABLE data.document_signatures_audit (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  document_id           uuid,
  session_id            uuid        REFERENCES data.document_signing_sessions(id) ON DELETE SET NULL,

  signer_name           text,
  signer_email          text,
  signer_role           text,

  timestamp_signed      timestamptz NOT NULL,

  ip_address            text,
  user_agent            text,
  geolocation           jsonb,

  -- Storage path xifrat, no pública
  signature_image_path  text,

  -- Prova d'integritat
  document_hash_before  text,
  document_hash_after   text,

  -- Storage path del certificat d'auditoria
  audit_pdf_path        text,

  created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sig_audit_tenant    ON data.document_signatures_audit (tenant_id);
CREATE INDEX idx_sig_audit_session   ON data.document_signatures_audit (session_id);
CREATE INDEX idx_sig_audit_document  ON data.document_signatures_audit (document_id);

-- ---------------------------------------------------------------------------
-- 4. RLS
-- ---------------------------------------------------------------------------

ALTER TABLE data.document_signing_sessions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.document_signature_evidences ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.document_signatures_audit    ENABLE ROW LEVEL SECURITY;

-- service_role: accés total
CREATE POLICY "service_role full on signing_sessions"
  ON data.document_signing_sessions FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "service_role full on sig_evidences"
  ON data.document_signature_evidences FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "service_role full on sig_audit"
  ON data.document_signatures_audit FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Membres autenticats: llegir sessions del seu tenant
CREATE POLICY "tenant members read signing_sessions"
  ON data.document_signing_sessions FOR SELECT TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM data.tenant_members
       WHERE user_id = auth.uid() AND is_active = true
    )
  );

CREATE POLICY "tenant members read sig_audit"
  ON data.document_signatures_audit FOR SELECT TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM data.tenant_members
       WHERE user_id = auth.uid() AND is_active = true
    )
  );

GRANT SELECT ON data.document_signing_sessions   TO authenticated;
GRANT SELECT ON data.document_signatures_audit   TO authenticated;
GRANT ALL    ON data.document_signing_sessions   TO service_role;
GRANT ALL    ON data.document_signature_evidences TO service_role;
GRANT ALL    ON data.document_signatures_audit   TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Vistes api
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW api.document_signing_sessions
WITH (security_invoker = true)
AS
SELECT
  id, tenant_id, document_version_id, signing_type, status,
  signer_name, signer_email, signer_role, operator_user_id,
  expires_at, timestamps, result_version_id, audit_version_id,
  pdf_job_id, created_at, updated_at
  -- signing_token, ip_address, user_agent, signature_image_path exclosos per seguretat
FROM data.document_signing_sessions;

CREATE OR REPLACE VIEW api.document_signatures_audit
WITH (security_invoker = true)
AS
SELECT
  id, tenant_id, document_id, session_id,
  signer_name, signer_email, signer_role,
  timestamp_signed, geolocation, audit_pdf_path,
  document_hash_before, document_hash_after,
  created_at
  -- ip_address, user_agent, signature_image_path exclosos per privacitat
FROM data.document_signatures_audit;

GRANT SELECT ON api.document_signing_sessions TO authenticated;
GRANT SELECT ON api.document_signatures_audit TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. RPC api.create_signing_session — crea sessió (presencial o remota)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_signing_session(
  p_tenant_id           uuid,
  p_document_version_id uuid,
  p_signing_type        text,
  p_signer_name         text DEFAULT NULL,
  p_signer_email        text DEFAULT NULL,
  p_signer_role         text DEFAULT NULL,
  p_pdf_job_id          uuid DEFAULT NULL,
  p_expires_days        int  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_token      text;
  v_session_id uuid;
  v_expires_at timestamptz;
  v_token_days int;
BEGIN
  -- Verificar membresia (skip per service_role; el router ja valida)
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.tenant_members
       WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_active = true
         AND role IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Forbidden: requires owner or manager role';
    END IF;
  END IF;

  -- Verificar native_signing_enabled
  IF NOT COALESCE(
    (SELECT (settings ->> 'native_signing_enabled')::boolean
       FROM data.system_settings WHERE module = 'pdf_converter'),
    false
  ) THEN
    RAISE EXCEPTION 'native_signing_disabled: La firma nativa no està activada per a aquesta plataforma';
  END IF;

  -- Llegir dies de validesa de config (o usar paràmetre)
  SELECT COALESCE(
    p_expires_days,
    (settings ->> 'remote_signing_token_days')::int,
    7
  ) INTO v_token_days
  FROM data.system_settings WHERE module = 'pdf_converter';

  v_expires_at := now() + (v_token_days || ' days')::interval;

  -- Generar token segur: UUID v4 (32 chars hex sense guions) + salt 32 chars hex
  v_token := replace(gen_random_uuid()::text, '-', '') || encode(extensions.gen_random_bytes(16), 'hex');

  INSERT INTO data.document_signing_sessions (
    tenant_id, document_version_id, signing_token, signing_type,
    signer_name, signer_email, signer_role,
    operator_user_id, expires_at, pdf_job_id
  ) VALUES (
    p_tenant_id, p_document_version_id, v_token, p_signing_type,
    p_signer_name, p_signer_email, p_signer_role,
    v_user_id, v_expires_at, p_pdf_job_id
  )
  RETURNING id INTO v_session_id;

  -- Evidència inicial: link_sent (per a remota) o session_created (per a presencial)
  IF p_signing_type = 'remote' THEN
    INSERT INTO data.document_signature_evidences (session_id, event_type)
    VALUES (v_session_id, 'link_sent');
  END IF;

  RETURN jsonb_build_object(
    'session_id',  v_session_id,
    'token',       v_token,
    'expires_at',  v_expires_at,
    'signing_type',p_signing_type
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_signing_session(uuid,uuid,text,text,text,text,uuid,int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. RPC api.get_signing_session_public — per a la pàgina pública /sign/[token]
--    Accessible sense autenticació (anon) però valida el token
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_signing_session_public(
  p_token text
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_session record;
BEGIN
  SELECT * INTO v_session
    FROM data.document_signing_sessions
   WHERE signing_token = p_token
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'token_not_found');
  END IF;

  IF v_session.status = 'signed' THEN
    RETURN jsonb_build_object(
      'error',          'already_signed',
      'timestamp_signed', v_session.timestamps ->> 'signed_at'
    );
  END IF;

  IF v_session.expires_at < now() THEN
    -- Marcar com expirat
    UPDATE data.document_signing_sessions
       SET status = 'expired', updated_at = now()
     WHERE id = v_session.id AND status NOT IN ('signed', 'cancelled');

    RETURN jsonb_build_object('error', 'token_expired');
  END IF;

  IF v_session.status = 'cancelled' THEN
    RETURN jsonb_build_object('error', 'session_cancelled');
  END IF;

  -- Marcar com obert
  IF v_session.status = 'pending' THEN
    UPDATE data.document_signing_sessions
       SET status     = 'opened',
           timestamps = COALESCE(v_session.timestamps, '{}') || jsonb_build_object('opened_at', now()),
           updated_at = now()
     WHERE id = v_session.id;
  END IF;

  RETURN jsonb_build_object(
    'session_id',           v_session.id,
    'tenant_id',            v_session.tenant_id,
    'document_version_id',  v_session.document_version_id,
    'signing_type',         v_session.signing_type,
    'status',               v_session.status,
    'signer_name',          v_session.signer_name,
    'signer_role',          v_session.signer_role,
    'expires_at',           v_session.expires_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_signing_session_public(text) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. RPC api.log_signing_evidence — afegir evidència (des de la pàgina pública)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.log_signing_evidence(
  p_session_id uuid,
  p_event_type text,
  p_ip_address text DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_geolocation jsonb DEFAULT NULL,
  p_metadata    jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  -- Validar event_type
  IF p_event_type NOT IN ('link_opened', 'document_viewed', 'signature_drawn', 'signed', 'link_sent') THEN
    RAISE EXCEPTION 'invalid_event_type';
  END IF;

  -- Verificar que la sessió existeixi i no estigui terminal
  IF NOT EXISTS (
    SELECT 1 FROM data.document_signing_sessions
     WHERE id = p_session_id AND status NOT IN ('signed', 'cancelled', 'expired')
  ) THEN
    RAISE EXCEPTION 'session_not_active';
  END IF;

  INSERT INTO data.document_signature_evidences (
    session_id, event_type, ip_address, user_agent, geolocation, metadata
  ) VALUES (
    p_session_id, p_event_type,
    CASE WHEN p_ip_address IS NOT NULL THEN p_ip_address::inet ELSE NULL END,
    p_user_agent,
    p_geolocation,
    p_metadata
  );

  -- Actualitzar timestamps de la sessió
  IF p_event_type = 'document_viewed' THEN
    UPDATE data.document_signing_sessions
       SET status     = CASE WHEN status = 'opened' THEN 'viewed' ELSE status END,
           timestamps = COALESCE(timestamps, '{}') || jsonb_build_object('viewed_at', now()),
           updated_at = now()
     WHERE id = p_session_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.log_signing_evidence(uuid,text,text,text,jsonb,jsonb) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. RPC api.expire_signing_sessions — purga sessions caducades
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.expire_signing_sessions()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE v_count int;
BEGIN
  UPDATE data.document_signing_sessions
     SET status = 'expired', updated_at = now()
   WHERE expires_at < now()
     AND status NOT IN ('signed', 'cancelled', 'expired');

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.expire_signing_sessions() TO service_role;

-- ---------------------------------------------------------------------------
-- 10. pg_cron: purgar sessions caducades cada hora
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN

    PERFORM cron.unschedule('expire_signing_sessions')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'expire_signing_sessions'
    );

    PERFORM cron.schedule(
      'expire_signing_sessions',
      '0 * * * *',
      'SELECT api.expire_signing_sessions()'
    );

  END IF;
END;
$$;
