-- CF-29: catàleg ready (preus il·lustratius + default_case) + metadades UI
ALTER TABLE data.calculator_catalog
  ADD COLUMN IF NOT EXISTS title jsonb,
  ADD COLUMN IF NOT EXISTS summary jsonb,
  ADD COLUMN IF NOT EXISTS default_case jsonb;

ALTER TABLE data.calculator_definitions
  ADD COLUMN IF NOT EXISTS tariffs_reviewed_at timestamptz;

COMMENT ON COLUMN data.calculator_catalog.default_case IS
  'Cas per defecte {name, params, expected_lines?} per activar el clon al portal.';
COMMENT ON COLUMN data.calculator_definitions.tariffs_reviewed_at IS
  'Quan el tenant confirma que ha revisat els preus d''exemple del clon.';

DROP VIEW IF EXISTS api.calculator_catalog;
CREATE VIEW api.calculator_catalog
  WITH (security_invoker = true)
AS
SELECT id, slug, target_archetypes, catalog_version, definition, tags, is_active,
       title, summary, default_case, created_at, updated_at
FROM data.calculator_catalog
WHERE is_active;
GRANT SELECT ON api.calculator_catalog TO authenticated;

CREATE OR REPLACE VIEW api.calculator_definitions
  WITH (security_invoker = true)
AS
SELECT *
FROM data.calculator_definitions
WHERE tenant_id = data.active_tenant_id();

INSERT INTO data.calculator_catalog (
  slug, target_archetypes, catalog_version, definition, tags, is_active,
  title, summary, default_case
)
VALUES
  (
    'site_visit_travel_materials',
    ARRAY['field_service']::text[],
    2,
    '{"schema_version":1,"parameters":[{"key":"distance_km","type":"number","min":0,"required":true,"label":{"ca":"Distància (km)","es":"Distancia (km)","en":"Distance (km)"}},{"key":"material_units","type":"integer","min":0,"required":true,"default":0,"label":{"ca":"Unitats de material","es":"Unidades de material","en":"Material units"}}],"constants":[{"key":"material_eur","type":"money","value":12.5,"label":{"ca":"€/unitat material"}}],"tables":[{"key":"travel","lookup":"tier","input":"distance_km","bound_column":"max_km","rows":[{"max_km":15,"eur_base":0},{"max_km":40,"eur_base":35},{"max_km":null,"eur_base":55}]}],"lines":[{"key":"travel","when":{"op":"cmp","cmp":"gt","left":{"op":"param","key":"distance_km"},"right":{"op":"const","value":0}},"name":{"ca":"Desplaçament"},"kind":"service","unit":"u","allow_zero_price":true,"quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"const","value":1}},"unit_price":{"op":"lookup_tier","table":"travel","value":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"row","field":"eur_base"}}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}},{"key":"materials","when":{"op":"cmp","cmp":"gt","left":{"op":"param","key":"material_units"},"right":{"op":"const","value":0}},"name":{"ca":"Materials"},"kind":"product","unit":"u","quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"param","key":"material_units"}},"unit_price":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"const_ref","key":"material_eur"}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}}]}'::jsonb,
    ARRAY['visita','desplacament','materials']::text[],
    true,
    '{"ca":"Visita tècnica","es":"Visita técnica","en":"Site visit"}'::jsonb,
    '{"ca":"Desplaçament per distància + materials. Preus d''exemple; adapta''ls.","es":"Desplazamiento + materiales. Precios de ejemplo.","en":"Travel by distance + materials. Example prices."}'::jsonb,
    '{"name":"25 km / 4 materials","params":{"distance_km":25,"material_units":4}}'::jsonb
  ),
  (
    'electrician_travel_labor',
    ARRAY['field_service']::text[],
    2,
    '{"schema_version":1,"parameters":[{"key":"distance_km","type":"number","min":0,"required":true,"label":{"ca":"Distància","es":"Distancia","en":"Distance"}},{"key":"power_kw","type":"number","min":0,"required":true,"label":{"ca":"Potència","es":"Potencia","en":"Power"}}],"constants":[{"key":"hour_eur","type":"money","value":45,"label":{"ca":"€/hora"}}],"tables":[{"key":"travel","lookup":"tier","input":"distance_km","bound_column":"max_km","rows":[{"max_km":10,"eur_base":0,"extra_after_km":0,"eur_per_extra_km":0},{"max_km":30,"eur_base":25,"extra_after_km":0,"eur_per_extra_km":0},{"max_km":null,"eur_base":25,"extra_after_km":30,"eur_per_extra_km":1.2}]},{"key":"labor","lookup":"tier","input":"power_kw","bound_column":"max_kw","rows":[{"max_kw":5,"hours":2},{"max_kw":15,"hours":4},{"max_kw":null,"hours":8}]}],"lines":[{"key":"travel","when":{"op":"cmp","cmp":"gt","left":{"op":"param","key":"distance_km"},"right":{"op":"const","value":0}},"name":{"ca":"Desplaçament"},"kind":"service","unit":"u","allow_zero_price":true,"quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"const","value":1}},"unit_price":{"op":"lookup_tier","table":"travel","value":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"add","args":[{"op":"row","field":"eur_base"},{"op":"mul","args":[{"op":"max","args":[{"op":"const","value":0},{"op":"sub","left":{"op":"param","key":"distance_km"},"right":{"op":"row","field":"extra_after_km"}}]},{"op":"row","field":"eur_per_extra_km"}]}]}}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}},{"key":"labor","name":{"ca":"Mà d''obra"},"kind":"service","unit":"h","quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"lookup_tier","table":"labor","value":{"op":"row","field":"hours"}}},"unit_price":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"const_ref","key":"hour_eur"}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}}]}'::jsonb,
    ARRAY['desplacament','electricitat']::text[],
    true,
    '{"ca":"Electricista (desplaçament + potència)","es":"Electricista","en":"Electrician"}'::jsonb,
    '{"ca":"Desplaçament per km i hores segons kW. Preus d''exemple.","es":"Desplazamiento y horas según kW.","en":"Travel + labor by kW."}'::jsonb,
    '{"name":"20 km / 3 kW","params":{"distance_km":20,"power_kw":3}}'::jsonb
  ),
  (
    'blinds_m2',
    ARRAY['field_service']::text[],
    2,
    '{"schema_version":1,"parameters":[{"key":"model","type":"enum","options_from":"models","required":true,"label":{"ca":"Model"}},{"key":"width_cm","type":"number","min":1,"required":true,"label":{"ca":"Amplada"}},{"key":"height_cm","type":"number","min":1,"required":true,"label":{"ca":"Alçada"}},{"key":"units","type":"integer","min":1,"required":true,"default":1,"label":{"ca":"Unitats"}}],"tables":[{"key":"models","lookup":"exact","input":"model","match_column":"id","rows":[{"id":"pvc","label":{"ca":"PVC"},"eur_m2":80,"min_m2":1},{"id":"alumini","label":{"ca":"Alumini"},"eur_m2":120,"min_m2":1}]}],"lines":[{"key":"blind","name":{"ca":"Persiana {{model}}"},"kind":"product","unit":"m2","quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"mul","args":[{"op":"param","key":"units"},{"op":"max","args":[{"op":"lookup_exact","table":"models","field":"min_m2"},{"op":"div","left":{"op":"mul","args":[{"op":"param","key":"width_cm"},{"op":"param","key":"height_cm"}]},"right":{"op":"const","value":10000}}]}]}},"unit_price":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"lookup_exact","table":"models","field":"eur_m2"}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}}]}'::jsonb,
    ARRAY['m2','persianes']::text[],
    true,
    '{"ca":"Persianes €/m²","es":"Persianas €/m²","en":"Blinds €/m²"}'::jsonb,
    '{"ca":"Preu per m² segons model i mides. Preus d''exemple.","es":"Precio por m² según modelo.","en":"Price per m² by model."}'::jsonb,
    '{"name":"PVC 100×150 ×2","params":{"model":"pvc","width_cm":100,"height_cm":150,"units":2}}'::jsonb
  ),
  (
    'elevator_maintenance_annual',
    ARRAY['field_service']::text[],
    2,
    '{"schema_version":1,"parameters":[{"key":"stops","type":"integer","min":1,"required":true,"default":4,"label":{"ca":"Parades","es":"Paradas","en":"Stops"}},{"key":"drive_type","type":"enum","options_from":"base_by_drive","required":true,"label":{"ca":"Tipus de tracció","es":"Tipo de tracción","en":"Drive type"}}],"constants":[{"key":"eur_per_stop","type":"money","value":85,"label":{"ca":"€ / parada / any"}}],"tables":[{"key":"base_by_drive","lookup":"exact","input":"drive_type","match_column":"id","rows":[{"id":"electric","label":{"ca":"Elèctric"},"eur_year":900},{"id":"hydraulic","label":{"ca":"Hidràulic"},"eur_year":1100}]}],"lines":[{"key":"base","name":{"ca":"Quota base anual"},"kind":"service","unit":"any","quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"const","value":1}},"unit_price":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"lookup_exact","table":"base_by_drive","field":"eur_year"}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}},{"key":"stops","name":{"ca":"Suplement per parades"},"kind":"service","unit":"parada","quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"param","key":"stops"}},"unit_price":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"const_ref","key":"eur_per_stop"}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}}]}'::jsonb,
    ARRAY['ascensors','manteniment']::text[],
    true,
    '{"ca":"Manteniment ascensors (anual)","es":"Mantenimiento ascensores","en":"Elevator maintenance"}'::jsonb,
    '{"ca":"Quota anual per tipus de tracció + suplement per parades. Preus d''exemple.","es":"Cuota anual + paradas.","en":"Annual fee + per stop."}'::jsonb,
    '{"name":"Elèctric 6 parades","params":{"stops":6,"drive_type":"electric"}}'::jsonb
  ),
  (
    'horeca_maintenance_monthly',
    ARRAY['field_service']::text[],
    2,
    '{"schema_version":1,"parameters":[{"key":"covers","type":"integer","min":1,"required":true,"label":{"ca":"Coberts","es":"Cubiertos","en":"Covers"}},{"key":"cold_addon","type":"enum","options_from":"cold_options","required":true,"default":"none","label":{"ca":"Fred industrial","es":"Frío industrial","en":"Cold storage"}}],"tables":[{"key":"quota","lookup":"tier","input":"covers","bound_column":"max_covers","rows":[{"max_covers":40,"eur_month":180},{"max_covers":100,"eur_month":320},{"max_covers":null,"eur_month":480}]},{"key":"cold_options","lookup":"exact","input":"cold_addon","match_column":"id","rows":[{"id":"none","label":{"ca":"Sense"},"eur_month":0},{"id":"basic","label":{"ca":"Càmera bàsica"},"eur_month":75},{"id":"full","label":{"ca":"Càmera + murals"},"eur_month":140}]}],"lines":[{"key":"maintenance","name":{"ca":"Manteniment mensual HORECA"},"kind":"service","unit":"mes","quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"const","value":1}},"unit_price":{"op":"lookup_tier","table":"quota","value":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"row","field":"eur_month"}}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}},{"key":"cold","when":{"op":"cmp","cmp":"gt","left":{"op":"lookup_exact","table":"cold_options","field":"eur_month"},"right":{"op":"const","value":0}},"name":{"ca":"Fred industrial"},"kind":"service","unit":"mes","allow_zero_price":true,"quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"const","value":1}},"unit_price":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"lookup_exact","table":"cold_options","field":"eur_month"}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}}]}'::jsonb,
    ARRAY['horeca','manteniment','restauracio']::text[],
    true,
    '{"ca":"Manteniment HORECA (mensual)","es":"Mantenimiento HORECA","en":"HORECA maintenance"}'::jsonb,
    '{"ca":"Quota mensual per coberts + fred industrial opcional. Preus d''exemple.","es":"Cuota mensual por cubiertos.","en":"Monthly fee by covers."}'::jsonb,
    '{"name":"60 coberts + càmera bàsica","params":{"covers":60,"cold_addon":"basic"}}'::jsonb
  )
ON CONFLICT (slug) DO UPDATE SET
  target_archetypes = EXCLUDED.target_archetypes,
  catalog_version = EXCLUDED.catalog_version,
  definition = EXCLUDED.definition,
  tags = EXCLUDED.tags,
  is_active = EXCLUDED.is_active,
  title = EXCLUDED.title,
  summary = EXCLUDED.summary,
  default_case = EXCLUDED.default_case,
  updated_at = now();

CREATE OR REPLACE FUNCTION api.mark_calculator_tariffs_reviewed(p_definition_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $func$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_calculator_owner_manager(v_tenant_id);
  UPDATE data.calculator_definitions
  SET tariffs_reviewed_at = now(), updated_at = now()
  WHERE id = p_definition_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'calculator_not_found' USING ERRCODE = 'no_data_found';
  END IF;
END;
$func$;

REVOKE ALL ON FUNCTION api.mark_calculator_tariffs_reviewed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.mark_calculator_tariffs_reviewed(uuid) TO authenticated;
