import { useCallback, useRef, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { uploadFile } from './storageService'
import type { UploadFileResult, UploadProgress } from '../types/storage.types'

/**
 * Upload params accepted by the hook's mutate() call.
 * onProgress and signal are managed internally — callers don't pass them.
 */
export interface UseUploadFileParams {
  tenant_id: string
  file: File
  parent_id?: string | null
  metadata?: Record<string, unknown> | null
}

/**
 * Orchestrates the complete 3-step upload lifecycle:
 *   1. requestUpload  → reserve node + get pre-signed URL
 *   2. PUT binary     → upload file bytes with live progress (via XHR)
 *   3. confirmUpload  → verify object + mark node as 'done'
 *
 * Returns the standard useMutation result plus:
 *   • `progress` — live UploadProgress while upload is in flight (null otherwise)
 *   • `abort`    — function to cancel the upload at any stage
 *
 * @example
 * const { mutate: upload, progress, abort, isPending } = useUploadFile()
 *
 * // In a file picker handler:
 * upload({ tenant_id, file, parent_id })
 *
 * // Cancel button:
 * <button onClick={abort} disabled={!isPending}>Cancel</button>
 *
 * // Progress bar:
 * {progress && <ProgressBar value={progress.percent} stage={progress.stage} />}
 */
export function useUploadFile() {
  const queryClient = useQueryClient()
  const [progress, setProgress] = useState<UploadProgress | null>(null)
  const abortRef = useRef<AbortController | null>(null)

  const mutation = useMutation<UploadFileResult, Error, UseUploadFileParams>({
    mutationFn: ({ tenant_id, file, parent_id, metadata }) => {
      const controller = new AbortController()
      abortRef.current = controller

      return uploadFile({
        tenant_id,
        file,
        parent_id,
        metadata,
        onProgress: setProgress,
        signal: controller.signal,
      })
    },

    onSuccess: () => {
      // Invalidate both the file list (new node is now 'done') and the quota
      queryClient.invalidateQueries({ queryKey: storageKeys.nodes() })
      queryClient.invalidateQueries({ queryKey: storageKeys.usage() })
    },

    onSettled: () => {
      setProgress(null)
      abortRef.current = null
    },
  })

  /** Cancels the in-flight upload at any stage. Safe to call repeatedly. */
  const abort = useCallback(() => {
    abortRef.current?.abort()
  }, [])

  return { ...mutation, progress, abort }
}
