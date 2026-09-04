import type { LucideIcon } from 'lucide-react'
import {
  Users,
  Package,
  Building2,
  MapPin,
  UserCheck,
  FileText,
  ClipboardList,
  Globe,
  Clock,
  CalendarDays,
  ListChecks,
  Sparkles,
  Zap,
  Briefcase,
  GitBranch,
  BarChart3,
  LayoutGrid,
  Folder,
  Settings,
  Palette,
} from 'lucide-react'

export type NavItemId =
  | 'home'
  | 'attendance'
  | 'attendance_calendar'
  | 'ai_chat'
  | 'employees'
  | 'hr_reporting'
  | 'organization'
  | 'job_positions'
  | 'skills'
  | 'recruitment'
  | 'control_horari'
  | 'departments'
  | 'locations'
  | 'catalog'
  | 'contacts'
  | 'field_orders'
  | 'projects'
  | 'documents'
  | 'files'
  | 'public_portal'
  | 'automation'
  | 'settings'
  | 'theme'

export type NavGate =
  | 'always'
  | 'hasMyEmployee'
  | 'isManager'
  | 'showRecruitment'
  | 'isFieldService'
  | 'notFieldService'

export type NavLabelKind = 'i18n' | 'sector_contact' | 'sector_project' | 'home' | 'theme'

export interface NavCatalogEntry {
  id: NavItemId
  /** i18n key under common (ignored for sector/home/theme kinds). */
  labelKey: string
  labelFallback: string
  labelKind: NavLabelKind
  icon: LucideIcon
  gate: NavGate
  /** Static route; home and FS projects resolve at runtime. */
  to?: string
  kind: 'link' | 'theme'
  match?: (path: string) => boolean
}

export const NAV_CATALOG: NavCatalogEntry[] = [
  {
    id: 'home',
    labelKey: 'nav.dashboard',
    labelFallback: 'Inici',
    labelKind: 'home',
    icon: LayoutGrid,
    gate: 'always',
    kind: 'link',
  },
  {
    id: 'attendance',
    labelKey: 'nav.attendance',
    labelFallback: 'Fitxatge',
    labelKind: 'i18n',
    icon: Clock,
    gate: 'hasMyEmployee',
    to: '/attendance',
    kind: 'link',
  },
  {
    id: 'attendance_calendar',
    labelKey: 'nav.attendance_calendar',
    labelFallback: 'Calendari',
    labelKind: 'i18n',
    icon: CalendarDays,
    gate: 'hasMyEmployee',
    to: '/attendance/calendar',
    kind: 'link',
  },
  {
    id: 'ai_chat',
    labelKey: 'nav.ai_chat',
    labelFallback: 'Assistent IA',
    labelKind: 'i18n',
    icon: Sparkles,
    gate: 'always',
    to: '/ai/chat',
    kind: 'link',
  },
  {
    id: 'employees',
    labelKey: 'nav.employees',
    labelFallback: 'Empleats',
    labelKind: 'i18n',
    icon: UserCheck,
    gate: 'always',
    to: '/employees',
    kind: 'link',
  },
  {
    id: 'hr_reporting',
    labelKey: 'nav.hr_reporting',
    labelFallback: 'Reporting HR',
    labelKind: 'i18n',
    icon: BarChart3,
    gate: 'isManager',
    to: '/employees/hr',
    kind: 'link',
  },
  {
    id: 'organization',
    labelKey: 'nav.organization',
    labelFallback: 'Organigrama',
    labelKind: 'i18n',
    icon: GitBranch,
    gate: 'always',
    to: '/employees/organization',
    kind: 'link',
  },
  {
    id: 'job_positions',
    labelKey: 'nav.job_positions',
    labelFallback: 'Llocs de treball',
    labelKind: 'i18n',
    icon: Briefcase,
    gate: 'isManager',
    to: '/employees/positions',
    kind: 'link',
  },
  {
    id: 'skills',
    labelKey: 'nav.skills',
    labelFallback: 'Skills',
    labelKind: 'i18n',
    icon: Sparkles,
    gate: 'isManager',
    to: '/employees/skills',
    kind: 'link',
  },
  {
    id: 'recruitment',
    labelKey: 'nav.recruitment',
    labelFallback: 'Reclutament',
    labelKind: 'i18n',
    icon: Briefcase,
    gate: 'showRecruitment',
    to: '/recruitment',
    kind: 'link',
    match: (path) => path === '/recruitment' || path.startsWith('/recruitment/'),
  },
  {
    id: 'control_horari',
    labelKey: 'nav.control_horari',
    labelFallback: 'Control horari',
    labelKind: 'i18n',
    icon: ListChecks,
    gate: 'isManager',
    to: '/attendance-mgmt/dashboard',
    kind: 'link',
  },
  {
    id: 'departments',
    labelKey: 'nav.departments',
    labelFallback: 'Departaments',
    labelKind: 'i18n',
    icon: Building2,
    gate: 'always',
    to: '/departments',
    kind: 'link',
  },
  {
    id: 'locations',
    labelKey: 'nav.locations',
    labelFallback: 'Ubicacions',
    labelKind: 'i18n',
    icon: MapPin,
    gate: 'always',
    to: '/locations',
    kind: 'link',
  },
  {
    id: 'catalog',
    labelKey: 'nav.catalog',
    labelFallback: 'Catàleg',
    labelKind: 'i18n',
    icon: Package,
    gate: 'always',
    to: '/catalog',
    kind: 'link',
  },
  {
    id: 'contacts',
    labelKey: 'nav.contacts',
    labelFallback: 'Contactes',
    labelKind: 'sector_contact',
    icon: Users,
    gate: 'always',
    to: '/contacts',
    kind: 'link',
  },
  {
    id: 'field_orders',
    labelKey: 'nav.projects',
    labelFallback: 'Projectes',
    labelKind: 'sector_project',
    icon: ClipboardList,
    gate: 'isFieldService',
    to: '/field/orders',
    kind: 'link',
    match: (path) => path.startsWith('/field/orders') || path.startsWith('/projects'),
  },
  {
    id: 'projects',
    labelKey: 'nav.projects',
    labelFallback: 'Projectes',
    labelKind: 'sector_project',
    icon: ClipboardList,
    gate: 'notFieldService',
    to: '/projects',
    kind: 'link',
  },
  {
    id: 'documents',
    labelKey: 'nav.documents',
    labelFallback: 'Documents',
    labelKind: 'i18n',
    icon: FileText,
    gate: 'always',
    to: '/documents',
    kind: 'link',
  },
  {
    id: 'files',
    labelKey: 'nav.files',
    labelFallback: 'Fitxers',
    labelKind: 'i18n',
    icon: Folder,
    gate: 'always',
    to: '/files',
    kind: 'link',
  },
  {
    id: 'public_portal',
    labelKey: 'nav.public_portal',
    labelFallback: 'Portal Públic',
    labelKind: 'i18n',
    icon: Globe,
    gate: 'isManager',
    to: '/public-portal',
    kind: 'link',
  },
  {
    id: 'automation',
    labelKey: 'nav.automation',
    labelFallback: "Centre d'automatitzacions",
    labelKind: 'i18n',
    icon: Zap,
    gate: 'isManager',
    to: '/automation',
    kind: 'link',
  },
  {
    id: 'settings',
    labelKey: 'nav.settings',
    labelFallback: 'Configuració',
    labelKind: 'i18n',
    icon: Settings,
    gate: 'always',
    to: '/settings',
    kind: 'link',
  },
  {
    id: 'theme',
    labelKey: 'theme.customizer_label',
    labelFallback: 'Aparença',
    labelKind: 'theme',
    icon: Palette,
    gate: 'always',
    kind: 'theme',
  },
]

export const NAV_CATALOG_BY_ID: Record<NavItemId, NavCatalogEntry> = Object.fromEntries(
  NAV_CATALOG.map((e) => [e.id, e]),
) as Record<NavItemId, NavCatalogEntry>

export const ALL_NAV_ITEM_IDS = NAV_CATALOG.map((e) => e.id)

export function isNavItemId(id: string): id is NavItemId {
  return id in NAV_CATALOG_BY_ID
}
