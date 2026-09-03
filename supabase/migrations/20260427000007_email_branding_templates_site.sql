-- =============================================================================
-- Migració: Email - Branding, Layouts, Plantilles i Overrides de Site
-- =============================================================================
-- Consolida:
--   • 20260427000007 (email_config_logo_storage)  — Columnes logo, bucket, layouts de plataforma
--   • 20260427000008 (email_platform_test)        — Plantilla de prova del sistema
--   • 20260427000009 (email_translations)         — Suport i18n a plantilles
--   • 20260428000001 (email_site_brand)           — Overrides d'email per site (multi-marca)
--   • 20260429000002 (fix_email_layout_color)     — [integrat] Color blanc als layouts de capçalera
--
-- Fixes integrats de layouts:
--   • Layout Professional: <td style="color:#ffffff;"> per al fallback <h1>
--   • Layout Bàsic: {{tenant_name}} → {{logo_html}} amb color:#ffffff al TD
--     (consistència logo/fallback text en fons de color)
--
-- La funció api.enqueue_email d'aquí és la versió final definitiva:
--   is_draft=false, locale (i18n), cascada Site → Tenant → Plataforma.
-- =============================================================================


-- ============================================================================
-- 1. Noves columnes a data.email_configs (logo i nom de marca)
-- ============================================================================

ALTER TABLE data.email_configs
  ADD COLUMN IF NOT EXISTS logo_url             text,
  ADD COLUMN IF NOT EXISTS tenant_name_fallback text;

COMMENT ON COLUMN data.email_configs.logo_url
  IS 'URL pública del logo del tenant (bucket public-assets). Injectada com a {{logo_html}} als layouts.';
COMMENT ON COLUMN data.email_configs.tenant_name_fallback
  IS 'Nom visible del tenant quan no hi ha logo_url. Fallback per a {{logo_html}} als layouts.';


-- ============================================================================
-- 2. Vista api.email_configs (versió final amb totes les columnes)
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
    metadata,
    logo_url,
    tenant_name_fallback
  FROM data.email_configs;

GRANT SELECT, INSERT, UPDATE ON api.email_configs TO authenticated;


-- ============================================================================
-- 3. Bucket d'storage "public-assets" (lectura pública, logos i assets)
-- ============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'public-assets',
  'public-assets',
  true,
  2097152, -- 2 MB màxim per fitxer
  ARRAY['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/svg+xml']
)
ON CONFLICT (id) DO NOTHING;

-- Lectura pública (sense autenticació)
CREATE POLICY "public-assets: lectura pública"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'public-assets');

-- Pujada: path format {tenant_id}/logos/logo.png
CREATE POLICY "public-assets: escriptura per tenant"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'public-assets'
    AND auth.role() = 'authenticated'
    AND split_part(name, '/', 1) IN (
      SELECT unnest(data.my_tenant_ids())::text
    )
  );

-- Actualització (upsert)
CREATE POLICY "public-assets: actualització per tenant"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'public-assets'
    AND auth.role() = 'authenticated'
    AND split_part(name, '/', 1) IN (
      SELECT unnest(data.my_tenant_ids())::text
    )
  )
  WITH CHECK (
    bucket_id = 'public-assets'
    AND auth.role() = 'authenticated'
    AND split_part(name, '/', 1) IN (
      SELECT unnest(data.my_tenant_ids())::text
    )
  );

-- Eliminació
CREATE POLICY "public-assets: eliminació per tenant"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'public-assets'
    AND auth.role() = 'authenticated'
    AND split_part(name, '/', 1) IN (
      SELECT unnest(data.my_tenant_ids())::text
    )
  );


-- ============================================================================
-- 4. Layouts de plataforma (is_platform_default = true)
--
-- {{logo_html}} és pre-computat pel worker:
--   • Si logo_url  → <img src="..." style="max-height:60px;...">
--   • Si no        → <h1 style="margin:0;font-size:22px;font-weight:bold;">nom</h1>
--   • Si no hi ha res → ""
--
-- FIX integrat:
--   • Layout Professional: color:#ffffff al TD de capçalera per llegibilitat
--     del <h1> fallback sobre fons fosc (#1e293b).
--   • Layout Bàsic: {{tenant_name}} → {{logo_html}} amb color:#ffffff al TD
--     perquè el <h1> fallback sigui llegible sobre fons blau (#3b82f6).
-- ============================================================================

INSERT INTO data.email_templates (
  tenant_id, name, slug, event_type,
  subject_template,
  html_body_template,
  text_body_template,
  variables_schema,
  is_layout, layout_id, use_layout,
  is_platform_default, is_active, is_draft
) VALUES

-- Layout 1: Professional (logo a l'esquerra, colors sobris, peu de pàgina complet)
(
  NULL,
  'Layout Professional',
  'platform-layout-professional',
  NULL,
  '',
  '<!DOCTYPE html>
<html lang="ca">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Email</title>
</head>
<body style="margin:0;padding:0;background-color:#f4f4f5;font-family:''Helvetica Neue'',Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background-color:#f4f4f5;padding:32px 0;">
    <tr>
      <td align="center">
        <table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background-color:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,0.08);">

          <!-- Capçalera -->
          <tr>
            <td style="background-color:#1e293b;padding:24px 32px;">
              <table width="100%" cellpadding="0" cellspacing="0">
                <tr>
                  <td style="color:#ffffff;">{{logo_html}}</td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- Contingut principal -->
          <tr>
            <td style="padding:32px;">
              {{content}}
            </td>
          </tr>

          <!-- Peu de pàgina -->
          <tr>
            <td style="background-color:#f8fafc;border-top:1px solid #e2e8f0;padding:20px 32px;text-align:center;">
              <p style="margin:0;font-size:12px;color:#94a3b8;line-height:1.5;">
                Has rebut aquest correu perquè estàs registrat/da a la plataforma.<br>
                © 2025 {{tenant_name}}. Tots els drets reservats.
              </p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>',
  NULL,
  '{"logo_html": "string", "content": "string", "tenant_name": "string"}',
  true, NULL, false,
  true, true, false
),

-- Layout 2: Modern (logo centrat, disseny minimalista, espai blanc generós)
(
  NULL,
  'Layout Modern',
  'platform-layout-modern',
  NULL,
  '',
  '<!DOCTYPE html>
<html lang="ca">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Email</title>
</head>
<body style="margin:0;padding:0;background-color:#ffffff;font-family:''Inter'',''Helvetica Neue'',Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background-color:#ffffff;padding:48px 0;">
    <tr>
      <td align="center">
        <table width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;">

          <!-- Capçalera centrada -->
          <tr>
            <td align="center" style="padding-bottom:40px;">
              {{logo_html}}
            </td>
          </tr>

          <!-- Separador -->
          <tr>
            <td style="border-top:1px solid #f1f5f9;padding-bottom:40px;"></td>
          </tr>

          <!-- Contingut principal -->
          <tr>
            <td style="color:#0f172a;font-size:15px;line-height:1.7;">
              {{content}}
            </td>
          </tr>

          <!-- Peu de pàgina minimalista -->
          <tr>
            <td style="padding-top:48px;border-top:1px solid #f1f5f9;margin-top:48px;text-align:center;">
              <p style="margin:0;font-size:11px;color:#cbd5e1;letter-spacing:0.05em;text-transform:uppercase;">
                {{tenant_name}}
              </p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>',
  NULL,
  '{"logo_html": "string", "content": "string", "tenant_name": "string"}',
  true, NULL, false,
  true, true, false
),

-- Layout 3: Bàsic (capçalera de color sòlid, simple i fiable)
-- FIX: usa {{logo_html}} (logo o <h1> fallback) en lloc de {{tenant_name}}
--      per consistència. El TD té color:#ffffff per herència al <h1> fallback.
(
  NULL,
  'Layout Bàsic',
  'platform-layout-basic',
  NULL,
  '',
  '<!DOCTYPE html>
<html lang="ca">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Email</title>
</head>
<body style="margin:0;padding:0;background-color:#f1f5f9;font-family:Arial,Helvetica,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background-color:#f1f5f9;padding:24px 0;">
    <tr>
      <td align="center">
        <table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background-color:#ffffff;border:1px solid #e2e8f0;">

          <!-- Capçalera de color sòlid (logo o nom de marca) -->
          <tr>
            <td style="background-color:#3b82f6;padding:20px 32px;color:#ffffff;">
              {{logo_html}}
            </td>
          </tr>

          <!-- Contingut principal -->
          <tr>
            <td style="padding:32px;font-size:14px;color:#334155;line-height:1.6;">
              {{content}}
            </td>
          </tr>

          <!-- Peu de pàgina -->
          <tr>
            <td style="background-color:#f8fafc;border-top:1px solid #e2e8f0;padding:16px 32px;text-align:center;">
              <p style="margin:0;font-size:12px;color:#94a3b8;">
                © 2025 {{tenant_name}}
              </p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>',
  NULL,
  '{"logo_html": "string", "content": "string", "tenant_name": "string"}',
  true, NULL, false,
  true, true, false
)

ON CONFLICT (slug) WHERE is_platform_default = true
DO UPDATE SET html_body_template = EXCLUDED.html_body_template;


-- ============================================================================
-- 5. Plantilla de prova del sistema
-- ============================================================================

INSERT INTO data.email_templates (
  tenant_id, name, slug, event_type,
  subject_template, html_body_template, text_body_template,
  variables_schema, is_layout, layout_id, use_layout,
  is_platform_default, is_active, is_draft
) VALUES (
  NULL,
  'Correu de prova del sistema',
  'platform-test-email',
  'test-email',
  'Correu de prova — {{app_name}}',
  '<p>Hola!</p><p>Això és un correu de prova de <strong>{{app_name}}</strong> per verificar que la teva infraestructura de correu i els layouts funcionen correctament.</p><p>Tot està llest per començar a enviar!</p>',
  'Hola! Això és un correu de prova de {{app_name}} per verificar que la teva infraestructura de correu funciona correctament. Tot està llest per començar a enviar!',
  '{"app_name": "string"}',
  false, NULL, true,
  true, true, false
)
ON CONFLICT (event_type)
  WHERE event_type IS NOT NULL
    AND is_platform_default = true
    AND is_layout = false
    AND is_active = true
    AND is_draft = false
DO NOTHING;


-- ============================================================================
-- 6. Columna translations a email_templates (suport i18n)
-- ============================================================================

ALTER TABLE data.email_templates
  ADD COLUMN IF NOT EXISTS translations jsonb NOT NULL DEFAULT '{}'::jsonb;


-- ============================================================================
-- 7. Vista api.email_templates (versió final: is_draft + translations)
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
    is_draft,
    translations
  FROM data.email_templates;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.email_templates TO authenticated;
GRANT SELECT ON api.email_templates TO service_role;


-- ============================================================================
-- 8. Traduccions inicials de la plantilla de prova
-- ============================================================================

UPDATE data.email_templates
SET translations = '{
  "es": {
    "subject": "Correo de prueba — {{app_name}}",
    "html": "<p>¡Hola!</p><p>Este es un correo de prueba de <strong>{{app_name}}</strong> para verificar que tu infraestructura de correo y los layouts funcionan correctamente.</p><p>¡Todo listo para empezar a enviar!</p>",
    "text": "¡Hola! Este es un correo de prueba de {{app_name}} para verificar que tu infraestructura de correo funciona correctamente. ¡Todo listo para empezar a enviar!"
  },
  "en": {
    "subject": "Test email — {{app_name}}",
    "html": "<p>Hello!</p><p>This is a test email from <strong>{{app_name}}</strong> to verify that your email infrastructure and layouts are working correctly.</p><p>All set to start sending!</p>",
    "text": "Hello! This is a test email from {{app_name}} to verify that your email infrastructure is working correctly. All set to start sending!"
  }
}'::jsonb
WHERE slug = 'platform-test-email'
  AND is_platform_default = true;


-- ============================================================================
-- 9. Columnes d'email a data.sites (overrides per site / multi-marca)
-- ============================================================================

ALTER TABLE data.sites
  ADD COLUMN IF NOT EXISTS email_from_name            text,
  ADD COLUMN IF NOT EXISTS email_reply_to             text,
  ADD COLUMN IF NOT EXISTS email_logo_url             text,
  ADD COLUMN IF NOT EXISTS email_tenant_name_fallback text,
  ADD COLUMN IF NOT EXISTS default_email_layout_id    uuid
    REFERENCES data.email_templates(id) ON DELETE SET NULL;

COMMENT ON COLUMN data.sites.email_from_name
  IS 'Nom del remitent específic d''aquest site (sobreescriu email_configs.default_from_name)';
COMMENT ON COLUMN data.sites.email_reply_to
  IS 'Adreça Reply-To específica d''aquest site';
COMMENT ON COLUMN data.sites.email_logo_url
  IS 'URL del logo de la marca (sub-marca) per a emails d''aquest site';
COMMENT ON COLUMN data.sites.email_tenant_name_fallback
  IS 'Nom de la marca/site (fallback textual quan no hi ha logo)';
COMMENT ON COLUMN data.sites.default_email_layout_id
  IS 'Layout per defecte per a correus d''aquest site (sobreescriu email_configs.default_layout_id)';


-- ============================================================================
-- 10. Vista api.sites actualitzada (exposa columnes email del site)
-- ============================================================================

DROP VIEW IF EXISTS api.sites;

CREATE VIEW api.sites
  WITH (security_invoker = true) AS
  SELECT
    s.id,
    s.tenant_id,
    s.name,
    s.address,
    s.is_active,
    s.metadata,
    s.email_from_name,
    s.email_reply_to,
    s.email_logo_url,
    s.email_tenant_name_fallback,
    s.default_email_layout_id,
    s.created_at,
    s.updated_at
  FROM data.sites s;

GRANT SELECT, INSERT, UPDATE ON api.sites TO authenticated;


-- ============================================================================
-- 11. api.enqueue_email — versió final definitiva
--
-- Funcionalitats incloses:
--   • Cascada de remitent: payload → sender_profile → site → domini → tenant → plataforma
--   • Resolució de plantilles: event_type → slug → template_id → inline
--   • Salta plantilles en esborrany (is_draft = false)
--   • Locale (i18n): llegit del payload, emmagatzemat a metadata per al worker
--   • Resolució de layout: template → site → tenant (cascada de 3 nivells)
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
      -- A2: te domini primary verificat
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
      -- B2: domini verificat → cascada completa
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

  -- ── Netejar espais en blanc: " <email>" seria invàlid per Resend ──
  v_from_name := NULLIF(BTRIM(v_from_name), '');

  -- ── NOTA: Rate Limits NO es comproven aqui. ──
  -- Els camps rate_limit_per_hour/day d'email_configs son llegits pel Worker
  -- (egress throttling). La ingesta accepta correus a maxima velocitat.

  -- ════════════════════════════════════════════════════════════════════════
  -- RESOLUCIO DE LA PLANTILLA
  -- Prioritat: event_type → template_slug → template_id (UUID) → inline
  -- En cada cas: plantilla publicada del tenant → fallback a plataforma.
  -- Les plantilles en esborrany (is_draft = true) ES SALTEN.
  -- ════════════════════════════════════════════════════════════════════════

  v_template_id   := (payload ->> 'template_id')::uuid;
  v_template_slug := payload ->> 'template_slug';
  v_event_type    := payload ->> 'event_type';
  v_subject       := payload ->> 'subject';

  -- 1. Cerca per event_type
  IF v_event_type IS NOT NULL AND v_template_id IS NULL THEN
    -- Primer: plantilla publicada del tenant
    SELECT * INTO v_template_row
    FROM data.email_templates
    WHERE tenant_id  = v_tenant_id
      AND event_type = v_event_type
      AND is_layout  = false
      AND is_active  = true
      AND is_draft   = false
    LIMIT 1;

    -- Fallback: plantilla publicada de plataforma
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
    -- Primer: plantilla publicada del tenant
    SELECT * INTO v_template_row
    FROM data.email_templates
    WHERE tenant_id = v_tenant_id
      AND slug      = v_template_slug
      AND is_layout = false
      AND is_active = true
      AND is_draft  = false
    LIMIT 1;

    -- Fallback: plantilla publicada de plataforma
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
  END IF;

  -- ── Inserir a email_logs (idempotent) ──
  -- NOTA: El locale es funde amb el metadata del payload perquè el Worker
  -- el pugui recuperar i aplicar la traducció correcta en render time.
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

GRANT EXECUTE ON FUNCTION api.enqueue_email(jsonb) TO authenticated;
