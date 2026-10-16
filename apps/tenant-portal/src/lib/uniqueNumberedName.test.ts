import { describe, expect, it } from 'vitest'
import { nextUniqueNumberedName } from './uniqueNumberedName'

describe('nextUniqueNumberedName', () => {
  it('returns base when free', () => {
    expect(nextUniqueNumberedName('Pressupost', ['Altra'])).toBe('Pressupost')
  })

  it('returns Base (2) when base exists', () => {
    expect(nextUniqueNumberedName('Pressupost', ['Pressupost'])).toBe('Pressupost (2)')
  })

  it('skips to next free number', () => {
    expect(nextUniqueNumberedName('Foo', ['Foo', 'Foo (2)', 'Foo (3)'])).toBe('Foo (4)')
  })

  it('uses empty fallback', () => {
    expect(nextUniqueNumberedName('  ', [], 'Plantilla')).toBe('Plantilla')
  })
})
