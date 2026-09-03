/**
 * Centralised React Query key factory for the storage feature.
 *
 * Keeping keys here lets any mutation invalidate exactly the right queries
 * without manually duplicating key arrays across multiple files.
 */
export const storageKeys = {
  all: ['storage'] as const,

  // ── File node listing (directory browsing) ──────────────────────────────
  nodes: () => [...storageKeys.all, 'nodes'] as const,
  /** Key for listing the direct children of `parentId` (null = root), optionally scoped to a drive. */
  nodesByParent: (tenantId: string, parentId: string | null, driveId?: string | null) =>
    [...storageKeys.nodes(), tenantId, parentId ?? 'root', driveId ?? 'default'] as const,

  // ── Storage provider / drives ─────────────────────────────────────────────
  drives: () => [...storageKeys.all, 'drives'] as const,
  drivesByTenant: (tenantId: string) =>
    [...storageKeys.drives(), tenantId] as const,

  // ── Storage quota ────────────────────────────────────────────────────────
  usage: () => [...storageKeys.all, 'usage'] as const,
  usageByTenant: (tenantId: string, driveId?: string | null) =>
    [...storageKeys.usage(), tenantId, driveId ?? 'default'] as const,

  // ── Trash ────────────────────────────────────────────────────────────────
  trash: () => [...storageKeys.all, 'trash'] as const,
  trashByTenant: (tenantId: string, driveId?: string | null) =>
    [...storageKeys.trash(), tenantId, driveId ?? 'default'] as const,

  // ── Starred files ────────────────────────────────────────────────────────
  starred: () => [...storageKeys.all, 'starred'] as const,
  starredByTenant: (tenantId: string, driveId?: string | null) =>
    [...storageKeys.starred(), tenantId, driveId ?? 'default'] as const,

  // ── Search results ───────────────────────────────────────────────────────
  search: () => [...storageKeys.all, 'search'] as const,
  searchResults: (tenantId: string, query: string) =>
    [...storageKeys.search(), tenantId, query] as const,

  // ── Node permissions (ACL) ───────────────────────────────────────────────
  permissions: () => [...storageKeys.all, 'permissions'] as const,
  permissionsByNode: (nodeId: string) =>
    [...storageKeys.permissions(), nodeId] as const,

  // ── Tenant members (used in PermissionsModal search) ─────────────────────
  tenantMembers: (tenantId: string) =>
    [...storageKeys.all, 'tenantMembers', tenantId] as const,
} as const
