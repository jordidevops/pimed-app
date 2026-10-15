import { describe, expect, it } from 'vitest'
import { readWhenMode, writeWhenMode } from './calculatorWhenMode'
import type { Parameter } from '@pimed/price-calculator'

const boolParams: Parameter[] = [
  { key: 'include_travel', type: 'boolean', label: { ca: 'Desplaçament' } },
]

describe('calculatorWhenMode', () => {
  it('maps always / never / bool', () => {
    expect(readWhenMode(undefined, boolParams).mode).toBe('always')
    expect(readWhenMode({ op: 'const', value: false }, boolParams).mode).toBe('never')
    expect(readWhenMode({ op: 'param', key: 'include_travel' }, boolParams)).toEqual({
      mode: 'bool_param',
      paramKey: 'include_travel',
    })
    expect(writeWhenMode('always')).toBeUndefined()
    expect(writeWhenMode('never')).toEqual({ op: 'const', value: false })
    expect(writeWhenMode('bool_param', 'include_travel')).toEqual({
      op: 'param',
      key: 'include_travel',
    })
  })

  it('marks complex when as read-only', () => {
    expect(
      readWhenMode(
        {
          op: 'cmp',
          cmp: 'gt',
          left: { op: 'param', key: 'distance_km' },
          right: { op: 'const', value: 0 },
        },
        boolParams,
      ).mode,
    ).toBe('complex')
  })
})
