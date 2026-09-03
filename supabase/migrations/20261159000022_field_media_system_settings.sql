-- Platform defaults for field media compression (admin can override via system_settings)
INSERT INTO data.system_settings (module, settings)
VALUES (
  'field_media',
  jsonb_build_object(
    'compression', jsonb_build_object(
      'enabled', true,
      'level', 'balanced'
    ),
    'upload_mode_default', 'direct'
  )
)
ON CONFLICT (module) DO UPDATE
SET settings = data.system_settings.settings || EXCLUDED.settings,
    updated_at = now();

-- Also merge into `defaults` so get_effective_settings surfaces field_media to tenants
INSERT INTO data.system_settings (module, settings)
VALUES (
  'defaults',
  jsonb_build_object(
    'field_media', jsonb_build_object(
      'compression', jsonb_build_object(
        'enabled', true,
        'level', 'balanced'
      ),
      'upload_mode_default', 'direct'
    )
  )
)
ON CONFLICT (module) DO UPDATE
SET settings = data.system_settings.settings || EXCLUDED.settings,
    updated_at = now();
