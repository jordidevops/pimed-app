import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ExplorerProvider, useExplorer } from '../contexts/ExplorerContext'
import { UploadManagerProvider, useUploadManager } from '../contexts/UploadManagerContext'
import { useFileNodes } from '../api/useFileNodes'
import { useStorageDrives } from '../api/useStorageDrives'
import { useTrash } from '../api/useTrash'
import { useStarredFiles, useStarNode, useUnstarNode } from '../api/useStarredFiles'
import { useSearchFiles } from '../api/useSearchFiles'
import { useTrashNode } from '../api/useTrashNode'
import { useRestoreNode } from '../api/useRestoreNode'
import { useCreateFolder } from '../api/useCreateFolder'
import { useRenameNode } from '../api/useRenameNode'
import { useDebounce, ALLOWED_MIME_ACCEPT } from '../utils/fileUtils'
import { useIsFieldService, useSectorLabel } from '@/hooks/useSectorLabel'
import { ExplorerSidebar } from './ExplorerSidebar'
import { ExplorerHeader } from './ExplorerHeader'
import {
  FileTable,
  toRows,
  trashedToRows,
  starredToRows,
  searchToRows,
  type TableRow,
} from './FileTable'
import { BulkActionsBar } from './BulkActionsBar'
import { DragDropZone } from './DragDropZone'
import { UploadManagerOverlay } from './UploadManagerOverlay'
import { FilePreviewModal } from './FilePreviewModal'
import { PermissionsModal } from './PermissionsModal'

const SIDEBAR_MIN = 180
const SIDEBAR_MAX = 480
const SIDEBAR_DEFAULT = 208
const SIDEBAR_WIDTH_KEY = 'files_sidebar_width'

function readSidebarWidth(): number {
  try {
    const raw = localStorage.getItem(SIDEBAR_WIDTH_KEY)
    const n = raw != null ? Number(raw) : NaN
    if (Number.isFinite(n) && n >= SIDEBAR_MIN && n <= SIDEBAR_MAX) return n
  } catch {
    /* ignore */
  }
  return SIDEBAR_DEFAULT
}

// ─── Inner orchestrator (needs contexts) ──────────────────────────────────────

function ExplorerInner({ tenantId }: { tenantId: string }) {
  const { t } = useTranslation('storage')
  const { state, clearSelection } = useExplorer()
  const { enqueueFiles } = useUploadManager()
  const fileInputRef = useRef<HTMLInputElement>(null)
  const isFieldService = useIsFieldService()
  const projectLabel = useSectorLabel('project', t('storage.explorer.project_fallback', 'Projecte'))
  const [showFieldWork, setShowFieldWork] = useState(() => {
    try {
      return localStorage.getItem('files_show_field_work') === '1'
    } catch {
      return false
    }
  })
  const [sidebarWidth, setSidebarWidth] = useState(readSidebarWidth)
  const sidebarWidthRef = useRef(sidebarWidth)
  sidebarWidthRef.current = sidebarWidth
  const [isResizing, setIsResizing] = useState(false)

  // ── Drives ──────────────────────────────────────────────────────────────
  const { data: byosDrives = [] } = useStorageDrives(tenantId)
  const activeDrive = useMemo(
    () => byosDrives.find((d) => d.id === state.activeDriveId) ?? null,
    [byosDrives, state.activeDriveId],
  )

  // ── Data: files / trash / starred / search ──────────────────────────────
  const { data: fileNodes = [], isLoading: filesLoading } = useFileNodes(
    state.view === 'files' ? tenantId : undefined,
    state.currentFolderId,
    state.activeDriveId,
    { hideFieldWork: !showFieldWork },
  )

  const fieldWorkBanner = useMemo(() => {
    if (state.view !== 'files' || !state.currentFolderId) return null
    const sample = fileNodes.find((n) => {
      const m = n.metadata as Record<string, unknown> | null
      return typeof m?.project_id === 'string' || n.entity_type === 'project'
    })
    if (!sample) return null
    const meta = sample.metadata as Record<string, unknown> | null
    const projectId =
      (typeof meta?.project_id === 'string' && meta.project_id) ||
      (sample.entity_type === 'project' ? sample.entity_id : null)
    if (!projectId) return null
    const kind = meta?.kind
    const isField =
      kind === 'field_photos' ||
      kind === 'field_attachments' ||
      kind === 'field_evidence' ||
      kind === 'field_project' ||
      kind === 'field_work_root' ||
      meta?.purpose != null
    if (!isField) return null
    return { projectId }
  }, [state.view, state.currentFolderId, fileNodes])

  useEffect(() => {
    try {
      localStorage.setItem('files_show_field_work', showFieldWork ? '1' : '0')
    } catch {
      /* ignore */
    }
  }, [showFieldWork])

  const handleSidebarResizeStart = useCallback((e: React.PointerEvent<HTMLDivElement>) => {
    e.preventDefault()
    const startX = e.clientX
    const startW = sidebarWidthRef.current
    setIsResizing(true)

    function onMove(ev: PointerEvent) {
      const next = Math.min(
        SIDEBAR_MAX,
        Math.max(SIDEBAR_MIN, startW + (ev.clientX - startX)),
      )
      setSidebarWidth(next)
      sidebarWidthRef.current = next
    }

    function onUp() {
      setIsResizing(false)
      try {
        localStorage.setItem(SIDEBAR_WIDTH_KEY, String(sidebarWidthRef.current))
      } catch {
        /* ignore */
      }
      document.removeEventListener('pointermove', onMove)
      document.removeEventListener('pointerup', onUp)
    }

    document.addEventListener('pointermove', onMove)
    document.addEventListener('pointerup', onUp)
  }, [])

  const { data: trashNodes = [], isLoading: trashLoading } = useTrash(
    state.view === 'trash' ? tenantId : undefined,
    state.activeDriveId,
  )
  const { data: starredNodes = [], isLoading: starredLoading } = useStarredFiles(
    tenantId,
    state.activeDriveId,
  )
  const debouncedSearch = useDebounce(state.searchQuery, 300)
  const { data: searchRes = [], isLoading: searchLoading } = useSearchFiles(
    state.view === 'search' ? tenantId : undefined,
    debouncedSearch,
  )

  // ── Mutations ───────────────────────────────────────────────────────────
  const { mutateAsync: trashMut, isPending: trashPending } = useTrashNode(tenantId)
  const { mutateAsync: restoreMut, isPending: restorePending } = useRestoreNode(tenantId)
  const { mutateAsync: starMut, isPending: starPending } = useStarNode(tenantId)
  const { mutateAsync: unstarMut, isPending: unstarPending } = useUnstarNode(tenantId)
  const { mutateAsync: createFolderMut } = useCreateFolder(tenantId, state.currentFolderId)
  const { mutateAsync: renameNodeMut } = useRenameNode(tenantId)

  const isPending = trashPending || restorePending || starPending || unstarPending

  // ── Rename modal state ──────────────────────────────────────────────────
  const [renameTarget, setRenameTarget] = useState<TableRow | null>(null)
  const [renameValue, setRenameValue] = useState('')
  const [renameError, setRenameError] = useState<string | null>(null)
  const [renamePending, setRenamePending] = useState(false)
  const renameInputRef = useRef<HTMLInputElement>(null)

  // ── Permissions modal state ─────────────────────────────────────────────
  const [permTarget, setPermTarget] = useState<TableRow | null>(null)

  useEffect(() => {
    if (renameTarget && renameInputRef.current) {
      renameInputRef.current.focus()
      renameInputRef.current.select()
    }
  }, [renameTarget])

  const selectedIds = useMemo(() => Array.from(state.selectedIds), [state.selectedIds])
  const starredIdSet = useMemo(() => new Set(starredNodes.map((n) => n.id)), [starredNodes])
  const allSelectedAreStarred = useMemo(
    () => selectedIds.length > 0 && selectedIds.every((id) => starredIdSet.has(id)),
    [selectedIds, starredIdSet],
  )

  // ── Compute table rows for current view ─────────────────────────────────
  const { rows, isLoading, emptyIcon, emptyTitle, emptyDescription, dateLabel } = useMemo(() => {
    switch (state.view) {
      case 'files':
        return {
          rows: toRows(fileNodes),
          isLoading: filesLoading,
          emptyIcon: '📂',
          emptyTitle: t('storage.explorer.empty_files_title', 'Carpeta buida'),
          emptyDescription: t('storage.explorer.empty_files_desc', 'Puja fitxers o crea una carpeta per començar.'),
          dateLabel: t('storage.explorer.col_modified', 'Modificat'),
        }
      case 'trash':
        return {
          rows: trashedToRows(trashNodes),
          isLoading: trashLoading,
          emptyIcon: '🗑️',
          emptyTitle: t('storage.explorer.empty_trash_title', 'Paperera buida'),
          emptyDescription: t('storage.explorer.empty_trash_desc', 'Els fitxers eliminats apareixeran aquí durant 30 dies.'),
          dateLabel: t('storage.explorer.col_deleted', 'Eliminat'),
        }
      case 'starred':
        return {
          rows: starredToRows(starredNodes),
          isLoading: starredLoading,
          emptyIcon: '⭐',
          emptyTitle: t('storage.explorer.empty_starred_title', 'Sense destacats'),
          emptyDescription: t('storage.explorer.empty_starred_desc', 'Marca fitxers com a destacats per trobar-los ràpidament.'),
          dateLabel: t('storage.explorer.col_starred', 'Destacat'),
        }
      case 'search':
        return {
          rows: searchToRows(searchRes),
          isLoading: searchLoading,
          emptyIcon: '🔍',
          emptyTitle: t('storage.explorer.empty_search_title', 'Sense resultats'),
          emptyDescription: t('storage.explorer.empty_search_desc', 'No s\'han trobat fitxers que coincideixin amb la cerca.'),
          dateLabel: t('storage.explorer.col_modified', 'Modificat'),
        }
    }
  }, [state.view, fileNodes, trashNodes, starredNodes, searchRes, filesLoading, trashLoading, starredLoading, searchLoading, t])

  // ── Bulk actions ────────────────────────────────────────────────────────
  const handleBulkStar = useCallback(async () => {
    const ids = Array.from(state.selectedIds)
    await Promise.allSettled(
      ids.map((id) => (starredIdSet.has(id) ? unstarMut(id) : starMut(id))),
    )
    clearSelection()
  }, [state.selectedIds, starredIdSet, starMut, unstarMut, clearSelection])

  const handleBulkTrash = useCallback(async () => {
    const ids = Array.from(state.selectedIds)
    await Promise.allSettled(ids.map((id) => trashMut({ nodeId: id })))
    clearSelection()
  }, [state.selectedIds, trashMut, clearSelection])

  const handleBulkRestore = useCallback(async () => {
    const ids = Array.from(state.selectedIds)
    await Promise.allSettled(ids.map((id) => restoreMut(id)))
    clearSelection()
  }, [state.selectedIds, restoreMut, clearSelection])

  const handleBulkDeletePermanent = useCallback(async () => {
    const ids = Array.from(state.selectedIds)
    await Promise.allSettled(ids.map((id) => trashMut({ nodeId: id, forcePermanent: true })))
    clearSelection()
  }, [state.selectedIds, trashMut, clearSelection])

  // ── Upload ──────────────────────────────────────────────────────────────
  const handleUploadClick = useCallback(() => {
    fileInputRef.current?.click()
  }, [])

  const handleFileChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const files = Array.from(e.target.files ?? [])
      if (files.length > 0) {
        enqueueFiles(tenantId, files, state.currentFolderId, activeDrive)
      }
      // Reset so re-selecting the same file triggers change
      e.target.value = ''
    },
    [enqueueFiles, tenantId, state.currentFolderId, activeDrive],
  )

  const handleDrop = useCallback(
    (files: File[]) => {
      enqueueFiles(tenantId, files, state.currentFolderId, activeDrive)
    },
    [enqueueFiles, tenantId, state.currentFolderId, activeDrive],
  )

  // ── Folder creation ─────────────────────────────────────────────────────
  const handleCreateFolder = useCallback(
    async (name: string) => {
      await createFolderMut({ name })
    },
    [createFolderMut],
  )

  // ── Rename ──────────────────────────────────────────────────────────────
  const handleRenameClick = useCallback((row: TableRow) => {
    setRenameTarget(row)
    setRenameValue(row.name)
    setRenameError(null)
  }, [])

  // ── Permissions ─────────────────────────────────────────────────────────
  const handlePermissionsClick = useCallback((row: TableRow) => {
    setPermTarget(row)
  }, [])

  const closeRenameModal = useCallback(() => {
    if (!renamePending) {
      setRenameTarget(null)
      setRenameError(null)
    }
  }, [renamePending])

  const handleRenameSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault()
      if (!renameTarget) return
      const newName = renameValue.trim()
      if (!newName || newName === renameTarget.name) {
        setRenameError(
          !newName
            ? t('storage.folder.error_required', 'El nom no pot estar buit')
            : t('storage.folder.error_same_name', 'El nom no ha canviat'),
        )
        return
      }
      setRenamePending(true)
      setRenameError(null)
      try {
        await renameNodeMut({ nodeId: renameTarget.id, newName })
        setRenameTarget(null)
      } catch (err) {
        const code = (err as any)?.code
        setRenameError(
          code === 'duplicate_name'
            ? t('storage.folder.error_duplicate', 'Ja existeix un element amb aquest nom')
            : code === 'forbidden'
              ? t('storage.folder.error_forbidden', 'No tens permisos per reanomenar aquest element')
            : t('storage.folder.error_generic', "No s'ha pogut completar l'operació"),
        )
      } finally {
        setRenamePending(false)
      }
    },
    [renameTarget, renameValue, renameNodeMut, t],
  )

  const isByosContext = !!activeDrive

  return (
    <div
      className={`flex h-full overflow-hidden rounded-2xl border shadow-sm ${
        isByosContext
          ? 'bg-gradient-to-b from-indigo-50/35 via-card to-card border-indigo-200'
          : 'bg-card border-border'
      } ${isResizing ? 'select-none cursor-col-resize' : ''}`}
    >
      {/* Hidden file input — accept restricted to allowed MIME types */}
      <input
        ref={fileInputRef}
        type="file"
        multiple
        accept={ALLOWED_MIME_ACCEPT}
        className="hidden"
        onChange={handleFileChange}
        aria-hidden
        aria-label="Upload files"
      />

      {/* Sidebar */}
      <ExplorerSidebar
        tenantId={tenantId}
        width={sidebarWidth}
        hideFieldWork={!showFieldWork}
      />
      <div
        role="separator"
        aria-orientation="vertical"
        aria-label={t('storage.explorer.resize_sidebar', 'Redimensionar panell')}
        onPointerDown={handleSidebarResizeStart}
        className={`w-1 shrink-0 cursor-col-resize hover:bg-indigo-400/40 active:bg-indigo-500/50 transition-colors ${
          isResizing ? 'bg-indigo-500/50' : 'bg-transparent'
        }`}
      />

      {/* Main area */}
      <div className="flex-1 flex flex-col min-w-0">
        <ExplorerHeader
          onUploadClick={handleUploadClick}
          onCreateFolder={handleCreateFolder}
          activeDriveName={activeDrive?.nickname ?? activeDrive?.bucket_name ?? null}
          isByosDrive={isByosContext}
          showDriveScope={byosDrives.length > 0}
        />

        {state.view === 'files' && !state.currentFolderId && (
          <div className="flex items-center justify-between gap-2 border-b border-border bg-muted/30 px-4 py-2 text-xs">
            <span className="text-muted-foreground">
              {showFieldWork
                ? t(
                    'storage.explorer.field_work_shown',
                    'Es mostren les carpetes de {{project}}.',
                    { project: projectLabel },
                  )
                : t(
                    'storage.explorer.field_work_hidden',
                    'Les carpetes de {{project}} (fotos/adjunts) estan ocultes.',
                    { project: projectLabel },
                  )}
            </span>
            <button
              type="button"
              className="font-medium text-primary underline-offset-2 hover:underline"
              onClick={() => setShowFieldWork((v) => !v)}
            >
              {showFieldWork
                ? t('storage.explorer.hide_field_work', 'Amagar arxius de {{project}}', {
                    project: projectLabel,
                  })
                : t('storage.explorer.show_field_work', 'Mostrar arxius de {{project}}', {
                    project: projectLabel,
                  })}
            </button>
          </div>
        )}

        {fieldWorkBanner?.projectId && (
          <div className="flex items-center justify-between gap-2 border-b border-amber-200 bg-amber-50 px-4 py-2 text-xs text-amber-950 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-100">
            <span>
              {t(
                'storage.explorer.field_work_banner',
                'Aquesta carpeta està vinculada a {{project}}.',
                { project: projectLabel },
              )}
            </span>
            <Link
              to={
                isFieldService
                  ? `/field/orders/${fieldWorkBanner.projectId}`
                  : `/projects/${fieldWorkBanner.projectId}`
              }
              className="font-medium underline-offset-2 hover:underline"
            >
              {t('storage.explorer.open_project', 'Obrir {{project}}', {
                project: projectLabel,
              })}
            </Link>
          </div>
        )}

        <DragDropZone onDrop={handleDrop} disabled={state.view !== 'files'}>
          <FileTable
            rows={rows}
            isLoading={isLoading}
            emptyIcon={emptyIcon}
            emptyTitle={emptyTitle}
            emptyDescription={emptyDescription}
            dateLabel={dateLabel}
            onRename={state.view === 'files' ? handleRenameClick : undefined}
            onPermissions={state.view === 'files' ? handlePermissionsClick : undefined}
          />
        </DragDropZone>

        <BulkActionsBar
          view={state.view}
          onStar={handleBulkStar}
          starMode={allSelectedAreStarred ? 'unstar' : 'star'}
          onTrash={handleBulkTrash}
          onRestore={handleBulkRestore}
          onDelete={handleBulkDeletePermanent}
          isPending={isPending}
        />
      </div>

      {/* Preview modal */}
      <FilePreviewModal tenantId={tenantId} />

      {/* Upload overlay */}
      <UploadManagerOverlay />

      {/* Permissions modal */}
      {permTarget && (
        <PermissionsModal
          nodeId={permTarget.id}
          nodeName={permTarget.name}
          tenantId={tenantId}
          nodeIsRestricted={permTarget.isRestricted ?? false}
          onClose={() => setPermTarget(null)}
        />
      )}

      {/* Rename modal */}
      {renameTarget && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm"
        >
          <div className="bg-card rounded-xl shadow-xl w-full max-w-sm mx-4 p-6">
            <h2 className="text-base font-semibold text-foreground mb-4">
              {t('storage.folder.rename_title', 'Reanomenar')}
            </h2>
            <form onSubmit={handleRenameSubmit}>
              <input
                ref={renameInputRef}
                type="text"
                value={renameValue}
                onChange={(e) => { setRenameValue(e.target.value); setRenameError(null) }}
                className="w-full rounded-lg border border-input bg-background text-foreground px-3 py-2 text-sm focus:border-primary focus:ring-1 focus:ring-primary/20 outline-none"
                maxLength={255}
                disabled={renamePending}
                placeholder={t('storage.folder.rename_placeholder', 'Enter new name')}
                aria-label={t('storage.folder.rename_label', 'New folder name')}
              />
              {renameError && (
                <p className="mt-2 text-xs text-red-600">{renameError}</p>
              )}
              <div className="mt-4 flex justify-end gap-2">
                <button
                  type="button"
                  onClick={closeRenameModal}
                  disabled={renamePending}
                  className="rounded-lg border border-border px-3 py-1.5 text-sm text-foreground hover:bg-accent transition"
                >
                  {t('storage.actions.cancel', 'Cancel·lar')}
                </button>
                <button
                  type="submit"
                  disabled={renamePending || !renameValue.trim()}
                  className="rounded-lg bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-indigo-700 disabled:opacity-50 transition"
                >
                  {renamePending
                    ? t('storage.folder.saving', 'Desant...')
                    : t('storage.folder.rename_btn', 'Desar')}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  )
}

// ─── Public component (wraps with providers) ──────────────────────────────────

interface FileExplorerProps {
  tenantId: string
}

export function FileExplorer({ tenantId }: FileExplorerProps) {
  return (
    <ExplorerProvider>
      <UploadManagerProvider>
        <ExplorerInner tenantId={tenantId} />
      </UploadManagerProvider>
    </ExplorerProvider>
  )
}
