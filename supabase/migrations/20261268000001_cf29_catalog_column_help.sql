-- CF-29: column_help on lookup tables in calculator catalog (explanations for UI).

CREATE OR REPLACE FUNCTION data.cf29_merge_table_column_help(
  p_definition jsonb,
  p_table_key text,
  p_help jsonb
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_set(
    p_definition,
    '{tables}',
    COALESCE(
      (
        SELECT jsonb_agg(
          CASE
            WHEN elem->>'key' = p_table_key
              THEN elem || jsonb_build_object('column_help', p_help)
            ELSE elem
          END
          ORDER BY ordinality
        )
        FROM jsonb_array_elements(COALESCE(p_definition->'tables', '[]'::jsonb))
          WITH ORDINALITY AS t(elem, ordinality)
      ),
      '[]'::jsonb
    )
  );
$$;

UPDATE data.calculator_catalog
SET
  catalog_version = GREATEST(catalog_version, 3),
  definition = data.cf29_merge_table_column_help(
    definition,
    'travel',
    '{
      "max_km": {"ca":"Límit superior de km del tram (buit = sense límit)","es":"Límite superior de km","en":"Upper km bound"},
      "eur_base": {"ca":"Preu del desplaçament en € per aquest tram","es":"Precio del desplazamiento €","en":"Travel fee € for this tier"}
    }'::jsonb
  ),
  updated_at = now()
WHERE slug = 'site_visit_travel_materials';

UPDATE data.calculator_catalog
SET
  catalog_version = GREATEST(catalog_version, 3),
  definition = data.cf29_merge_table_column_help(
    data.cf29_merge_table_column_help(
      definition,
      'travel',
      '{
        "max_km": {"ca":"Límit superior de km del tram (buit = sense límit)","es":"Límite superior de km","en":"Upper km bound (empty = open)"},
        "eur_base": {"ca":"Preu base del desplaçament en €","es":"Precio base en €","en":"Base travel fee €"},
        "extra_after_km": {"ca":"A partir d’aquests km es cobra el suplement","es":"Desde estos km se cobra el suplemento","en":"Km after which extra fee applies"},
        "eur_per_extra_km": {"ca":"€ per cada km extra després del llindar","es":"€ por km extra","en":"€ per extra km"}
      }'::jsonb
    ),
    'labor',
    '{
      "max_kw": {"ca":"Límit superior de kW del tram (buit = sense límit)","es":"Límite superior de kW","en":"Upper kW bound"},
      "hours": {"ca":"Hores de mà d’obra estimades per aquest tram","es":"Horas de mano de obra","en":"Estimated labor hours"}
    }'::jsonb
  ),
  updated_at = now()
WHERE slug = 'electrician_travel_labor';

UPDATE data.calculator_catalog
SET
  catalog_version = GREATEST(catalog_version, 3),
  definition = data.cf29_merge_table_column_help(
    definition,
    'models',
    '{
      "id": {"ca":"Identificador de l’opció (ha de coincidir amb el paràmetre Model)","es":"Id de la opción","en":"Option id matching Model param"},
      "eur_m2": {"ca":"Preu €/m² d’aquest model","es":"Precio €/m²","en":"€/m² for this model"},
      "min_m2": {"ca":"Mínim de m² facturables","es":"Mínimo de m² facturables","en":"Minimum billable m²"}
    }'::jsonb
  ),
  updated_at = now()
WHERE slug = 'blinds_m2';

UPDATE data.calculator_catalog
SET
  catalog_version = GREATEST(catalog_version, 3),
  definition = data.cf29_merge_table_column_help(
    definition,
    'base_by_drive',
    '{
      "id": {"ca":"Tipus de tracció (ha de coincidir amb el paràmetre)","es":"Tipo de tracción","en":"Drive type id"},
      "eur_year": {"ca":"Quota base anual en €","es":"Cuota base anual €","en":"Annual base fee €"}
    }'::jsonb
  ),
  updated_at = now()
WHERE slug = 'elevator_maintenance_annual';

UPDATE data.calculator_catalog
SET
  catalog_version = GREATEST(catalog_version, 3),
  definition = data.cf29_merge_table_column_help(
    data.cf29_merge_table_column_help(
      definition,
      'quota',
      '{
        "max_covers": {"ca":"Límit superior de coberts del tram (buit = sense límit)","es":"Límite de cubiertos","en":"Upper covers bound"},
        "eur_month": {"ca":"Quota mensual en € per aquest tram","es":"Cuota mensual €","en":"Monthly fee €"}
      }'::jsonb
    ),
    'cold_options',
    '{
      "id": {"ca":"Opció de fred (ha de coincidir amb el paràmetre)","es":"Opción de frío","en":"Cold option id"},
      "eur_month": {"ca":"Suplement mensual en €","es":"Suplemento mensual €","en":"Monthly addon €"}
    }'::jsonb
  ),
  updated_at = now()
WHERE slug = 'horeca_maintenance_monthly';

DROP FUNCTION data.cf29_merge_table_column_help(jsonb, text, jsonb);
