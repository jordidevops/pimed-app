-- =============================================================================
-- Migration: 20260429000001_api_log_email_body_viewed.sql
-- Propòsit: Exposa via PostgREST (api.*) una funció per registrar la consulta
--           del cos d'un correu electrònic a data.audit_logs.
--
-- Patró d'autorització:
--   - Requereix usuari autenticat (auth.uid() NOT NULL)
--   - Verifica que l'usuari pertany al tenant propietari del registre
--   - Usa data.log_audit_event() (SECURITY DEFINER) per escriure l'audit
--
-- Acció d'auditoria: EMAIL_BODY_VIEWED
--   entity_type: 'email_log'
--   payload: { subject, sent_at, to_emails, portal }
-- =============================================================================

CREATE OR REPLACE FUNCTION api.log_email_body_viewed(
  p_email_log_id  uuid,
  p_portal        text DEFAULT 'tenant-portal'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_tenant_id uuid;
  v_subject   text;
  v_sent_at   timestamptz;
  v_to_emails text[];
BEGIN
  -- 1. Requereix usuari autenticat
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  -- 2. Llegir les dades del email_log
  SELECT tenant_id, subject, sent_at, to_emails
    INTO v_tenant_id, v_subject, v_sent_at, v_to_emails
    FROM data.email_logs
   WHERE id = p_email_log_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'email_log not found: %', p_email_log_id;
  END IF;

  -- 3. Verificar que l'usuari té accés al tenant (via JWT claims o cache)
  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'forbidden: user does not belong to tenant %', v_tenant_id;
  END IF;

  -- 4. Registrar a audit_logs (fire-and-forget: errors no trenquen el flux)
  PERFORM data.log_audit_event(
    p_tenant_id   := v_tenant_id,
    p_user_id     := v_user_id,
    p_site_id     := NULL,
    p_action      := 'EMAIL_BODY_VIEWED',
    p_entity_type := 'email_log',
    p_entity_id   := p_email_log_id,
    p_payload     := jsonb_build_object(
      'subject',    v_subject,
      'sent_at',    v_sent_at,
      'to_emails',  v_to_emails,
      'portal',     p_portal
    )
  );
END;
$$;

-- Permetre a usuaris autenticats cridar aquesta funció
GRANT EXECUTE ON FUNCTION api.log_email_body_viewed(uuid, text) TO authenticated;

COMMENT ON FUNCTION api.log_email_body_viewed(uuid, text) IS
  'Registra a audit_logs que un usuari ha consultat el cos d''un correu electrònic. '
  'Requereix autenticació i que l''usuari pertanyi al tenant propietari del registre.';
