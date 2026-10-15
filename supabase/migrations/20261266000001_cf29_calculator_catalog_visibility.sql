-- CF-29: visibilitat biblioteca (generic + settings cross-arquetip)

-- Tenants genèrics / no field_service veuen models el dia 1
UPDATE data.calculator_catalog
SET target_archetypes = array_append(target_archetypes, 'generic'),
    updated_at = now()
WHERE NOT ('generic' = ANY (target_archetypes));

-- Admin (service_role) pot gestionar el catàleg via data.* / Prisma
GRANT SELECT, UPDATE ON data.calculator_catalog TO service_role;

INSERT INTO data.system_settings (module, settings, updated_at)
VALUES (
  'commercial_calculators',
  jsonb_build_object('show_cross_archetype_catalog', false),
  now()
)
ON CONFLICT (module) DO UPDATE SET
  settings = COALESCE(data.system_settings.settings, '{}'::jsonb)
    || jsonb_build_object(
      'show_cross_archetype_catalog',
      COALESCE(
        (data.system_settings.settings->>'show_cross_archetype_catalog')::boolean,
        false
      )
    ),
  updated_at = now();

CREATE OR REPLACE FUNCTION api.get_calculator_catalog_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $func$
DECLARE
  v_settings jsonb;
BEGIN
  SELECT settings INTO v_settings
  FROM data.system_settings
  WHERE module = 'commercial_calculators';

  RETURN jsonb_build_object(
    'show_cross_archetype_catalog',
    COALESCE((v_settings->>'show_cross_archetype_catalog')::boolean, false)
  );
END;
$func$;

REVOKE ALL ON FUNCTION api.get_calculator_catalog_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_calculator_catalog_settings() TO authenticated;
