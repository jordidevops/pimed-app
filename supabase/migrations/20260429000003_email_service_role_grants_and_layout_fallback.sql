-- =============================================================================
-- Fix: grants de service_role sobre api.* usades pel worker + fallback de layout
-- =============================================================================
--
-- Problema 1: el worker (Edge Function, service_role) no pot llegir api.email_configs
--   ni api.email_templates ni api.sites perquè els GRANTs eren only per a 'authenticated'.
--   Resultat: logo_url i tenant_name_fallback retornaven NULL → cap logo als correus.
--
-- Problema 2: api.enqueue_email no tenia fallback de layout de plataforma.
--   Si email_configs.default_layout_id = NULL i la plantilla té use_layout = true,
--   cap layout s'aplicava → cap {{logo_html}} → logos invisibles als emails.
--
-- Fixes:
--   1. GRANT SELECT sobre les tres vistes al rol service_role
--   2. api.enqueue_email: fallback al primer layout de plataforma actiu quan
--      cap nivell (template → site → tenant) no ha configurat cap layout
-- =============================================================================


-- ============================================================================
-- 1. Grants per a service_role (worker / Edge Functions via adminClient)
-- ============================================================================

-- api.email_configs: logo_url, tenant_name_fallback, rate limits
GRANT SELECT ON api.email_configs TO service_role;

-- api.email_templates: plantilles de layout usades pel worker
GRANT SELECT ON api.email_templates TO service_role;

-- api.sites: email_logo_url, email_tenant_name_fallback (overrides per site)
GRANT SELECT ON api.sites TO service_role;


-- ============================================================================
-- 2. Actualitzar api.enqueue_email: afegir fallback de layout de plataforma
--
-- Canvi respecte a la versió anterior (20260427000007):
--   Afegit bloc "IF v_layout_id IS NULL" just després del COALESCE del layout,
--   que busca el primer layout de plataforma actiu com a fallback universal.
-- ============================================================================

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
  v_site_row           data.sites%ROWTYPE;
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
  -- Locale (i18n)
  v_locale             text;
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
  v_locale              := COALESCE(payload ->> 'locale', 'ca');

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

  -- ── Carregar configuracio del site (si aplica) ──
  IF v_site_id IS NOT NULL THEN
    SELECT * INTO v_site_row FROM data.sites WHERE id = v_site_id;
  END IF;

  -- ── Resoldre Sender Profile (si n'hi ha) ──
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
  -- Prioritat: payload → sender_profile → site → domini → tenant → plataforma
  -- ════════════════════════════════════════════════════════════════════════

  IF v_from_email IS NULL THEN
    SELECT * INTO v_primary_domain
    FROM data.email_domains
    WHERE tenant_id = v_tenant_id
      AND is_primary = true
      AND verification_status = 'verified'
    LIMIT 1;

    IF v_primary_domain IS NULL THEN
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
        v_site_row.email_from_name,
        v_config.default_from_name,
        v_platform_settings ->> 'platform_default_from_name'
      );
      v_reply_to := COALESCE(
        payload ->> 'reply_to',
        v_profile_reply_to,
        v_site_row.email_reply_to,
        v_config.default_reply_to
      );

    ELSE
      v_from_email := COALESCE(
        v_primary_domain.default_from_email,
        'noreply@' || v_primary_domain.domain
      );
      v_from_name := COALESCE(
        payload ->> 'from_name',
        v_profile_from_name,
        v_site_row.email_from_name,
        v_primary_domain.default_from_name,
        v_config.default_from_name,
        v_platform_settings ->> 'platform_default_from_name'
      );
      v_reply_to := COALESCE(
        payload ->> 'reply_to',
        v_profile_reply_to,
        v_site_row.email_reply_to,
        v_primary_domain.default_reply_to,
        v_config.default_reply_to
      );
    END IF;

  ELSE
    v_domain := split_part(v_from_email, '@', 2);

    SELECT * INTO v_domain_config
    FROM data.email_domains
    WHERE tenant_id = v_tenant_id
      AND domain = v_domain
      AND verification_status = 'verified'
    LIMIT 1;

    IF v_domain_config IS NULL THEN
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
        v_site_row.email_from_name,
        v_config.default_from_name,
        v_platform_settings ->> 'platform_default_from_name'
      );
      v_reply_to := COALESCE(
        payload ->> 'reply_to',
        v_profile_reply_to,
        v_site_row.email_reply_to,
        v_config.default_reply_to
      );

    ELSE
      v_from_name := COALESCE(
        payload ->> 'from_name',
        v_profile_from_name,
        v_site_row.email_from_name,
        v_domain_config.default_from_name,
        v_config.default_from_name,
        v_platform_settings ->> 'platform_default_from_name'
      );
      v_reply_to := COALESCE(
        payload ->> 'reply_to',
        v_profile_reply_to,
        v_site_row.email_reply_to,
        v_domain_config.default_reply_to,
        v_config.default_reply_to
      );
    END IF;
  END IF;

  v_from_name := NULLIF(BTRIM(v_from_name), '');

  -- ════════════════════════════════════════════════════════════════════════
  -- RESOLUCIO DE LA PLANTILLA
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
      AND is_draft   = false
    LIMIT 1;

    IF v_template_row.id IS NULL THEN
      SELECT * INTO v_template_row
      FROM data.email_templates
      WHERE is_platform_default = true
        AND event_type = v_event_type
        AND is_layout  = false
        AND is_active  = true
        AND is_draft   = false
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
      AND is_draft  = false
    LIMIT 1;

    IF v_template_row.id IS NULL THEN
      SELECT * INTO v_template_row
      FROM data.email_templates
      WHERE is_platform_default = true
        AND slug      = v_template_slug
        AND is_layout = false
        AND is_active = true
        AND is_draft  = false
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
      AND is_active = true
      AND is_draft  = false;

    IF v_template_row.id IS NULL THEN
      RAISE EXCEPTION
        'Plantilla % no trobada, no accessible o en estat esborrany per al tenant %',
        v_template_id, v_tenant_id;
    END IF;
  END IF;

  -- 4. Inline: cal "subject" si no hi ha plantilla
  IF v_template_id IS NULL AND v_subject IS NULL THEN
    RAISE EXCEPTION
      'Cal indicar "event_type", "template_slug", "template_id" o "subject" (contingut directe)';
  END IF;

  -- ── Resolucio del layout (cascada: template → site → tenant) ──
  IF v_template_row.id IS NOT NULL AND v_template_row.use_layout = true THEN
    v_layout_id := COALESCE(
      v_template_row.layout_id,
      v_site_row.default_email_layout_id,
      v_config.default_layout_id
    );

    -- Fallback: si cap nivell ha configurat layout, usar el primer layout de plataforma actiu.
    -- Garanteix que les plantilles amb use_layout=true sempre tinguin un layout aplicat.
    IF v_layout_id IS NULL THEN
      SELECT id INTO v_layout_id
      FROM data.email_templates
      WHERE is_platform_default = true
        AND is_layout           = true
        AND is_active           = true
      ORDER BY created_at
      LIMIT 1;
    END IF;
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
    COALESCE(payload -> 'metadata', '{}') || jsonb_build_object('locale', v_locale),
    CASE WHEN payload ? 'tags' THEN ARRAY(SELECT jsonb_array_elements_text(payload -> 'tags')) END,
    v_scheduled_at,
    v_layout_id
  )
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_log_id;

  IF v_log_id IS NULL THEN
    SELECT id INTO v_log_id
    FROM data.email_logs
    WHERE tenant_id = v_tenant_id AND idempotency_key = v_idempotency_key;
    RETURN v_log_id;
  END IF;

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

GRANT EXECUTE ON FUNCTION api.enqueue_email(jsonb) TO authenticated;
