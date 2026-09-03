-- =============================================================================
-- Migració: Corregeix plantilla email confirmació lead (portal públic)
-- Número:   20260515000013
-- Motiu:
--   1. Claus de traduccions: el motor d'email espera "subject"/"html"/"text",
--      però la migració anterior usava "subject_template"/"html_body_template"/
--      "text_body_template". El worker llegeix exactament subject/html/text.
--   2. Sintaxi {{#if}}: el motor de templates només suporta substitució simple
--      {{key}}. Els blocs condicionals {{#if message}}...{{/if}} es treuen.
--      El worker pre-construeix el bloc HTML/text i l'injecta com {{message_block}}
--      i {{message_block_text}} (buit si el lead no ha deixat missatge).
-- =============================================================================

UPDATE data.email_templates
SET
  -- Plantilla base (ca) — sense condicionals
  html_body_template = '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{name}}</strong>,</p>
<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  Hem rebut el teu missatge a través del nostre portal. Ens posarem en contacte amb tu el més aviat possible.
</p>
{{message_block}}
<p style="font-size:14px;color:#6b7280;margin:16px 0 0;">
  Si tens qualsevol dubte, pots contactar-nos directament a
  <a href="mailto:{{contact_email}}" style="color:#3b82f6;text-decoration:none;">{{contact_email}}</a>.
</p>',

  text_body_template = 'Hola, {{name}},

Hem rebut el teu missatge a través del nostre portal. Ens posarem en contacte amb tu el més aviat possible.

{{message_block_text}}Si tens qualsevol dubte, pots contactar-nos a: {{contact_email}}',

  -- Actualitza l''esquema de variables per reflectir les noves claus
  variables_schema = '{
    "name": "string",
    "message_block": "string",
    "message_block_text": "string",
    "contact_email": "string"
  }'::jsonb,

  -- Traduccions amb les claus correctes (subject/html/text, no *_template)
  translations = jsonb_build_object(
    'es', jsonb_build_object(
      'subject', 'Hemos recibido tu mensaje, {{name}}',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{name}}</strong>,</p>
<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  Hemos recibido tu mensaje a través de nuestro portal. Nos pondremos en contacto contigo lo antes posible.
</p>
{{message_block}}
<p style="font-size:14px;color:#6b7280;margin:16px 0 0;">
  Si tienes alguna duda, puedes contactarnos directamente en
  <a href="mailto:{{contact_email}}" style="color:#3b82f6;text-decoration:none;">{{contact_email}}</a>.
</p>',
      'text', 'Hola, {{name}},

Hemos recibido tu mensaje a través de nuestro portal. Nos pondremos en contacto contigo lo antes posible.

{{message_block_text}}Si tienes alguna duda, puedes contactarnos en: {{contact_email}}'
    ),
    'en', jsonb_build_object(
      'subject', 'We received your message, {{name}}',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hi, <strong>{{name}}</strong>,</p>
<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  We have received your message through our portal. We will get back to you as soon as possible.
</p>
{{message_block}}
<p style="font-size:14px;color:#6b7280;margin:16px 0 0;">
  If you have any questions, you can contact us directly at
  <a href="mailto:{{contact_email}}" style="color:#3b82f6;text-decoration:none;">{{contact_email}}</a>.
</p>',
      'text', 'Hi, {{name}},

We have received your message through our portal. We will get back to you as soon as possible.

{{message_block_text}}If you have any questions, please contact us at: {{contact_email}}'
    )
  )
WHERE slug = 'portal-lead-submitted-confirmation'
  AND is_platform_default = true;
