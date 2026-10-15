import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { activationGaps, type Definition } from '../src/index.ts'

const base: Definition = {
  schema_version: 1,
  parameters: [],
  constants: [{ key: 'hour_eur', type: 'money', value: 45 }],
  tables: [
    {
      key: 'travel',
      lookup: 'tier',
      input: 'distance_km',
      bound_column: 'max_km',
      rows: [{ max_km: 10, eur_base: 0 }],
    },
  ],
  lines: [],
}

Deno.test('activationGaps: empty when complete', () => {
  assertEquals(activationGaps(base), [])
})

Deno.test('activationGaps: null constant', () => {
  const def: Definition = {
    ...base,
    constants: [{ key: 'hour_eur', type: 'money', value: null }],
  }
  assertEquals(activationGaps(def).map((i) => i.path), ['constants.hour_eur'])
})

Deno.test('activationGaps: assumed constant', () => {
  const def: Definition = {
    ...base,
    constants: [{ key: 'hour_eur', type: 'money', value: 45, assumed: true }],
  }
  assertEquals(activationGaps(def)[0]?.message, 'incomplete')
})

Deno.test('activationGaps: null table cell', () => {
  const def: Definition = {
    ...base,
    tables: [
      {
        key: 'travel',
        lookup: 'tier',
        input: 'distance_km',
        bound_column: 'max_km',
        rows: [{ max_km: 10, eur_base: null }],
      },
    ],
  }
  assertEquals(activationGaps(def).some((i) => i.message === 'incomplete'), true)
})

Deno.test('activationGaps: assumed row', () => {
  const def: Definition = {
    ...base,
    tables: [
      {
        key: 'travel',
        lookup: 'tier',
        input: 'distance_km',
        bound_column: 'max_km',
        rows: [{ max_km: 10, eur_base: 0, assumed: true }],
      },
    ],
  }
  assertEquals(activationGaps(def)[0]?.message, 'assumed')
})

Deno.test('activationGaps: open tier bound null is not a gap', () => {
  const def: Definition = {
    ...base,
    tables: [
      {
        key: 'travel',
        lookup: 'tier',
        input: 'distance_km',
        bound_column: 'max_km',
        rows: [
          { max_km: 10, eur_base: 0 },
          { max_km: null, eur_base: 25 },
        ],
      },
      {
        key: 'labor',
        lookup: 'tier',
        input: 'power_kw',
        bound_column: 'max_kw',
        rows: [
          { max_kw: 5, hours: 2 },
          { max_kw: null, hours: 8 },
        ],
      },
    ],
  }
  assertEquals(activationGaps(def), [])
})

Deno.test('activationGaps: null price on open tier row still gaps', () => {
  const def: Definition = {
    ...base,
    tables: [
      {
        key: 'travel',
        lookup: 'tier',
        input: 'distance_km',
        bound_column: 'max_km',
        rows: [{ max_km: null, eur_base: null }],
      },
    ],
  }
  assertEquals(
    activationGaps(def).map((i) => i.path),
    ['tables.travel[0].eur_base'],
  )
})
