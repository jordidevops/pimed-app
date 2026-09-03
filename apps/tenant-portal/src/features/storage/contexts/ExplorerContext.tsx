import { createContext, useCallback, useContext, useMemo, useReducer, type ReactNode } from 'react'

// ─── View types ───────────────────────────────────────────────────────────────

export type ExplorerView = 'files' | 'starred' | 'trash' | 'search'

export interface BreadcrumbSegment {
  id: string | null
  name: string
}

export interface SidebarPreview {
  id: string
  name: string
  nodeType: 'file' | 'folder'
  mimeType: string | null
  storageKey: string | null
  sizeBytes: number | null
  createdAt: string | null
  updatedAt: string | null
}

// ─── State ────────────────────────────────────────────────────────────────────

export interface ExplorerState {
  view: ExplorerView
  currentFolderId: string | null
  breadcrumbs: BreadcrumbSegment[]
  selectedIds: Set<string>
  searchQuery: string
  previewNodeId: string | null
  sidebarPreview: SidebarPreview | null
  /** null = App Drive (Supabase default); string = BYOS drive id */
  activeDriveId: string | null
}

const ROOT_CRUMB: BreadcrumbSegment = { id: null, name: 'Fitxers' }

const initialState: ExplorerState = {
  view: 'files',
  currentFolderId: null,
  breadcrumbs: [ROOT_CRUMB],
  selectedIds: new Set(),
  searchQuery: '',
  previewNodeId: null,
  sidebarPreview: null,
  activeDriveId: null,
}

function clearNavExtras(state: ExplorerState): Pick<
  ExplorerState,
  'selectedIds' | 'searchQuery' | 'previewNodeId' | 'sidebarPreview'
> {
  return {
    selectedIds: new Set(),
    searchQuery: '',
    previewNodeId: null,
    sidebarPreview: null,
  }
}

// ─── Actions ──────────────────────────────────────────────────────────────────

type ExplorerAction =
  | { type: 'NAVIGATE_INTO'; folderId: string; folderName: string }
  | {
      type: 'NAVIGATE_TO'
      folderId: string | null
      folderName: string
      crumbs?: BreadcrumbSegment[]
    }
  | { type: 'NAVIGATE_UP' }
  | { type: 'NAVIGATE_BREADCRUMB'; index: number }
  | { type: 'SET_VIEW'; view: ExplorerView }
  | { type: 'SELECT_NODE'; nodeId: string; multi: boolean; range: boolean; orderedIds?: string[] }
  | { type: 'SELECT_ALL'; nodeIds: string[] }
  | { type: 'CLEAR_SELECTION' }
  | { type: 'SET_SEARCH'; query: string }
  | { type: 'OPEN_PREVIEW'; nodeId: string }
  | { type: 'CLOSE_PREVIEW' }
  | { type: 'SET_SIDEBAR_PREVIEW'; preview: SidebarPreview | null }
  | { type: 'SET_DRIVE'; driveId: string | null }

// ─── Reducer ──────────────────────────────────────────────────────────────────

function explorerReducer(state: ExplorerState, action: ExplorerAction): ExplorerState {
  switch (action.type) {
    case 'NAVIGATE_INTO': {
      if (state.currentFolderId === action.folderId) return state
      const ancestorIdx = state.breadcrumbs.findIndex((c) => c.id === action.folderId)
      if (ancestorIdx >= 0) {
        const crumbs = state.breadcrumbs.slice(0, ancestorIdx + 1)
        return {
          ...state,
          view: 'files',
          currentFolderId: action.folderId,
          breadcrumbs: crumbs,
          ...clearNavExtras(state),
        }
      }
      return {
        ...state,
        view: 'files',
        currentFolderId: action.folderId,
        breadcrumbs: [
          ...state.breadcrumbs,
          { id: action.folderId, name: action.folderName },
        ],
        ...clearNavExtras(state),
      }
    }

    case 'NAVIGATE_TO': {
      if (
        state.currentFolderId === action.folderId &&
        (!action.crumbs || action.crumbs.length === 0)
      ) {
        return state
      }
      const ancestorIdx = state.breadcrumbs.findIndex((c) => c.id === action.folderId)
      if (ancestorIdx >= 0 && !action.crumbs) {
        const crumbs = state.breadcrumbs.slice(0, ancestorIdx + 1)
        return {
          ...state,
          view: 'files',
          currentFolderId: action.folderId,
          breadcrumbs: crumbs,
          ...clearNavExtras(state),
        }
      }
      const breadcrumbs =
        action.crumbs && action.crumbs.length > 0
          ? action.crumbs
          : action.folderId == null
            ? [ROOT_CRUMB]
            : [ROOT_CRUMB, { id: action.folderId, name: action.folderName }]
      return {
        ...state,
        view: 'files',
        currentFolderId: action.folderId,
        breadcrumbs,
        ...clearNavExtras(state),
      }
    }

    case 'NAVIGATE_UP': {
      if (state.breadcrumbs.length <= 1) {
        if (state.currentFolderId == null) return state
        return {
          ...state,
          view: 'files',
          currentFolderId: null,
          breadcrumbs: [ROOT_CRUMB],
          ...clearNavExtras(state),
        }
      }
      const crumbs = state.breadcrumbs.slice(0, -1)
      const target = crumbs[crumbs.length - 1]
      return {
        ...state,
        view: 'files',
        currentFolderId: target.id,
        breadcrumbs: crumbs,
        ...clearNavExtras(state),
      }
    }

    case 'NAVIGATE_BREADCRUMB': {
      const crumbs = state.breadcrumbs.slice(0, action.index + 1)
      const target = crumbs[crumbs.length - 1]
      return {
        ...state,
        view: 'files',
        currentFolderId: target.id,
        breadcrumbs: crumbs,
        ...clearNavExtras(state),
      }
    }

    case 'SET_VIEW':
      return {
        ...state,
        view: action.view,
        currentFolderId: null,
        breadcrumbs: [ROOT_CRUMB],
        selectedIds: new Set(),
        searchQuery: action.view === 'search' ? state.searchQuery : '',
        previewNodeId: null,
        sidebarPreview: null,
      }

    case 'SELECT_NODE': {
      const { nodeId, multi, range, orderedIds } = action

      if (range && orderedIds && state.selectedIds.size > 0) {
        const lastSelected = Array.from(state.selectedIds).pop()!
        const lastIdx = orderedIds.indexOf(lastSelected)
        const curIdx = orderedIds.indexOf(nodeId)
        if (lastIdx !== -1 && curIdx !== -1) {
          const [start, end] = lastIdx < curIdx ? [lastIdx, curIdx] : [curIdx, lastIdx]
          const rangeIds = orderedIds.slice(start, end + 1)
          const next = new Set(state.selectedIds)
          rangeIds.forEach((id) => next.add(id))
          return { ...state, selectedIds: next }
        }
      }

      if (multi) {
        const next = new Set(state.selectedIds)
        if (next.has(nodeId)) next.delete(nodeId)
        else next.add(nodeId)
        return { ...state, selectedIds: next }
      }

      // Plain click on the only selected item → deselect (checkbox / re-click)
      if (state.selectedIds.size === 1 && state.selectedIds.has(nodeId)) {
        return { ...state, selectedIds: new Set() }
      }

      return { ...state, selectedIds: new Set([nodeId]) }
    }

    case 'SELECT_ALL':
      return { ...state, selectedIds: new Set(action.nodeIds) }

    case 'CLEAR_SELECTION':
      return { ...state, selectedIds: new Set(), sidebarPreview: null }

    case 'SET_SEARCH':
      return {
        ...state,
        view: action.query.trim() ? 'search' : 'files',
        searchQuery: action.query,
        selectedIds: new Set(),
        previewNodeId: null,
        sidebarPreview: null,
      }

    case 'OPEN_PREVIEW':
      return { ...state, previewNodeId: action.nodeId }

    case 'CLOSE_PREVIEW':
      return { ...state, previewNodeId: null }

    case 'SET_SIDEBAR_PREVIEW':
      return { ...state, sidebarPreview: action.preview }

    case 'SET_DRIVE':
      return {
        ...state,
        activeDriveId: action.driveId,
        view: 'files',
        currentFolderId: null,
        breadcrumbs: [ROOT_CRUMB],
        selectedIds: new Set(),
        previewNodeId: null,
        sidebarPreview: null,
      }

    default:
      return state
  }
}

// ─── Context type ─────────────────────────────────────────────────────────────

interface ExplorerContextType {
  state: ExplorerState
  /** Enter a child of the current folder (append crumb). */
  navigateInto: (folderId: string, folderName: string) => void
  /** Absolute jump (sidebar / rebuild path). */
  navigateTo: (
    folderId: string | null,
    folderName: string,
    crumbs?: BreadcrumbSegment[],
  ) => void
  navigateUp: () => void
  /** @deprecated Prefer navigateInto / navigateTo */
  navigateFolder: (folderId: string | null, folderName: string) => void
  navigateBreadcrumb: (index: number) => void
  setView: (view: ExplorerView) => void
  selectNode: (nodeId: string, multi: boolean, range: boolean, orderedIds?: string[]) => void
  selectAll: (nodeIds: string[]) => void
  clearSelection: () => void
  setSearch: (query: string) => void
  openPreview: (nodeId: string) => void
  closePreview: () => void
  setSidebarPreview: (preview: SidebarPreview | null) => void
  setActiveDrive: (driveId: string | null) => void
}

const ExplorerContext = createContext<ExplorerContextType | undefined>(undefined)

// ─── Provider ─────────────────────────────────────────────────────────────────

export function ExplorerProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(explorerReducer, initialState)

  const navigateInto = useCallback(
    (folderId: string, folderName: string) =>
      dispatch({ type: 'NAVIGATE_INTO', folderId, folderName }),
    [],
  )
  const navigateTo = useCallback(
    (folderId: string | null, folderName: string, crumbs?: BreadcrumbSegment[]) =>
      dispatch({ type: 'NAVIGATE_TO', folderId, folderName, crumbs }),
    [],
  )
  const navigateUp = useCallback(() => dispatch({ type: 'NAVIGATE_UP' }), [])
  const navigateFolder = useCallback(
    (folderId: string | null, folderName: string) => {
      if (folderId == null) {
        dispatch({ type: 'NAVIGATE_TO', folderId: null, folderName })
      } else {
        dispatch({ type: 'NAVIGATE_INTO', folderId, folderName })
      }
    },
    [],
  )
  const navigateBreadcrumb = useCallback(
    (index: number) => dispatch({ type: 'NAVIGATE_BREADCRUMB', index }),
    [],
  )
  const setView = useCallback(
    (view: ExplorerView) => dispatch({ type: 'SET_VIEW', view }),
    [],
  )
  const selectNode = useCallback(
    (nodeId: string, multi: boolean, range: boolean, orderedIds?: string[]) =>
      dispatch({ type: 'SELECT_NODE', nodeId, multi, range, orderedIds }),
    [],
  )
  const selectAll = useCallback(
    (nodeIds: string[]) => dispatch({ type: 'SELECT_ALL', nodeIds }),
    [],
  )
  const clearSelection = useCallback(() => dispatch({ type: 'CLEAR_SELECTION' }), [])
  const setSearch = useCallback(
    (query: string) => dispatch({ type: 'SET_SEARCH', query }),
    [],
  )
  const openPreview = useCallback(
    (nodeId: string) => dispatch({ type: 'OPEN_PREVIEW', nodeId }),
    [],
  )
  const closePreview = useCallback(() => dispatch({ type: 'CLOSE_PREVIEW' }), [])
  const setSidebarPreview = useCallback(
    (preview: SidebarPreview | null) => dispatch({ type: 'SET_SIDEBAR_PREVIEW', preview }),
    [],
  )
  const setActiveDrive = useCallback(
    (driveId: string | null) => dispatch({ type: 'SET_DRIVE', driveId }),
    [],
  )

  const value = useMemo<ExplorerContextType>(
    () => ({
      state,
      navigateInto,
      navigateTo,
      navigateUp,
      navigateFolder,
      navigateBreadcrumb,
      setView,
      selectNode,
      selectAll,
      clearSelection,
      setSearch,
      openPreview,
      closePreview,
      setSidebarPreview,
      setActiveDrive,
    }),
    [
      state,
      navigateInto,
      navigateTo,
      navigateUp,
      navigateFolder,
      navigateBreadcrumb,
      setView,
      selectNode,
      selectAll,
      clearSelection,
      setSearch,
      openPreview,
      closePreview,
      setSidebarPreview,
      setActiveDrive,
    ],
  )

  return <ExplorerContext.Provider value={value}>{children}</ExplorerContext.Provider>
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function useExplorer() {
  const ctx = useContext(ExplorerContext)
  if (!ctx) throw new Error('useExplorer must be used within ExplorerProvider')
  return ctx
}
