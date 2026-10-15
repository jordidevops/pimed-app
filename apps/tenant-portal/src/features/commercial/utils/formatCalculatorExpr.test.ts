import { describe, expect, it } from 'vitest'
import type { Definition } from '@pimed/price-calculator'
import { formatCalculatorExpr, formatLineFormula } from './formatCalculatorExpr'

const def: Definition = {
  schema_version: 1,
  parameters: [
    { key: 'hours', type: 'number', label: { ca: 'Hores' }, unit: 'h' },
    { key: 'distance_km', type: 'number', label: { ca: 'Distància' }, unit: 'km' },
  ],
  constants: [
    { key: 'labor_eur_h', type: 'money', value: 45, label: { ca: '€/hora mà d’obra' } },
  ],
  tables: [
    {
      key: 'travel',
      lookup: 'tier',
      input: 'distance_km',
      bound_column: 'max_km',
      column_help: { eur_base: { ca: 'Import base' } },
      rows: [],
    },
  ],
  lines: [],
}

describe('formatCalculatorExpr', () => {
  it('renders param × const_ref', () => {
    expect(
      formatLineFormula(
        { op: 'param', key: 'hours' },
        { op: 'const_ref', key: 'labor_eur_h' },
        def,
      ).product,
    ).toBe('Hores × €/hora mà d’obra')
  })

  it('unwraps round and formats lookup_tier + row', () => {
    const expr = {
      op: 'round' as const,
      value: {
        op: 'lookup_tier' as const,
        table: 'travel',
        value: { op: 'row' as const, field: 'eur_base' },
      },
      decimals: 2 as const,
      mode: 'half_away_from_zero' as const,
    }
    expect(formatCalculatorExpr(expr, def)).toBe(
      'Import base de la taula «travel» pel paràmetre Distància',
    )
  })

  it('formats mul/div with parentheses when needed', () => {
    expect(
      formatCalculatorExpr(
        {
          op: 'mul',
          args: [
            { op: 'param', key: 'hours' },
            {
              op: 'add',
              args: [
                { op: 'const', value: 1 },
                { op: 'const', value: 2 },
              ],
            },
          ],
        },
        def,
      ),
    ).toBe('Hores × (1 + 2)')
  })
})
