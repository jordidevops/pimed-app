import {
  listPendingFieldMedia,
  markFieldMediaFailed,
  removePendingFieldMedia,
  resetFailedFieldMediaToPending,
  type PendingFieldMediaRow,
} from '@/lib/today-cache'
import { uploadFieldMedia } from './fieldMediaService'

async function uploadOne(row: PendingFieldMediaRow): Promise<void> {
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
    // Already compressed at enqueue
    compressionPrefs: { enabled: false, level: 'balanced' },
  })
}

/** Drain Dexie field-media queue when back online. Returns remaining pending count. */
export async function drainPendingPhotos(tenantId: string): Promise<number> {
  await resetFailedFieldMediaToPending(tenantId)
  const pending = await listPendingFieldMedia(tenantId)
  for (const row of pending) {
    if ((row.retry_count ?? 0) >= 5) continue
    try {
      await uploadOne(row)
      await removePendingFieldMedia(row.id)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'upload_failed'
      await markFieldMediaFailed(row.id, msg)
    }
  }
  return (await listPendingFieldMedia(tenantId)).length
}

export { drainPendingFieldMedia } from './fieldMediaQueue'
