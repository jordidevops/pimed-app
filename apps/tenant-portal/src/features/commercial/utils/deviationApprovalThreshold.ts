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
export const COMMERCIAL_ALLOW_OFFICE_ACCEPT_KEY = 'allow_office_accept' as const

export const FORMALIZATION_MODES = ['signed_quote', 'separate_agreement'] as const
export type FormalizationMode = (typeof FORMALIZATION_MODES)[number]

export const WORK_GATES = ['none', 'require_signed_agreement'] as const
export type WorkGate = (typeof WORK_GATES)[number]

/** Tenant opt-in: office may accept quotes without client pad (default false). */
export function parseAllowOfficeAccept(
  effective: Record<string, unknown> | null | undefined,
): boolean {
  const commercial = effective?.commercial
  let raw: unknown
  if (commercial && typeof commercial === 'object' && !Array.isArray(commercial)) {
    raw = (commercial as Record<string, unknown>)[COMMERCIAL_ALLOW_OFFICE_ACCEPT_KEY]
  }
  if (raw == null) {
    raw = effective?.[`commercial.${COMMERCIAL_ALLOW_OFFICE_ACCEPT_KEY}`]
  }
  return raw === true || raw === 'true'
}

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
  return readExplicitFormalizationModeDefault(effective) ?? 'signed_quote'
}

/**
 * CF-29 fase 3: només retorna mode si el tenant l’ha fixat explícitament
 * (`signed_quote` | `separate_agreement`). Absent o invàlid → null (cal preguntar).
 */
export function readExplicitFormalizationModeDefault(
  effective: Record<string, unknown> | null | undefined,
): FormalizationMode | null {
  const commercial = effective?.commercial
  let raw: unknown
  if (commercial && typeof commercial === 'object' && !Array.isArray(commercial)) {
    raw = (commercial as Record<string, unknown>)[COMMERCIAL_FORMALIZATION_MODE_DEFAULT_KEY]
  }
  if (raw == null) {
    raw = effective?.[`commercial.${COMMERCIAL_FORMALIZATION_MODE_DEFAULT_KEY}`]
  }
  if (raw === 'signed_quote' || raw === 'separate_agreement') return raw
  return null
}

/**
 * CF-29 fase 3: si la clau quote/agreement template existeix (uuid o «none»),
 * es pot saltar el selector. Absent → null (cal preguntar).
 */
export function shouldSkipCommercialTemplateStep(
  effective: Record<string, unknown> | null | undefined,
  key:
    | typeof COMMERCIAL_QUOTE_TEMPLATE_ID_KEY
    | typeof COMMERCIAL_AGREEMENT_TEMPLATE_ID_KEY
    | typeof COMMERCIAL_DELIVERY_NOTE_TEMPLATE_ID_KEY,
): boolean {
  return readCommercialSettingRaw(effective, key) != null
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

/** Raw commercial setting string (keeps explicit «none»). */
export function readCommercialSettingRaw(
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

export type ResolveActiveCommercialTemplateInput = {
  id: string
  category?: string | null
  tenant_id?: string | null
  is_platform_default?: boolean | null
  is_active?: boolean | null
  template_type?: string | null
  created_at?: string | null
}

/**
 * Mirrors data.resolve_commercial_full_body_template_id for quote/delivery_note:
 * settings uuid → that template; settings «none» → null (QT-D1); unset → oldest own.
 */
export function resolveActiveCommercialFullBodyTemplateId(
  effective: Record<string, unknown> | null | undefined,
  settingsKey: typeof COMMERCIAL_QUOTE_TEMPLATE_ID_KEY | typeof COMMERCIAL_DELIVERY_NOTE_TEMPLATE_ID_KEY,
  category: 'quote' | 'delivery_note',
  templates: ResolveActiveCommercialTemplateInput[],
  tenantId: string | null | undefined,
): string | null {
  if (!tenantId) return null
  const raw = readCommercialSettingRaw(effective, settingsKey)
  if (raw && raw.toLowerCase() === COMMERCIAL_FULL_BODY_TEMPLATE_NONE) return null

  const eligible = (tpl: ResolveActiveCommercialTemplateInput) =>
    tpl.is_active !== false &&
    (tpl.template_type === 'html' || tpl.template_type === 'docx') &&
    (tpl.category ?? '').toLowerCase() === category &&
    (tpl.tenant_id === tenantId ||
      (tpl.tenant_id == null && tpl.is_platform_default === true))

  if (raw) {
    const configured = templates.find((tpl) => tpl.id === raw && eligible(tpl))
    if (configured) return configured.id
  }

  const own = templates
    .filter(
      (tpl) =>
        tpl.tenant_id === tenantId &&
        tpl.is_active !== false &&
        (tpl.template_type === 'html' || tpl.template_type === 'docx') &&
        (tpl.category ?? '').toLowerCase() === category,
    )
    .sort((a, b) => String(a.created_at ?? '').localeCompare(String(b.created_at ?? '')))
  return own[0]?.id ?? null
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
