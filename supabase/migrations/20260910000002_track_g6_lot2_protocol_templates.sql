-- Track G6 Lot 2 (G6.1 + G6.2): configurable protocol templates per tenant / work profile

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  (
    'attendance_protocol_template_locale_id',
    'tenant',
    'settings.manage',
    false,
    true,
    'Plantilla DMS (locale_id) per defecte del protocol de registre horari'
  ),
  (
    'attendance_protocol_template_by_profile',
    'tenant',
    'settings.manage',
    false,
    true,
    'Mapa opcional work_profile → template_locale_id per al protocol horari'
  )
ON CONFLICT (setting_key) DO UPDATE SET
  description = EXCLUDED.description,
  updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES (
  'defaults',
  '{
    "attendance_protocol_template_locale_id": null,
    "attendance_protocol_template_by_profile": {
      "mobile_peripatetic": "71000000-0000-0000-0000-000000000031",
      "hybrid": "71000000-0000-0000-0000-000000000032",
      "delivery": "71000000-0000-0000-0000-000000000033"
    }
  }'::jsonb
)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

-- --- Platform templates per perfil (G6.2) ---

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by)
VALUES
(
  '70000000-0000-0000-0000-000000000031',
  NULL,
  'Protocol horari — itinerant / camp',
  'Protocol per perfil mobile_peripatetic: fitxatges de dia, obres i desplaçaments.',
  'attendance',
  'html',
  true,
  true,
  NULL
),
(
  '70000000-0000-0000-0000-000000000032',
  NULL,
  'Protocol horari — híbrid',
  'Protocol per perfil hybrid: combinació d''oficina i treball extern.',
  'attendance',
  'html',
  true,
  true,
  NULL
),
(
  '70000000-0000-0000-0000-000000000033',
  NULL,
  'Protocol horari — repartiment',
  'Protocol per perfil delivery: rutes, parades i jornada oberta.',
  'attendance',
  'html',
  true,
  true,
  NULL
)
ON CONFLICT (id) DO UPDATE SET
  name        = EXCLUDED.name,
  description = EXCLUDED.description,
  category    = EXCLUDED.category,
  is_active   = true;

INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
(
  '71000000-0000-0000-0000-000000000031',
  '70000000-0000-0000-0000-000000000031',
  'ca',
  'text/html',
  NULL,
  '<h1>Protocol de registre horari — Itinerant</h1>
<p><strong>{{employee_name}}</strong> — {{tenant_name}}</p>
<p>Perfil: <strong>{{work_profile_label}}</strong> · {{jurisdiction_code}}</p>
<h2>Com es calculen les teves hores</h2>
<p>{{profile_explanation}}</p>
<ul>
  <li><strong>Presència</strong>: inici i fi de jornada (day_start / day_end) i temps a client.</li>
  <li><strong>Treball net</strong>: temps efectiu als clients / obres, descomptant pauses.</li>
  <li><strong>Desplaçament</strong>: pot comptar com a temps remunerable segons conveni.</li>
  <li><strong>Hores extra</strong>: fora de la jornada prevista; poden requerir autorització.</li>
</ul>
<p style="font-size:12px;color:#6b7280;">Publicat: {{published_date}}</p>',
  '{"employee_name":{"type":"string","required":true},"tenant_name":{"type":"string","required":true},"work_profile_label":{"type":"string","required":true},"jurisdiction_code":{"type":"string","required":true},"profile_explanation":{"type":"string","required":true},"published_date":{"type":"string","required":true}}',
  '{"Empleat":{"entity_type":"employee","label":"Empleat/da","order":0,"for_signing":true}}',
  '{}',
  true
),
(
  '71000000-0000-0000-0000-000000000032',
  '70000000-0000-0000-0000-000000000032',
  'ca',
  'text/html',
  NULL,
  '<h1>Protocol de registre horari — Híbrid</h1>
<p><strong>{{employee_name}}</strong> — {{tenant_name}}</p>
<p>Perfil: <strong>{{work_profile_label}}</strong> · {{jurisdiction_code}}</p>
<h2>Com es calculen les teves hores</h2>
<p>{{profile_explanation}}</p>
<ul>
  <li>Dies a centre: intersecció amb horari programat.</li>
  <li>Dies externs: consolidació per temps de treball i desplaçaments segons política.</li>
  <li>Revisa el registre mensual abans del tancament de nòmina.</li>
</ul>
<p style="font-size:12px;color:#6b7280;">Publicat: {{published_date}}</p>',
  '{"employee_name":{"type":"string","required":true},"tenant_name":{"type":"string","required":true},"work_profile_label":{"type":"string","required":true},"jurisdiction_code":{"type":"string","required":true},"profile_explanation":{"type":"string","required":true},"published_date":{"type":"string","required":true}}',
  '{"Empleat":{"entity_type":"employee","label":"Empleat/da","order":0,"for_signing":true}}',
  '{}',
  true
),
(
  '71000000-0000-0000-0000-000000000033',
  '70000000-0000-0000-0000-000000000033',
  'ca',
  'text/html',
  NULL,
  '<h1>Protocol de registre horari — Repartiment</h1>
<p><strong>{{employee_name}}</strong> — {{tenant_name}}</p>
<p>Perfil: <strong>{{work_profile_label}}</strong> · {{jurisdiction_code}}</p>
<h2>Com es calculen les teves hores</h2>
<p>{{profile_explanation}}</p>
<ul>
  <li>Jornada oberta amb inici/fi de ruta i parades de servei.</li>
  <li>El temps de conducció pot classificar-se com a desplaçament remunerable.</li>
  <li>Les incidències de ruta s''han de comunicar al responsable.</li>
</ul>
<p style="font-size:12px;color:#6b7280;">Publicat: {{published_date}}</p>',
  '{"employee_name":{"type":"string","required":true},"tenant_name":{"type":"string","required":true},"work_profile_label":{"type":"string","required":true},"jurisdiction_code":{"type":"string","required":true},"profile_explanation":{"type":"string","required":true},"published_date":{"type":"string","required":true}}',
  '{"Empleat":{"entity_type":"employee","label":"Empleat/da","order":0,"for_signing":true}}',
  '{}',
  true
)
ON CONFLICT (id) DO UPDATE SET
  html_content = EXCLUDED.html_content,
  is_active    = true;

-- --- Resolver (shared server-side) ---

CREATE OR REPLACE FUNCTION data.resolve_attendance_protocol_template_locale(
  p_settings     jsonb,
  p_work_profile text,
  p_platform_id  uuid DEFAULT '71000000-0000-0000-0000-000000000030'::uuid
)
RETURNS uuid
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_default text;
  v_profile text;
  v_by_profile jsonb;
BEGIN
  v_by_profile := COALESCE(p_settings->'attendance_protocol_template_by_profile', '{}'::jsonb);
  v_profile := NULLIF(trim(COALESCE(v_by_profile->>p_work_profile, '')), '');

  IF v_profile IS NOT NULL THEN
    RETURN v_profile::uuid;
  END IF;

  v_default := NULLIF(trim(COALESCE(p_settings->>'attendance_protocol_template_locale_id', '')), '');
  IF v_default IS NOT NULL THEN
    RETURN v_default::uuid;
  END IF;

  RETURN p_platform_id;
END;
$$;

COMMENT ON FUNCTION data.resolve_attendance_protocol_template_locale(jsonb, text, uuid) IS
  'G6.1/G6.2: resol template_locale_id per perfil → default tenant → plataforma.';
