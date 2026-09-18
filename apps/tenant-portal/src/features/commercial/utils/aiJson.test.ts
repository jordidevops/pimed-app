import { describe, expect, it } from 'vitest'
import { matchCatalogItemId, matchNamedId, parseAiJsonContent } from './aiJson'

describe('parseAiJsonContent', () => {
  it('parses fenced json', () => {
    const raw = '```json\n{"name":"Visita"}\n```'
    expect(parseAiJsonContent(raw)).toEqual({ name: 'Visita' })
  })
})

describe('matchCatalogItemId', () => {
  const items = [
    { id: 'a', name: 'Hora tècnic' },
    { id: 'b', name: 'Visita de diagnosi' },
  ]

  it('matches exact names case-insensitively', () => {
    expect(matchCatalogItemId('hora tècnic', items)).toBe('a')
  })

  it('matches a unique partial name', () => {
    expect(matchCatalogItemId('diagnosi', items)).toBe('b')
  })

  it('does not invent ids when ambiguous', () => {
    expect(matchCatalogItemId('i', items)).toBeNull()
  })
})

describe('matchNamedId', () => {
  it('matches unique checklist titles', () => {
    expect(
      matchNamedId('visita', [{ id: 'c1', name: 'Visita estàndard' }]),
    ).toBe('c1')
  })
})
