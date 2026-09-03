import type { NodeType } from '../types/storage.types'

// ─── Allowed MIME types ───────────────────────────────────────────────────────
//
// Mirrors the server-side allow-list enforced by the Edge Functions.
// Any file whose MIME type is not in this set is rejected client-side BEFORE
// the upload request is even made, saving a round-trip and a quota reservation.

export const ALLOWED_MIME_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'application/pdf',
  'text/plain',
  'text/csv',
  'application/json',
  'application/zip',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
])

/**
 * Build the `accept` string for an <input type="file">.
 * Example: "image/jpeg,image/png,application/pdf,..."
 */
export const ALLOWED_MIME_ACCEPT = [...ALLOWED_MIME_TYPES].join(',')

/**
 * Validates a single File against the allowed MIME type list.
 *
 * Early-exit strategy:
 *   1. If `file.type` (browser-detected MIME) is in the allow-list → OK.
 *   2. If `file.type` is empty (some older browsers/OS) → fall back to extension
 *      heuristics so users are not unfairly blocked.
 *   3. Otherwise → return the rejection reason so the caller can show a
 *      localised error without initiating any network request.
 *
 * Returns `null` when the file is valid, or an error code string when rejected.
 */
export function validateMimeType(file: File, allowedMimes?: Set<string>): 'mime_type_not_allowed' | 'mime_type_unknown' | null {
  const allowed = allowedMimes ?? ALLOWED_MIME_TYPES
  const mime = file.type

  // Non-empty MIME — check allow-list directly
  if (mime) {
    return allowed.has(mime) ? null : 'mime_type_not_allowed'
  }

  // Empty MIME — try extension-based fallback
  const ext = file.name.split('.').pop()?.toLowerCase() ?? ''
  const extMap: Record<string, string> = {
    jpg: 'image/jpeg', jpeg: 'image/jpeg',
    png: 'image/png',
    gif: 'image/gif',
    webp: 'image/webp',
    pdf: 'application/pdf',
    txt: 'text/plain',
    csv: 'text/csv',
    json: 'application/json',
    zip: 'application/zip',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  }

  if (ext in extMap) return null  // extension is in the known-good list
  return 'mime_type_unknown'
}



const UNITS = ['B', 'KB', 'MB', 'GB', 'TB'] as const

export function formatBytes(bytes: number | null | undefined): string {
  if (bytes == null || bytes === 0) return '—'
  let i = 0
  let b = bytes
  while (b >= 1024 && i < UNITS.length - 1) {
    b /= 1024
    i++
  }
  return `${b.toFixed(i === 0 ? 0 : 1)} ${UNITS[i]}`
}

// ─── Date formatting ──────────────────────────────────────────────────────────

export function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString('ca-ES', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  })
}

export function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString('ca-ES', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

// ─── MIME → emoji/icon mapping ────────────────────────────────────────────────

export function getFileEmoji(mimeType: string | null, nodeType: NodeType): string {
  if (nodeType === 'folder') return '📁'
  if (!mimeType) return '📄'
  if (mimeType.startsWith('image/')) return '🖼️'
  if (mimeType.startsWith('video/')) return '🎬'
  if (mimeType.startsWith('audio/')) return '🎵'
  if (mimeType === 'application/pdf') return '📕'
  if (mimeType.includes('spreadsheet') || mimeType.includes('excel')) return '📊'
  if (mimeType.includes('presentation') || mimeType.includes('powerpoint')) return '📽️'
  if (mimeType.includes('document') || mimeType.includes('word')) return '📝'
  if (mimeType.includes('zip') || mimeType.includes('compressed') || mimeType.includes('archive')) return '🗜️'
  if (mimeType.startsWith('text/')) return '📄'
  return '📄'
}

// ─── Previewable check ────────────────────────────────────────────────────────

export function isPreviewable(mimeType: string | null): boolean {
  if (!mimeType) return false
  return (
    mimeType.startsWith('image/') ||
    mimeType === 'application/pdf' ||
    mimeType.startsWith('text/')
  )
}

// ─── Debounce hook helper ─────────────────────────────────────────────────────

import { useEffect, useState } from 'react'

export function useDebounce<T>(value: T, delay: number): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delay)
    return () => clearTimeout(timer)
  }, [value, delay])
  return debounced
}
