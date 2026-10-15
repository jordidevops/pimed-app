-- CF-29 fase 5: catàleg plataforma + clone RPC

INSERT INTO data.calculator_catalog (slug, target_archetypes, catalog_version, definition, tags, is_active)
VALUES
  (
    'electrician_travel_labor',
    ARRAY['field_service']::text[],
    1,
    '{"schema_version":1,"parameters":[{"key":"distance_km","type":"number","min":0,"required":true,"label":{"ca":"Distància","es":"Distancia","en":"Distance"}},{"key":"power_kw","type":"number","min":0,"required":true,"label":{"ca":"Potència","es":"Potencia","en":"Power"}}],"constants":[{"key":"hour_eur","type":"money","value":null,"label":{"ca":"€/hora"}}],"tables":[{"key":"travel","lookup":"tier","input":"distance_km","bound_column":"max_km","rows":[{"max_km":10,"eur_base":null,"extra_after_km":0,"eur_per_extra_km":null},{"max_km":30,"eur_base":null,"extra_after_km":0,"eur_per_extra_km":null},{"max_km":null,"eur_base":null,"extra_after_km":30,"eur_per_extra_km":null}]},{"key":"labor","lookup":"tier","input":"power_kw","bound_column":"max_kw","rows":[{"max_kw":5,"hours":2},{"max_kw":15,"hours":4},{"max_kw":null,"hours":8}]}],"lines":[{"key":"travel","when":{"op":"cmp","cmp":"gt","left":{"op":"param","key":"distance_km"},"right":{"op":"const","value":0}},"name":{"ca":"Desplaçament"},"kind":"service","unit":"u","allow_zero_price":true,"quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"const","value":1}},"unit_price":{"op":"lookup_tier","table":"travel","value":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"add","args":[{"op":"row","field":"eur_base"},{"op":"mul","args":[{"op":"max","args":[{"op":"const","value":0},{"op":"sub","left":{"op":"param","key":"distance_km"},"right":{"op":"row","field":"extra_after_km"}}]},{"op":"row","field":"eur_per_extra_km"}]}]}}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}},{"key":"labor","name":{"ca":"Mà d''obra"},"kind":"service","unit":"h","quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"lookup_tier","table":"labor","value":{"op":"row","field":"hours"}}},"unit_price":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"const_ref","key":"hour_eur"}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}}]}'::jsonb,
    ARRAY['desplacament','electricitat']::text[],
    true
  ),
  (
    'blinds_m2',
    ARRAY['field_service']::text[],
    1,
    '{"schema_version":1,"parameters":[{"key":"model","type":"enum","options_from":"models","required":true,"label":{"ca":"Model"}},{"key":"width_cm","type":"number","min":1,"required":true,"label":{"ca":"Amplada"}},{"key":"height_cm","type":"number","min":1,"required":true,"label":{"ca":"Alçada"}},{"key":"units","type":"integer","min":1,"required":true,"default":1,"label":{"ca":"Unitats"}}],"tables":[{"key":"models","lookup":"exact","input":"model","match_column":"id","rows":[{"id":"pvc","label":{"ca":"PVC"},"eur_m2":null,"min_m2":1},{"id":"alumini","label":{"ca":"Alumini"},"eur_m2":null,"min_m2":1}]}],"lines":[{"key":"blind","name":{"ca":"Persiana {{model}}"},"kind":"product","unit":"m2","quantity":{"op":"round","decimals":3,"mode":"half_away_from_zero","value":{"op":"mul","args":[{"op":"param","key":"units"},{"op":"max","args":[{"op":"lookup_exact","table":"models","field":"min_m2"},{"op":"div","left":{"op":"mul","args":[{"op":"param","key":"width_cm"},{"op":"param","key":"height_cm"}]},"right":{"op":"const","value":10000}}]}]}},"unit_price":{"op":"round","decimals":2,"mode":"half_away_from_zero","value":{"op":"lookup_exact","table":"models","field":"eur_m2"}},"discount_pct":{"op":"const","value":0},"tax_rate":{"op":"const","value":21}}]}'::jsonb,
    ARRAY['m2','persianes']::text[],
    true
  )
ON CONFLICT (slug) DO UPDATE SET
  target_archetypes = EXCLUDED.target_archetypes,
  catalog_version = EXCLUDED.catalog_version,
  definition = EXCLUDED.definition,
  tags = EXCLUDED.tags,
  is_active = EXCLUDED.is_active,
  updated_at = now();

CREATE OR REPLACE FUNCTION api.clone_calculator_from_catalog(
  p_catalog_id uuid,
  p_name text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $func$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_cat data.calculator_catalog%ROWTYPE;
  v_id uuid;
  v_name text;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_calculator_owner_manager(v_tenant_id);

  SELECT * INTO v_cat
  FROM data.calculator_catalog
  WHERE id = p_catalog_id AND is_active
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'calculator_catalog_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_name := COALESCE(
    NULLIF(btrim(p_name), ''),
    initcap(replace(v_cat.slug, '_', ' '))
  );

  INSERT INTO data.calculator_definitions (
    tenant_id, name, description, status, draft_definition,
    cloned_from_catalog_id, cloned_from_catalog_version, tags, created_by
  ) VALUES (
    v_tenant_id,
    v_name,
    NULL,
    'incomplete',
    v_cat.definition,
    v_cat.id,
    v_cat.catalog_version,
    data.normalize_calculator_tags(v_cat.tags),
    auth.uid()
  )
  RETURNING id INTO v_id;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    NULL,
    'CALCULATOR_CLONED',
    'calculator_definition',
    v_id,
    jsonb_build_object(
      'catalog_id', v_cat.id,
      'catalog_slug', v_cat.slug,
      'catalog_version', v_cat.catalog_version
    )
  );

  RETURN v_id;
END;
$func$;

REVOKE ALL ON FUNCTION api.clone_calculator_from_catalog(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.clone_calculator_from_catalog(uuid, text) TO authenticated;
