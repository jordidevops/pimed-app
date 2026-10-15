import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import {
  applyLineOverrides,
  isPlaceholderBlankLine,
  needsQtyPricePrompt,
  run,
  type Definition,
} from '../src/index.ts'

const blankLineDef: Definition = {
  schema_version: 1,
  parameters: [],
  lines: [
    {
      key: 'blank',
      name: { ca: 'Buida' },
      kind: 'service',
      unit: 'u',
      quantity: {
        op: 'round',
        decimals: 3,
        mode: 'half_away_from_zero',
        value: { op: 'const', value: 1 },
      },
      unit_price: {
        op: 'round',
        decimals: 2,
        mode: 'half_away_from_zero',
        value: { op: 'const', value: 0 },
      },
      discount_pct: { op: 'const', value: 0 },
      tax_rate: { op: 'const', value: 21 },
      prompt_qty_price: true,
    },
  ],
}

Deno.test('placeholder blank line is detected; prompt only with flag', () => {
  assertEquals(isPlaceholderBlankLine(blankLineDef.lines[0]!), true)
  assertEquals(needsQtyPricePrompt(blankLineDef.lines[0]!), true)
  assertEquals(
    needsQtyPricePrompt({ ...blankLineDef.lines[0]!, prompt_qty_price: false }),
    false,
  )
  assertEquals(
    needsQtyPricePrompt({ ...blankLineDef.lines[0]!, prompt_qty_price: undefined }),
    false,
  )
})

Deno.test('run emits blank prompt line without zero_price error', () => {
  const result = run(blankLineDef, {}, 'ca')
  assertEquals(result.errors.length, 0)
  assertEquals(result.lines.length, 1)
  assertEquals(result.lines[0]!.unit_price, '0.00')
})

Deno.test('applyLineOverrides validates and formats', () => {
  const result = run(blankLineDef, {}, 'ca')
  const applied = applyLineOverrides(
    result.lines,
    { blank: { quantity: '2', unit_price: '15,5' } },
    blankLineDef,
  )
  assertEquals(applied.errors.length, 0)
  assertEquals(applied.lines[0]!.quantity, '2.000')
  assertEquals(applied.lines[0]!.unit_price, '15.50')
})

Deno.test('applyLineOverrides rejects zero price without allow_zero', () => {
  const result = run(blankLineDef, {}, 'ca')
  const applied = applyLineOverrides(
    result.lines,
    { blank: { quantity: '1', unit_price: '0' } },
    blankLineDef,
  )
  assertEquals(applied.errors.some((e) => e.code === 'zero_price_not_allowed'), true)
})
