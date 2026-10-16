import { describe, expect, it } from 'vitest'
import {
  applyCalculatorPatches,
  demoteUnconfirmedTariffNumbers,
  inferParameterHintsFromPrompt,
  normalizeCalculatorKey,
  parseAiCalculatorDefinition,
  parseAiCalculatorFragment,
  parseAiConstantProposal,
  parseAiParameterProposal,
} from './calculatorAi'
import type { Definition } from '@pimed/price-calculator'

const valid: Definition = {
  schema_version: 1,
  parameters: [
    { key: 'hours', type: 'number', required: true, label: { ca: 'Hores' } },
  ],
  constants: [{ key: 'hour_eur', type: 'money', value: 40 }],
  lines: [
    {
      key: 'labor',
      name: { ca: 'Mà d’obra' },
      kind: 'service',
      unit: 'h',
      quantity: {
        op: 'round',
        decimals: 3,
        mode: 'half_away_from_zero',
        value: { op: 'param', key: 'hours' },
      },
      unit_price: {
        op: 'round',
        decimals: 2,
        mode: 'half_away_from_zero',
        value: { op: 'const_ref', key: 'hour_eur' },
      },
      discount_pct: { op: 'const', value: 0 },
      tax_rate: { op: 'const', value: 21 },
    },
  ],
}

describe('calculatorAi', () => {
  it('accepts valid definition with holes after demote', () => {
    const withInvented = structuredClone(valid)
    withInvented.constants![0]!.value = 99
    const demoted = demoteUnconfirmedTariffNumbers(withInvented, 'Cobra 40 euros l’hora')
    expect(demoted.constants![0]!.value).toBeNull()
    expect(demoted.constants![0]!.assumed).toBe(true)
    expect(parseAiCalculatorDefinition(JSON.stringify(valid)).constants?.[0]?.value).toBe(40)
  })

  it('keeps numbers mentioned in the prompt', () => {
    const demoted = demoteUnconfirmedTariffNumbers(valid, 'Cobra 40 €/h')
    expect(demoted.constants![0]!.value).toBe(40)
  })

  it('strips unknown AI top-level keys (title/eval/inputs…)', () => {
    const parsed = parseAiCalculatorDefinition(
      JSON.stringify({ ...valid, eval: '1+1', title: 'X', inputs: [] }),
    )
    expect(parsed).not.toHaveProperty('eval')
    expect(parsed).not.toHaveProperty('title')
    expect(parsed).not.toHaveProperty('inputs')
    expect(parsed.schema_version).toBe(1)
    expect(parsed.lines).toHaveLength(1)
  })

  it('coerces AI map-shaped arrays without iterable crash', () => {
    const asMaps = {
      schema_version: 1,
      parameters: { 0: valid.parameters[0] },
      constants: { 0: valid.constants![0] },
      tables: {},
      lines: { 0: valid.lines[0] },
    }
    const parsed = parseAiCalculatorDefinition(JSON.stringify(asMaps))
    expect(parsed.parameters).toHaveLength(1)
    expect(parsed.lines).toHaveLength(1)
    expect(parsed.constants).toHaveLength(1)
  })

  it('maps inputs → parameters when parameters missing', () => {
    const raw = {
      schema_version: 1,
      inputs: [{ key: 'hours', type: 'number', name: 'Hores', unit: 'h' }],
      constants: valid.constants,
      lines: valid.lines,
    }
    const parsed = parseAiCalculatorDefinition(JSON.stringify(raw))
    expect(parsed.parameters[0]?.key).toBe('hours')
    expect(parsed.parameters[0]?.label.ca).toBe('Hores')
  })

  it('coerces symbolic ops (-, +) and args-shaped sub', () => {
    const raw = {
      schema_version: 1,
      parameters: valid.parameters,
      constants: valid.constants,
      lines: [
        {
          ...valid.lines[0],
          key: 'travel',
          quantity: {
            op: 'round',
            decimals: 3,
            mode: 'half_away_from_zero',
            value: {
              op: 'mul',
              args: [
                { op: 'param', key: 'hours' },
                {
                  op: '-',
                  args: [
                    { op: 'const', value: 10 },
                    { op: 'const', value: 2 },
                  ],
                },
              ],
            },
          },
        },
      ],
    }
    const parsed = parseAiCalculatorDefinition(JSON.stringify(raw))
    const qty = parsed.lines[0]!.quantity
    expect(qty.op).toBe('round')
    if (qty.op !== 'round') throw new Error('expected round')
    expect(qty.value.op).toBe('mul')
    if (qty.value.op !== 'mul') throw new Error('expected mul')
    const sub = qty.value.args[1]
    expect(sub).toMatchObject({
      op: 'sub',
      left: { op: 'const', value: 10 },
      right: { op: 'const', value: 2 },
    })
  })

  it('applies patch lot atomically', () => {
    const next = applyCalculatorPatches(valid, [
      { op: 'replace', path: '/constants/0/value', value: 45 },
    ])
    expect(next.constants![0]!.value).toBe(45)
    expect(() =>
      applyCalculatorPatches(valid, [
        { op: 'replace', path: '/constants/0/value', value: 45 },
        { op: 'add', path: '/eval', value: true },
      ]),
    ).toThrow()
    expect(valid.constants![0]!.value).toBe(40)
  })

  it('normalizes AI keys to snake_case', () => {
    expect(normalizeCalculatorKey('Pes')).toBe('pes')
    expect(normalizeCalculatorKey('Weight (kg)')).toBe('weight_kg')
    expect(normalizeCalculatorKey('weightKg')).toBe('weightkg')
    expect(normalizeCalculatorKey('distància km')).toBe('distancia_km')
  })

  it('accepts parameter fragments with human keys', () => {
    const empty: Definition = {
      schema_version: 1,
      parameters: [],
      constants: [],
      lines: [],
    }
    const next = parseAiCalculatorFragment(
      JSON.stringify({
        parameter: {
          key: 'Pes',
          type: 'number',
          label: { ca: 'Pes' },
          unit: 'kg',
        },
      }),
      'parameter',
      empty,
    )
    expect(next.parameters[0]?.key).toBe('pes')
    expect(next.parameters[0]?.label.ca).toBe('Pes')
    expect(next.parameters[0]?.unit).toBe('kg')
  })

  it('infers pes from user prompt when AI returns generic names', () => {
    expect(inferParameterHintsFromPrompt('Vull un paràmetre per entrar el pes')).toEqual({
      label: 'Pes',
      key: 'weight_kg',
      unit: 'kg',
    })
    const empty: Definition = {
      schema_version: 1,
      parameters: [],
      constants: [],
      lines: [],
    }
    const next = parseAiCalculatorFragment(
      JSON.stringify({
        parameter: { key: 'parametre', type: 'number', label: { ca: 'Paràmetre' } },
      }),
      'parameter',
      empty,
      'Vull un paràmetre per entrar el pes',
    )
    expect(next.parameters[0]?.key).toBe('weight_kg')
    expect(next.parameters[0]?.label.ca).toBe('Pes')
    expect(next.parameters[0]?.unit).toBe('kg')
  })

  it('builds a parameter proposal without mutating definition', () => {
    const proposal = parseAiParameterProposal(
      JSON.stringify({
        parameter: { key: 'parametre', type: 'number', label: { ca: 'Paràmetre' } },
      }),
      'Vull un paràmetre per entrar el pes',
    )
    expect(proposal.key).toBe('weight_kg')
    expect(proposal.label.ca).toBe('Pes')
    expect(proposal.unit).toBe('kg')
  })

  it('replaces generic constant names from the prompt and keeps AI estimates as assumed', () => {
    const proposal = parseAiConstantProposal(
      JSON.stringify({
        constant: {
          key: 'constant',
          type: 'money',
          label: { ca: 'Constant' },
          value: 1.62,
        },
      }),
      'Vull una tarifa per calcular les despeses de benzina en un cotxe',
    )
    expect(proposal.key).toBe('fuel_eur_l')
    expect(proposal.label.ca).toBe('€/l benzina')
    expect(proposal.value).toBe(1.62)
    expect(proposal.assumed).toBe(true)
  })
})
