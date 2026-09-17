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

export const COMMERCIAL_QUOTE_TEMPLATE_ID_KEY = 'quote_template_id' as const
export const COMMERCIAL_DELIVERY_NOTE_TEMPLATE_ID_KEY = 'delivery_note_template_id' as const

function commercialSettingsBase(existingCommercial: unknown): Record<string, unknown> {
  return existingCommercial &&
    typeof existingCommercial === 'object' &&
    !Array.isArray(existingCommercial)
    ? { ...(existingCommercial as Record<string, unknown>) }
    : {}
}

export function commercialSettingsPatch(
  existingCommercial: unknown,
  patch: Record<string, unknown>,
): { commercial: Record<string, unknown> } {
  return {
    commercial: {
      ...commercialSettingsBase(existingCommercial),
      ...patch,
    },
  }
}

export function parseCommercialSettingId(
  effective: Record<string, unknown> | null | undefined,
  key: string,
): string | null {
  const commercial = effective?.commercial
  let raw: unknown
  if (commercial && typeof commercial === 'object' && !Array.isArray(commercial)) {
    raw = (commercial as Record<string, unknown>)[key]
  }
  if (raw == null) {
    raw = effective?.[`commercial.${key}`]
  }
  if (typeof raw !== 'string') return null
  const trimmed = raw.trim()
  return trimmed || null
}

export function commercialSettingsPatchWithThreshold(
  existingCommercial: unknown,
  thresholdEur: number,
): { commercial: Record<string, unknown> } {
  return commercialSettingsPatch(existingCommercial, {
    [COMMERCIAL_DEVIATION_THRESHOLD_KEY]: Math.max(0, thresholdEur),
  })
}

export function commercialSettingsPatchWithFullBodyTemplates(
  existingCommercial: unknown,
  patch: {
    quote_template_id?: string | null
    delivery_note_template_id?: string | null
  },
): { commercial: Record<string, unknown> } {
  return commercialSettingsPatch(existingCommercial, patch)
}
