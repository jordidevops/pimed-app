import { describe, expect, it } from 'vitest'
import { validateDefinition, type Definition } from '@pimed/price-calculator'
import { defaultBlankLineExpr } from './CalculatorExprBuilder'

describe('CalculatorExprBuilder defaults', () => {
  it('blank line exprs pass the fase-1 validator', () => {
    const def: Definition = {
      schema_version: 1,
      parameters: [],
      lines: [
        {
          key: 'n',
          name: { ca: 'Nova' },
          kind: 'service',
          unit: 'u',
          quantity: defaultBlankLineExpr('quantity'),
          unit_price: defaultBlankLineExpr('unit_price'),
          discount_pct: defaultBlankLineExpr('discount'),
          tax_rate: defaultBlankLineExpr('tax'),
          allow_zero_price: true,
        },
      ],
    }
    expect(validateDefinition(def).ok).toBe(true)
  })
})
