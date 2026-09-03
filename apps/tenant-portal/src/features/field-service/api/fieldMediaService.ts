/**
 * fieldMediaService — OS media on Fitxers (tenant-files / file_nodes).
 * Photos, attachments, and checklist/task evidence share this path.
 */

import { supabase } from '@/lib/supabase'
import {
  getFileUrl,
  trashNode,
  uploadFile,
  type UploadProgress,
} from '@/features/storage/api/storageService'
import {
  prepareFieldImage,
  resolveFieldMediaCompression,
  type FieldMediaCompressionPrefs,
} from './fieldMediaCompression'

export type FieldMediaPurpose =
  | 'field_photo'
  | 'field_attachment'
  | 'checklist_evidence'
  | 'task_evidence'

export interface FieldProjectFolders {
  site_folder_id: string
  project_folder_id: string
  photos_id: string
  attachments_id: string
  evidence_id: string
}

export interface FieldMediaNode {
  id: string
  tenant_id: string
  name: string
  mime_type: string | null
  size_bytes: number | null
  storage_key: string | null
  entity_type: string | null
  entity_id: string | null
  metadata: Record<string, unknown> | null
  created_at: string
  parent_id: string | null
}

export interface UploadFieldMediaParams {
  tenantId: string
  projectId: string
  file: File
  purpose: FieldMediaPurpose
  /** For evidence: checklist_run_item or task id */
  entityType?: string
  entityId?: string
  displayName?: string
  onProgress?: (p: UploadProgress) => void
  signal?: AbortSignal
  /** Skip network resolve when caller already has prefs (e.g. offline prepare). */
  compressionPrefs?: FieldMediaCompressionPrefs
}

function folderIdForPurpose(
  folders: FieldProjectFolders,
  purpose: FieldMediaPurpose,
): string {
  if (purpose === 'field_attachment') return folders.attachments_id
  if (purpose === 'checklist_evidence' || purpose === 'task_evidence') {
    return folders.evidence_id
  }
  return folders.photos_id
}

export async function ensureFieldProjectFolders(
  projectId: string,
): Promise<FieldProjectFolders> {
  const { data, error } = await supabase.rpc('ensure_field_project_folders', {
    p_project_id: projectId,
  })
  if (error) throw error
  const row = data as Record<string, unknown>
  return {
    site_folder_id: String(row.site_folder_id),
    project_folder_id: String(row.project_folder_id),
    photos_id: String(row.photos_id),
    attachments_id: String(row.attachments_id),
    evidence_id: String(row.evidence_id),
  }
}

async function attachEntity(
  nodeId: string,
  entityType: string,
  entityId: string,
  metadata: Record<string, unknown>,
): Promise<void> {
  const { error } = await supabase.rpc('attach_file_node_entity', {
    p_node_id: nodeId,
    p_entity_type: entityType,
    p_entity_id: entityId,
    p_metadata: metadata,
  })
  if (error) throw error
}

function lightFileName(originalName: string): string {
  const dot = originalName.lastIndexOf('.')
  if (dot <= 0) return `light_${originalName}.jpg`
  return `${originalName.slice(0, dot)}_light${originalName.slice(dot)}`
}

/** Avoid duplicate_name collisions (camera often reuses filenames). */
function uniqueFieldFileName(name: string): string {
  const stamp = Date.now().toString(36)
  const rand = Math.random().toString(36).slice(2, 6)
  const dot = name.lastIndexOf('.')
  if (dot <= 0) return `${name}_${stamp}${rand}`
  return `${name.slice(0, dot)}_${stamp}${rand}${name.slice(dot)}`
}

function withUniqueName(file: File): File {
  const next = uniqueFieldFileName(file.name)
  if (next === file.name) return file
  return new File([file], next, { type: file.type || 'application/octet-stream' })
}

/**
 * Upload one field-media file to Fitxers (optional light sibling when keeping original).
 */
export async function uploadFieldMedia(
  params: UploadFieldMediaParams,
): Promise<{ nodeId: string; lightNodeId: string | null }> {
  const {
    tenantId,
    projectId,
    file: rawFile,
    purpose,
    displayName,
    onProgress,
    signal,
  } = params

  const prefs = params.compressionPrefs ?? (await resolveFieldMediaCompression(tenantId))
  const prepared =
    purpose === 'field_attachment'
      ? { primary: withUniqueName(rawFile), light: null as File | null, keptOriginal: false }
      : await prepareFieldImage(rawFile, prefs).then((p) => ({
          ...p,
          primary: withUniqueName(p.primary),
          light: p.light ? withUniqueName(p.light) : null,
        }))

  const folders = await ensureFieldProjectFolders(projectId)
  const parentId = folderIdForPurpose(folders, purpose)
  const entityType = params.entityType ?? 'project'
  const entityId = params.entityId ?? projectId
  const name = displayName ? uniqueFieldFileName(displayName) : prepared.primary.name
  const primaryFile =
    prepared.primary.name === name
      ? prepared.primary
      : new File([prepared.primary], name, {
          type: prepared.primary.type || 'application/octet-stream',
        })

  const baseMeta: Record<string, unknown> = {
    kind: purpose,
    purpose,
    project_id: projectId,
    kept_original: prepared.keptOriginal,
    original_name: rawFile.name,
  }

  const primary = await uploadFile({
    tenant_id: tenantId,
    file: primaryFile,
    parent_id: parentId,
    metadata: baseMeta,
    onProgress,
    signal,
  })

  await attachEntity(primary.node_id, entityType, entityId, baseMeta)

  let lightNodeId: string | null = null
  if (prepared.light) {
    const lightMeta: Record<string, unknown> = {
      ...baseMeta,
      variant: 'light',
      original_node_id: primary.node_id,
    }
    const light = await uploadFile({
      tenant_id: tenantId,
      file: new File([prepared.light], lightFileName(name), {
        type: prepared.light.type || 'image/jpeg',
      }),
      parent_id: parentId,
      metadata: lightMeta,
      signal,
    })
    await attachEntity(light.node_id, entityType, entityId, lightMeta)
    lightNodeId = light.node_id

    await attachEntity(primary.node_id, entityType, entityId, {
      ...baseMeta,
      light_node_id: light.node_id,
    })
  }

  return { nodeId: primary.node_id, lightNodeId }
}

/** List primary (non-light) media for an entity. */
export async function listFieldMedia(params: {
  tenantId: string
  entityType: string
  entityId: string
  purpose?: FieldMediaPurpose | FieldMediaPurpose[]
}): Promise<FieldMediaNode[]> {
  let query = supabase
    .from('file_nodes')
    .select(
      'id, tenant_id, name, mime_type, size_bytes, storage_key, entity_type, entity_id, metadata, created_at, parent_id',
    )
    .eq('tenant_id', params.tenantId)
    .eq('entity_type', params.entityType)
    .eq('entity_id', params.entityId)
    .eq('node_type', 'file')
    .neq('processing_status', 'pending')
    .order('created_at', { ascending: false })

  const { data, error } = await query
  if (error) throw error

  const purposes = params.purpose
    ? Array.isArray(params.purpose)
      ? params.purpose
      : [params.purpose]
    : null

  return ((data ?? []) as unknown as FieldMediaNode[]).filter((n) => {
    const meta = n.metadata ?? {}
    if (meta.variant === 'light') return false
    if (!purposes) return true
    const p = String(meta.purpose ?? meta.kind ?? '')
    return purposes.includes(p as FieldMediaPurpose)
  })
}

/** Project gallery photos (entity project + purpose field_photo). */
export async function listProjectPhotos(
  tenantId: string,
  projectId: string,
): Promise<FieldMediaNode[]> {
  return listFieldMedia({
    tenantId,
    entityType: 'project',
    entityId: projectId,
    purpose: 'field_photo',
  })
}

export async function listProjectAttachments(
  tenantId: string,
  projectId: string,
): Promise<FieldMediaNode[]> {
  return listFieldMedia({
    tenantId,
    entityType: 'project',
    entityId: projectId,
    purpose: 'field_attachment',
  })
}

/**
 * Evidence attached to checklist run items / tasks for a project
 * (metadata.project_id + purpose checklist_evidence | task_evidence).
 */
export async function listProjectEvidenceMedia(
  tenantId: string,
  projectId: string,
): Promise<FieldMediaNode[]> {
  const { data, error } = await supabase
    .from('file_nodes')
    .select(
      'id, tenant_id, name, mime_type, size_bytes, storage_key, entity_type, entity_id, metadata, created_at, parent_id',
    )
    .eq('tenant_id', tenantId)
    .eq('node_type', 'file')
    .in('entity_type', ['checklist_run_item', 'task'])
    .neq('processing_status', 'pending')
    .order('created_at', { ascending: false })
    .limit(500)

  if (error) throw error

  return ((data ?? []) as unknown as FieldMediaNode[]).filter((n) => {
    const meta = n.metadata ?? {}
    if (meta.variant === 'light') return false
    if (String(meta.project_id ?? '') !== projectId) return false
    const p = String(meta.purpose ?? meta.kind ?? '')
    return p === 'checklist_evidence' || p === 'task_evidence'
  })
}

/** Photos + attachments + evidence for bulletin media picker. */
export async function listProjectBulletinMedia(
  tenantId: string,
  projectId: string,
): Promise<FieldMediaNode[]> {
  const [photos, attachments, evidence] = await Promise.all([
    listProjectPhotos(tenantId, projectId),
    listProjectAttachments(tenantId, projectId),
    listProjectEvidenceMedia(tenantId, projectId),
  ])
  const byId = new Map<string, FieldMediaNode>()
  for (const n of [...photos, ...attachments, ...evidence]) byId.set(n.id, n)
  return Array.from(byId.values())
}

/** Evidence node ids tied to included checklist items / tasks. */
export function evidenceNodeIdsForSelection(
  nodes: FieldMediaNode[],
  params: {
    showChecklists: boolean
    showTasks: boolean
    checklistItemIds: string[]
    taskIds: string[]
  },
): string[] {
  const checklistSet = new Set(params.checklistItemIds)
  const taskSet = new Set(params.taskIds)
  const out: string[] = []
  for (const n of nodes) {
    const meta = n.metadata ?? {}
    const purpose = String(meta.purpose ?? meta.kind ?? '')
    const entityId = String(n.entity_id ?? '')
    if (params.showChecklists && purpose === 'checklist_evidence' && checklistSet.has(entityId)) {
      out.push(n.id)
    }
    if (params.showTasks && purpose === 'task_evidence' && taskSet.has(entityId)) {
      out.push(n.id)
    }
  }
  return out
}

/**
 * Merge auto evidence into current selection, respecting explicit exclusions.
 */
export function mergeAutoEvidenceMediaIds(params: {
  currentIds: string[]
  evidenceIds: string[]
  excludedIds: string[]
}): string[] {
  const excluded = new Set(params.excludedIds)
  const set = new Set(params.currentIds.filter((id) => !excluded.has(id)))
  for (const id of params.evidenceIds) {
    if (!excluded.has(id)) set.add(id)
  }
  return Array.from(set)
}

/** Prefer light sibling URL for gallery/bulletin when available. */
export async function getFieldMediaDisplayUrl(
  tenantId: string,
  node: FieldMediaNode,
  expirySeconds = 3600,
): Promise<string | null> {
  const lightId = node.metadata?.light_node_id
  const targetId =
    typeof lightId === 'string' && lightId.length > 0 ? lightId : node.id
  try {
    const { url } = await getFileUrl(targetId, expirySeconds, tenantId, false)
    return url
  } catch {
    if (targetId !== node.id) {
      try {
        const { url } = await getFileUrl(node.id, expirySeconds, tenantId, false)
        return url
      } catch {
        return null
      }
    }
    return null
  }
}

export async function trashFieldMedia(nodeId: string): Promise<void> {
  // Also trash light sibling if present
  const { data } = await supabase
    .from('file_nodes')
    .select('id, metadata')
    .eq('id', nodeId)
    .maybeSingle()
  const meta = (data?.metadata ?? {}) as Record<string, unknown>
  const lightId = typeof meta.light_node_id === 'string' ? meta.light_node_id : null
  await trashNode(nodeId)
  if (lightId) {
    try {
      await trashNode(lightId)
    } catch {
      /* ignore */
    }
  }
}

export async function countFieldProjectFiles(projectId: string): Promise<number> {
  const { data, error } = await supabase.rpc('count_field_project_files', {
    p_project_id: projectId,
  })
  if (error) throw error
  return Number(data ?? 0)
}

export async function trashFieldProjectFiles(projectId: string): Promise<number> {
  const { data, error } = await supabase.rpc('trash_field_project_files', {
    p_project_id: projectId,
  })
  if (error) throw error
  try {
    await supabase.rpc('trash_field_project_orphan_files', {
      p_project_id: projectId,
    })
  } catch {
    /* optional */
  }
  return Number(data ?? 0)
}

export const fieldMediaKeys = {
  all: (tenantId: string) => ['field_media', tenantId] as const,
  entity: (tenantId: string, entityType: string, entityId: string) =>
    ['field_media', tenantId, entityType, entityId] as const,
  photos: (tenantId: string, projectId: string) =>
    ['field_media', tenantId, 'photos', projectId] as const,
  attachments: (tenantId: string, projectId: string) =>
    ['field_media', tenantId, 'attachments', projectId] as const,
}
