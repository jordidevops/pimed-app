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
export const COMMERCIAL_FORMALIZATION_MODE_DEFAULT_KEY = 'formalization_mode_default' as const
export const COMMERCIAL_AGREEMENT_TEMPLATE_ID_KEY = 'agreement_template_id' as const
export const COMMERCIAL_WORK_GATE_DEFAULT_KEY = 'work_gate_default' as const

export const FORMALIZATION_MODES = ['signed_quote', 'separate_agreement'] as const
export type FormalizationMode = (typeof FORMALIZATION_MODES)[number]

export const WORK_GATES = ['none', 'require_signed_agreement'] as const
export type WorkGate = (typeof WORK_GATES)[number]

export function parseWorkGateDefault(
  effective: Record<string, unknown> | null | undefined,
): WorkGate {
  const commercial = effective?.commercial
  let raw: unknown
  if (commercial && typeof commercial === 'object' && !Array.isArray(commercial)) {
    raw = (commercial as Record<string, unknown>)[COMMERCIAL_WORK_GATE_DEFAULT_KEY]
  }
  if (raw == null) {
    raw = effective?.[`commercial.${COMMERCIAL_WORK_GATE_DEFAULT_KEY}`]
  }
  return raw === 'require_signed_agreement' ? 'require_signed_agreement' : 'none'
}

export function parseFormalizationModeDefault(
  effective: Record<string, unknown> | null | undefined,
): FormalizationMode {
  const commercial = effective?.commercial
  let raw: unknown
  if (commercial && typeof commercial === 'object' && !Array.isArray(commercial)) {
    raw = (commercial as Record<string, unknown>)[COMMERCIAL_FORMALIZATION_MODE_DEFAULT_KEY]
  }
  if (raw == null) {
    raw = effective?.[`commercial.${COMMERCIAL_FORMALIZATION_MODE_DEFAULT_KEY}`]
  }
  return raw === 'separate_agreement' ? 'separate_agreement' : 'signed_quote'
}
/** Settings «Cap»: explicit QT-D1 fallback even when own clones exist. */
export const COMMERCIAL_FULL_BODY_TEMPLATE_NONE = 'none' as const

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
  if (!trimmed || trimmed.toLowerCase() === COMMERCIAL_FULL_BODY_TEMPLATE_NONE) return null
  return trimmed
}

export function commercialFullBodyTemplateSettingValue(id: string | null | undefined): string {
  const trimmed = (id ?? '').trim()
  return trimmed || COMMERCIAL_FULL_BODY_TEMPLATE_NONE
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
