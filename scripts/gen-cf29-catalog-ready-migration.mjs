import fs from 'fs'

const load = (f) =>
  JSON.stringify(JSON.parse(fs.readFileSync(`packages/price-calculator/fixtures/${f}`, 'utf8')))

const loadCase = (f) =>
  JSON.parse(fs.readFileSync(`packages/price-calculator/fixtures/${f}`, 'utf8'))

const esc = (s) => s.replace(/'/g, "''")

const entries = [
  {
    slug: 'site_visit_travel_materials',
    title: {
      ca: 'Visita tècnica',
      es: 'Visita técnica',
      en: 'Site visit',
    },
    summary: {
      ca: "Desplaçament per distància + materials. Preus d'exemple; adapta'ls.",
      es: 'Desplazamiento + materiales. Precios de ejemplo.',
      en: 'Travel by distance + materials. Example prices.',
    },
    tags: ['visita', 'desplacament', 'materials'],
    def: load('site_visit.filled.json'),
    default_case: loadCase('site_visit.case.json'),
  },
  {
    slug: 'electrician_travel_labor',
    title: {
      ca: 'Electricista (desplaçament + potència)',
      es: 'Electricista',
      en: 'Electrician',
    },
    summary: {
      ca: "Desplaçament per km i hores segons kW. Preus d'exemple.",
      es: 'Desplazamiento y horas según kW.',
      en: 'Travel + labor by kW.',
    },
    tags: ['desplacament', 'electricitat'],
    def: load('electrician.filled.json'),
    default_case: loadCase('electrician.case.json'),
  },
  {
    slug: 'blinds_m2',
    title: {
      ca: 'Persianes €/m²',
      es: 'Persianas €/m²',
      en: 'Blinds €/m²',
    },
    summary: {
      ca: "Preu per m² segons model i mides. Preus d'exemple.",
      es: 'Precio por m² según modelo.',
      en: 'Price per m² by model.',
    },
    tags: ['m2', 'persianes'],
    def: load('blinds.filled.json'),
    default_case: loadCase('blinds.case.json'),
  },
  {
    slug: 'elevator_maintenance_annual',
    title: {
      ca: 'Manteniment ascensors (anual)',
      es: 'Mantenimiento ascensores',
      en: 'Elevator maintenance',
    },
    summary: {
      ca: "Quota anual per tipus de tracció + suplement per parades. Preus d'exemple.",
      es: 'Cuota anual + paradas.',
      en: 'Annual fee + per stop.',
    },
    tags: ['ascensors', 'manteniment'],
    def: load('elevator_maintenance.filled.json'),
    default_case: loadCase('elevator_maintenance.case.json'),
  },
  {
    slug: 'horeca_maintenance_monthly',
    title: {
      ca: 'Manteniment HORECA (mensual)',
      es: 'Mantenimiento HORECA',
      en: 'HORECA maintenance',
    },
    summary: {
      ca: "Quota mensual per coberts + fred industrial opcional. Preus d'exemple.",
      es: 'Cuota mensual por cubiertos.',
      en: 'Monthly fee by covers.',
    },
    tags: ['horeca', 'manteniment', 'restauracio'],
    def: load('horeca_maintenance.filled.json'),
    default_case: loadCase('horeca_maintenance.case.json'),
  },
]

const values = entries
  .map(
    (e) => `  (
    '${e.slug}',
    ARRAY['field_service']::text[],
    2,
    '${esc(e.def)}'::jsonb,
    ARRAY[${e.tags.map((t) => `'${t}'`).join(',')}]::text[],
    true,
    '${esc(JSON.stringify(e.title))}'::jsonb,
    '${esc(JSON.stringify(e.summary))}'::jsonb,
    '${esc(JSON.stringify(e.default_case))}'::jsonb
  )`,
  )
  .join(',\n')

const sql = `-- CF-29: catàleg ready (preus il·lustratius + default_case) + metadades UI
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
${values}
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
`

fs.writeFileSync(
  'supabase/migrations/20261264000001_cf29_calculator_catalog_ready.sql',
  sql,
)
console.log('wrote', sql.length, 'chars')
