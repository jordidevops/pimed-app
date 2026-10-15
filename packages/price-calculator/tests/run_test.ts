import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import {
  Dec,
  hashLines,
  lineNet,
  lineTax,
  previewTotals,
  run,
  validateDefinition,
  type Definition,
} from '../src/index.ts'

const electrician = JSON.parse(
  await Deno.readTextFile(new URL('../fixtures/electrician.filled.json', import.meta.url)),
) as Definition
const electricianLib = JSON.parse(
  await Deno.readTextFile(new URL('../fixtures/electrician.library.json', import.meta.url)),
) as Definition
const blinds = JSON.parse(
  await Deno.readTextFile(new URL('../fixtures/blinds.filled.json', import.meta.url)),
) as Definition
const blindsLib = JSON.parse(
  await Deno.readTextFile(new URL('../fixtures/blinds.library.json', import.meta.url)),
) as Definition

Deno.test('ROUND half away from zero matches Postgres vectors', () => {
  assertEquals(Dec.from('1.005').round(2).toFixed(2), '1.01')
  assertEquals(Dec.from('1.004').round(2).toFixed(2), '1.00')
  assertEquals(Dec.from('-1.5').round(0).toFixed(0), '-2')
  assertEquals(lineNet('1', '100', '10').toFixed(2), '90.00')
  assertEquals(lineTax('10.01', '21').toFixed(2), '2.10')
})

Deno.test('D10 vector: one-step vs two-step diverge', () => {
  // qty 1.236 * price 81 * 1.21 rounded once = 121.14
  // two-step: net ROUND(1.236*81,2)=100.12; tax ROUND(100.12*0.21,2)=21.03; total=121.15
  const oneStep = Dec.from('1.236').mul(Dec.from('81')).mul(Dec.from('1.21')).round(2)
  const net = lineNet('1.236', '81', '0')
  const tax = lineTax(net, '21')
  const twoStep = net.add(tax)
  assertEquals(oneStep.toFixed(2), '121.14')
  assertEquals(twoStep.toFixed(2), '121.15')
})

Deno.test('electrician oracles', () => {
  const v = validateDefinition(electrician)
  assertEquals(v.ok, true)

  const a = run(electrician, { distance_km: 0, power_kw: 3 })
  assertEquals(a.errors, [])
  assertEquals(a.lines.length, 1)
  assertEquals(a.lines[0]!.key, 'labor')
  assertEquals(a.lines[0]!.quantity, '2.000')
  assertEquals(a.lines[0]!.unit_price, '45.00')
  const ta = previewTotals(a.lines)
  assertEquals(ta.subtotal, '90.00')
  assertEquals(ta.tax_total, '18.90')
  assertEquals(ta.total, '108.90')

  const b = run(electrician, { distance_km: 20, power_kw: 3 })
  assertEquals(b.errors, [])
  assertEquals(b.lines.map((l) => l.key), ['travel', 'labor'])
  assertEquals(b.lines[0]!.unit_price, '25.00')
  const tb = previewTotals(b.lines)
  assertEquals(tb.subtotal, '115.00')
  assertEquals(tb.tax_total, '24.15')

  const c = run(electrician, { distance_km: 40, power_kw: 20 })
  assertEquals(c.errors, [])
  assertEquals(c.lines[0]!.unit_price, '37.00')
  assertEquals(c.lines[1]!.quantity, '8.000')
  assertEquals(c.lines[1]!.unit_price, '45.00')
  const tc = previewTotals(c.lines)
  assertEquals(tc.subtotal, '397.00')
  assertEquals(tc.tax_total, '83.37')
})

Deno.test('blinds oracles', () => {
  assertEquals(validateDefinition(blinds).ok, true)
  const a = run(blinds, { model: 'pvc', width_cm: 100, height_cm: 150, units: 2 })
  assertEquals(a.errors, [])
  assertEquals(a.lines[0]!.quantity, '3.000')
  assertEquals(a.lines[0]!.unit_price, '80.00')
  assertEquals(a.lines[0]!.name, 'Persiana PVC')
  assertEquals(previewTotals(a.lines).subtotal, '240.00')
  assertEquals(previewTotals(a.lines).tax_total, '50.40')

  const b = run(blinds, { model: 'pvc', width_cm: 50, height_cm: 50, units: 1 })
  assertEquals(b.lines[0]!.quantity, '1.000')
  assertEquals(previewTotals(b.lines).subtotal, '80.00')
  assertEquals(previewTotals(b.lines).tax_total, '16.80')
})

Deno.test('library holes fail with tariff_incomplete', () => {
  const a = run(electricianLib, { distance_km: 20, power_kw: 3 })
  assertEquals(a.lines, [])
  assertEquals(a.errors[0]!.code, 'tariff_incomplete')

  const b = run(blindsLib, { model: 'pvc', width_cm: 100, height_cm: 100, units: 1 })
  assertEquals(b.lines, [])
  assertEquals(b.errors[0]!.code, 'tariff_incomplete')
})

Deno.test('validator rejects eval and deep AST', () => {
  const bad = { ...electrician, eval: '1+1' }
  assertEquals(validateDefinition(bad).ok, false)

  const withoutRound = structuredClone(electrician)
  withoutRound.lines[1]!.quantity = { op: 'const', value: 2 } as never
  assertEquals(validateDefinition(withoutRound).ok, false)
})

Deno.test('hash is stable', async () => {
  const r = run(electrician, { distance_km: 20, power_kw: 3 })
  const h1 = await hashLines(r.lines)
  const h2 = await hashLines(r.lines)
  assertEquals(h1, h2)
  assertEquals(h1.length, 64)
})

const siteVisit = JSON.parse(
  await Deno.readTextFile(new URL('../fixtures/site_visit.filled.json', import.meta.url)),
) as Definition
const elevator = JSON.parse(
  await Deno.readTextFile(new URL('../fixtures/elevator_maintenance.filled.json', import.meta.url)),
) as Definition
const horeca = JSON.parse(
  await Deno.readTextFile(new URL('../fixtures/horeca_maintenance.filled.json', import.meta.url)),
) as Definition

Deno.test('site visit fixture runs', () => {
  assertEquals(validateDefinition(siteVisit).ok, true)
  const r = run(siteVisit, { distance_km: 25, material_units: 4 }, 'ca')
  assertEquals(r.errors, [])
  assertEquals(r.lines.length, 2)
})

Deno.test('elevator maintenance fixture runs', () => {
  assertEquals(validateDefinition(elevator).ok, true)
  const r = run(elevator, { stops: 6, drive_type: 'electric' }, 'ca')
  assertEquals(r.errors, [])
  assertEquals(r.lines.length, 2)
  assertEquals(r.lines[0]!.unit_price, '900.00')
  assertEquals(r.lines[1]!.quantity, '6.000')
})

Deno.test('horeca maintenance fixture runs', () => {
  assertEquals(validateDefinition(horeca).ok, true)
  const r = run(horeca, { covers: 60, cold_addon: 'basic' }, 'ca')
  assertEquals(r.errors, [])
  assertEquals(r.lines.length, 2)
  assertEquals(r.lines[0]!.unit_price, '320.00')
})

async function assertCaseParity(fixtureName: string, caseName: string) {
  const def = JSON.parse(
    await Deno.readTextFile(new URL(`../fixtures/${fixtureName}`, import.meta.url)),
  ) as Definition
  const cas = JSON.parse(
    await Deno.readTextFile(new URL(`../fixtures/${caseName}`, import.meta.url)),
  ) as { params: Record<string, string | number>; expected_lines: unknown[] }
  const r = run(def, cas.params, 'ca')
  assertEquals(r.errors, [])
  assertEquals(JSON.stringify(r.lines), JSON.stringify(cas.expected_lines))
}

Deno.test('case parity: site visit', async () => {
  await assertCaseParity('site_visit.filled.json', 'site_visit.case.json')
})
Deno.test('case parity: electrician', async () => {
  await assertCaseParity('electrician.filled.json', 'electrician.case.json')
})
Deno.test('case parity: blinds', async () => {
  await assertCaseParity('blinds.filled.json', 'blinds.case.json')
})
Deno.test('case parity: elevator', async () => {
  await assertCaseParity('elevator_maintenance.filled.json', 'elevator_maintenance.case.json')
})
Deno.test('case parity: horeca', async () => {
  await assertCaseParity('horeca_maintenance.filled.json', 'horeca_maintenance.case.json')
})
