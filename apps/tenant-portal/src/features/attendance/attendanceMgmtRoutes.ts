/** English URL paths for manager attendance section (+ legacy Catalan redirects). */
export const ATTENDANCE_MGMT_BASE = '/attendance-mgmt'

export const ATTENDANCE_MGMT_TABS = [
  { to: `${ATTENDANCE_MGMT_BASE}/dashboard`, key: 'dashboard', labelKey: 'control_horari.tabs.tauler', fallback: 'Tauler' },
  { to: `${ATTENDANCE_MGMT_BASE}/records`, key: 'records', labelKey: 'control_horari.tabs.fitxatges', fallback: 'Fitxatges' },
  { to: `${ATTENDANCE_MGMT_BASE}/calendar`, key: 'calendar', labelKey: 'control_horari.tabs.calendari', fallback: 'Calendari' },
  { to: `${ATTENDANCE_MGMT_BASE}/planning`, key: 'planning', labelKey: 'control_horari.tabs.planificacio', fallback: 'Planificació' },
  { to: `${ATTENDANCE_MGMT_BASE}/absences`, key: 'absences', labelKey: 'control_horari.tabs.absencies', fallback: 'Absències' },
] as const

/** Old Catalan path segment → new English segment */
export const LEGACY_CONTROL_HORARI_SEGMENTS: Record<string, string> = {
  tauler: 'dashboard',
  fitxatges: 'records',
  empleats: 'employees',
  calendari: 'calendar',
  planificacio: 'planning',
  absencies: 'absences',
}
