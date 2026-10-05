import { describe, expect, it } from 'vitest'
import {
  centsToEuros,
  eurosToCents,
  marginBpsToPercent,
  percentToMarginBps,
  suggestPvpEurosFromCost,
} from './catalogMoney'

describe('CF-19 money helpers', () => {
  it('eurosToCents rounds half-up and accepts comma decimals', () => {
    expect(eurosToCents('12.50')).toBe(1250)
    expect(eurosToCents('12,50')).toBe(1250)
    expect(eurosToCents(12.5)).toBe(1250)
    expect(eurosToCents('0')).toBe(0)
    expect(eurosToCents('-1')).toBeNull()
    expect(eurosToCents('abc')).toBeNull()
    expect(eurosToCents('')).toBeNull()
  })

  it('centsToEuros formats two decimals', () => {
    expect(centsToEuros(1250)).toBe('12.50')
    expect(centsToEuros(0)).toBe('0.00')
    expect(centsToEuros(null)).toBe('')
    expect(centsToEuros(undefined)).toBe('')
  })

  it('margin bps ↔ percent', () => {
    expect(percentToMarginBps('50')).toBe(5000)
    expect(percentToMarginBps('50,5')).toBe(5050)
    expect(percentToMarginBps(99)).toBe(9900)
    expect(percentToMarginBps(100)).toBeNull()
    expect(percentToMarginBps(-1)).toBeNull()
    expect(marginBpsToPercent(5000)).toBe('50.00')
    expect(marginBpsToPercent(null)).toBe('')
  })

  it('suggestPvpEurosFromCost matches margin-on-sale formula (SQL twin)', () => {
    // 10€ cost, 50% margin → 20€ PVP (same assert as commercial_cf19 SQL)
    expect(suggestPvpEurosFromCost(1000, 5000)).toBe(20)
    expect(suggestPvpEurosFromCost(1250, 0)).toBe(12.5)
    expect(suggestPvpEurosFromCost(1000, 10000)).toBeNull()
    expect(suggestPvpEurosFromCost(-1, 1000)).toBeNull()
  })
})
