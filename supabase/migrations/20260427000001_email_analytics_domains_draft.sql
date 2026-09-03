-- =============================================================================
-- Migració: Email - Analítica, Dominis i Mode Esborrany
-- =============================================================================
-- Consolida:
--   • 20260427000001 (email_usage_rpc)       — RPC de consum d'emails
--   • 20260427000002 (email_view_fixes)      — Vista email_logs completa, RPC amb p_tenant_id
--   • 20260427000003 (email_domains_flag)    — Feature flag dominis personalitzats + triggers
--   • 20260427000004 (email_templates_draft) — Suport esborrany a plantilles
--
-- NOTA: api.enqueue_email s'actualitza completament a 20260427000007
--       (inclou esborrany, locale i cascada de site).
-- =============================================================================


-- ============================================================================
-- 1. Vista api.email_logs (columnes completes per al modal de detall)
-- ============================================================================

DROP VIEW IF EXISTS api.email_logs;

CREATE VIEW api.email_logs
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
    cc_emails,
    bcc_emails,
    reply_to,
    subject,
    html_body,
    text_body,
    provider,
    provider_message_id,
    attempt_count,
    is_dead_letter,
    last_error,
    error_history,
    tags,
    scheduled_at,
    created_at,
    sent_at,
    delivered_at
  FROM data.email_logs;

GRANT SELECT ON api.email_logs TO authenticated;


-- ============================================================================
-- 2. RPC api.get_my_email_usage (accepta p_tenant_id opcional)
-- Reemplaça la versió sense paràmetre.
-- ============================================================================

DROP FUNCTION IF EXISTS api.get_my_email_usage();

CREATE OR REPLACE FUNCTION api.get_my_email_usage(p_tenant_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id  uuid := COALESCE(p_tenant_id, data.active_tenant_id());
  v_hour_count bigint := 0;
  v_day_count  bigint := 0;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No tenant context — cal passar p_tenant_id o x-tenant-id header';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'Forbidden: l''usuari no pertany al tenant %', v_tenant_id;
  END IF;

  SELECT COALESCE(SUM(count), 0)
    INTO v_hour_count
    FROM data.worker_rate_limits
   WHERE tenant_id   = v_tenant_id
     AND window_type = 'hour'
     AND window_start = date_trunc('hour', now());

  SELECT COALESCE(SUM(count), 0)
    INTO v_day_count
    FROM data.worker_rate_limits
   WHERE tenant_id   = v_tenant_id
     AND window_type = 'day'
     AND window_start = date_trunc('day', now());

  RETURN jsonb_build_object(
    'sent_hour', v_hour_count,
    'sent_day',  v_day_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_my_email_usage(uuid) TO authenticated;


-- ============================================================================
-- 3. Feature flag de dominis personalitzats a email_configs
-- ============================================================================

ALTER TABLE data.email_configs
  ADD COLUMN IF NOT EXISTS custom_domains_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS max_custom_domains     integer NOT NULL DEFAULT 1
    CONSTRAINT chk_max_custom_domains CHECK (max_custom_domains >= 1);

COMMENT ON COLUMN data.email_configs.custom_domains_enabled
  IS 'Habilita o deshabilita la funcionalitat de dominis personalitzats per a aquest tenant.';
COMMENT ON COLUMN data.email_configs.max_custom_domains
  IS 'Nombre màxim de dominis personalitzats que pot tenir aquest tenant.';


-- ============================================================================
-- 4. Vista api.email_configs actualitzada (afegeix feature flag dominis)
-- NOTA: serà reemplaçada a 20260427000007 per afegir logo_url i
--       tenant_name_fallback.
-- ============================================================================

DROP VIEW IF EXISTS api.email_configs;

CREATE VIEW api.email_configs
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
    custom_domains_enabled,
    max_custom_domains,
    created_at,
    updated_at,
    metadata
  FROM data.email_configs;

GRANT SELECT, INSERT, UPDATE ON api.email_configs TO authenticated;


-- ============================================================================
-- 5. Trigger: quota de dominis personalitzats (BEFORE INSERT on email_domains)
-- ============================================================================

CREATE OR REPLACE FUNCTION data.check_email_domain_quota()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_enabled boolean;
  v_max     integer;
  v_count   integer;
BEGIN
  SELECT custom_domains_enabled, max_custom_domains
    INTO v_enabled, v_max
    FROM data.email_configs
   WHERE tenant_id = NEW.tenant_id;

  IF NOT FOUND OR v_enabled = false THEN
    RAISE EXCEPTION 'CUSTOM_DOMAINS_DISABLED'
      USING HINT = 'La funcionalitat de dominis personalitzats no està inclosa en el teu pla.';
  END IF;

  SELECT COUNT(*) INTO v_count
    FROM data.email_domains
   WHERE tenant_id = NEW.tenant_id;

  IF v_count >= v_max THEN
    RAISE EXCEPTION 'CUSTOM_DOMAINS_QUOTA_EXCEEDED'
      USING HINT = format(
        'Has arribat al límit de %s domini(s) personalitzat(s) contractat(s).', v_max
      );
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_email_domain_quota
  BEFORE INSERT ON data.email_domains
  FOR EACH ROW
  EXECUTE FUNCTION data.check_email_domain_quota();


-- ============================================================================
-- 6. Trigger: primer domini verificat → primary automàtic
-- ============================================================================

CREATE OR REPLACE FUNCTION data.auto_set_primary_domain()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NEW.verification_status = 'verified'
     AND (OLD.verification_status IS DISTINCT FROM 'verified')
  THEN
    IF NOT EXISTS (
      SELECT 1
        FROM data.email_domains
       WHERE tenant_id = NEW.tenant_id
         AND is_primary = true
         AND id        <> NEW.id
    ) THEN
      NEW.is_primary = true;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_auto_set_primary_domain
  BEFORE UPDATE OF verification_status ON data.email_domains
  FOR EACH ROW
  EXECUTE FUNCTION data.auto_set_primary_domain();


-- ============================================================================
-- 7. Columna is_draft a email_templates
-- ============================================================================

ALTER TABLE data.email_templates
  ADD COLUMN IF NOT EXISTS is_draft boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN data.email_templates.is_draft IS
  'true: esborrany visible a l''editor però no usada per enviar emails. '
  'Permet editar i previsualitzar abans de publicar.';


-- ============================================================================
-- 8. Índexs únics d'activitat (exclouen esborranys)
--
-- Els esborranys poden coexistir amb una plantilla publicada per al mateix
-- (tenant, event_type): el constraint únic s'aplica ONLY als publicats.
-- ============================================================================

-- Un sol template de contingut PUBLICAT actiu per (tenant, event_type)
DROP INDEX IF EXISTS data.idx_email_templates_tenant_event_type;
CREATE UNIQUE INDEX idx_email_templates_tenant_event_type
  ON data.email_templates (tenant_id, event_type)
  WHERE event_type IS NOT NULL
    AND tenant_id  IS NOT NULL
    AND is_layout   = false
    AND is_active   = true
    AND is_draft    = false;

-- Un sol template de plataforma PUBLICAT actiu per event_type
DROP INDEX IF EXISTS data.idx_email_templates_platform_event_type;
CREATE UNIQUE INDEX idx_email_templates_platform_event_type
  ON data.email_templates (event_type)
  WHERE event_type        IS NOT NULL
    AND is_platform_default = true
    AND is_layout           = false
    AND is_active           = true
    AND is_draft            = false;


-- ============================================================================
-- 9. Vista api.email_templates (afegeix is_draft)
-- NOTA: serà reemplaçada a 20260427000007 per afegir translations.
-- ============================================================================

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
    updated_at,
    is_draft
  FROM data.email_templates;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.email_templates TO authenticated;
GRANT SELECT ON api.email_templates TO service_role;
