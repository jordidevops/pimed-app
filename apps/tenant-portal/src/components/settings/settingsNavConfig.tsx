import type { LucideIcon } from 'lucide-react'
import {
  Activity,
  Bell,
  Bot,
  Calendar,
  Clock,
  FileText,
  HardDrive,
  Link2,
  Mail,
  PenLine,
  Settings,
  Shield,
  Users,
  Workflow,
  Building2,
  MapPin,
  Newspaper,
  Scale,
} from 'lucide-react'
import type { TenantTimelineFeatures } from '@/features/entity-timeline/api/tenantFeaturesService'

export type SettingsNavGroup = 'general' | 'org' | 'comms' | 'activity' | 'docs' | 'advanced'

export interface SettingsNavItem {
  to: string
  labelKey: string
  labelDefault: string
  icon: LucideIcon
  group: SettingsNavGroup
  show: boolean
  badge?: number
  /** Match child routes (e.g. /settings/activity/*) */
  matchPrefix?: boolean
}

interface BuildSettingsNavParams {
  isOwner: boolean
  isManagerOrOwner: boolean
  canManageSettings: boolean
  canViewOperations: boolean
  unresolvedCount: number
  features?: TenantTimelineFeatures
}

const GROUP_ORDER: SettingsNavGroup[] = [
  'general',
  'org',
  'comms',
  'activity',
  'docs',
  'advanced',
]

const GROUP_LABELS: Record<SettingsNavGroup, { key: string; default: string }> = {
  general: { key: 'nav.group_general', default: 'General' },
  org: { key: 'nav.group_org', default: 'Organització' },
  comms: { key: 'nav.group_comms', default: 'Comunicació' },
  activity: { key: 'nav.group_activity', default: 'Activitat' },
  docs: { key: 'nav.group_docs', default: 'Documents' },
  advanced: { key: 'nav.group_advanced', default: 'Avançat' },
}

export function buildSettingsNavItems({
  isOwner,
  isManagerOrOwner,
  canManageSettings,
  canViewOperations,
  unresolvedCount,
  features,
}: BuildSettingsNavParams): SettingsNavItem[] {
  const showActivityHub = isManagerOrOwner

  return [
    {
      to: '/settings/config',
      labelKey: 'tabs.config',
      labelDefault: 'Configuració',
      icon: Settings,
      group: 'general',
      show: true,
    },
    {
      to: '/settings/members',
      labelKey: 'tabs.members',
      labelDefault: 'Membres',
      icon: Users,
      group: 'org',
      show: isOwner,
    },
    {
      to: '/settings/sites',
      labelKey: 'tabs.sites',
      labelDefault: 'Locals',
      icon: Building2,
      group: 'org',
      show: isOwner,
    },
    {
      to: '/settings/permissions',
      labelKey: 'tabs.permissions',
      labelDefault: 'Permisos',
      icon: Shield,
      group: 'org',
      show: isManagerOrOwner,
    },
    {
      to: '/settings/notifications',
      labelKey: 'tabs.notifications',
      labelDefault: 'Notificacions',
      icon: Bell,
      group: 'comms',
      show: true,
    },
    {
      to: '/settings/email',
      labelKey: 'tabs.email',
      labelDefault: 'Correu electrònic',
      icon: Mail,
      group: 'comms',
      show: true,
    },
    {
      to: '/settings/customer-portal',
      labelKey: 'tabs.customer_portal',
      labelDefault: 'Portal de clients',
      icon: Newspaper,
      group: 'comms',
      show: canManageSettings,
    },
    {
      to: '/settings/legal',
      labelKey: 'tabs.legal',
      labelDefault: 'Legal',
      icon: Scale,
      group: 'docs',
      show: canManageSettings,
    },
    {
      to: '/settings/activity',
      labelKey: 'tabs.activity',
      labelDefault: 'Activitats',
      icon: Activity,
      group: 'activity',
      show: showActivityHub,
      matchPrefix: true,
    },
    {
      to: '/settings/webhooks',
      labelKey: 'tabs.webhooks',
      labelDefault: 'Webhooks',
      icon: Link2,
      group: 'activity',
      show: isManagerOrOwner && features?.entity_timeline_webhooks !== false,
    },
    {
      to: '/settings/signing',
      labelKey: 'tabs.signing',
      labelDefault: 'Firmes',
      icon: PenLine,
      group: 'docs',
      show: isManagerOrOwner,
    },
    {
      to: '/settings/templates',
      labelKey: 'tabs.templates',
      labelDefault: 'Plantilles',
      icon: FileText,
      group: 'docs',
      show: isManagerOrOwner,
    },
    {
      to: '/settings/ai',
      labelKey: 'tabs.ai',
      labelDefault: 'IA',
      icon: Bot,
      group: 'advanced',
      show: isManagerOrOwner,
    },
    {
      to: '/settings/maps',
      labelKey: 'tabs.maps',
      labelDefault: 'Mapes',
      icon: MapPin,
      group: 'advanced',
      show: isManagerOrOwner,
    },
    {
      to: '/settings/storage',
      labelKey: 'tabs.storage',
      labelDefault: 'Emmagatzematge',
      icon: HardDrive,
      group: 'advanced',
      show: true,
    },
    {
      to: '/settings/labor-calendar',
      labelKey: 'tabs.labor_calendar',
      labelDefault: 'Calendari laboral',
      icon: Calendar,
      group: 'advanced',
      show: isManagerOrOwner,
    },
    {
      to: '/settings/attendance-stations',
      labelKey: 'tabs.attendance_stations',
      labelDefault: 'Estacions de fitxatge',
      icon: Clock,
      group: 'advanced',
      show: isManagerOrOwner,
    },
    {
      to: '/settings/attendance-control',
      labelKey: 'tabs.attendance_control',
      labelDefault: 'Control horari',
      icon: Clock,
      group: 'advanced',
      show: isManagerOrOwner,
    },
    {
      to: '/settings/secrets',
      labelKey: 'tabs.secrets',
      labelDefault: 'Secrets',
      icon: Shield,
      group: 'advanced',
      show: isManagerOrOwner,
    },
    {
      to: '/settings/operations',
      labelKey: 'tabs.operations',
      labelDefault: 'Operacions',
      icon: Workflow,
      group: 'advanced',
      show: canViewOperations,
      badge: unresolvedCount > 0 ? unresolvedCount : undefined,
    },
  ].filter((item) => item.show) as SettingsNavItem[]
}

export function groupSettingsNavItems(items: SettingsNavItem[]) {
  return GROUP_ORDER.map((group) => ({
    group,
    label: GROUP_LABELS[group],
    items: items.filter((item) => item.group === group),
  })).filter((g) => g.items.length > 0)
}

export function isSettingsNavItemActive(pathname: string, item: SettingsNavItem) {
  if (item.matchPrefix) {
    return pathname === item.to || pathname.startsWith(`${item.to}/`)
  }
  return pathname === item.to
}
