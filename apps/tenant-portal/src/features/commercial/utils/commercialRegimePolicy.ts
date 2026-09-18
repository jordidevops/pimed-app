/**
 * Tenant commercial regime policy (consumer vs contractual).
 * Stored under tenants.settings.commercial.regimes.
 */

export type CommercialRegime = 'consumer' | 'contractual'
export type ServiceMode = 'execute' | 'assessment'
export type PolicyEnforcement = 'off' | 'warn' | 'block'

export type RegimePolicy = {
  require_auth_before_work: PolicyEnforcement
  overage_on_close: PolicyEnforcement
  overage_on_delivery: PolicyEnforcement
}

export const COMMERCIAL_REGIMES_KEY = 'regimes' as const

export const DEFAULT_REGIME_POLICIES: Record<CommercialRegime, RegimePolicy> = {
  consumer: {
    require_auth_before_work: 'warn',
    overage_on_close: 'block',
    overage_on_delivery: 'block',
  },
  contractual: {
    require_auth_before_work: 'off',
    overage_on_close: 'warn',
    overage_on_delivery: 'warn',
  },
}

function asEnforcement(raw: unknown, fallback: PolicyEnforcement): PolicyEnforcement {
  if (raw === 'off' || raw === 'warn' || raw === 'block') return raw
  return fallback
}

function parseRegimeBlock(
  raw: unknown,
  defaults: RegimePolicy,
): RegimePolicy {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { ...defaults }
  const o = raw as Record<string, unknown>
  return {
    require_auth_before_work: asEnforcement(
      o.require_auth_before_work,
      defaults.require_auth_before_work,
    ),
    overage_on_close: asEnforcement(o.overage_on_close, defaults.overage_on_close),
    overage_on_delivery: asEnforcement(
      o.overage_on_delivery,
      defaults.overage_on_delivery,
    ),
  }
}

export function parseCommercialRegimes(
  effective: Record<string, unknown> | null | undefined,
): Record<CommercialRegime, RegimePolicy> {
  const commercial = effective?.commercial
  let regimesRaw: unknown
  if (commercial && typeof commercial === 'object' && !Array.isArray(commercial)) {
    regimesRaw = (commercial as Record<string, unknown>)[COMMERCIAL_REGIMES_KEY]
  }
  const root =
    regimesRaw && typeof regimesRaw === 'object' && !Array.isArray(regimesRaw)
      ? (regimesRaw as Record<string, unknown>)
      : {}
  return {
    consumer: parseRegimeBlock(root.consumer, DEFAULT_REGIME_POLICIES.consumer),
    contractual: parseRegimeBlock(
      root.contractual,
      DEFAULT_REGIME_POLICIES.contractual,
    ),
  }
}

export function commercialSettingsPatchWithRegimes(
  existingCommercial: unknown,
  regimes: Record<CommercialRegime, RegimePolicy>,
): { commercial: Record<string, unknown> } {
  const base =
    existingCommercial &&
    typeof existingCommercial === 'object' &&
    !Array.isArray(existingCommercial)
      ? { ...(existingCommercial as Record<string, unknown>) }
      : {}
  return {
    commercial: {
      ...base,
      [COMMERCIAL_REGIMES_KEY]: {
        consumer: { ...regimes.consumer },
        contractual: { ...regimes.contractual },
      },
    },
  }
}

export function isCommercialRegime(value: string | null | undefined): value is CommercialRegime {
  return value === 'consumer' || value === 'contractual'
}

export function isServiceMode(value: string | null | undefined): value is ServiceMode {
  return value === 'execute' || value === 'assessment'
}

/** OS snapshot only — never contact.is_consumer. Invalid/null → consumer / execute. */
export function resolveProjectCommercialSnapshot(
  project:
    | {
        commercial_regime?: string | null
        service_mode?: string | null
      }
    | null
    | undefined,
): { commercialRegime: CommercialRegime; serviceMode: ServiceMode } {
  return {
    commercialRegime: isCommercialRegime(project?.commercial_regime)
      ? project.commercial_regime
      : 'consumer',
    serviceMode: isServiceMode(project?.service_mode)
      ? project.service_mode
      : 'execute',
  }
}

/** Effective policy for an OS (assessment forces overage/auth off). */
export function effectiveProjectCommercialPolicy(input: {
  commercialRegime: CommercialRegime | null | undefined
  serviceMode: ServiceMode | null | undefined
  tenantRegimes?: Record<CommercialRegime, RegimePolicy> | null
}): RegimePolicy & { commercial_regime: CommercialRegime; service_mode: ServiceMode } {
  const snap = resolveProjectCommercialSnapshot({
    commercial_regime: input.commercialRegime,
    service_mode: input.serviceMode,
  })
  const base =
    input.tenantRegimes?.[snap.commercialRegime] ??
    DEFAULT_REGIME_POLICIES[snap.commercialRegime]
  if (snap.serviceMode === 'assessment') {
    return {
      commercial_regime: snap.commercialRegime,
      service_mode: snap.serviceMode,
      require_auth_before_work: 'off',
      overage_on_close: 'off',
      overage_on_delivery: 'off',
    }
  }
  return {
    commercial_regime: snap.commercialRegime,
    service_mode: snap.serviceMode,
    ...base,
  }
}
