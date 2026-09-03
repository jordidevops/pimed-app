-- =============================================================================
-- Migration: 20260603000006_signing_notification_mode.sql
--
-- Propòsit: Afegir control de flux de notificació al mòdul de signatura
--
-- Crea:
--   data.signing_notification_mode  — enum de 4 modes
--   data.signing_submitters         — taula normalitzada de signants (obliga per orquestració seqüencial)
--
-- Altera:
--   data.signing_submissions        — afegeix notification_mode, notification_enabled,
--                                     next_signer_index, first_email_sent_at, last_notification_at
--   data.tenant_signing_config      — afegeix default_notification_mode
--
-- Vistes api.*:
--   api.signing_submissions         — reconstruïda amb els nous camps
--   api.signing_submitters          — nova vista de signants normalitzats
--
-- RPCs SECURITY DEFINER:
--   api.enqueue_signing_notification(uuid, integer, text)
--     — encua email de signatura via api.enqueue_email; actualitza notified_at
--
-- Seeds:
--   data.email_templates            — signing.request.initial, signing.request.next_signer
--
-- Auditoria:
--   SIGNING_NOTIFICATION_SENT
--
-- Bugs resolts:
--   BUG-1: Ara data.signing_submitters guarda external_submitter_id per a
--           cada signant — el webhook pot fer lookup stripejant el sufix :sN
--   BUG-4: GRANT EXECUTE a service_role per a api.enqueue_signing_notification
-- =============================================================================

-- ============================================================================
-- 1. Enum signing_notification_mode
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE data.signing_notification_mode AS ENUM (
    'docuseal_auto',        -- DocuSeal envia tots els emails directament
    'app_manual',           -- cap email automàtic; URLs visibles a l'app
    'app_auto_all',         -- app envia email a tots els signants immediatament
    'app_auto_sequential'   -- app envia email seqüencialment: signer N+1 quan N completa
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ============================================================================
-- 2. Columnes noves a data.signing_submissions
-- ============================================================================

ALTER TABLE data.signing_submissions
  ADD COLUMN IF NOT EXISTS notification_mode    data.signing_notification_mode
                             NOT NULL DEFAULT 'app_auto_sequential',
  ADD COLUMN IF NOT EXISTS notification_enabled boolean
                             NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS next_signer_index    integer    NULL,
  ADD COLUMN IF NOT EXISTS first_email_sent_at  timestamptz NULL,
  ADD COLUMN IF NOT EXISTS last_notification_at timestamptz NULL;

COMMENT ON COLUMN data.signing_submissions.notification_mode
  IS 'Mode de notificació triat en crear la submissió. Hereta de tenant default si no s''especifica.';
COMMENT ON COLUMN data.signing_submissions.notification_enabled
  IS 'Si false: cap notificació automàtica independentment del mode.';
COMMENT ON COLUMN data.signing_submissions.next_signer_index
  IS 'Índex 0-based del proper signant a notificar en mode app_auto_sequential.';
COMMENT ON COLUMN data.signing_submissions.first_email_sent_at
  IS 'Quan s''ha enviat el primer email de signatura.';
COMMENT ON COLUMN data.signing_submissions.last_notification_at
  IS 'Quan s''ha enviat l''últim email de notificació a qualsevol signant.';


-- ============================================================================
-- 3. Columna nova a data.tenant_signing_config
-- ============================================================================

ALTER TABLE data.tenant_signing_config
  ADD COLUMN IF NOT EXISTS default_notification_mode data.signing_notification_mode
                             NOT NULL DEFAULT 'app_auto_sequential';

COMMENT ON COLUMN data.tenant_signing_config.default_notification_mode
  IS 'Mode per defecte de notificació per a noves submissions del tenant.';


-- ============================================================================
-- 4. data.signing_submitters — taula normalitzada de signants
--    Obligatòria per orquestració seqüencial fiable (evita race conditions
--    sobre el JSONB signing_submissions.signers sota events concurrents).
-- ============================================================================

CREATE TABLE IF NOT EXISTS data.signing_submitters (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id           uuid        NOT NULL
                            REFERENCES data.signing_submissions(id) ON DELETE CASCADE,
  tenant_id               uuid        NOT NULL
                            REFERENCES data.tenants(id) ON DELETE CASCADE,
  signer_order            integer     NOT NULL CHECK (signer_order >= 0),
  role                    text,
  email                   text        NOT NULL,
  name                    text        NOT NULL DEFAULT '',
  -- external_id enviat a DocuSeal per a AQUEST signant (format: "{submission_ext_id}:s{idx}")
  external_submitter_id   text,
  signing_url             text,
  status                  text        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending','sent','opened','completed','declined')),
  notified_at             timestamptz,
  email_log_id            uuid,        -- FK a data.email_logs per traçabilitat
  opened_at               timestamptz,
  completed_at            timestamptz,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (submission_id, signer_order)
);

CREATE INDEX IF NOT EXISTS idx_signing_submitters_submission
  ON data.signing_submitters (submission_id, signer_order);

CREATE INDEX IF NOT EXISTS idx_signing_submitters_tenant
  ON data.signing_submitters (tenant_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_signing_submitters_ext_id
  ON data.signing_submitters (external_submitter_id)
  WHERE external_submitter_id IS NOT NULL;

COMMENT ON TABLE data.signing_submitters
  IS 'Signants normalitzats per submissió. Usada per orquestració seqüencial i tracking de notificacions.';
COMMENT ON COLUMN data.signing_submitters.external_submitter_id
  IS 'external_id enviat a DocuSeal (format: "{submission_external_id}:s{idx}"). Permite lookup al webhook.';


-- ============================================================================
-- 5. RLS per data.signing_submitters
-- ============================================================================

ALTER TABLE data.signing_submitters ENABLE ROW LEVEL SECURITY;

CREATE POLICY "signing_submitters: tenant members select"
  ON data.signing_submitters FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

CREATE POLICY "signing_submitters: owner/manager/member insert"
  ON data.signing_submitters FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

CREATE POLICY "signing_submitters: owner/manager update"
  ON data.signing_submitters FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );


-- ============================================================================
-- 6. Trigger updated_at per signing_submitters
-- ============================================================================

CREATE TRIGGER trg_signing_submitters_updated_at
  BEFORE UPDATE ON data.signing_submitters
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();


-- ============================================================================
-- 7. GRANTs
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON data.signing_submitters TO authenticated;
GRANT SELECT, INSERT, UPDATE ON data.signing_submitters TO service_role;


-- ============================================================================
-- 8. Reconstruir api.signing_submissions amb camps nous
-- ============================================================================

DROP VIEW IF EXISTS api.signing_submissions;

CREATE VIEW api.signing_submissions WITH (security_invoker = true) AS
  SELECT
    ss.id,
    ss.tenant_id,
    ss.source_type,
    ss.source_document_id,
    ss.source_document_version_id,
    ss.source_template_locale_id,
    ss.result_document_version_id,
    rv.file_path_or_url       AS result_file_path_or_url,
    rv.storage_type           AS result_storage_type,
    ss.docuseal_submission_id,
    ss.external_id,
    ss.status,
    ss.status_reason,
    ss.error_message,
    ss.last_event_at,
    ss.signers,
    ss.docuseal_signing_url,
    -- Notification flow
    ss.notification_mode,
    ss.notification_enabled,
    ss.next_signer_index,
    ss.first_email_sent_at,
    ss.last_notification_at,
    -- Timestamps cicle de vida
    ss.submitted_at,
    ss.completed_at,
    ss.reviewed_at,
    ss.reviewed_by,
    ss.document_title,
    ss.audit_trail_storage_path,
    ss.audit_log_url,
    ss.initiated_by,
    ss.metadata,
    ss.created_at,
    ss.updated_at
  FROM data.signing_submissions ss
  LEFT JOIN data.document_versions rv ON rv.id = ss.result_document_version_id;

GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.signing_submissions TO service_role;


-- ============================================================================
-- 9. Nova vista api.signing_submitters
-- ============================================================================

CREATE VIEW api.signing_submitters WITH (security_invoker = true) AS
  SELECT
    st.id,
    st.submission_id,
    st.tenant_id,
    st.signer_order,
    st.role,
    st.email,
    st.name,
    st.external_submitter_id,
    st.signing_url,
    st.status,
    st.notified_at,
    st.email_log_id,
    st.opened_at,
    st.completed_at,
    st.created_at,
    st.updated_at
  FROM data.signing_submitters st;

GRANT SELECT, INSERT, UPDATE ON api.signing_submitters TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.signing_submitters TO service_role;


-- ============================================================================
-- 10. RPC api.enqueue_signing_notification
--     Encua email de signatura per a un signant. Fire-and-forget des del webhook.
--     Accessible per authenticated (resend manual) i service_role (webhook).
-- ============================================================================

CREATE OR REPLACE FUNCTION api.enqueue_signing_notification(
  p_submission_id  uuid,
  p_signer_order   integer,
  p_reason         text  DEFAULT 'manual'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_submitter  data.signing_submitters%ROWTYPE;
  v_submission data.signing_submissions%ROWTYPE;
  v_total      bigint;
  v_log_id     uuid;
  v_event_type text;
BEGIN
  -- Validació: submitter existeix
  SELECT * INTO v_submitter
  FROM data.signing_submitters
  WHERE submission_id = p_submission_id
    AND signer_order  = p_signer_order;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'submitter_not_found: submission=%, order=%',
      p_submission_id, p_signer_order
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Validació: submission existeix
  SELECT * INTO v_submission
  FROM data.signing_submissions
  WHERE id = p_submission_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'submission_not_found: %', p_submission_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Validació: ha d'haver URL per enviar
  IF v_submitter.signing_url IS NULL THEN
    RAISE EXCEPTION 'no_signing_url: submitter signer_order=% no té signing_url', p_signer_order
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Nombre total de signants
  SELECT COUNT(*) INTO v_total
  FROM data.signing_submitters
  WHERE submission_id = p_submission_id;

  -- Event type de l'email
  v_event_type := CASE WHEN p_signer_order = 0
    THEN 'signing.request.initial'
    ELSE 'signing.request.next_signer'
  END;

  -- Encuar via infraestructura d'email
  SELECT api.enqueue_email(jsonb_build_object(
    'tenant_id',    v_submission.tenant_id,
    'event_type',   v_event_type,
    'to_email',     v_submitter.email,
    'to_name',      v_submitter.name,
    'variables',    jsonb_build_object(
      'signer_name',    v_submitter.name,
      'signer_email',   v_submitter.email,
      'signer_role',    COALESCE(v_submitter.role, ''),
      'document_title', COALESCE(v_submission.document_title, ''),
      'signing_url',    v_submitter.signing_url,
      'current_order',  p_signer_order + 1,
      'total_signers',  v_total
    )
  )) INTO v_log_id;

  -- Actualitzar notified_at i email_log_id al submitter
  UPDATE data.signing_submitters
  SET
    notified_at  = now(),
    email_log_id = v_log_id,
    status       = CASE WHEN status = 'pending' THEN 'sent' ELSE status END,
    updated_at   = now()
  WHERE id = v_submitter.id;

  -- Actualitzar timestamps a la submission
  UPDATE data.signing_submissions
  SET
    last_notification_at = now(),
    next_signer_index    = p_signer_order,
    first_email_sent_at  = COALESCE(first_email_sent_at, now()),
    updated_at           = now()
  WHERE id = p_submission_id;

  -- Audit log
  PERFORM data.log_audit_event(
    v_submission.tenant_id,
    COALESCE(auth.uid(), NULL),
    NULL,
    'SIGNING_NOTIFICATION_SENT',
    'signing_submitter',
    v_submitter.id,
    jsonb_build_object(
      'submission_id',  p_submission_id,
      'signer_order',   p_signer_order,
      'email',          v_submitter.email,
      'event_type',     v_event_type,
      'reason',         p_reason,
      'email_log_id',   v_log_id
    )
  );

  RETURN v_log_id;
END;
$$;

-- BUG-4 FIX: cal grant explícit a service_role (webhook usa createAdminClient)
GRANT EXECUTE ON FUNCTION api.enqueue_signing_notification(uuid, integer, text)
  TO authenticated, service_role;


-- ============================================================================
-- 12. Actualitzar api.tenant_signing_status per incloure default_notification_mode
-- ============================================================================

DROP VIEW IF EXISTS api.tenant_signing_status;
CREATE VIEW api.tenant_signing_status WITH (security_invoker = true) AS
  SELECT
    c.tenant_id,
    c.mode,
    c.signing_credits,
    c.docuseal_api_url,
    c.is_active,
    c.admin_disabled,
    (c.is_active AND NOT c.admin_disabled)        AS effective_is_active,
    data.is_signing_feature_enabled(c.tenant_id)  AS feature_enabled,
    (
      data.is_signing_feature_enabled(c.tenant_id)
      AND NOT c.admin_disabled
    )                                              AS can_activate,
    c.default_notification_mode,
    c.created_at,
    c.updated_at
    -- docuseal_key_secret_id: EXCLÒS deliberadament
  FROM data.tenant_signing_config c;

GRANT SELECT ON api.tenant_signing_status TO authenticated;
GRANT SELECT ON api.tenant_signing_status TO service_role;

