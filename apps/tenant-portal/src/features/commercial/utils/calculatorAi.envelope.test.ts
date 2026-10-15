import { describe, expect, it } from 'vitest'
import {
  isPatchesDraft,
  parseCalculatorAiEnvelope,
  type CalculatorAiProposal,
} from './calculatorAi'
import type { Definition } from '@pimed/price-calculator'

const validDef: Definition = {
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

describe('parseCalculatorAiEnvelope', () => {
  it('parses clarify', () => {
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({
        mode: 'clarify',
        assistant_message: 'Cal més dades',
        questions: [{ id: 'q1', prompt: 'Quin €/h?' }],
      }),
      { scope: 'section' },
    )
    expect(env.mode).toBe('clarify')
    if (env.mode !== 'clarify') return
    expect(env.questions).toHaveLength(1)
    expect(env.questions[0]!.prompt).toContain('€/h')
  })

  it('parses section ready with parameter', () => {
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({
        mode: 'ready',
        parameter: { key: 'km', type: 'number', label: { ca: 'Km' }, required: true },
      }),
      { scope: 'section' },
    )
    expect(env.mode).toBe('ready')
    if (env.mode !== 'ready') return
    expect(env.payload).toMatchObject({ parameter: { key: 'km' } })
  })

  it('wraps legacy fragment as ready for section', () => {
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({
        constant: { key: 'eur_h', type: 'money', value: 40, label: { ca: '€/h' } },
      }),
      { scope: 'section' },
    )
    expect(env.mode).toBe('ready')
  })

  it('parses full proposal with draft + example.params', () => {
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({
        mode: 'proposal',
        assistant_message: 'Ok',
        summary: '40€/h',
        draft: validDef,
        example: { params: { hours: 2 } },
      }),
      { scope: 'full' },
    )
    expect(env.mode).toBe('proposal')
    if (env.mode !== 'proposal') return
    expect(env.example.params).toEqual({ hours: 2 })
    expect(isPatchesDraft(env.draft)).toBe(false)
  })

  it('rejects proposal without example.params', () => {
    expect(() =>
      parseCalculatorAiEnvelope(
        JSON.stringify({
          mode: 'proposal',
          summary: 'x',
          draft: validDef,
        }),
        { scope: 'full' },
      ),
    ).toThrow(/example\.params/)
  })

  it('coerces full ready with definition to proposal', () => {
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({ mode: 'ready', ...validDef }),
      { scope: 'full' },
    )
    expect(env.mode).toBe('proposal')
  })

  it('wraps legacy patches as proposal in full edit', () => {
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({ patches: [{ op: 'replace', path: '/constants/0/value', value: 50 }] }),
      { scope: 'full', editMode: true },
    ) as CalculatorAiProposal
    expect(env.mode).toBe('proposal')
    expect(isPatchesDraft(env.draft)).toBe(true)
  })

  it('coerces section proposal with nested parameter to ready', () => {
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({
        mode: 'proposal',
        summary: 'param',
        draft: {
          parameter: { key: 'km', type: 'number', label: { ca: 'Km' }, required: true },
        },
        example: { params: {} },
      }),
      { scope: 'section', sectionKind: 'parameter' },
    )
    expect(env.mode).toBe('ready')
    if (env.mode !== 'ready') return
    expect(env.payload).toMatchObject({ parameter: { key: 'km' } })
  })

  it('extracts constant from section proposal with full Definition draft', () => {
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({
        mode: 'proposal',
        summary: 'c',
        draft: validDef,
        example: { params: {} },
      }),
      {
        scope: 'section',
        sectionKind: 'constant',
        userPrompt: 'tarifa €/hora',
      },
    )
    expect(env.mode).toBe('ready')
    if (env.mode !== 'ready') return
    expect(env.payload).toMatchObject({ constant: { key: 'hour_eur' } })
  })

  it('picks fuel constant from Definition when prompt mentions benzina', () => {
    const draft = {
      ...validDef,
      constants: [
        { key: 'hour_eur', type: 'money', value: 40, label: { ca: '€/hora' } },
        { key: 'fuel_eur_l', type: 'money', value: null, assumed: true, label: { ca: '€/l benzina' } },
      ],
    }
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({ mode: 'proposal', summary: 'x', draft, example: { params: {} } }),
      {
        scope: 'section',
        sectionKind: 'constant',
        userPrompt: 'Vull una tarifa per calcular les despeses de benzina en un cotxe',
      },
    )
    expect(env.mode).toBe('ready')
    if (env.mode !== 'ready') return
    expect(env.payload).toMatchObject({ constant: { key: 'fuel_eur_l' } })
  })

  it('accepts bare constant as proposal draft', () => {
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({
        mode: 'proposal',
        summary: 'ok',
        draft: { key: 'fuel_eur_l', type: 'money', value: null, label: { ca: 'Benzina' } },
        example: { params: {} },
      }),
      { scope: 'section', sectionKind: 'constant' },
    )
    expect(env.mode).toBe('ready')
    if (env.mode !== 'ready') return
    expect(env.payload).toMatchObject({ constant: { key: 'fuel_eur_l' } })
  })

  it('synthesizes fuel constant when proposal has no usable fragment', () => {
    const env = parseCalculatorAiEnvelope(
      JSON.stringify({
        mode: 'proposal',
        summary: 'ok',
        draft: { schema_version: 1, parameters: [], constants: [], tables: [], lines: [] },
        example: { params: {} },
      }),
      {
        scope: 'section',
        sectionKind: 'constant',
        userPrompt: 'Vull una tarifa per calcular les despeses de benzina en un cotxe',
      },
    )
    expect(env.mode).toBe('ready')
    if (env.mode !== 'ready') return
    expect(env.payload).toMatchObject({
      constant: { key: 'fuel_eur_l', type: 'money', assumed: true },
    })
  })
})
