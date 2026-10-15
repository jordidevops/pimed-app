import { readFileSync, writeFileSync } from 'fs'
import { createRequire } from 'module'
import { register } from 'node:module'
import { pathToFileURL } from 'node:url'

// Load TS via tsx if available as child — fallback: spawn note
const cases = [
  {
    fixture: 'site_visit.filled.json',
    name: '25 km / 4 materials',
    params: { distance_km: 25, material_units: 4 },
    out: 'site_visit.case.json',
  },
  {
    fixture: 'electrician.filled.json',
    name: '20 km / 3 kW',
    params: { distance_km: 20, power_kw: 3 },
    out: 'electrician.case.json',
  },
  {
    fixture: 'blinds.filled.json',
    name: 'PVC 100×150 ×2',
    params: { model: 'pvc', width_cm: 100, height_cm: 150, units: 2 },
    out: 'blinds.case.json',
  },
  {
    fixture: 'elevator_maintenance.filled.json',
    name: 'Elèctric 6 parades',
    params: { stops: 6, drive_type: 'electric' },
    out: 'elevator_maintenance.case.json',
  },
  {
    fixture: 'horeca_maintenance.filled.json',
    name: '60 coberts + càmera bàsica',
    params: { covers: 60, cold_addon: 'basic' },
    out: 'horeca_maintenance.case.json',
  },
]

const { run } = await import('../packages/price-calculator/src/index.ts')

for (const c of cases) {
  const def = JSON.parse(
    readFileSync(`packages/price-calculator/fixtures/${c.fixture}`, 'utf8'),
  )
  const r = run(def, c.params, 'ca')
  if (r.errors.length) {
    console.error(c.fixture, r.errors)
    process.exit(1)
  }
  const payload = { name: c.name, params: c.params, expected_lines: r.lines }
  writeFileSync(
    `packages/price-calculator/fixtures/${c.out}`,
    JSON.stringify(payload, null, 2) + '\n',
  )
  console.log('ok', c.out, r.lines.length, 'lines')
}
