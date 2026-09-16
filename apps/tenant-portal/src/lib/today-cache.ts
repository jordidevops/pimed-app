import Dexie, { type Table } from 'dexie'
import type { ProjectListItem } from '@/features/projects/api/projectsService'

export interface TodayCacheRow {
  /** `${tenantId}:${yyyy-mm-dd}` */
  id: string
  tenant_id: string
  day: string
  items: ProjectListItem[]
  cached_at: string
}

export interface PendingPhotoRow {
  id: string
  tenant_id: string
  project_id: string
  project_name: string
  file_name: string
  mime_type: string
  blob: Blob
  created_at: string
  status: 'pending' | 'uploading' | 'failed'
  last_error?: string
}

export type PendingFieldMediaPurpose =
  | 'field_photo'
  | 'field_attachment'
  | 'checklist_evidence'
  | 'task_evidence'

export interface PendingFieldMediaRow {
  id: string
  tenant_id: string
  project_id: string
  project_name: string
  purpose: PendingFieldMediaPurpose
  entity_type?: string
  entity_id?: string
  file_name: string
  mime_type: string
  blob: Blob
  created_at: string
  status: 'pending' | 'uploading' | 'failed'
  last_error?: string
  retry_count?: number
}

export interface PendingChecklistAnswerRow {
  id: string
  tenant_id: string
  project_id: string
  item_id: string
  value_bool?: boolean | null
  value_option_id?: string | null
  value_number?: number | null
  value_text?: string | null
  note?: string | null
  created_at: string
  status: 'pending' | 'failed'
  last_error?: string
}

export interface FieldProjectSnapshot {
  /** `${tenantId}:${projectId}` */
  id: string
  tenant_id: string
  project_id: string
  project?: unknown
  lines?: unknown[]
  materials?: unknown[]
  work_logs?: unknown[]
  checklist_runs?: unknown[]
  closeout_blockers?: unknown[]
  cached_at: string
}

class FieldTodayDatabase extends Dexie {
  today_cache!: Table<TodayCacheRow, string>
  pending_photos!: Table<PendingPhotoRow, string>
  pending_checklist_answers!: Table<PendingChecklistAnswerRow, string>
  pending_field_media!: Table<PendingFieldMediaRow, string>
  project_snapshots!: Table<FieldProjectSnapshot, string>

  constructor() {
    super('field_today_v1')
    this.version(1).stores({
      today_cache: 'id, tenant_id, day',
      pending_photos: 'id, tenant_id, project_id, status, created_at',
    })
    this.version(2).stores({
      today_cache: 'id, tenant_id, day',
      pending_photos: 'id, tenant_id, project_id, status, created_at',
      pending_checklist_answers: 'id, tenant_id, project_id, item_id, status, created_at',
    })
    this.version(3)
      .stores({
        today_cache: 'id, tenant_id, day',
        pending_photos: 'id, tenant_id, project_id, status, created_at',
        pending_checklist_answers: 'id, tenant_id, project_id, item_id, status, created_at',
        pending_field_media: 'id, tenant_id, project_id, status, created_at, purpose',
      })
      .upgrade(async (tx) => {
        const legacy = await tx.table('pending_photos').toArray()
        for (const row of legacy as PendingPhotoRow[]) {
          await tx.table('pending_field_media').put({
            id: row.id,
            tenant_id: row.tenant_id,
            project_id: row.project_id,
            project_name: row.project_name,
            purpose: 'field_photo' as const,
            file_name: row.file_name,
            mime_type: row.mime_type,
            blob: row.blob,
            created_at: row.created_at,
            status: row.status === 'uploading' ? 'pending' : row.status,
            last_error: row.last_error,
            retry_count: 0,
          })
        }
        await tx.table('pending_photos').clear()
      })
    this.version(4).stores({
      today_cache: 'id, tenant_id, day',
      pending_photos: 'id, tenant_id, project_id, status, created_at',
      pending_checklist_answers: 'id, tenant_id, project_id, item_id, status, created_at',
      pending_field_media: 'id, tenant_id, project_id, status, created_at, purpose',
      project_snapshots: 'id, tenant_id, project_id, cached_at',
    })
  }
}

const db = new FieldTodayDatabase()

export async function patchFieldProjectSnapshot(
  tenantId: string,
  projectId: string,
  patch: Partial<
    Pick<
      FieldProjectSnapshot,
      | 'project'
      | 'lines'
      | 'materials'
      | 'work_logs'
      | 'checklist_runs'
      | 'closeout_blockers'
    >
  >,
): Promise<void> {
  const id = `${tenantId}:${projectId}`
  await db.transaction('rw', db.project_snapshots, async () => {
    const existing = await db.project_snapshots.get(id)
    await db.project_snapshots.put({
      id,
      tenant_id: tenantId,
      project_id: projectId,
      ...existing,
      ...patch,
      cached_at: new Date().toISOString(),
    })
  })
}

export async function getFieldProjectSnapshot(
  tenantId: string,
  projectId: string,
): Promise<FieldProjectSnapshot | null> {
  return (await db.project_snapshots.get(`${tenantId}:${projectId}`)) ?? null
}

export async function purgeOldFieldProjectSnapshots(
  tenantId: string,
  olderThanIso: string,
): Promise<number> {
  const rows = await db.project_snapshots
    .where('tenant_id')
    .equals(tenantId)
    .filter((row) => row.cached_at < olderThanIso)
    .toArray()
  if (rows.length > 0) {
    await db.project_snapshots.bulkDelete(rows.map((row) => row.id))
  }
  return rows.length
}

export async function saveTodayCache(
  tenantId: string,
  day: string,
  items: ProjectListItem[],
): Promise<void> {
  await db.today_cache.put({
    id: `${tenantId}:${day}`,
    tenant_id: tenantId,
    day,
    items,
    cached_at: new Date().toISOString(),
  })
}

export async function loadTodayCache(
  tenantId: string,
  day: string,
): Promise<TodayCacheRow | undefined> {
  return db.today_cache.get(`${tenantId}:${day}`)
}

/** @deprecated Prefer enqueuePendingFieldMedia */
export async function enqueuePendingPhoto(
  row: Omit<PendingPhotoRow, 'status'>,
): Promise<void> {
  await enqueuePendingFieldMedia({
    ...row,
    purpose: 'field_photo',
  })
}

/** @deprecated Prefer listPendingFieldMedia */
export async function listPendingPhotos(tenantId: string): Promise<PendingPhotoRow[]> {
  const rows = await listPendingFieldMedia(tenantId)
  return rows
    .filter((r) => r.purpose === 'field_photo')
    .map((r) => ({
      id: r.id,
      tenant_id: r.tenant_id,
      project_id: r.project_id,
      project_name: r.project_name,
      file_name: r.file_name,
      mime_type: r.mime_type,
      blob: r.blob,
      created_at: r.created_at,
      status: r.status,
      last_error: r.last_error,
    }))
}

export async function countPendingPhotos(tenantId: string): Promise<number> {
  return countPendingFieldMedia(tenantId)
}

export async function removePendingPhoto(id: string): Promise<void> {
  await removePendingFieldMedia(id)
}

export async function markPhotoFailed(id: string, msg: string): Promise<void> {
  await markFieldMediaFailed(id, msg)
}

export async function enqueuePendingFieldMedia(
  row: Omit<PendingFieldMediaRow, 'status'>,
): Promise<void> {
  await db.pending_field_media.put({ ...row, status: 'pending', retry_count: row.retry_count ?? 0 })
}

export async function listPendingFieldMedia(tenantId: string): Promise<PendingFieldMediaRow[]> {
  return db.pending_field_media
    .where('tenant_id')
    .equals(tenantId)
    .filter((p) => p.status === 'pending' || p.status === 'failed')
    .sortBy('created_at')
}

export async function countPendingFieldMedia(tenantId: string): Promise<number> {
  return db.pending_field_media
    .where('tenant_id')
    .equals(tenantId)
    .filter((p) => p.status === 'pending' || p.status === 'failed')
    .count()
}

export async function countPendingFieldMediaForProject(
  tenantId: string,
  projectId: string,
): Promise<number> {
  return db.pending_field_media
    .where('tenant_id')
    .equals(tenantId)
    .filter(
      (p) =>
        p.project_id === projectId && (p.status === 'pending' || p.status === 'failed'),
    )
    .count()
}

export async function removePendingFieldMedia(id: string): Promise<void> {
  await db.pending_field_media.delete(id)
}

export async function markFieldMediaFailed(id: string, msg: string): Promise<void> {
  const row = await db.pending_field_media.get(id)
  const retries = (row?.retry_count ?? 0) + 1
  await db.pending_field_media.update(id, {
    status: 'failed',
    last_error: msg,
    retry_count: retries,
  })
}

export async function discardFailedFieldMedia(tenantId: string): Promise<number> {
  const failed = await db.pending_field_media
    .where('tenant_id')
    .equals(tenantId)
    .filter((p) => p.status === 'failed')
    .toArray()
  await Promise.all(failed.map((r) => db.pending_field_media.delete(r.id)))
  return failed.length
}

export async function resetFailedFieldMediaToPending(tenantId: string): Promise<void> {
  const failed = await db.pending_field_media
    .where('tenant_id')
    .equals(tenantId)
    .filter((p) => p.status === 'failed' && (p.retry_count ?? 0) < 5)
    .toArray()
  for (const r of failed) {
    await db.pending_field_media.update(r.id, { status: 'pending' })
  }
}

export async function enqueuePendingChecklistAnswer(
  row: Omit<PendingChecklistAnswerRow, 'status'>,
): Promise<void> {
  await db.pending_checklist_answers.put({ ...row, status: 'pending' })
}

export async function listPendingChecklistAnswers(
  tenantId: string,
  options?: { includeFailed?: boolean },
): Promise<PendingChecklistAnswerRow[]> {
  const includeFailed = options?.includeFailed ?? true
  return db.pending_checklist_answers
    .where('tenant_id')
    .equals(tenantId)
    .filter((r) => r.status === 'pending' || (includeFailed && r.status === 'failed'))
    .sortBy('created_at')
}

export async function countPendingChecklistAnswers(tenantId: string): Promise<number> {
  return db.pending_checklist_answers
    .where('tenant_id')
    .equals(tenantId)
    .filter((r) => r.status === 'pending' || r.status === 'failed')
    .count()
}

export async function removePendingChecklistAnswer(id: string): Promise<void> {
  await db.pending_checklist_answers.delete(id)
}

export async function markChecklistAnswerFailed(id: string, msg: string): Promise<void> {
  await db.pending_checklist_answers.update(id, { status: 'failed', last_error: msg })
}

export async function resetFailedChecklistAnswersToPending(tenantId: string): Promise<number> {
  const failed = await db.pending_checklist_answers
    .where('tenant_id')
    .equals(tenantId)
    .filter((r) => r.status === 'failed')
    .toArray()
  for (const row of failed) {
    await db.pending_checklist_answers.update(row.id, { status: 'pending', last_error: undefined })
  }
  return failed.length
}
