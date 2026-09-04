import {
  NAV_CATALOG_BY_ID,
  isNavItemId,
  type NavCatalogEntry,
  type NavGate,
  type NavItemId,
} from './navCatalog'
import { buildDefaultNavLayout, DEFAULT_GROUP_LABEL_KEYS, PINNED_SECTION_ID } from './defaultNavLayout'
import {
  parseSidebarNav,
  type SidebarNavItemV1,
  type SidebarNavV1,
} from './sidebarNavSchema'

export interface NavGateContext {
  isManager: boolean
  hasMyEmployee: boolean
  showRecruitment: boolean
  isFieldService: boolean
}

export interface ResolvedNavItem {
  id: NavItemId
  kind: 'link' | 'theme'
  to?: string
  label: string
  icon: NavCatalogEntry['icon']
  match?: (path: string) => boolean
  customLabel?: string
  showIcon: boolean
  emphasis: 'default' | 'accent'
}

export interface ResolvedNavGroup {
  id: string
  /** Display label; null = untitled section. */
  label: string | null
  items: ResolvedNavItem[]
}

export interface ResolvedSidebarNav {
  /** Fixed top block; null when hidden or empty after gates. */
  pinned: ResolvedNavGroup | null
  /** Scrollable sections. */
  groups: ResolvedNavGroup[]
}

export interface LabelResolvers {
  t: (key: string, fallback: string) => string
  contactLabel: string
  projectLabel: string
}

export function passesGate(gate: NavGate, ctx: NavGateContext): boolean {
  switch (gate) {
    case 'always':
      return true
    case 'hasMyEmployee':
      return ctx.hasMyEmployee
    case 'isManager':
      return ctx.isManager
    case 'showRecruitment':
      return ctx.showRecruitment
    case 'isFieldService':
      return ctx.isFieldService
    case 'notFieldService':
      return !ctx.isFieldService
    default:
      return false
  }
}

export function resolveItemLabel(
  entry: NavCatalogEntry,
  customLabel: string | undefined,
  labels: LabelResolvers,
  ctx: NavGateContext,
): string {
  if (customLabel?.trim()) return customLabel.trim()
  switch (entry.labelKind) {
    case 'sector_contact':
      return labels.contactLabel
    case 'sector_project':
      return labels.projectLabel
    case 'home':
      return ctx.isFieldService
        ? labels.t('nav.field_today', 'Avui')
        : labels.t('nav.dashboard', 'Inici')
    case 'theme':
      return labels.t(entry.labelKey, entry.labelFallback)
    case 'i18n':
    default:
      return labels.t(entry.labelKey, entry.labelFallback)
  }
}

export function resolveItemTo(entry: NavCatalogEntry, ctx: NavGateContext): string | undefined {
  if (entry.kind === 'theme') return undefined
  if (entry.id === 'home') {
    return ctx.isFieldService ? '/field/today' : '/dashboard'
  }
  return entry.to
}

export function resolveItemMatch(
  entry: NavCatalogEntry,
  ctx: NavGateContext,
): ((path: string) => boolean) | undefined {
  if (entry.id === 'home' && ctx.isFieldService) {
    return (path: string) =>
      path === '/field' || path === '/field/' || path.startsWith('/field/today')
  }
  return entry.match
}

/** Pick layout: user ?? tenant ?? platform default. */
export function pickSidebarLayout(
  userRaw: unknown,
  tenantRaw: unknown,
): { layout: SidebarNavV1; source: 'user' | 'tenant' | 'platform' } {
  const user = parseSidebarNav(userRaw)
  if (user) return { layout: user, source: 'user' }
  const tenant = parseSidebarNav(tenantRaw)
  if (tenant) return { layout: tenant, source: 'tenant' }
  return { layout: buildDefaultNavLayout(), source: 'platform' }
}

function resolveGroupLabel(
  groupId: string,
  storedLabel: string | null,
  labels: LabelResolvers,
): string | null {
  if (storedLabel === null) return null
  const stock = DEFAULT_GROUP_LABEL_KEYS[groupId]
  if (stock && (storedLabel === stock.fallback || storedLabel === labels.t(stock.key, stock.fallback))) {
    return labels.t(stock.key, stock.fallback)
  }
  if (stock && storedLabel.trim() === '') {
    return labels.t(stock.key, stock.fallback)
  }
  return storedLabel
}

function resolveRawItems(
  rawItems: SidebarNavItemV1[],
  ctx: NavGateContext,
  labels: LabelResolvers,
): ResolvedNavItem[] {
  const items: ResolvedNavItem[] = []
  for (const rawItem of rawItems) {
    if (!isNavItemId(rawItem.id)) continue
    const entry = NAV_CATALOG_BY_ID[rawItem.id]
    if (!passesGate(entry.gate, ctx)) continue

    items.push({
      id: entry.id,
      kind: entry.kind,
      to: resolveItemTo(entry, ctx),
      label: resolveItemLabel(entry, rawItem.label, labels, ctx),
      icon: entry.icon,
      match: resolveItemMatch(entry, ctx),
      customLabel: rawItem.label,
      showIcon: rawItem.showIcon !== false,
      emphasis: rawItem.emphasis === 'accent' ? 'accent' : 'default',
    })
  }
  return items
}

/** Expand a stored layout into pinned + scrollable groups (gates applied). */
export function resolveSidebarNav(
  layout: SidebarNavV1,
  ctx: NavGateContext,
  labels: LabelResolvers,
): ResolvedSidebarNav {
  const pinnedItems =
    layout.pinned.visible ? resolveRawItems(layout.pinned.items, ctx, labels) : []
  const pinned: ResolvedNavGroup | null =
    pinnedItems.length > 0
      ? { id: PINNED_SECTION_ID, label: null, items: pinnedItems }
      : null

  const groups: ResolvedNavGroup[] = []
  for (const group of layout.groups) {
    const items = resolveRawItems(group.items, ctx, labels)
    if (items.length === 0) continue
    groups.push({
      id: group.id,
      label: resolveGroupLabel(group.id, group.label, labels),
      items,
    })
  }

  return { pinned, groups }
}

/** Full allowed catalog grouped like the platform default (for /app launcher). */
export function resolveLauncherNav(
  ctx: NavGateContext,
  labels: LabelResolvers,
): ResolvedNavGroup[] {
  const { pinned, groups } = resolveSidebarNav(buildDefaultNavLayout(), ctx, labels)
  const out: ResolvedNavGroup[] = []
  if (pinned) {
    out.push({
      ...pinned,
      label: labels.t('nav.group_pinned', 'Superior'),
    })
  }
  out.push(...groups)
  return out
}

/** Catalog entries the user may place in the editor (gate-visible). */
export function listAvailableCatalogEntries(ctx: NavGateContext): NavCatalogEntry[] {
  return Object.values(NAV_CATALOG_BY_ID).filter((e) => passesGate(e.gate, ctx))
}

/** Pairs that must not both appear for a given tenant archetype (same UI label). */
export const MUTUALLY_EXCLUSIVE_NAV_IDS: ReadonlyArray<readonly [NavItemId, NavItemId]> = [
  ['field_orders', 'projects'],
]

export function isNavItemAllowed(id: string, ctx: NavGateContext): boolean {
  if (!isNavItemId(id)) return false
  return passesGate(NAV_CATALOG_BY_ID[id].gate, ctx)
}

/** Drop the other id of an exclusive pair when one is present. */
export function enforceExclusiveNavIds(layout: SidebarNavV1): SidebarNavV1 {
  const present = new Set<string>()
  for (const i of layout.pinned.items) present.add(i.id)
  for (const g of layout.groups) {
    for (const i of g.items) present.add(i.id)
  }

  const drop = new Set<string>()
  for (const [a, b] of MUTUALLY_EXCLUSIVE_NAV_IDS) {
    if (present.has(a) && present.has(b)) {
      // Prefer the one that would show for... we don't have ctx here.
      // Keep first occurrence order: drop the later one when scanning.
      let seenFirst: string | null = null
      const order = [...layout.pinned.items, ...layout.groups.flatMap((g) => g.items)]
      for (const item of order) {
        if (item.id === a || item.id === b) {
          if (!seenFirst) seenFirst = item.id
          else drop.add(item.id)
        }
      }
    }
  }

  if (drop.size === 0) return layout

  const keep = (items: SidebarNavItemV1[]) => items.filter((i) => !drop.has(i.id))
  return {
    ...layout,
    pinned: { ...layout.pinned, items: keep(layout.pinned.items) },
    groups: layout.groups.map((g) => ({ ...g, items: keep(g.items) })),
  }
}

function sanitizeItems(
  items: SidebarNavItemV1[],
  seen: Set<string>,
  ctx?: NavGateContext,
): SidebarNavItemV1[] {
  return items.filter((item) => {
    if (!isNavItemId(item.id)) return false
    if (ctx && !passesGate(NAV_CATALOG_BY_ID[item.id].gate, ctx)) return false
    if (seen.has(item.id)) return false
    seen.add(item.id)
    return true
  })
}

export function sanitizeLayoutAgainstCatalog(
  layout: SidebarNavV1,
  ctx?: NavGateContext,
): SidebarNavV1 {
  const seen = new Set<string>()
  const next: SidebarNavV1 = {
    version: 2,
    pinned: {
      visible: layout.pinned.visible,
      items: sanitizeItems(layout.pinned.items, seen, ctx),
    },
    groups: layout.groups.map((g) => ({
      id: g.id,
      label: g.label,
      items: sanitizeItems(g.items, seen, ctx),
    })),
  }
  return enforceExclusiveNavIds(next)
}
