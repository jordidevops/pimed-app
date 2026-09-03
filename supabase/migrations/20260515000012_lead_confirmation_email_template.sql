-- =============================================================================
-- Migració: Plantilla email confirmació de lead del portal públic
-- Número:   20260515000012
-- Patró:    Plantilla de plataforma (tenant_id NULL, is_platform_default = true)
--           event_type = 'portal.lead_submitted_confirmation'
--           Base: català (ca) + translations jsonb per a es/en
-- =============================================================================

INSERT INTO data.email_templates (
  tenant_id,
  name,
  slug,
  event_type,
  subject_template,
  html_body_template,
  text_body_template,
  variables_schema,
  translations,
  is_layout,
  layout_id,
  use_layout,
  is_platform_default,
  is_active,
  is_draft
)
VALUES (
  NULL,
  'Confirmació de contacte rebut (Portal Públic)',
  'portal-lead-submitted-confirmation',
  'portal.lead_submitted_confirmation',

  -- Assumpte base (català)
  'Hem rebut el teu missatge, {{name}}',

  -- Cos HTML base (català)
  '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{name}}</strong>,</p>

<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  Hem rebut el teu missatge a través del nostre portal. Ens posarem en contacte amb tu el més aviat possible.
</p>

{{#if message}}
<div style="background:#f9fafb;border-left:4px solid #e5e7eb;padding:12px 16px;margin:16px 0;border-radius:0 4px 4px 0;">
  <p style="font-size:13px;color:#6b7280;margin:0 0 4px;font-weight:600;">El teu missatge:</p>
  <p style="font-size:14px;color:#374151;margin:0;white-space:pre-wrap;">{{message}}</p>
</div>
{{/if}}

<p style="font-size:14px;color:#6b7280;margin:16px 0 0;">
  Si tens qualsevol dubte, pots contactar-nos directament a
  <a href="mailto:{{contact_email}}" style="color:#3b82f6;text-decoration:none;">{{contact_email}}</a>.
</p>',

  -- Cos text pla (català)
  'Hola, {{name}},

Hem rebut el teu missatge a través del nostre portal. Ens posarem en contacte amb tu el més aviat possible.

{{#if message}}El teu missatge:
{{message}}

{{/if}}Si tens qualsevol dubte, pots contactar-nos a: {{contact_email}}',

  -- Esquema de variables
  '{"name": "string", "message": "string", "contact_email": "string"}'::jsonb,

  -- Traduccions jsonb (castellà i anglès)
  jsonb_build_object(
    'es', jsonb_build_object(
      'subject_template', 'Hemos recibido tu mensaje, {{name}}',
      'html_body_template', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{name}}</strong>,</p>

<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  Hemos recibido tu mensaje a través de nuestro portal. Nos pondremos en contacto contigo lo antes posible.
</p>

{{#if message}}
<div style="background:#f9fafb;border-left:4px solid #e5e7eb;padding:12px 16px;margin:16px 0;border-radius:0 4px 4px 0;">
  <p style="font-size:13px;color:#6b7280;margin:0 0 4px;font-weight:600;">Tu mensaje:</p>
  <p style="font-size:14px;color:#374151;margin:0;white-space:pre-wrap;">{{message}}</p>
</div>
{{/if}}

<p style="font-size:14px;color:#6b7280;margin:16px 0 0;">
  Si tienes alguna duda, puedes contactarnos directamente en
  <a href="mailto:{{contact_email}}" style="color:#3b82f6;text-decoration:none;">{{contact_email}}</a>.
</p>',
      'text_body_template', 'Hola, {{name}},

Hemos recibido tu mensaje a través de nuestro portal. Nos pondremos en contacto contigo lo antes posible.

{{#if message}}Tu mensaje:
{{message}}

{{/if}}Si tienes alguna duda, puedes contactarnos en: {{contact_email}}'
    ),
    'en', jsonb_build_object(
      'subject_template', 'We received your message, {{name}}',
      'html_body_template', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hi, <strong>{{name}}</strong>,</p>

<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  We have received your message through our portal. We will get back to you as soon as possible.
</p>

{{#if message}}
<div style="background:#f9fafb;border-left:4px solid #e5e7eb;padding:12px 16px;margin:16px 0;border-radius:0 4px 4px 0;">
  <p style="font-size:13px;color:#6b7280;margin:0 0 4px;font-weight:600;">Your message:</p>
  <p style="font-size:14px;color:#374151;margin:0;white-space:pre-wrap;">{{message}}</p>
</div>
{{/if}}

<p style="font-size:14px;color:#6b7280;margin:16px 0 0;">
  If you have any questions, you can contact us directly at
  <a href="mailto:{{contact_email}}" style="color:#3b82f6;text-decoration:none;">{{contact_email}}</a>.
</p>',
      'text_body_template', 'Hi, {{name}},

We have received your message through our portal. We will get back to you as soon as possible.

{{#if message}}Your message:
{{message}}

{{/if}}If you have any questions, please contact us at: {{contact_email}}'
    )
  ),

  -- Configuració
  false,  -- is_layout: NO és un layout, és contingut
  NULL,   -- layout_id: usa el layout de la config del tenant (si en té)
  true,   -- use_layout: sí, aplica layout si el tenant en té un configurat
  true,   -- is_platform_default
  true,   -- is_active
  false   -- is_draft: llesta per a producció
)
ON CONFLICT DO NOTHING;
