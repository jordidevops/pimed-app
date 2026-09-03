-- Dev/local: enqueue_email requereix platform_default_domain quan el tenant no té dominis verificats.
-- Resend permet onboarding@resend.dev per proves (veure docs/email.md).

UPDATE data.system_settings
SET settings = settings || jsonb_build_object(
  'platform_default_domain',     COALESCE(NULLIF(settings->>'platform_default_domain', ''), 'mail.cavalle.dev'),
  'platform_default_from_email', COALESCE(NULLIF(settings->>'platform_default_from_email', ''), 'noreply@mail.cavalle.dev'),
  'platform_default_from_name',  COALESCE(NULLIF(settings->>'platform_default_from_name', ''), 'La Meva Plataforma')
),
updated_at = now()
WHERE module = 'email'
  AND (
    settings->>'platform_default_domain' IS NULL
    OR settings->>'platform_default_domain' = ''
  );
