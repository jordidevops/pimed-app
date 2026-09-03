-- =============================================================================
-- EX-09.2 — Plantilla email accés inspecció
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
  'Accés inspecció control horari',
  'attendance-inspection-access',
  'attendance.inspection_access',
  'Accés temporal al registre horari — {{employee_name}}',
  '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Bon dia,</p>

<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  <strong>{{tenant_name}}</strong> us facilita un enllaç temporal per consultar el registre horari
  (fitxatges reals i consolidats) de <strong>{{employee_name}}</strong>
  del <strong>{{period_from}}</strong> al <strong>{{period_to}}</strong>.
</p>

<p style="text-align:center;margin:24px 0;">
  <a href="{{inspection_url}}" style="display:inline-block;background:#1f2937;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:8px;font-weight:600;">
    Obrir el registre
  </a>
</p>

<p style="font-size:13px;color:#6b7280;margin:0 0 8px;word-break:break-all;">
  O copia aquest enllaç: <a href="{{inspection_url}}" style="color:#2563eb;">{{inspection_url}}</a>
</p>

<p style="font-size:13px;color:#6b7280;margin:16px 0 0;">
  L''enllaç caduca el <strong>{{expires_at}}</strong>. Qui el tingui pot veure les dades fins a la caducitat o fins que es revoqui.
</p>

<p style="font-size:14px;color:#6b7280;margin:24px 0 0;">
  Si teniu dubtes, contacteu
  <a href="mailto:{{support_email}}" style="color:#3b82f6;text-decoration:none;">{{support_email}}</a>.
</p>',
  'Bon dia,

{{tenant_name}} facilita un enllaç temporal al registre horari de {{employee_name}}
(del {{period_from}} al {{period_to}}).

Enllaç: {{inspection_url}}
Caduca: {{expires_at}}

Dubtes: {{support_email}}',
  '{"employee_name":"string","tenant_name":"string","period_from":"string","period_to":"string","expires_at":"string","inspection_url":"string","support_email":"string"}'::jsonb,
  jsonb_build_object(
    'es', jsonb_build_object(
      'subject', 'Acceso temporal al registro horario — {{employee_name}}',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Buenos días,</p><p style="font-size:15px;color:#374151;margin:0 0 12px;"><strong>{{tenant_name}}</strong> facilita un enlace temporal al registro horario (fichajes reales y consolidados) de <strong>{{employee_name}}</strong> del <strong>{{period_from}}</strong> al <strong>{{period_to}}</strong>.</p><p style="text-align:center;margin:24px 0;"><a href="{{inspection_url}}" style="display:inline-block;background:#1f2937;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:8px;font-weight:600;">Abrir el registro</a></p><p style="font-size:13px;color:#6b7280;margin:0 0 8px;word-break:break-all;">Enlace: <a href="{{inspection_url}}" style="color:#2563eb;">{{inspection_url}}</a></p><p style="font-size:13px;color:#6b7280;margin:16px 0 0;">Caduca el <strong>{{expires_at}}</strong>.</p><p style="font-size:14px;color:#6b7280;margin:24px 0 0;">Dudas: <a href="mailto:{{support_email}}" style="color:#3b82f6;">{{support_email}}</a></p>',
      'text', E'Buenos días,\n\n{{tenant_name}} — registro de {{employee_name}} ({{period_from}} – {{period_to}}).\n\nEnlace: {{inspection_url}}\nCaduca: {{expires_at}}\n\nDudas: {{support_email}}'
    ),
    'en', jsonb_build_object(
      'subject', 'Temporary time-record access — {{employee_name}}',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hello,</p><p style="font-size:15px;color:#374151;margin:0 0 12px;"><strong>{{tenant_name}}</strong> is sharing a time-limited link to the time record (raw punches and consolidated) for <strong>{{employee_name}}</strong> from <strong>{{period_from}}</strong> to <strong>{{period_to}}</strong>.</p><p style="text-align:center;margin:24px 0;"><a href="{{inspection_url}}" style="display:inline-block;background:#1f2937;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:8px;font-weight:600;">Open the record</a></p><p style="font-size:13px;color:#6b7280;margin:0 0 8px;word-break:break-all;">Link: <a href="{{inspection_url}}" style="color:#2563eb;">{{inspection_url}}</a></p><p style="font-size:13px;color:#6b7280;margin:16px 0 0;">Expires on <strong>{{expires_at}}</strong>.</p><p style="font-size:14px;color:#6b7280;margin:24px 0 0;">Questions: <a href="mailto:{{support_email}}" style="color:#3b82f6;">{{support_email}}</a></p>',
      'text', E'Hello,\n\n{{tenant_name}} — time record for {{employee_name}} ({{period_from}} – {{period_to}}).\n\nLink: {{inspection_url}}\nExpires: {{expires_at}}\n\nQuestions: {{support_email}}'
    )
  ),
  false,
  NULL,
  true,
  true,
  true,
  false
)
ON CONFLICT (slug) WHERE is_platform_default = true DO UPDATE SET
  name = EXCLUDED.name,
  event_type = EXCLUDED.event_type,
  subject_template = EXCLUDED.subject_template,
  html_body_template = EXCLUDED.html_body_template,
  text_body_template = EXCLUDED.text_body_template,
  variables_schema = EXCLUDED.variables_schema,
  translations = EXCLUDED.translations,
  is_active = true,
  is_draft = false;
