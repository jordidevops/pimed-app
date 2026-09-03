import { createContext, useCallback, useContext, useMemo, useReducer, type ReactNode } from 'react'
import { uploadFile } from '../api/storageService'
import type { UploadProgress, StorageDrive } from '../types/storage.types'
import { useQueryClient } from '@tanstack/react-query'
import { storageKeys } from '../api/storageKeys'
import { validateMimeType } from '../utils/fileUtils'

// ─── Types ────────────────────────────────────────────────────────────────────

export type UploadStatus = 'queued' | 'uploading' | 'done' | 'error' | 'aborted'

export interface UploadItem {
  id: string
  fileName: string
  fileSize: number
  status: UploadStatus
  progress: UploadProgress | null
  error: string | null
  abortController: AbortController | null
}

// ─── State ────────────────────────────────────────────────────────────────────

interface UploadManagerState {
  items: UploadItem[]
  minimised: boolean
}

const initialState: UploadManagerState = { items: [], minimised: false }

// ─── Actions ──────────────────────────────────────────────────────────────────

type Action =
  | { type: 'ADD'; item: UploadItem }
  | { type: 'PROGRESS'; id: string; progress: UploadProgress }
  | { type: 'DONE'; id: string }
  | { type: 'ERROR'; id: string; error: string }
  | { type: 'ABORT'; id: string }
  | { type: 'REMOVE'; id: string }
  | { type: 'CLEAR_DONE' }
  | { type: 'TOGGLE_MINIMISE' }

function reducer(state: UploadManagerState, action: Action): UploadManagerState {
  switch (action.type) {
    case 'ADD':
      return { ...state, items: [...state.items, action.item], minimised: false }
    case 'PROGRESS':
      return {
        ...state,
        items: state.items.map((i) =>
          i.id === action.id ? { ...i, status: 'uploading' as const, progress: action.progress } : i,
        ),
      }
    case 'DONE':
      return {
        ...state,
        items: state.items.map((i) =>
          i.id === action.id
            ? { ...i, status: 'done' as const, progress: { percent: 100, loaded: i.fileSize, total: i.fileSize, stage: 'done' as const }, abortController: null }
            : i,
        ),
      }
    case 'ERROR':
      return {
        ...state,
        items: state.items.map((i) =>
          i.id === action.id ? { ...i, status: 'error' as const, error: action.error, abortController: null } : i,
        ),
      }
    case 'ABORT':
      return {
        ...state,
        items: state.items.map((i) => {
          if (i.id !== action.id) return i
          i.abortController?.abort()
          return { ...i, status: 'aborted' as const, abortController: null }
        }),
      }
    case 'REMOVE':
      return { ...state, items: state.items.filter((i) => i.id !== action.id) }
    case 'CLEAR_DONE':
      return { ...state, items: state.items.filter((i) => i.status !== 'done') }
    case 'TOGGLE_MINIMISE':
      return { ...state, minimised: !state.minimised }
    default:
      return state
  }
}

// ─── Context ──────────────────────────────────────────────────────────────────

interface UploadManagerContextType {
  items: UploadItem[]
  minimised: boolean
  enqueueFiles: (tenantId: string, files: File[], parentId: string | null, drive?: StorageDrive | null) => void
  abortUpload: (id: string) => void
  removeUpload: (id: string) => void
  clearDone: () => void
  toggleMinimise: () => void
}

const UploadManagerContext = createContext<UploadManagerContextType | undefined>(undefined)

// ─── Provider ─────────────────────────────────────────────────────────────────

let nextId = 0
function uid() {
  return `upload-${++nextId}-${Date.now()}`
}

export function UploadManagerProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(reducer, initialState)
  const queryClient = useQueryClient()

  const enqueueFiles = useCallback(
    (tenantId: string, files: File[], parentId: string | null, drive?: StorageDrive | null) => {
      for (const file of files) {
        const id = uid()

        // ── Per-drive file size validation ──────────────────────────────────
        if (drive?.max_file_size_bytes && file.size > drive.max_file_size_bytes) {
          dispatch({
            type: 'ADD',
            item: { id, fileName: file.name, fileSize: file.size, status: 'error', progress: null, error: 'file_too_large', abortController: null },
          })
          continue
        }

        // ── Per-drive MIME type validation ──────────────────────────────────
        if (drive?.allowed_mime_types?.length) {
          const driveAllowed = new Set(drive.allowed_mime_types)
          const driveMimeError = validateMimeType(file, driveAllowed)
          if (driveMimeError) {
            dispatch({
              type: 'ADD',
              item: { id, fileName: file.name, fileSize: file.size, status: 'error', progress: null, error: driveMimeError, abortController: null },
            })
            continue
          }
        }

        // ── Global MIME validation ──────────────────────────────────────────
        const mimeError = validateMimeType(file)
        if (mimeError) {
          const errorItem: UploadItem = {
            id,
            fileName: file.name,
            fileSize: file.size,
            status: 'error',
            progress: null,
            error: mimeError,
            abortController: null,
          }
          dispatch({ type: 'ADD', item: errorItem })
          continue
        }
        // ───────────────────────────────────────────────────────────────────

        const controller = new AbortController()

        const item: UploadItem = {
          id,
          fileName: file.name,
          fileSize: file.size,
          status: 'queued',
          progress: null,
          error: null,
          abortController: controller,
        }

        dispatch({ type: 'ADD', item })

        // Fire-and-forget — each upload runs concurrently
        uploadFile({
          tenant_id: tenantId,
          file,
          parent_id: parentId,
          storage_provider_id: drive?.id ?? null,
          onProgress: (p) => dispatch({ type: 'PROGRESS', id, progress: p }),
          signal: controller.signal,
        })
          .then(() => {
            dispatch({ type: 'DONE', id })
            queryClient.invalidateQueries({ queryKey: storageKeys.nodes() })
            queryClient.invalidateQueries({ queryKey: storageKeys.usage() })
          })
          .catch((err) => {
            if (err?.code === 'upload_aborted') {
              dispatch({ type: 'ABORT', id })
            } else {
              dispatch({ type: 'ERROR', id, error: err?.message ?? 'Upload failed' })
            }
          })
      }
    },
    [queryClient],
  )

  const abortUpload = useCallback((id: string) => dispatch({ type: 'ABORT', id }), [])
  const removeUpload = useCallback((id: string) => dispatch({ type: 'REMOVE', id }), [])
  const clearDone = useCallback(() => dispatch({ type: 'CLEAR_DONE' }), [])
  const toggleMinimise = useCallback(() => dispatch({ type: 'TOGGLE_MINIMISE' }), [])

  const value = useMemo<UploadManagerContextType>(
    () => ({
      items: state.items,
      minimised: state.minimised,
      enqueueFiles,
      abortUpload,
      removeUpload,
      clearDone,
      toggleMinimise,
    }),
    [state.items, state.minimised, enqueueFiles, abortUpload, removeUpload, clearDone, toggleMinimise],
  )

  return <UploadManagerContext.Provider value={value}>{children}</UploadManagerContext.Provider>
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function useUploadManager() {
  const ctx = useContext(UploadManagerContext)
  if (!ctx) throw new Error('useUploadManager must be used within UploadManagerProvider')
  return ctx
}
