import { z } from 'zod'

export const SIDEBAR_NAV_USER_KEY = 'sidebar_nav'
export const SIDEBAR_NAV_TENANT_KEY = 'sidebar_nav_tenant'

export const MAX_SIDEBAR_GROUPS = 24
export const MAX_SIDEBAR_ITEMS_PER_GROUP = 40
/** Max height share for the fixed top (pinned) block so scrollable nav keeps room. */
export const PINNED_MAX_HEIGHT_CLASS = 'max-h-[40%]'

export const sidebarNavItemSchema = z.object({
  id: z.string().min(1).max(64),
  label: z.string().min(1).max(80).optional(),
  /** Default true when omitted. */
  showIcon: z.boolean().optional(),
  /** `accent` = highlighted style in the sidebar. */
  emphasis: z.enum(['default', 'accent']).optional(),
})

export const sidebarNavGroupSchema = z.object({
  id: z.string().min(1).max(64),
  label: z.string().max(80).nullable(),
  items: z.array(sidebarNavItemSchema).max(MAX_SIDEBAR_ITEMS_PER_GROUP),
})

export const sidebarNavPinnedSchema = z.object({
  /** When false, the fixed top block is hidden (items stay in layout for editor). */
  visible: z.boolean(),
  items: z.array(sidebarNavItemSchema).max(MAX_SIDEBAR_ITEMS_PER_GROUP),
})

const sidebarNavV2Schema = z.object({
  version: z.literal(2),
  pinned: sidebarNavPinnedSchema,
  groups: z.array(sidebarNavGroupSchema).max(MAX_SIDEBAR_GROUPS),
})

const sidebarNavV1Schema = z.object({
  version: z.literal(1),
  groups: z.array(sidebarNavGroupSchema).max(MAX_SIDEBAR_GROUPS),
})

export const sidebarNavSchema = sidebarNavV2Schema

export type SidebarNavItemV1 = z.infer<typeof sidebarNavItemSchema>
export type SidebarNavGroupV1 = z.infer<typeof sidebarNavGroupSchema>
export type SidebarNavPinned = z.infer<typeof sidebarNavPinnedSchema>
/** Normalized layout (version 2). */
export type SidebarNavV1 = z.infer<typeof sidebarNavV2Schema>

function migrateV1ToV2(v1: z.infer<typeof sidebarNavV1Schema>): SidebarNavV1 {
  const groups = v1.groups.map((g) => ({
    ...g,
    items: g.items.map((i) => ({ ...i })),
  }))
  const homeIdx = groups.findIndex((g) => g.id === 'home')
  if (homeIdx >= 0) {
    const [home] = groups.splice(homeIdx, 1)
    return {
      version: 2,
      pinned: { visible: true, items: home.items },
      groups,
    }
  }
  return {
    version: 2,
    pinned: { visible: false, items: [] },
    groups,
  }
}

function assertNoDuplicateIds(layout: SidebarNavV1): boolean {
  const seenItems = new Set<string>()
  const seenGroups = new Set<string>()
  for (const item of layout.pinned.items) {
    if (seenItems.has(item.id)) return false
    seenItems.add(item.id)
  }
  for (const group of layout.groups) {
    if (seenGroups.has(group.id)) return false
    seenGroups.add(group.id)
    for (const item of group.items) {
      if (seenItems.has(item.id)) return false
      seenItems.add(item.id)
    }
  }
  return true
}

/** Parse stored JSON. null / invalid → null (inherit). Accepts v1 (migrated) and v2. */
export function parseSidebarNav(raw: unknown): SidebarNavV1 | null {
  if (raw == null) return null

  const v2 = sidebarNavV2Schema.safeParse(raw)
  if (v2.success) {
    return assertNoDuplicateIds(v2.data) ? v2.data : null
  }

  const v1 = sidebarNavV1Schema.safeParse(raw)
  if (v1.success) {
    const migrated = migrateV1ToV2(v1.data)
    return assertNoDuplicateIds(migrated) ? migrated : null
  }

  return null
}

export function countNavItems(layout: SidebarNavV1): number {
  return (
    layout.pinned.items.length +
    layout.groups.reduce((n, g) => n + g.items.length, 0)
  )
}
