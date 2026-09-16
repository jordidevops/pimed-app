/** User setting already in data.settings_registry (user scope). */
export const FIELD_SERVICE_HOME_SETTING_KEY = 'home_default_module'

export const FIELD_TODAY_PATH = '/field/today'
export const DASHBOARD_PATH = '/dashboard'

export type FieldServiceHomePath = typeof FIELD_TODAY_PATH | typeof DASHBOARD_PATH

/** auto = mòbil Avui / escriptori Inici. Members ignore this and always land on Avui. */
export type FieldServiceHomePreference = 'auto' | 'field_today' | 'dashboard'

export function isFieldServiceOfficeRole(role: string | null | undefined): boolean {
  return role === 'owner' || role === 'manager'
}

export function parseFieldServiceHomePreference(raw: unknown): FieldServiceHomePreference {
  if (raw === 'field_today' || raw === 'dashboard' || raw === 'auto') return raw
  return 'auto'
}

export function resolveFieldServiceHomePath(input: {
  isFieldService: boolean
  role: string | null | undefined
  isLargeScreen: boolean
  preference?: unknown
}): FieldServiceHomePath {
  if (!input.isFieldService) return DASHBOARD_PATH
  if (!isFieldServiceOfficeRole(input.role)) return FIELD_TODAY_PATH

  const preference = parseFieldServiceHomePreference(input.preference)
  if (preference === 'field_today') return FIELD_TODAY_PATH
  if (preference === 'dashboard') return DASHBOARD_PATH
  return input.isLargeScreen ? DASHBOARD_PATH : FIELD_TODAY_PATH
}
