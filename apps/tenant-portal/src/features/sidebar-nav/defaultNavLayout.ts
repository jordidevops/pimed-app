import type { SidebarNavV1 } from './sidebarNavSchema'
import type { NavItemId } from './navCatalog'

export const DEFAULT_GROUP_IDS = {
  home: 'home',
  operations: 'operations',
  personal: 'personal',
  automation: 'automation',
  team: 'team',
  company: 'company',
  settings: 'settings',
} as const

export const PINNED_SECTION_ID = 'pinned'

/** Platform default: pinned Avui + Operativa → Jo → Automatitzacions → Equip → Empresa → Configuració */
export function buildDefaultNavLayout(): SidebarNavV1 {
  return {
    version: 2,
    pinned: {
      visible: true,
      items: [{ id: 'home' satisfies NavItemId }],
    },
    groups: [
      {
        id: DEFAULT_GROUP_IDS.operations,
        label: 'Operativa',
        items: [
          { id: 'field_today' },
          { id: 'office_dashboard' },
          { id: 'contacts' },
          { id: 'quotes' },
          { id: 'field_orders' },
          { id: 'maintenance_plans' },
          { id: 'projects' },
          { id: 'documents' },
          { id: 'files' },
          { id: 'public_portal' },
        ],
      },
      {
        id: DEFAULT_GROUP_IDS.personal,
        label: 'Jo',
        items: [{ id: 'attendance' }, { id: 'attendance_calendar' }, { id: 'ai_chat' }],
      },
      {
        id: DEFAULT_GROUP_IDS.automation,
        label: 'Automatitzacions',
        items: [{ id: 'automation' }],
      },
      {
        id: DEFAULT_GROUP_IDS.team,
        label: 'Equip',
        items: [
          { id: 'employees' },
          { id: 'hr_reporting' },
          { id: 'organization' },
          { id: 'job_positions' },
          { id: 'skills' },
          { id: 'recruitment' },
          { id: 'control_horari' },
        ],
      },
      {
        id: DEFAULT_GROUP_IDS.company,
        label: 'Empresa',
        items: [{ id: 'departments' }, { id: 'locations' }, { id: 'catalog' }],
      },
      {
        id: DEFAULT_GROUP_IDS.settings,
        label: 'Configuració',
        items: [{ id: 'settings' }, { id: 'theme' }],
      },
    ],
  }
}

/** Default group labels keyed for i18n when layout uses stock group ids without override semantics. */
export const DEFAULT_GROUP_LABEL_KEYS: Record<string, { key: string; fallback: string }> = {
  [DEFAULT_GROUP_IDS.operations]: { key: 'nav.group_operations', fallback: 'Operativa' },
  [DEFAULT_GROUP_IDS.personal]: { key: 'nav.group_personal', fallback: 'Jo' },
  [DEFAULT_GROUP_IDS.automation]: { key: 'nav.group_automation', fallback: 'Automatitzacions' },
  [DEFAULT_GROUP_IDS.team]: { key: 'nav.group_team', fallback: 'Equip' },
  [DEFAULT_GROUP_IDS.company]: { key: 'nav.group_company', fallback: 'Empresa' },
  [DEFAULT_GROUP_IDS.settings]: { key: 'nav.group_settings', fallback: 'Configuració' },
}
