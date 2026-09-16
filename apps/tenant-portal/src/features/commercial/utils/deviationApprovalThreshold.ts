/**
 * CF-13: euros of estimated overage above authorized_total that require
 * office approval (commercial.pricing.edit) before accepting an amendment.
 * Default 0 = short path for anyone with pricing permission.
 */
export const COMMERCIAL_DEVIATION_THRESHOLD_KEY =
  'deviation_approval_threshold_eur' as const

export function parseDeviationApprovalThresholdEur(
  effective: Record<string, unknown> | null | undefined,
): number {
  const commercial = effective?.commercial
  let raw: unknown
  if (commercial && typeof commercial === 'object' && !Array.isArray(commercial)) {
    raw = (commercial as Record<string, unknown>)[COMMERCIAL_DEVIATION_THRESHOLD_KEY]
  }
  if (raw == null) {
    raw = effective?.['commercial.deviation_approval_threshold_eur']
  }
  const n = typeof raw === 'number' ? raw : Number(raw)
  if (!Number.isFinite(n) || n < 0) return 0
  return n
}

export function commercialSettingsPatchWithThreshold(
  existingCommercial: unknown,
  thresholdEur: number,
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
      [COMMERCIAL_DEVIATION_THRESHOLD_KEY]: Math.max(0, thresholdEur),
    },
  }
}
