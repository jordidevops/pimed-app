import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useExplorer, type BreadcrumbSegment } from '../contexts/ExplorerContext'
import { useFileNodes } from '../api/useFileNodes'
import type { FileNode } from '../types/storage.types'

const ROOT_CRUMB: BreadcrumbSegment = { id: null, name: 'Fitxers' }

interface FolderTreeProps {
  tenantId: string | undefined
  hideFieldWork?: boolean
}

interface FolderTreeNodeProps {
  folder: FileNode
  depth: number
  pathCrumbs: BreadcrumbSegment[]
  tenantId: string | undefined
  hideFieldWork?: boolean
  expandedIds: Set<string>
  onToggle: (id: string) => void
}

function FolderTreeNode({
  folder,
  depth,
  pathCrumbs,
  tenantId,
  hideFieldWork,
  expandedIds,
  onToggle,
}: FolderTreeNodeProps) {
  const { state, navigateTo } = useExplorer()
  const isExpanded = expandedIds.has(folder.id)
  const isActive = state.currentFolderId === folder.id

  const { data: childNodes = [], isLoading } = useFileNodes(
    isExpanded ? tenantId : undefined,
    folder.id,
    state.activeDriveId,
    { hideFieldWork },
  )
  const childFolders = childNodes.filter((n) => n.node_type === 'folder')

  function handleNavigate() {
    navigateTo(folder.id, folder.name, pathCrumbs)
    if (!isExpanded) onToggle(folder.id)
  }

  return (
    <div>
      <div
        className={`flex items-center gap-0.5 rounded-lg text-sm transition-colors ${
          isActive
            ? 'bg-indigo-50 text-indigo-700'
            : 'text-muted-foreground hover:bg-accent hover:text-foreground'
        }`}
        style={{ paddingLeft: `${Math.min(depth, 6) * 12 + 4}px` }}
      >
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation()
            onToggle(folder.id)
          }}
          className="shrink-0 p-0.5 rounded hover:bg-black/5"
          aria-expanded={isExpanded}
          aria-label={isExpanded ? 'Collapse' : 'Expand'}
        >
          <svg
            className={`h-3.5 w-3.5 transition-transform ${isExpanded ? 'rotate-90' : ''}`}
            viewBox="0 0 20 20"
            fill="currentColor"
            aria-hidden
          >
            <path
              fillRule="evenodd"
              d="M7.21 14.77a.75.75 0 0 1 .02-1.06L11.168 10 7.23 6.29a.75.75 0 1 1 1.04-1.08l4.5 4.25a.75.75 0 0 1 0 1.08l-4.5 4.25a.75.75 0 0 1-1.06-.02Z"
              clipRule="evenodd"
            />
          </svg>
        </button>
        <button
          type="button"
          onClick={handleNavigate}
          className="flex min-w-0 flex-1 items-center gap-1.5 py-1 pr-2 text-left"
          title={folder.name}
        >
          <span className="text-sm leading-none shrink-0" aria-hidden>
            {isExpanded ? '📂' : '📁'}
          </span>
          <span className="truncate">{folder.name}</span>
        </button>
      </div>

      {isExpanded && (
        <div>
          {isLoading && (
            <p
              className="py-1 text-[11px] text-muted-foreground"
              style={{ paddingLeft: `${Math.min(depth + 1, 6) * 12 + 20}px` }}
            >
              …
            </p>
          )}
          {!isLoading &&
            childFolders.map((child) => (
              <FolderTreeNode
                key={child.id}
                folder={child}
                depth={depth + 1}
                pathCrumbs={[...pathCrumbs, { id: child.id, name: child.name }]}
                tenantId={tenantId}
                hideFieldWork={hideFieldWork}
                expandedIds={expandedIds}
                onToggle={onToggle}
              />
            ))}
        </div>
      )}
    </div>
  )
}

export function FolderTree({ tenantId, hideFieldWork }: FolderTreeProps) {
  const { t } = useTranslation('storage')
  const { state, navigateTo } = useExplorer()
  const [expandedIds, setExpandedIds] = useState<Set<string>>(() => new Set())

  const { data: rootNodes = [] } = useFileNodes(tenantId, null, state.activeDriveId, {
    hideFieldWork,
  })
  const rootFolders = rootNodes.filter((n) => n.node_type === 'folder')

  // Keep ancestors of the current path expanded
  useEffect(() => {
    const ancestorIds = state.breadcrumbs
      .map((c) => c.id)
      .filter((id): id is string => id != null)
    if (ancestorIds.length === 0) return
    setExpandedIds((prev) => {
      let changed = false
      const next = new Set(prev)
      for (const id of ancestorIds) {
        if (!next.has(id)) {
          next.add(id)
          changed = true
        }
      }
      return changed ? next : prev
    })
  }, [state.breadcrumbs])

  function toggleExpand(id: string) {
    setExpandedIds((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const rootActive = state.currentFolderId == null && state.view === 'files'

  return (
    <div className="mt-3 pt-3 border-t border-border">
      <p className="px-3 mb-1 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
        {t('storage.explorer.folder_tree', 'Carpetes')}
      </p>
      <div className="space-y-0.5">
        <button
          type="button"
          onClick={() => navigateTo(null, ROOT_CRUMB.name)}
          className={`w-full flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm transition-colors ${
            rootActive
              ? 'bg-indigo-50 text-indigo-700'
              : 'text-muted-foreground hover:bg-accent hover:text-foreground'
          }`}
        >
          <span className="text-sm leading-none" aria-hidden>
            🏠
          </span>
          <span className="truncate">{ROOT_CRUMB.name}</span>
        </button>

        {rootFolders.map((folder) => (
          <FolderTreeNode
            key={folder.id}
            folder={folder}
            depth={1}
            pathCrumbs={[ROOT_CRUMB, { id: folder.id, name: folder.name }]}
            tenantId={tenantId}
            hideFieldWork={hideFieldWork}
            expandedIds={expandedIds}
            onToggle={toggleExpand}
          />
        ))}
      </div>
    </div>
  )
}
