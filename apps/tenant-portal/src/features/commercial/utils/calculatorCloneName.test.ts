import { describe, expect, it } from 'vitest'
import { nextCalculatorCloneName } from './calculatorCloneName'

describe('nextCalculatorCloneName', () => {
  it('returns base when free', () => {
    expect(nextCalculatorCloneName('Visita tècnica', ['Altra'])).toBe('Visita tècnica')
  })

  it('returns Base (2) when base exists', () => {
    expect(nextCalculatorCloneName('Visita tècnica', ['Visita tècnica'])).toBe(
      'Visita tècnica (2)',
    )
  })

  it('skips to next free number', () => {
    expect(
      nextCalculatorCloneName('Foo', ['Foo', 'Foo (2)', 'Foo (3)']),
    ).toBe('Foo (4)')
  })

  it('ignores archived-style gaps only by exact name set', () => {
    expect(nextCalculatorCloneName('Foo', ['Foo (2)'])).toBe('Foo')
  })

  it('trims base and falls back when empty', () => {
    expect(nextCalculatorCloneName('  ', [])).toBe('Calculadora')
  })
})
