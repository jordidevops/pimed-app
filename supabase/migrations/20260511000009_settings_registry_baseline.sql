-- =============================================================================
-- Settings Registry baseline (claus inicials recomanades)
--
-- Aquesta migració amplia el catàleg data.settings_registry amb una base de
-- claus per a configuració real de producte, mapades a permisos granulars.
--
-- Estratègia:
--   - Idempotent: ON CONFLICT(setting_key) DO UPDATE
--   - Conservadora: defaults de seguretat per valors sensibles
--   - Compatible amb assert_setting_write_access()
-- =============================================================================

INSERT INTO data.settings_registry (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  -- -------------------------------------------------------------------------
  -- TENANT scope
  -- -------------------------------------------------------------------------
  -- Calendari: valors per defecte de tota l'organització.
  -- Els sites poden tenir calendar_business_hours i calendar_slot_minutes propis
  -- (scope site), però la vista, timezone i durada base pertanyen al tenant.
  ('default_event_start_time',        'tenant', 'calendar.manage',   false, true, 'Hora d''inici per defecte d''esdeveniments'),
  ('default_event_duration_minutes',  'tenant', 'calendar.manage',   false, true, 'Durada per defecte d''esdeveniments'),
  ('week_starts_on',                  'tenant', 'calendar.manage',   false, true, 'Primer dia de setmana del tenant'),
  ('default_calendar_timezone',       'tenant', 'calendar.manage',   false, true, 'Timezone per defecte del tenant'),
  ('default_calendar_view',           'tenant', 'calendar.manage',   false, true, 'Vista per defecte del calendari del tenant'),

  -- Idioma i formats: el tenant defineix els valors globals.
  -- Cada site pot sobreescriure'ls amb site_language / site_date_format / site_time_format
  -- (scope site, definits a la secció SITE scope més avall).
  ('default_language',                'tenant', 'settings.manage',   false, true, 'Idioma per defecte del tenant'),
  ('default_date_format',             'tenant', 'settings.manage',   false, true, 'Format de data per defecte (sobreescrivible per site amb site_date_format)'),
  ('default_time_format',             'tenant', 'settings.manage',   false, true, 'Format d''hora per defecte (sobreescrivible per site amb site_time_format)'),

  ('member_invites_enabled',          'tenant', 'members.invite',    false, true, 'Activa/desactiva invitacions de membres'),
  ('site_creation_enabled',           'tenant', 'sites.create',      false, true, 'Permet crear nous sites dins del tenant'),

  ('email_domain_enforcement_mode',   'tenant', 'email.manage',      false, true, 'Mode d''enforcament de dominis de correu'),
  ('email_default_from_name',         'tenant', 'email.manage',      false, true, 'Nom remitent per defecte de tenant'),
  ('email_default_reply_to',          'tenant', 'email.manage',      false, true, 'Reply-to per defecte de tenant'),

  ('storage_soft_quota_warning_pct',  'tenant', 'storage.manage',    false, true, 'Percentatge d''avís de quota de storage'),
  ('storage_hard_quota_gb',           'tenant', null,                true,  true, 'Quota dura de storage (nomes owner)'),

  ('rbac_customization_enabled',      'tenant', 'permissions.manage', false, true, 'Permet personalització de rols/permisos'),
  ('rbac_lockdown_mode',              'tenant', null,                true,  true, 'Bloqueja canvis de permisos fora owner'),

  ('audit_retention_days',            'tenant', null,                true,  true, 'Dies de retenció d''auditoria'),
  ('security_require_mfa',            'tenant', null,                true,  true, 'Força MFA per usuaris del tenant'),

  -- -------------------------------------------------------------------------
  -- SITE scope
  -- -------------------------------------------------------------------------
  -- Email: els sites poden tenir identitat de correu pròpia (nom, reply-to, logo)
  -- independent del tenant. Si no s'estableix, el sistema usa els valors del tenant
  -- (email_default_from_name, email_default_reply_to).
  ('email_from_name',                 'site',   'email.manage',      false, true, 'Nom remitent de correu del site'),
  ('email_reply_to',                  'site',   'email.manage',      false, true, 'Reply-to de correu del site'),
  ('email_logo_url',                  'site',   'email.manage',      false, true, 'Logo de correu del site'),
  ('default_email_layout_id',         'site',   'email.manage',      false, true, 'Plantilla de correu per defecte del site'),

  -- Idioma i formats per site: sobreescriuen els valors del tenant.
  -- El merge get_effective_settings() aplica: system || tenant || site || user.
  -- Exemple: tenant usa dd/MM/yyyy però un site internacional usa yyyy-MM-dd.
  ('site_timezone',                   'site',   'settings.manage',   false, true, 'Timezone del site (sobreescriu default_calendar_timezone del tenant)'),
  ('site_language',                   'site',   'settings.manage',   false, true, 'Idioma del site (sobreescriu default_language del tenant)'),
  ('site_date_format',                'site',   'settings.manage',   false, true, 'Format de data del site (sobreescriu default_date_format del tenant)'),
  ('site_time_format',                'site',   'settings.manage',   false, true, 'Format d''hora del site (sobreescriu default_time_format del tenant)'),

  ('calendar_business_hours',         'site',   'calendar.manage',   false, true, 'Franja horària operativa del site'),
  ('calendar_slot_minutes',           'site',   'calendar.manage',   false, true, 'Duració de slot de calendari del site'),
  ('calendar_allow_overlap',          'site',   'calendar.manage',   false, true, 'Permet solapament d''esdeveniments al site'),

  ('storage_upload_max_mb',           'site',   'storage.manage',    false, true, 'Mida màxima pujada per arxiu al site'),
  ('storage_allowed_mime_types',      'site',   'storage.manage',    false, true, 'Llista MIME permesa al site'),

  ('site_archived',                   'site',   null,                true,  true, 'Marca el site com arxivat (nomes owner)'),

  -- -------------------------------------------------------------------------
  -- USER scope
  -- -------------------------------------------------------------------------
  ('theme',                           'user',   null,                false, true, 'Tema visual de l''usuari'),
  ('language',                        'user',   null,                false, true, 'Idioma preferit de l''usuari'),
  ('timezone',                        'user',   null,                false, true, 'Timezone preferida de l''usuari'),
  ('date_format',                     'user',   null,                false, true, 'Format de data preferit de l''usuari'),
  ('time_format',                     'user',   null,                false, true, 'Format d''hora preferit de l''usuari'),

  ('calendar_default_view',           'user',   null,                false, true, 'Vista per defecte de calendari de l''usuari'),
  ('calendar_show_weekends',          'user',   null,                false, true, 'Mostrar caps de setmana al calendari'),
  ('calendar_compact_mode',           'user',   null,                false, true, 'Mode compacte del calendari de l''usuari'),

  ('notifications_email_enabled',     'user',   null,                false, true, 'Activar notificacions per email de l''usuari'),
  ('notifications_in_app_enabled',    'user',   null,                false, true, 'Activar notificacions in-app de l''usuari'),
  ('notifications_digest_frequency',  'user',   null,                false, true, 'Freqüència de resum de notificacions'),

  ('home_default_module',             'user',   null,                false, true, 'Mòdul inicial en entrar al portal'),
  ('table_density',                   'user',   null,                false, true, 'Densitat de taules de l''usuari')
ON CONFLICT (setting_key)
DO UPDATE SET
  scope               = EXCLUDED.scope,
  required_permission = EXCLUDED.required_permission,
  owner_only          = EXCLUDED.owner_only,
  is_active           = EXCLUDED.is_active,
  description         = EXCLUDED.description,
  updated_at          = now();
