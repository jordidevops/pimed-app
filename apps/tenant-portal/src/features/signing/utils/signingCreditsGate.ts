export type SigningCreditsGateInput = {
  featureEnabled: boolean
  effectivelyActive: boolean
  mode: string | null | undefined
  credits: number
  nativeSigningEnabled: boolean
}

export function canSignWithDocuseal(input: SigningCreditsGateInput): boolean {
  if (!input.featureEnabled || !input.effectivelyActive) return false
  if (input.mode === 'platform' && input.credits <= 0) return false
  return true
}

export function canSignWithNative(input: SigningCreditsGateInput): boolean {
  return input.featureEnabled && input.effectivelyActive && input.nativeSigningEnabled
}

/** Opening the orchestrator depends on signing being active, not on DocuSeal credits. */
export function canOpenSigningOrchestrator(input: SigningCreditsGateInput): boolean {
  return input.featureEnabled && input.effectivelyActive
}
