-- EP-ACC-2: plantilla correu accés portal + bucket privat per attachments.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'email-attachments',
  'email-attachments',
  false,
  26214400,
  ARRAY['image/png', 'image/jpeg', 'application/pdf']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

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
  'Accés al portal d''empleat',
  'employee-portal-access-link',
  'employee_portal.access_link',
  'Accés al portal d''empleat — {{employee_name}}',
  '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{employee_name}}</strong>,</p>

<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  {% if site_name %}
  T''hem preparat l''accés al portal d''empleat de <strong>{{site_name}}</strong>.
  {% else %}
  T''hem preparat l''accés al portal d''empleat de <strong>{{tenant_name}}</strong>.
  {% endif %}
</p>

<p style="font-size:14px;color:#374151;margin:0 0 16px;">{{pin_instructions}}</p>

<div style="text-align:center;margin:24px 0;">
  <img src="cid:employee-portal-qr" alt="QR accés portal" width="200" height="200" style="display:inline-block;border:1px solid #e5e7eb;border-radius:8px;">
</div>

<p style="text-align:center;margin:0 0 24px;">
  <a href="{{portal_url}}" style="display:inline-block;background:#2563eb;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:8px;font-weight:600;">
    Obrir el portal
  </a>
</p>

<p style="font-size:13px;color:#6b7280;margin:0 0 8px;word-break:break-all;">
  O copia aquest enllaç: <a href="{{portal_url}}" style="color:#2563eb;">{{portal_url}}</a>
</p>

{% if expires_at %}
<p style="font-size:13px;color:#6b7280;margin:16px 0 0;">Aquest enllaç caduca el {{expires_at}}.</p>
{% endif %}

<p style="font-size:14px;color:#6b7280;margin:24px 0 0;">
  Si tens dubtes, contacta amb
  <a href="mailto:{{support_email}}" style="color:#3b82f6;text-decoration:none;">{{support_email}}</a>.
</p>',
  'Hola, {{employee_name}},

{% if site_name %}Accés al portal d''empleat de {{site_name}}.{% else %}Accés al portal d''empleat de {{tenant_name}}.{% endif %}

{{pin_instructions}}

Enllaç: {{portal_url}}
{% if expires_at %}Caduca: {{expires_at}}{% endif %}

Dubtes: {{support_email}}',
  '{"employee_name":"string","employee_first_name":"string","portal_url":"string","link_type":"string","pin_instructions":"string","tenant_name":"string","site_name":"string","support_email":"string","expires_at":"string"}'::jsonb,
  jsonb_build_object(
    'es', jsonb_build_object(
      'subject', 'Acceso al portal del empleado — {{employee_name}}',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{employee_name}}</strong>,</p><p style="font-size:15px;color:#374151;margin:0 0 12px;">{% if site_name %}Te hemos preparado el acceso al portal de <strong>{{site_name}}</strong>.{% else %}Te hemos preparado el acceso al portal de <strong>{{tenant_name}}</strong>.{% endif %}</p><p style="font-size:14px;color:#374151;margin:0 0 16px;">{{pin_instructions}}</p><div style="text-align:center;margin:24px 0;"><img src="cid:employee-portal-qr" alt="QR portal" width="200" height="200" style="display:inline-block;border:1px solid #e5e7eb;border-radius:8px;"></div><p style="text-align:center;margin:0 0 24px;"><a href="{{portal_url}}" style="display:inline-block;background:#2563eb;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:8px;font-weight:600;">Abrir el portal</a></p><p style="font-size:13px;color:#6b7280;margin:0 0 8px;word-break:break-all;">Enlace: <a href="{{portal_url}}" style="color:#2563eb;">{{portal_url}}</a></p>{% if expires_at %}<p style="font-size:13px;color:#6b7280;margin:16px 0 0;">Caduca el {{expires_at}}.</p>{% endif %}<p style="font-size:14px;color:#6b7280;margin:24px 0 0;">Dudas: <a href="mailto:{{support_email}}" style="color:#3b82f6;">{{support_email}}</a></p>',
      'text', E'Hola, {{employee_name}},\n\n{{pin_instructions}}\n\nEnlace: {{portal_url}}\n{% if expires_at %}Caduca: {{expires_at}}{% endif %}\n\nDudas: {{support_email}}'
    ),
    'en', jsonb_build_object(
      'subject', 'Employee portal access — {{employee_name}}',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hi, <strong>{{employee_name}}</strong>,</p><p style="font-size:15px;color:#374151;margin:0 0 12px;">{% if site_name %}Your access to the <strong>{{site_name}}</strong> employee portal is ready.{% else %}Your access to the <strong>{{tenant_name}}</strong> employee portal is ready.{% endif %}</p><p style="font-size:14px;color:#374151;margin:0 0 16px;">{{pin_instructions}}</p><div style="text-align:center;margin:24px 0;"><img src="cid:employee-portal-qr" alt="Portal QR" width="200" height="200" style="display:inline-block;border:1px solid #e5e7eb;border-radius:8px;"></div><p style="text-align:center;margin:0 0 24px;"><a href="{{portal_url}}" style="display:inline-block;background:#2563eb;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:8px;font-weight:600;">Open portal</a></p><p style="font-size:13px;color:#6b7280;margin:0 0 8px;word-break:break-all;">Link: <a href="{{portal_url}}" style="color:#2563eb;">{{portal_url}}</a></p>{% if expires_at %}<p style="font-size:13px;color:#6b7280;margin:16px 0 0;">Expires on {{expires_at}}.</p>{% endif %}<p style="font-size:14px;color:#6b7280;margin:24px 0 0;">Questions: <a href="mailto:{{support_email}}" style="color:#3b82f6;">{{support_email}}</a></p>',
      'text', E'Hi, {{employee_name}},\n\n{{pin_instructions}}\n\nLink: {{portal_url}}\n{% if expires_at %}Expires: {{expires_at}}{% endif %}\n\nQuestions: {{support_email}}'
    )
  ),
  false,
  NULL,
  true,
  true,
  true,
  false
)
ON CONFLICT DO NOTHING;

-- Permetre resolució URL des de Edge service_role (després d'autoritzar l'usuari al handler).
CREATE OR REPLACE FUNCTION api.resolve_public_site_for_employee(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_chosen record;
  v_fallback boolean := false;
  v_canonical text;
  v_base_url text;
  v_site_name text;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, t.slug AS tenant_slug
  INTO v_emp
  FROM data.employees e
  JOIN data.tenants t ON t.id = e.tenant_id
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'no_data_found';
  END IF;

  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
      RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  IF NOT data.public_portal_enabled_for_tenant(v_emp.tenant_id) THEN
    RAISE EXCEPTION 'public_portal_disabled' USING ERRCODE = 'check_violation';
  END IF;

  SELECT ps.id, ps.site_id, ps.slug, ps.primary_domain_id
  INTO v_chosen
  FROM data.public_sites ps
  WHERE ps.tenant_id = v_emp.tenant_id
    AND ps.status = 'published'
    AND (
      (v_emp.site_id IS NOT NULL AND ps.site_id = v_emp.site_id)
      OR ps.site_id IS NULL
    )
  ORDER BY
    CASE
      WHEN v_emp.site_id IS NOT NULL AND ps.site_id = v_emp.site_id THEN 0
      ELSE 1
    END,
    ps.created_at ASC,
    ps.id ASC
  LIMIT 1;

  IF v_chosen.id IS NULL THEN
    RAISE EXCEPTION 'no_published_public_site' USING ERRCODE = 'check_violation';
  END IF;

  v_fallback := v_emp.site_id IS NOT NULL AND v_chosen.site_id IS NULL;

  SELECT d.domain
  INTO v_canonical
  FROM data.public_domains d
  WHERE d.id = v_chosen.primary_domain_id
    AND d.public_site_id = v_chosen.id
    AND d.status = 'ssl_active'
  LIMIT 1;

  IF v_canonical IS NULL THEN
    SELECT d.domain
    INTO v_canonical
    FROM data.public_domains d
    WHERE d.public_site_id = v_chosen.id
      AND d.status = 'ssl_active'
      AND d.domain IS NOT NULL
    ORDER BY d.created_at ASC, d.id ASC
    LIMIT 1;
  END IF;

  IF v_canonical IS NOT NULL THEN
    v_base_url := 'https://' || v_canonical;
  ELSE
    v_base_url := NULL;
  END IF;

  IF v_emp.site_id IS NOT NULL THEN
    SELECT s.name INTO v_site_name
    FROM data.sites s
    WHERE s.id = v_emp.site_id;
  END IF;

  RETURN jsonb_build_object(
    'public_site_id', v_chosen.id,
    'site_id', v_emp.site_id,
    'site_name', v_site_name,
    'slug', v_chosen.slug,
    'canonical_domain', v_canonical,
    'portal_base_url', v_base_url,
    'fallback_used', v_fallback,
    'tenant_slug', v_emp.tenant_slug
  );
END;
$$;
