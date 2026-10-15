import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { Dec, lineNet, run, type Definition } from './mod.ts'

const electrician: Definition = JSON.parse(
  await Deno.readTextFile(
    new URL('../../../../packages/price-calculator/fixtures/electrician.filled.json', import.meta.url),
  ),
)

Deno.test('_shared reexport runs electrician oracle', () => {
  assertEquals(Dec.from('1.005').round(2).toFixed(2), '1.01')
  const r = run(electrician, { distance_km: 40, power_kw: 20 })
  assertEquals(r.errors, [])
  assertEquals(r.lines[0]!.unit_price, '37.00')
  assertEquals(lineNet('8', '45', '0').toFixed(2), '360.00')
})
