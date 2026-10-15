-- CF-29: default_case amb expected_lines precalculades (paritat motor)
UPDATE data.calculator_catalog
SET default_case = '{
  "name": "25 km / 4 materials",
  "params": {
    "distance_km": 25,
    "material_units": 4
  },
  "expected_lines": [
    {
      "key": "travel",
      "kind": "service",
      "name": "Desplaçament",
      "description": null,
      "unit": "u",
      "quantity": "1.000",
      "unit_price": "35.00",
      "discount_pct": "0.00",
      "tax_rate": "21.00",
      "allow_zero_price": true
    },
    {
      "key": "materials",
      "kind": "product",
      "name": "Materials",
      "description": null,
      "unit": "u",
      "quantity": "4.000",
      "unit_price": "12.50",
      "discount_pct": "0.00",
      "tax_rate": "21.00",
      "allow_zero_price": false
    }
  ]
}'::jsonb,
    updated_at = now()
WHERE slug = 'site_visit_travel_materials';

UPDATE data.calculator_catalog
SET default_case = '{
  "name": "20 km / 3 kW",
  "params": {
    "distance_km": 20,
    "power_kw": 3
  },
  "expected_lines": [
    {
      "key": "travel",
      "kind": "service",
      "name": "Desplaçament",
      "description": null,
      "unit": "u",
      "quantity": "1.000",
      "unit_price": "25.00",
      "discount_pct": "0.00",
      "tax_rate": "21.00",
      "allow_zero_price": true
    },
    {
      "key": "labor",
      "kind": "service",
      "name": "Mà d''obra",
      "description": null,
      "unit": "h",
      "quantity": "2.000",
      "unit_price": "45.00",
      "discount_pct": "0.00",
      "tax_rate": "21.00",
      "allow_zero_price": false
    }
  ]
}'::jsonb,
    updated_at = now()
WHERE slug = 'electrician_travel_labor';

UPDATE data.calculator_catalog
SET default_case = '{
  "name": "PVC 100×150 ×2",
  "params": {
    "model": "pvc",
    "width_cm": 100,
    "height_cm": 150,
    "units": 2
  },
  "expected_lines": [
    {
      "key": "blind",
      "kind": "product",
      "name": "Persiana PVC",
      "description": null,
      "unit": "m2",
      "quantity": "3.000",
      "unit_price": "80.00",
      "discount_pct": "0.00",
      "tax_rate": "21.00",
      "allow_zero_price": false
    }
  ]
}'::jsonb,
    updated_at = now()
WHERE slug = 'blinds_m2';

UPDATE data.calculator_catalog
SET default_case = '{
  "name": "Elèctric 6 parades",
  "params": {
    "stops": 6,
    "drive_type": "electric"
  },
  "expected_lines": [
    {
      "key": "base",
      "kind": "service",
      "name": "Quota base anual",
      "description": null,
      "unit": "any",
      "quantity": "1.000",
      "unit_price": "900.00",
      "discount_pct": "0.00",
      "tax_rate": "21.00",
      "allow_zero_price": false
    },
    {
      "key": "stops",
      "kind": "service",
      "name": "Suplement per parades",
      "description": null,
      "unit": "parada",
      "quantity": "6.000",
      "unit_price": "85.00",
      "discount_pct": "0.00",
      "tax_rate": "21.00",
      "allow_zero_price": false
    }
  ]
}'::jsonb,
    updated_at = now()
WHERE slug = 'elevator_maintenance_annual';

UPDATE data.calculator_catalog
SET default_case = '{
  "name": "60 coberts + càmera bàsica",
  "params": {
    "covers": 60,
    "cold_addon": "basic"
  },
  "expected_lines": [
    {
      "key": "maintenance",
      "kind": "service",
      "name": "Manteniment mensual HORECA",
      "description": null,
      "unit": "mes",
      "quantity": "1.000",
      "unit_price": "320.00",
      "discount_pct": "0.00",
      "tax_rate": "21.00",
      "allow_zero_price": false
    },
    {
      "key": "cold",
      "kind": "service",
      "name": "Fred industrial",
      "description": null,
      "unit": "mes",
      "quantity": "1.000",
      "unit_price": "75.00",
      "discount_pct": "0.00",
      "tax_rate": "21.00",
      "allow_zero_price": true
    }
  ]
}'::jsonb,
    updated_at = now()
WHERE slug = 'horeca_maintenance_monthly';
