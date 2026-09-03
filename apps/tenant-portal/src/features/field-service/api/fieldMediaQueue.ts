/**
 * Field media offline queue + upload mode (direct | queue).
 * Compresses before enqueue to limit device disk usage.
 */

import {
  countPendingFieldMedia,
  countPendingFieldMediaForProject,
  enqueuePendingFieldMedia,
  listPendingFieldMedia,
  markFieldMediaFailed,
  removePendingFieldMedia,
  type PendingFieldMediaRow,
} from '@/lib/today-cache'
import {
  prepareFieldImage,
  resolveFieldMediaCompression,
} from './fieldMediaCompression'
import {
  uploadFieldMedia,
  type FieldMediaPurpose,
} from './fieldMediaService'

export type FieldMediaUploadMode = 'direct' | 'queue'

const MODE_KEY = 'field_media_upload_mode'
const LOCAL_QUOTA_BYTES = 80 * 1024 * 1024 // ~80 MB device soft cap
const LOCAL_MAX_ITEMS = 80

export function getFieldMediaUploadMode(
  tenantDefault?: FieldMediaUploadMode | null,
): FieldMediaUploadMode {
  try {
    const raw = localStorage.getItem(MODE_KEY)
    if (raw === 'direct' || raw === 'queue') return raw
  } catch {
    /* ignore */
  }
  return tenantDefault === 'queue' ? 'queue' : 'direct'
}

export function setFieldMediaUploadMode(mode: FieldMediaUploadMode): void {
  try {
    localStorage.setItem(MODE_KEY, mode)
  } catch {
    /* ignore */
  }
}

async function estimateQueueBytes(tenantId: string): Promise<number> {
  const rows = await listPendingFieldMedia(tenantId)
  let total = 0
  for (const r of rows) total += r.blob.size
  return total
}

export async function enqueueFieldMediaOrUpload(params: {
  tenantId: string
  projectId: string
  projectName: string
  file: File
  purpose: FieldMediaPurpose
  entityType?: string
  entityId?: string
  isOnline: boolean
  tenantDefaultMode?: FieldMediaUploadMode | null
}): Promise<'uploaded' | 'queued'> {
  const mode = getFieldMediaUploadMode(params.tenantDefaultMode)
  const shouldQueue = mode === 'queue' || !params.isOnline

  if (!shouldQueue && params.isOnline) {
    try {
      await uploadFieldMedia({
        tenantId: params.tenantId,
        projectId: params.projectId,
        file: params.file,
        purpose: params.purpose,
        entityType: params.entityType,
        entityId: params.entityId,
      })
      return 'uploaded'
    } catch (err) {
      const msg = err instanceof Error ? err.message.toLowerCase() : ''
      if (!msg.includes('network') && !msg.includes('fetch') && params.isOnline) {
        throw err
      }
    }
  }

  const prefs = await resolveFieldMediaCompression(params.tenantId)
  const prepared =
    params.purpose === 'field_attachment'
      ? { primary: params.file, light: null, keptOriginal: false }
      : await prepareFieldImage(params.file, prefs)

  const pendingCount = await countPendingFieldMedia(params.tenantId)
  if (pendingCount >= LOCAL_MAX_ITEMS) {
    throw new Error('local_queue_full')
  }
  const used = await estimateQueueBytes(params.tenantId)
  if (used + prepared.primary.size > LOCAL_QUOTA_BYTES) {
    throw new Error('local_queue_quota')
  }

  await enqueuePendingFieldMedia({
    id: crypto.randomUUID(),
    tenant_id: params.tenantId,
    project_id: params.projectId,
    project_name: params.projectName,
    purpose: params.purpose,
    entity_type: params.entityType,
    entity_id: params.entityId,
    file_name: prepared.primary.name,
    mime_type: prepared.primary.type || 'application/octet-stream',
    blob: prepared.primary,
    created_at: new Date().toISOString(),
  })
  return 'queued'
}

export async function drainPendingFieldMedia(tenantId: string): Promise<number> {
  const pending = await listPendingFieldMedia(tenantId)
  for (const row of pending) {
    try {
      await uploadOneQueued(row)
      await removePendingFieldMedia(row.id)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'upload_failed'
      await markFieldMediaFailed(row.id, msg)
    }
  }
  return (await listPendingFieldMedia(tenantId)).length
}

async function uploadOneQueued(row: PendingFieldMediaRow): Promise<void> {
  const file = new File([row.blob], row.file_name, {
    type: row.mime_type || 'application/octet-stream',
  })
  await uploadFieldMedia({
    tenantId: row.tenant_id,
    projectId: row.project_id,
    file,
    purpose: row.purpose,
    entityType: row.entity_type,
    entityId: row.entity_id,
    // Already compressed at enqueue time
    compressionPrefs: { enabled: false, level: 'balanced' },
  })
}

export async function countPendingMediaForProject(
  tenantId: string,
  projectId: string,
): Promise<number> {
  return countPendingFieldMediaForProject(tenantId, projectId)
}

export { countPendingFieldMedia, listPendingFieldMedia }
