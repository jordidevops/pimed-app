import { describe, expect, it } from 'vitest'
import {
  Dec,
  activationGaps,
  hashLines,
  lineNet,
  lineTax,
  previewTotals,
  run,
  validateDefinition,
  type Definition,
} from '@pimed/price-calculator'
import electrician from '../../../../../../../packages/price-calculator/fixtures/electrician.filled.json'
import blinds from '../../../../../../../packages/price-calculator/fixtures/blinds.filled.json'
import electricianLib from '../../../../../../../packages/price-calculator/fixtures/electrician.library.json'
import siteVisit from '../../../../../../../packages/price-calculator/fixtures/site_visit.filled.json'
import siteVisitCase from '../../../../../../../packages/price-calculator/fixtures/site_visit.case.json'
import electricianCase from '../../../../../../../packages/price-calculator/fixtures/electrician.case.json'
import blindsCase from '../../../../../../../packages/price-calculator/fixtures/blinds.case.json'
import elevator from '../../../../../../../packages/price-calculator/fixtures/elevator_maintenance.filled.json'
import elevatorCase from '../../../../../../../packages/price-calculator/fixtures/elevator_maintenance.case.json'
import horeca from '../../../../../../../packages/price-calculator/fixtures/horeca_maintenance.filled.json'
import horecaCase from '../../../../../../../packages/price-calculator/fixtures/horeca_maintenance.case.json'

describe('price-calculator (portal)', () => {
  it('matches Postgres ROUND vectors', () => {
    expect(Dec.from('1.005').round(2).toFixed(2)).toBe('1.01')
    expect(Dec.from('1.004').round(2).toFixed(2)).toBe('1.00')
    expect(Dec.from('-1.5').round(0).toFixed(0)).toBe('-2')
    expect(lineNet('1', '100', '10').toFixed(2)).toBe('90.00')
    expect(lineTax('10.01', '21').toFixed(2)).toBe('2.10')
  })

  it('D10 one-step vs two-step', () => {
    const oneStep = Dec.from('1.236').mul(Dec.from('81')).mul(Dec.from('1.21')).round(2)
    const net = lineNet('1.236', '81', '0')
    const twoStep = net.add(lineTax(net, '21'))
    expect(oneStep.toFixed(2)).toBe('121.14')
    expect(twoStep.toFixed(2)).toBe('121.15')
  })

  it('electrician oracles', () => {
    expect(validateDefinition(electrician).ok).toBe(true)
    const a = run(electrician as Definition, { distance_km: 0, power_kw: 3 })
    expect(a.errors).toEqual([])
    expect(a.lines).toHaveLength(1)
    expect(previewTotals(a.lines).total).toBe('108.90')

    const b = run(electrician as Definition, { distance_km: 40, power_kw: 20 })
    expect(b.lines[0]!.unit_price).toBe('37.00')
    expect(b.lines[1]!.quantity).toBe('8.000')
    expect(previewTotals(b.lines).subtotal).toBe('397.00')
  })

  it('blinds oracles', () => {
    const a = run(blinds as Definition, {
      model: 'pvc',
      width_cm: 100,
      height_cm: 150,
      units: 2,
    })
    expect(a.lines[0]!.quantity).toBe('3.000')
    expect(previewTotals(a.lines).tax_total).toBe('50.40')
  })

  it('library fails tariff_incomplete', () => {
    const r = run(electricianLib as Definition, { distance_km: 20, power_kw: 3 })
    expect(r.lines).toEqual([])
    expect(r.errors[0]!.code).toBe('tariff_incomplete')
  })

  it('hash stable', async () => {
    const r = run(electrician as Definition, { distance_km: 20, power_kw: 3 })
    const h = await hashLines(r.lines)
    expect(h).toHaveLength(64)
    expect(await hashLines(r.lines)).toBe(h)
  })

  it('open tier bound null is not an activation gap', () => {
    expect(activationGaps(electrician as Definition)).toEqual([])
  })

  it('case parity fixtures', () => {
    const pairs = [
      [siteVisit, siteVisitCase],
      [electrician, electricianCase],
      [blinds, blindsCase],
      [elevator, elevatorCase],
      [horeca, horecaCase],
    ] as const
    for (const [def, cas] of pairs) {
      const r = run(def as Definition, cas.params as never, 'ca')
      expect(r.errors).toEqual([])
      expect(r.lines).toEqual(cas.expected_lines)
    }
  })
})
