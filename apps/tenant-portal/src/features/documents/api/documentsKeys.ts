export const documentsKeys = {
  allFolders: (tenantId: string) => ['documents', tenantId, 'folders'] as const,
  folders: (
    tenantId: string,
    parentId?: string | null,
    scopeMode?: 'global' | 'embedded',
    entityType?: string | null,
    entityId?: string | null,
    siteId?: string | null,
  ) =>
    [
      ...documentsKeys.allFolders(tenantId),
      parentId ?? 'root',
      scopeMode ?? 'global',
      entityType ?? null,
      entityId ?? null,
      siteId ?? null,
    ] as const,

  allDocs: (tenantId: string) => ['documents', tenantId, 'docs'] as const,
  docs: (
    tenantId: string,
    folderId?: string | null,
    entityType?: string,
    entityId?: string,
    siteId?: string | null,
  ) =>
    [
      ...documentsKeys.allDocs(tenantId),
      folderId ?? 'all',
      entityType ?? null,
      entityId ?? null,
      siteId ?? null,
    ] as const,

  allArchivedDocs: (tenantId: string) => ['documents', tenantId, 'archived'] as const,
  archivedDocs: (
    tenantId: string,
    folderId?: string | null,
    siteId?: string | null,
  ) =>
    [
      ...documentsKeys.allArchivedDocs(tenantId),
      folderId ?? 'all',
      siteId ?? null,
    ] as const,

  versions: (documentId: string) => ['document-versions', documentId] as const,
}
