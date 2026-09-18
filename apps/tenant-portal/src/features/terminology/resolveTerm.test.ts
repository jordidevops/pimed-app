import { describe, expect, it } from 'vitest'
import { foldTermValue, isTermKey, termBadges } from './termCatalog'
import { resolveTerm, sanitizeTermValue, sanitizeTerminologyMap, termOrigin } from './resolveTerm'

describe('sanitizeTermValue', () => {
  it('accepts typical overlays including Catalan punctuation', () => {
    expect(sanitizeTermValue('Obres')).toBe('Obres')
    expect(sanitizeTermValue('  Què es cobra  ')).toBe('Què es cobra')
    expect(sanitizeTermValue('Ordres de servei')).toBe('Ordres de servei')
  })

  it('rejects Pressupost / Albarà / Factura after folding accents', () => {
    expect(sanitizeTermValue('Pressupost')).toBeNull()
    expect(sanitizeTermValue('PRESSUPOST')).toBeNull()
    expect(sanitizeTermValue('Presupuesto')).toBeNull()
    expect(sanitizeTermValue('Albarà')).toBeNull()
    expect(sanitizeTermValue('Albarán')).toBeNull()
    expect(sanitizeTermValue('Factura')).toBeNull()
    expect(foldTermValue('Albarà')).toBe('albara')
  })

  it('does not treat Imports as a denylisted substring', () => {
    expect(sanitizeTermValue('Imports')).toBe('Imports')
    expect(sanitizeTermValue('Partides')).toBe('Partides')
  })

  it('rejects HTML, URLs, too short, too long, and bad charset', () => {
    expect(sanitizeTermValue('<script>')).toBeNull()
    expect(sanitizeTermValue('https://evil.example')).toBeNull()
    expect(sanitizeTermValue('A')).toBeNull()
    expect(sanitizeTermValue('x'.repeat(41))).toBeNull()
    expect(sanitizeTermValue('Full/preus')).toBeNull()
  })
})

describe('sanitizeTerminologyMap', () => {
  it('drops unknown keys including visit and quote', () => {
    const cleaned = sanitizeTerminologyMap({
      visit: 'Sortida',
      quote: 'Oferta',
      project: 'Obres',
      junk: 'Nope',
    })
    expect(cleaned).toEqual({ project: 'Obres' })
    expect(isTermKey('visit')).toBe(false)
    expect(isTermKey('quote')).toBe(false)
  })

  it('omits empty and denylisted values', () => {
    expect(
      sanitizeTerminologyMap({
        project: 'Obres',
        price_sheet: 'Pressupost',
        contact: '  ',
      }),
    ).toEqual({ project: 'Obres' })
  })
})

describe('resolveTerm', () => {
  const sector = { project: 'Ordre de servei', project_plural: 'Ordres de servei', contact: 'Client' }

  it('prefers tenant overlay over sector over fallback', () => {
    expect(resolveTerm('project', { tenant: { project: 'Obres' }, sector, fallback: 'Projecte' })).toBe(
      'Obres',
    )
    expect(resolveTerm('project', { tenant: {}, sector, fallback: 'Projecte' })).toBe('Ordre de servei')
    expect(resolveTerm('project', { tenant: {}, sector: {}, fallback: 'Projecte' })).toBe('Projecte')
  })

  it('ignores invalid overlay and unknown keys on the tenant map', () => {
    expect(
      resolveTerm('project', { tenant: { project: 'Pressupost' }, sector, fallback: 'Projecte' }),
    ).toBe('Ordre de servei')
    expect(resolveTerm('visit', { tenant: { visit: 'Sortida' }, sector, fallback: 'Visita' })).toBe(
      'Visita',
    )
  })

  it('resolves price_sheet from overlay then i18n (not sector seed)', () => {
    expect(
      resolveTerm('price_sheet', {
        tenant: { price_sheet: 'Imports' },
        sector,
        fallback: 'Full de preus',
      }),
    ).toBe('Imports')
    expect(
      resolveTerm('price_sheet', { tenant: {}, sector, fallback: 'Full de preus' }),
    ).toBe('Full de preus')
  })
})

describe('termOrigin', () => {
  const sector = { project: 'Ordre de servei', project_plural: 'Ordres de servei' }

  it('distinguishes tenant overlay from sector seed and platform fallback', () => {
    expect(termOrigin('project', { tenant: { project: 'Obra' }, sector })).toBe('tenant')
    expect(termOrigin('project', { tenant: {}, sector })).toBe('sector')
    expect(termOrigin('price_sheet', { tenant: {}, sector })).toBe('platform')
  })
})

describe('termBadges', () => {
  it('never suggests Pressupost for the price sheet', () => {
    expect(termBadges('price_sheet', 'field_service')).toEqual([
      'Imports',
      'Què es cobra',
      'Partides',
    ])
    expect(termBadges('project', 'field_service')).toEqual(['Obra', 'Ordre de servei'])
    expect(termBadges('project_plural', 'field_service')).toEqual(['Obres', 'Ordres de servei'])
  })
})
