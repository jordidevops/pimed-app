import fs from 'fs'

const esc = (s) => s.replace(/'/g, "''")

const entries = [
  { slug: 'site_visit_travel_materials', caseFile: 'site_visit.case.json' },
  { slug: 'electrician_travel_labor', caseFile: 'electrician.case.json' },
  { slug: 'blinds_m2', caseFile: 'blinds.case.json' },
  { slug: 'elevator_maintenance_annual', caseFile: 'elevator_maintenance.case.json' },
  { slug: 'horeca_maintenance_monthly', caseFile: 'horeca_maintenance.case.json' },
]

const updates = entries
  .map((e) => {
    const payload = fs.readFileSync(
      `packages/price-calculator/fixtures/${e.caseFile}`,
      'utf8',
    )
    return `UPDATE data.calculator_catalog
SET default_case = '${esc(payload.trim())}'::jsonb,
    updated_at = now()
WHERE slug = '${e.slug}';`
  })
  .join('\n\n')

const sql = `-- CF-29: default_case amb expected_lines precalculades (paritat motor)
${updates}
`

fs.writeFileSync(
  'supabase/migrations/20261265000001_cf29_catalog_default_case_expected.sql',
  sql,
)
console.log('wrote', sql.length, 'chars')
