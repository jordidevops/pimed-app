import React, { useCallback, useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { useExplorer } from '../contexts/ExplorerContext'
import { formatBytes, formatDate, getFileEmoji, isPreviewable } from '../utils/fileUtils'
import type { FileNode, TrashedNode, StarredFile, SearchResult } from '../types/storage.types'

// ─── Normalise different node shapes into a common row ────────────────────────

export interface TableRow {
  id: string
  name: string
  nodeType: 'file' | 'folder'
  mimeType: string | null
  storageKey: string | null
  sizeBytes: number | null
  createdAt: string | null
  updatedAt: string | null
  date: string
  isRestricted?: boolean
  canAccessForMe?: boolean
}

export function toRows(nodes: FileNode[]): TableRow[] {
  return nodes.map((n) => ({
    id: n.id,
    name: n.name,
    nodeType: n.node_type,
    mimeType: n.mime_type,
    storageKey: n.storage_key,
    sizeBytes: n.size_bytes,
    createdAt: n.created_at,
    updatedAt: n.updated_at,
    date: n.updated_at,
    isRestricted: n.is_restricted,
    canAccessForMe: n.can_access_for_me,
  }))
}

export function trashedToRows(nodes: TrashedNode[]): TableRow[] {
  return nodes.map((n) => ({
    id: n.id,
    name: n.name,
    nodeType: n.node_type,
    mimeType: n.mime_type,
    storageKey: null, // not exposed on trash view
    sizeBytes: n.size_bytes,
    createdAt: n.created_at,
    updatedAt: null,
    date: n.deleted_at,
  }))
}

export function starredToRows(nodes: StarredFile[]): TableRow[] {
  return nodes.map((n) => ({
    id: n.id,
    name: n.name,
    nodeType: n.node_type,
    mimeType: n.mime_type,
    storageKey: n.storage_key,
    sizeBytes: n.size_bytes,
    createdAt: n.created_at,
    updatedAt: n.updated_at,
    date: n.starred_at,
  }))
}

export function searchToRows(nodes: SearchResult[]): TableRow[] {
  return nodes.map((n) => ({
    id: n.id,
    name: n.name,
    nodeType: n.node_type,
    mimeType: n.mime_type,
    storageKey: null,
    sizeBytes: n.size_bytes,
    createdAt: n.created_at,
    updatedAt: n.updated_at,
    date: n.updated_at,
  }))
}

// ─── EmptyState ───────────────────────────────────────────────────────────────

function EmptyState({ icon, title, description }: { icon: string; title: string; description: string }) {
  return (
    <div className="flex flex-col items-center justify-center py-20 text-center">
      <span className="text-4xl mb-3" aria-hidden>{icon}</span>
      <p className="text-sm font-medium text-foreground">{title}</p>
      <p className="text-xs text-muted-foreground mt-1 max-w-xs">{description}</p>
    </div>
  )
}

// ─── Row component (memoised) ─────────────────────────────────────────────────

interface FileRowProps {
  row: TableRow
  isSelected: boolean
  orderedIds: string[]
  dateLabel: string
  onRename?: (row: TableRow) => void
  onPermissions?: (row: TableRow) => void
}

const FileRow = React.memo(function FileRow({ row, isSelected, orderedIds, onRename, onPermissions }: FileRowProps) {
  const { t } = useTranslation('storage')
  const { selectNode, navigateInto, openPreview, setSidebarPreview } = useExplorer()

  const handleClick = useCallback(
    (e: React.MouseEvent) => {
      selectNode(row.id, e.metaKey || e.ctrlKey, e.shiftKey, orderedIds)
      // On plain single-click (no modifier), update sidebar preview for files.
      if (!e.metaKey && !e.ctrlKey && !e.shiftKey && row.nodeType === 'file') {
        setSidebarPreview({
          id: row.id,
          name: row.name,
          nodeType: row.nodeType,
          mimeType: row.mimeType,
          storageKey: row.storageKey,
          sizeBytes: row.sizeBytes,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
        })
      } else if (!e.metaKey && !e.ctrlKey && !e.shiftKey) {
        setSidebarPreview(null)
      }
    },
    [row, selectNode, orderedIds, setSidebarPreview],
  )

  const handleDoubleClick = useCallback(() => {
    if (row.nodeType === 'folder') {
      navigateInto(row.id, row.name)
    } else if (isPreviewable(row.mimeType) && !!row.storageKey) {
      setSidebarPreview({
        id: row.id,
        name: row.name,
        nodeType: row.nodeType,
        mimeType: row.mimeType,
        storageKey: row.storageKey,
        sizeBytes: row.sizeBytes,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      })
      openPreview(row.id)
    }
  }, [row, navigateInto, openPreview, setSidebarPreview])

  return (
    <tr
      onClick={handleClick}
      onDoubleClick={handleDoubleClick}
      className={`group cursor-pointer select-none transition-colors ${
        isSelected ? 'bg-primary/10' : 'hover:bg-accent'
      }`}
      // aria-selected={isSelected ? 'true' : 'false'}
    >
      {/* Checkbox */}
      <td className="w-10 pl-3 py-2">
        <input
          type="checkbox"
          checked={isSelected}
          onClick={(e) => {
            e.stopPropagation()
            // Always toggle via multi-select semantics so a second click deselects
            selectNode(row.id, true, false, orderedIds)
          }}
          onChange={() => {}}
          className="h-3.5 w-3.5 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
          tabIndex={-1}
          aria-label={row.name}
        />
      </td>

      {/* Name */}
      <td className="py-2 pr-3">
        <div className="flex items-center gap-2.5 min-w-0">
          {row.isRestricted && (
            <span className="shrink-0 text-xs text-amber-500" title="Restringit" aria-label="Restringit">🔒</span>
          )}
          <span className="text-base leading-none shrink-0" aria-hidden>
            {getFileEmoji(row.mimeType, row.nodeType)}
          </span>
          <span className="text-sm text-foreground truncate font-medium">{row.name}</span>
        </div>
      </td>

      {/* Size */}
      <td className="py-2 pr-3 text-xs text-muted-foreground tabular-nums w-24">
        {row.nodeType === 'folder' ? '—' : formatBytes(row.sizeBytes)}
      </td>

      {/* Date */}
      <td className="py-2 pr-4 text-xs text-muted-foreground w-32 tabular-nums">
        {formatDate(row.date)}
      </td>

      {/* Row actions */}
      <td className="py-2 pr-3 w-16 text-right">
        <div className="flex items-center justify-end gap-0.5">
          {onPermissions && (
            <button
              type="button"
              onClick={(e) => { e.stopPropagation(); onPermissions(row) }}
              className="opacity-0 group-hover:opacity-100 transition-opacity rounded p-0.5 text-muted-foreground hover:text-amber-500 hover:bg-amber-50 dark:hover:bg-amber-950/50"
              title={t('storage.acl.manage_btn', 'Gestionar accés')}
              aria-label={t('storage.acl.manage_btn', 'Gestionar accés')}
            >
              <svg className="h-3.5 w-3.5" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
                <path fillRule="evenodd" d="M10 1a4.5 4.5 0 0 0-4.5 4.5V9H5a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6a2 2 0 0 0-2-2h-.5V5.5A4.5 4.5 0 0 0 10 1Zm3 8V5.5a3 3 0 1 0-6 0V9h6Z" clipRule="evenodd" />
              </svg>
            </button>
          )}
          {onRename && (
            <button
              type="button"
              onClick={(e) => { e.stopPropagation(); onRename(row) }}
              className="opacity-0 group-hover:opacity-100 transition-opacity rounded p-0.5 text-muted-foreground hover:text-primary hover:bg-primary/10"
              title={t('storage.folder.rename_title', 'Reanomenar')}
              aria-label={t('storage.folder.rename_title', 'Reanomenar')}
            >
              <svg className="h-3.5 w-3.5" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
                <path d="M2.695 14.763l-1.262 3.154a.5.5 0 0 0 .65.65l3.155-1.262a4 4 0 0 0 1.343-.885L17.5 5.5a2.121 2.121 0 0 0-3-3L3.58 13.42a4 4 0 0 0-.885 1.343z" />
              </svg>
            </button>
          )}
        </div>
      </td>
    </tr>
  )
})

// ─── FileTable ────────────────────────────────────────────────────────────────

interface FileTableProps {
  rows: TableRow[]
  isLoading: boolean
  emptyIcon: string
  emptyTitle: string
  emptyDescription: string
  dateLabel: string
  onRename?: (row: TableRow) => void
  onPermissions?: (row: TableRow) => void
}

export function FileTable({ rows, isLoading, emptyIcon, emptyTitle, emptyDescription, dateLabel, onRename, onPermissions }: FileTableProps) {
  const { t } = useTranslation('storage')
  const { state, selectAll, clearSelection, navigateUp } = useExplorer()

  const orderedIds = useMemo(() => rows.map((r) => r.id), [rows])
  const allSelected = rows.length > 0 && rows.every((r) => state.selectedIds.has(r.id))
  const showParentRow = state.view === 'files' && state.currentFolderId != null

  const handleToggleAll = useCallback(() => {
    if (allSelected) clearSelection()
    else selectAll(orderedIds)
  }, [allSelected, clearSelection, selectAll, orderedIds])

  if (isLoading) {
    return (
      <div className="flex-1 flex items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600" />
      </div>
    )
  }

  if (rows.length === 0 && !showParentRow) {
    return <EmptyState icon={emptyIcon} title={emptyTitle} description={emptyDescription} />
  }

  return (
    <div className="flex-1 overflow-auto">
      <table className="w-full text-left" role="grid">
        <thead className="sticky top-0 bg-muted/80 backdrop-blur-sm z-10 border-b border-border">
          <tr>
            <th className="w-10 pl-3 py-2">
              <input
                type="checkbox"
                checked={allSelected}
                onChange={handleToggleAll}
                className="h-3.5 w-3.5 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                aria-label={t('storage.explorer.select_all', 'Selecciona-ho tot')}
              />
            </th>
            <th className="py-2 pr-3 text-xs font-medium text-muted-foreground uppercase tracking-wider">
              {t('storage.explorer.col_name', 'Nom')}
            </th>
            <th className="py-2 pr-3 text-xs font-medium text-muted-foreground uppercase tracking-wider w-24">
              {t('storage.explorer.col_size', 'Mida')}
            </th>
            <th className="py-2 pr-4 text-xs font-medium text-muted-foreground uppercase tracking-wider w-32">
              {dateLabel}
            </th>
            <th className="py-2 pr-3 w-16" />
          </tr>
        </thead>
        <tbody className="divide-y divide-border">
          {showParentRow && (
            <tr
              onDoubleClick={() => navigateUp()}
              className="group cursor-pointer select-none transition-colors hover:bg-accent"
              title={t('storage.explorer.parent_folder', 'Carpeta superior')}
            >
              <td className="w-10 pl-3 py-2" />
              <td className="py-2 pr-3">
                <div className="flex items-center gap-2.5 min-w-0">
                  <span className="text-base leading-none shrink-0" aria-hidden>
                    📁
                  </span>
                  <span className="text-sm text-muted-foreground truncate font-medium">
                    ..
                  </span>
                  <span className="text-xs text-muted-foreground/70 truncate hidden sm:inline">
                    {t('storage.explorer.parent_folder', 'Carpeta superior')}
                  </span>
                </div>
              </td>
              <td className="py-2 pr-3 text-xs text-muted-foreground tabular-nums w-24">—</td>
              <td className="py-2 pr-4 text-xs text-muted-foreground w-32 tabular-nums">—</td>
              <td className="py-2 pr-3 w-16" />
            </tr>
          )}
          {rows.map((row) => (
            <FileRow
              key={row.id}
              row={row}
              isSelected={state.selectedIds.has(row.id)}
              orderedIds={orderedIds}
              dateLabel={dateLabel}
              onRename={onRename}
              onPermissions={onPermissions}
            />
          ))}
        </tbody>
      </table>
      {rows.length === 0 && showParentRow && (
        <EmptyState icon={emptyIcon} title={emptyTitle} description={emptyDescription} />
      )}
    </div>
  )
}
