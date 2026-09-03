-- Migration: 20260604000000_seed_email_templates.sql
-- Consolidació de dades llavor (seeds) per a plantilles de correu electrònic.
-- Aquestes plantilles usen sintaxi LiquidJS ({% if %}, {{ var }}) i són 
-- les que el sistema carrega per defecte per a la plataforma.

-- ────────────────────────────────────────────────────────────────────────────
-- signing.request.initial — primer email al signer #1
-- ────────────────────────────────────────────────────────────────────────────
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
) VALUES (
  NULL,
  'Sol·licitud de signatura de document',
  'signing-request-initial',
  'signing.request.initial',

  -- Assumpte base (català)
  '{{document_title}} — Signatura requerida',

  -- Cos HTML (català)
  '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{signer_name}}</strong>,</p>

<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  T''han sol·licitat que signis el document <strong>{{document_title}}</strong>.
</p>

{% if signer_role %}
<p style="font-size:14px;color:#6b7280;margin:0 0 12px;">
  El teu rol: <strong>{{signer_role}}</strong>{% if total_signers %} (signant {{current_order}} de {{total_signers}}){% endif %}
</p>
{% endif %}

<div style="margin:24px 0;">
  <a href="{{signing_url}}"
     style="background:#3b82f6;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-size:15px;font-weight:600;display:inline-block;">
    Signar document
  </a>
</div>

<p style="font-size:13px;color:#9ca3af;margin:16px 0 0;">
  Si el botó no funciona, copia aquesta adreça al navegador:<br>
  <a href="{{signing_url}}" style="color:#6b7280;word-break:break-all;">{{signing_url}}</a>
</p>',

  -- Cos text pla (català)
  'Hola, {{signer_name}},

T''han sol·licitat que signis el document: {{document_title}}
{% if signer_role %}Rol: {{signer_role}}{% if total_signers %} (signant {{current_order}} de {{total_signers}}){% endif %}
{% endif %}
Accedeix aquí per signar:
{{signing_url}}',

  -- Esquema de variables
  '{"signer_name":"string","signer_email":"string","signer_role":"string","document_title":"string","signing_url":"string","current_order":"number","total_signers":"number"}'::jsonb,

  -- Traduccions (castellà + anglès)
  jsonb_build_object(
    'es', jsonb_build_object(
      'subject', '{{document_title}} — Firma requerida',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{signer_name}}</strong>,</p><p style="font-size:15px;color:#374151;margin:0 0 12px;">Se te ha solicitado que firmes el documento <strong>{{document_title}}</strong>.</p>{% if signer_role %}<p style="font-size:14px;color:#6b7280;margin:0 0 12px;">Tu rol: <strong>{{signer_role}}</strong>{% if total_signers %} (firmante {{current_order}} de {{total_signers}}){% endif %}</p>{% endif %}<div style="margin:24px 0;"><a href="{{signing_url}}" style="background:#3b82f6;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-size:15px;font-weight:600;display:inline-block;">Firmar documento</a></div><p style="font-size:13px;color:#9ca3af;margin:16px 0 0;">Si el botón no funciona, copia esta dirección en el navegador:<br><a href="{{signing_url}}" style="color:#6b7280;word-break:break-all;">{{signing_url}}</a></p>',
      'text', E'Hola, {{signer_name}},\n\nSe te ha solicitado que firmes el documento: {{document_title}}\n{% if signer_role %}Rol: {{signer_role}}{% if total_signers %} (firmante {{current_order}} de {{total_signers}}){% endif %}\n{% endif %}\nAccede aquí para firmar:\n{{signing_url}}'
    ),
    'en', jsonb_build_object(
      'subject', '{{document_title}} — Signature required',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hello, <strong>{{signer_name}}</strong>,</p><p style="font-size:15px;color:#374151;margin:0 0 12px;">You have been requested to sign the document <strong>{{document_title}}</strong>.</p>{% if signer_role %}<p style="font-size:14px;color:#6b7280;margin:0 0 12px;">Your role: <strong>{{signer_role}}</strong>{% if total_signers %} (signer {{current_order}} of {{total_signers}}){% endif %}</p>{% endif %}<div style="margin:24px 0;"><a href="{{signing_url}}" style="background:#3b82f6;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-size:15px;font-weight:600;display:inline-block;">Sign document</a></div><p style="font-size:13px;color:#9ca3af;margin:16px 0 0;">If the button does not work, copy this address into your browser:<br><a href="{{signing_url}}" style="color:#6b7280;word-break:break-all;">{{signing_url}}</a></p>',
      'text', E'Hello, {{signer_name}},\n\nYou have been requested to sign the document: {{document_title}}\n{% if signer_role %}Role: {{signer_role}}{% if total_signers %} (signer {{current_order}} of {{total_signers}}){% endif %}\n{% endif %}\nAccess here to sign:\n{{signing_url}}'
    )
  ),
  false,   -- is_layout
  NULL,    -- layout_id (es resol automàticament per tenant)
  true,    -- use_layout
  true,    -- is_platform_default
  true,    -- is_active
  false    -- is_draft
)
ON CONFLICT (slug) WHERE is_platform_default = true DO UPDATE SET
  subject_template    = EXCLUDED.subject_template,
  html_body_template  = EXCLUDED.html_body_template,
  text_body_template  = EXCLUDED.text_body_template,
  variables_schema    = EXCLUDED.variables_schema,
  translations        = EXCLUDED.translations,
  updated_at          = now();


-- ────────────────────────────────────────────────────────────────────────────
-- signing.request.next_signer — email seqüencial per signants posteriors
-- ────────────────────────────────────────────────────────────────────────────
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
) VALUES (
  NULL,
  'Sol·licitud de signatura (pendent vostre)',
  'signing-request-next-signer',
  'signing.request.next_signer',

  -- Assumpte base (català)
  '{{document_title}} — El torn és vostre per signar',

  -- Cos HTML (català)
  '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{signer_name}}</strong>,</p>

<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  El signant anterior ha completat la seva signatura del document <strong>{{document_title}}</strong>.
  Ara et toca a tu.
</p>

{% if signer_role %}
<p style="font-size:14px;color:#6b7280;margin:0 0 12px;">
  El teu rol: <strong>{{signer_role}}</strong>{% if total_signers %} (signant {{current_order}} de {{total_signers}}){% endif %}
</p>
{% endif %}

<div style="margin:24px 0;">
  <a href="{{signing_url}}"
     style="background:#3b82f6;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-size:15px;font-weight:600;display:inline-block;">
    Signar document
  </a>
</div>

<p style="font-size:13px;color:#9ca3af;margin:16px 0 0;">
  Si el botó no funciona, copia aquesta adreça al navegador:<br>
  <a href="{{signing_url}}" style="color:#6b7280;word-break:break-all;">{{signing_url}}</a>
</p>',

  -- Cos text pla (català)
  'Hola, {{signer_name}},

El signant anterior ha completat la signatura de {{document_title}}. Ara et toca a tu.
{% if signer_role %}Rol: {{signer_role}}{% if total_signers %} (signant {{current_order}} de {{total_signers}}){% endif %}
{% endif %}
Accedeix aquí per signar:
{{signing_url}}',

  -- Esquema de variables
  '{"signer_name":"string","signer_email":"string","signer_role":"string","document_title":"string","signing_url":"string","current_order":"number","total_signers":"number"}'::jsonb,

  -- Traduccions (castellà + anglès)
  jsonb_build_object(
    'es', jsonb_build_object(
      'subject', '{{document_title}} — Le toca firmar',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{signer_name}}</strong>,</p><p style="font-size:15px;color:#374151;margin:0 0 12px;">El firmante anterior ha completado su firma del documento <strong>{{document_title}}</strong>. Ahora le toca a usted.</p>{% if signer_role %}<p style="font-size:14px;color:#6b7280;margin:0 0 12px;">Su rol: <strong>{{signer_role}}</strong>{% if total_signers %} (firmante {{current_order}} de {{total_signers}}){% endif %}</p>{% endif %}<div style="margin:24px 0;"><a href="{{signing_url}}" style="background:#3b82f6;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-size:15px;font-weight:600;display:inline-block;">Firmar documento</a></div><p style="font-size:13px;color:#9ca3af;margin:16px 0 0;">Si el botón no funciona, copia esta dirección en el navegador:<br><a href="{{signing_url}}" style="color:#6b7280;word-break:break-all;">{{signing_url}}</a></p>',
      'text', E'Hola, {{signer_name}},\n\nEl firmante anterior ha completado su firma de {{document_title}}. Ahora le toca a usted.\n{% if signer_role %}Rol: {{signer_role}}{% if total_signers %} (firmante {{current_order}} de {{total_signers}}){% endif %}\n{% endif %}\nAcceda aquí para firmar:\n{{signing_url}}'
    ),
    'en', jsonb_build_object(
      'subject', '{{document_title}} — Your turn to sign',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hello, <strong>{{signer_name}}</strong>,</p><p style="font-size:15px;color:#374151;margin:0 0 12px;">The previous signer has completed their signature of <strong>{{document_title}}</strong>. Now it is your turn.</p>{% if signer_role %}<p style="font-size:14px;color:#6b7280;margin:0 0 12px;">Your role: <strong>{{signer_role}}</strong>{% if total_signers %} (signer {{current_order}} of {{total_signers}}){% endif %}</p>{% endif %}<div style="margin:24px 0;"><a href="{{signing_url}}" style="background:#3b82f6;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-size:15px;font-weight:600;display:inline-block;">Sign document</a></div><p style="font-size:13px;color:#9ca3af;margin:16px 0 0;">If the button does not work, copy this address into your browser:<br><a href="{{signing_url}}" style="color:#6b7280;word-break:break-all;">{{signing_url}}</a></p>',
      'text', E'Hello, {{signer_name}},\n\nThe previous signer has completed their signature of {{document_title}}. Now it is your turn.\n{% if signer_role %}Role: {{signer_role}}{% if total_signers %} (signer {{current_order}} of {{total_signers}}){% endif %}\n{% endif %}\nAccess here to sign:\n{{signing_url}}'
    )
  ),
  false,   -- is_layout
  NULL,    -- layout_id
  true,    -- use_layout
  true,    -- is_platform_default
  true,    -- is_active
  false    -- is_draft
)
ON CONFLICT (slug) WHERE is_platform_default = true DO UPDATE SET
  subject_template    = EXCLUDED.subject_template,
  html_body_template  = EXCLUDED.html_body_template,
  text_body_template  = EXCLUDED.text_body_template,
  variables_schema    = EXCLUDED.variables_schema,
  translations        = EXCLUDED.translations,
  updated_at          = now();
