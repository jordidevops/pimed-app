import { describe, expect, it } from 'vitest'
import {
  parseFieldServiceHomePreference,
  resolveFieldServiceHomePath,
} from './resolveFieldServiceHome'

describe('parseFieldServiceHomePreference', () => {
  it('defaults unknown values to auto', () => {
    expect(parseFieldServiceHomePreference(undefined)).toBe('auto')
    expect(parseFieldServiceHomePreference('today')).toBe('auto')
  })

  it('accepts stored values', () => {
    expect(parseFieldServiceHomePreference('field_today')).toBe('field_today')
    expect(parseFieldServiceHomePreference('dashboard')).toBe('dashboard')
    expect(parseFieldServiceHomePreference('auto')).toBe('auto')
  })
})

describe('resolveFieldServiceHomePath', () => {
  it('keeps non-FS tenants on dashboard', () => {
    expect(
      resolveFieldServiceHomePath({
        isFieldService: false,
        role: 'member',
        isLargeScreen: false,
      }),
    ).toBe('/dashboard')
  })

  it('sends members and viewers always to Avui', () => {
    expect(
      resolveFieldServiceHomePath({
        isFieldService: true,
        role: 'member',
        isLargeScreen: true,
        preference: 'dashboard',
      }),
    ).toBe('/field/today')
    expect(
      resolveFieldServiceHomePath({
        isFieldService: true,
        role: 'viewer',
        isLargeScreen: true,
      }),
    ).toBe('/field/today')
  })

  it('uses auto: mobile Avui, desktop Inici for office roles', () => {
    expect(
      resolveFieldServiceHomePath({
        isFieldService: true,
        role: 'owner',
        isLargeScreen: false,
      }),
    ).toBe('/field/today')
    expect(
      resolveFieldServiceHomePath({
        isFieldService: true,
        role: 'manager',
        isLargeScreen: true,
      }),
    ).toBe('/dashboard')
  })

  it('honours an explicit office preference', () => {
    expect(
      resolveFieldServiceHomePath({
        isFieldService: true,
        role: 'owner',
        isLargeScreen: true,
        preference: 'field_today',
      }),
    ).toBe('/field/today')
    expect(
      resolveFieldServiceHomePath({
        isFieldService: true,
        role: 'manager',
        isLargeScreen: false,
        preference: 'dashboard',
      }),
    ).toBe('/dashboard')
  })
})
