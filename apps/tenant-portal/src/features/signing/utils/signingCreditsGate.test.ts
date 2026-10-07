import { describe, expect, it } from 'vitest'
import {
  canOpenSigningOrchestrator,
  canSignWithDocuseal,
  canSignWithNative,
} from './signingCreditsGate'

const base = {
  featureEnabled: true,
  effectivelyActive: true,
  mode: 'platform' as const,
  credits: 0,
  nativeSigningEnabled: true,
}

describe('signingCreditsGate', () => {
  it('allows native with zero platform credits', () => {
    expect(canSignWithNative(base)).toBe(true)
    expect(canSignWithDocuseal(base)).toBe(false)
    expect(canOpenSigningOrchestrator(base)).toBe(true)
  })

  it('blocks DocuSeal until credits are available', () => {
    expect(canSignWithDocuseal({ ...base, credits: 2 })).toBe(true)
    expect(canSignWithDocuseal({ ...base, credits: 0 })).toBe(false)
  })

  it('blocks native when native signing is disabled', () => {
    expect(canSignWithNative({ ...base, nativeSigningEnabled: false })).toBe(false)
  })
})
