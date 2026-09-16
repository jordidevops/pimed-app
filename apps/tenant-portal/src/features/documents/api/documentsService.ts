import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

// ─── Types ─────────────────────────────────────────────────────────────────

export type Folder = Database['api']['Views']['document_folders']['Row']
export type ActiveDocument = Database['api']['Views']['active_documents']['Row']
export type ArchivedDocument = Database['api']['Views']['archived_documents']['Row']
export type DocumentVersion = Database['api']['Views']['document_versions']['Row']

// ─── Edge Function call helper ────────────────────────────────────────────

const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1`

function getErrorMessage(status: number, json: any): string {
  return json?.error?.message ?? json?.message ?? `HTTP ${status}`
}

async function getAccessTokenOrThrow(): Promise<string> {
  const {
    data: { session },
  } = await supabase.auth.getSession()

  if (session?.access_token) return session.access_token

  const { data, error } = await supabase.auth.refreshSession()
  if (error || !data.session?.access_token) {
    throw new Error('Sessio expirada. Torna a iniciar sessio.')
  }
  return data.session.access_token
}

async function postEdgeFunction(
  name: string,
  body: Record<string, unknown>,
  token: string,
  tenantId?: string,
): Promise<Response> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${token}`,
  }
  if (tenantId) headers['x-tenant-id'] = tenantId

  return fetch(`${FUNCTIONS_BASE}/${name}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  })
}

async function callEdgeFunction<T>(
  name: string,
  body: Record<string, unknown>,
  tenantId?: string,
): Promise<T> {
  let token = await getAccessTokenOrThrow()
  let res = await postEdgeFunction(name, body, token, tenantId)
  let json = await res.json().catch(() => null)

  // Despres d'un db reset local, la sessio guardada pot quedar invalida.
  // Intentem refrescar i reintentar una vegada abans de fallar.
  if (res.status === 401) {
    const { data, error } = await supabase.auth.refreshSession()
    if (!error && data.session?.access_token) {
      token = data.session.access_token
      res = await postEdgeFunction(name, body, token, tenantId)
      json = await res.json().catch(() => null)
    }
  }

  if (!res.ok) {
    if (res.status === 401) {
      await supabase.auth.signOut()
      throw new Error('Sessio invalida o expirada. Torna a iniciar sessio.')
    }
    throw new Error(getErrorMessage(res.status, json))
  }

  return json as T
}

// ─── Folders ──────────────────────────────────────────────────────────────

export type FolderScopeMode = 'global' | 'embedded'

export interface GetFoldersOptions {
  /**
   * 'global'   → root de /documents: carpetes sense scope d'entitat (entity_type IS NULL)
   * 'embedded' → context de mòdul: carpetes shared del mòdul + específiques del registre
   */
  scopeMode?: FolderScopeMode
  /** Tipus d'entitat del mòdul (ex: 'employee'). Requerit quan scopeMode='embedded'. */
  entityType?: string | null
  /** ID del registre concret. Null = mostra totes les shared del mòdul. */
  entityId?: string | null
  /** Filtre per site: mostra carpetes del site + globals (site_id IS NULL). Null = sense filtre. */
  siteId?: string | null
}

export async function getFolders(
  tenantId: string,
  parentId?: string | null,
  opts: GetFoldersOptions = {},
): Promise<Folder[]> {
  const { scopeMode = 'global', entityType, entityId, siteId } = opts

  let query = supabase
    .from('document_folders')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('name', { ascending: true })

  if (parentId) {
    // Navegació dins una carpeta: filtre simple per parent (scope heretat)
    query = query.eq('parent_id', parentId)
  } else {
    // Root: aplica filtre de scope
    query = query.is('parent_id', null)
    if (scopeMode === 'global') {
      // /documents: carpetes globals + arrels de client (PDF comercials)
      query = query.or('entity_type.is.null,entity_type.eq.contact')
    } else if (scopeMode === 'embedded' && entityType) {
      // Mòdul embedded: carpetes shared del mòdul (entity_id IS NULL) +
      // carpetes específiques d'aquest registre (entity_id = entityId)
      if (entityId) {
        query = query
          .eq('entity_type', entityType)
          .or(`entity_id.is.null,entity_id.eq.${entityId}`)
      } else {
        // Sense entityId concret: només carpetes shared del mòdul
        query = query.eq('entity_type', entityType).is('entity_id', null)
      }
    }
  }

  if (siteId) {
    query = query.or(`site_id.eq.${siteId},site_id.is.null`)
  }

  const { data, error } = await query
  if (error) throw error
  return data ?? []
}

export interface CreateFolderParams {
  tenant_id: string
  name: string
  parent_id?: string | null
  site_id?: string | null
  entity_type?: string | null
  entity_id?: string | null
}

/** Walk parent_id up to the tenant root. Commercial trees are two levels. */
export async function getFolderPath(folderId: string): Promise<Folder[]> {
  const path: Folder[] = []
  let currentId: string | null = folderId
  for (let i = 0; i < 8 && currentId; i++) {
    const { data, error } = await supabase
      .from('document_folders')
      .select('*')
      .eq('id', currentId)
      .maybeSingle()
    if (error) throw error
    if (!data) break
    path.unshift(data)
    currentId = data.parent_id
  }
  return path
}

export async function createFolder(params: CreateFolderParams): Promise<Folder> {
  const { data, error } = await supabase
    .from('document_folders')
    .insert(params)
    .select()
    .single()
  if (error) throw error
  return data
}

export interface UpdateFolderParams {
  name?: string
}

export async function updateFolder(id: string, params: UpdateFolderParams): Promise<Folder> {
  const { data, error } = await supabase
    .from('document_folders')
    .update(params)
    .eq('id', id)
    .select()
    .single()
  if (error) throw error
  return data
}

export async function deleteFolder(id: string): Promise<void> {
  const { error } = await supabase.from('document_folders').delete().eq('id', id)
  if (error) throw error
}

// ─── Documents (active_documents view) ───────────────────────────────────

export interface GetDocumentsFilters {
  tenantId: string
  folderId?: string | null
  entityType?: string | null
  entityId?: string | null
  /** Filtre per site: mostra docs del site + globals (site_id IS NULL). Null = sense filtre. */
  siteId?: string | null
  /** true = ometre el filtre de carpeta (per la vista per categories) */
  allFolders?: boolean
  /** Filtre per categoria específica (null = docs sense categoria) */
  category?: string | null
}

export async function getActiveDocuments(filters: GetDocumentsFilters): Promise<ActiveDocument[]> {
  let query = supabase
    .from('active_documents')
    .select('*')
    .eq('tenant_id', filters.tenantId)
    .order('title', { ascending: true })

  if (!filters.allFolders) {
    if (filters.folderId) {
      query = query.eq('folder_id', filters.folderId)
    } else if (!filters.entityType) {
      // Explorer mode at root: only show root-level documents (no folder)
      query = query.is('folder_id', null)
    }
  }
  if (filters.entityType) {
    query = query.eq('entity_type', filters.entityType)
  }
  if (filters.entityId) {
    query = query.eq('entity_id', filters.entityId)
  }
  if (filters.siteId) {
    query = query.or(`site_id.eq.${filters.siteId},site_id.is.null`)
  }

  const { data, error } = await query
  if (error) throw error
  return data ?? []
}

export interface CreateDocumentWithVersionParams {
  tenant_id: string
  title: string
  storage_type: 'native' | 'external_link'
  file_path_or_url: string
  folder_id?: string | null
  site_id?: string | null
  entity_type?: string | null
  entity_id?: string | null
  mime_type?: string | null
  size_bytes?: number | null
  // Expiry + renewal (Phase 2)
  valid_from?: string | null
  expires_at?: string | null
  renewal_interval_months?: number | null
  renewal_anchor_mode?: 'rolling' | 'natural' | null
  renewal_anchor_month?: number | null
  renewal_anchor_day?: number | null
  category?: string | null
}

export async function createDocumentWithVersion(
  params: CreateDocumentWithVersionParams,
): Promise<{ document_id: string; version_id: string }> {
  const { data, error } = await supabase.rpc('create_document_with_version', {
    p_tenant_id: params.tenant_id,
    p_title: params.title,
    p_storage_type: params.storage_type,
    p_file_path_or_url: params.file_path_or_url,
    p_folder_id: params.folder_id ?? undefined,
    p_site_id: params.site_id ?? undefined,
    p_entity_type: params.entity_type ?? undefined,
    p_entity_id: params.entity_id ?? undefined,
    p_mime_type: params.mime_type ?? undefined,
    p_size_bytes: params.size_bytes ?? 0,
    p_valid_from: params.valid_from ?? undefined,
    p_expires_at: params.expires_at ?? undefined,
    p_renewal_interval_months: params.renewal_interval_months ?? undefined,
    p_renewal_anchor_mode: params.renewal_anchor_mode ?? undefined,
    p_renewal_anchor_month: params.renewal_anchor_month ?? undefined,
    p_renewal_anchor_day: params.renewal_anchor_day ?? undefined,
    p_category: params.category ?? undefined,
  })
  if (error) throw error
  return data as { document_id: string; version_id: string }
}

export async function updateDocument(
  documentId: string,
  params: { category?: string | null; folder_id?: string | null; title?: string },
): Promise<void> {
  const { error } = await (supabase.from('documents') as any)
    .update(params)
    .eq('id', documentId)
  if (error) throw error
}

export interface AddDocumentVersionParams {
  document_id: string
  storage_type: 'native' | 'external_link'
  file_path_or_url: string
  mime_type?: string | null
  size_bytes?: number | null
}

export async function addDocumentVersion(
  params: AddDocumentVersionParams,
): Promise<{ id: string; version_number: number }> {
  const { data, error } = await supabase.rpc('add_document_version', {
    p_document_id: params.document_id,
    p_storage_type: params.storage_type,
    p_file_path_or_url: params.file_path_or_url,
    p_mime_type: params.mime_type ?? undefined,
    p_size_bytes: params.size_bytes ?? 0,
  })
  if (error) throw error
  return data as { id: string; version_number: number }
}

// ─── Edge Functions ───────────────────────────────────────────────────────

export interface RequestUploadResult {
  upload_url: string
  method: 'PUT'
  path: string
}

export async function requestDocumentUpload(
  tenantId: string,
  filename: string,
  sizeBytes: number,
  mimeType?: string,
): Promise<RequestUploadResult> {
  return callEdgeFunction<RequestUploadResult>(
    'request-document-upload',
    { tenant_id: tenantId, filename, size_bytes: sizeBytes, mime_type: mimeType },
    tenantId,
  )
}

export interface GetDocumentUrlResult {
  url: string
  storage_type: string
}

export async function getDocumentUrl(
  versionId: string,
  expirySeconds = 3600,
): Promise<GetDocumentUrlResult> {
  return callEdgeFunction<GetDocumentUrlResult>(
    'get-document-url',
    { version_id: versionId, expiry_seconds: expirySeconds },
  )
}

export interface GetDocumentAuditTrailUrlResult {
  url: string
}

export async function getDocumentAuditTrailUrl(
  storagePath: string,
  expirySeconds = 3600,
): Promise<GetDocumentAuditTrailUrlResult> {
  const { data, error } = await supabase.storage
    .from('documents')
    .createSignedUrl(storagePath, expirySeconds)

  if (error || !data?.signedUrl) {
    throw new Error(error?.message ?? 'No s\'ha pogut generar URL per al PDF d\'auditoria')
  }

  return { url: data.signedUrl }
}

// ─── Document Versions ────────────────────────────────────────────────────

export async function getDocumentVersions(documentId: string): Promise<DocumentVersion[]> {
  const { data, error } = await supabase
    .from('document_versions')
    .select('*')
    .eq('document_id', documentId)
    .order('version_number', { ascending: false })
  if (error) throw error
  return data ?? []
}

// ─── Expiry helpers ───────────────────────────────────────────────────────

/** Calls api.suggest_next_expiry to compute next renewal date. */
export async function suggestNextExpiry(
  documentId: string,
  effectiveDate?: string,
): Promise<string | null> {
  const { data, error } = await supabase.rpc('suggest_next_expiry', {
    p_document_id: documentId,
    p_effective_date: effectiveDate ?? new Date().toISOString(),
  })
  if (error) throw error
  return data as string | null
}

/** Updates expiry-related fields on a document directly. */
export async function updateDocumentExpiry(
  documentId: string,
  params: {
    expires_at?: string | null
    valid_from?: string | null
    renewal_interval_months?: number | null
    renewal_anchor_mode?: 'rolling' | 'natural' | null
    renewal_anchor_month?: number | null
    renewal_anchor_day?: number | null
  },
): Promise<void> {
  // active_documents is an updatable view in the api schema
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { error } = await (supabase.from('active_documents') as any)
    .update(params)
    .eq('id', documentId)
  if (error) throw error
}

// ─── Document Share Links ────────────────────────────────────────────────

export interface DocumentShareLink {
  id: string
  tenant_id: string
  document_id: string
  document_version_id: string
  token: string
  expires_at: string
  revoked_at: string | null
  created_by: string | null
  created_at: string
  last_accessed_at: string | null
  access_count: number
  is_active: boolean
}

export interface CreateShareLinkResult {
  id: string
  token: string
  expires_at: string
  share_url: string
}

export async function createDocumentShareLink(params: {
  tenantId: string
  documentId: string
  documentVersionId: string
  expirySeconds?: number
}): Promise<CreateShareLinkResult> {
  return callEdgeFunction<CreateShareLinkResult>(
    'create-document-share-link',
    {
      tenant_id:           params.tenantId,
      document_id:         params.documentId,
      document_version_id: params.documentVersionId,
      expiry_seconds:      params.expirySeconds ?? 86400,
    },
    params.tenantId,
  )
}

export async function revokeDocumentShareLink(shareLinkId: string): Promise<void> {
  const { error } = await supabase.rpc('revoke_document_share_link', {
    p_share_link_id: shareLinkId,
  })
  if (error) throw error
}

export async function getDocumentShareLinks(documentId: string): Promise<DocumentShareLink[]> {
  const { data, error } = await supabase
    .from('document_share_links')
    .select('*')
    .eq('document_id', documentId)
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as DocumentShareLink[]
}

// ─── Document Deletion ───────────────────────────────────────────────────

/**
 * Elimina la darrera versió d'un document.
 * Requereix ≥2 versions; si n'hi ha 1 cal usar deleteDocumentAll.
 * Permís: owner/manager global o de site, o creador de la versió.
 */
export async function deleteDocumentLatestVersion(documentId: string): Promise<void> {
  const { error } = await supabase.rpc('delete_document_latest_version', {
    p_document_id: documentId,
  })
  if (error) throw error
}

/**
 * Elimina el document complet (totes les versions i fitxers).
 * Permís: owner/manager global o de site, o propietari de TOTES les versions.
 */
export async function deleteDocumentAll(documentId: string): Promise<void> {
  const { error } = await supabase.rpc('delete_document_all', {
    p_document_id: documentId,
  })
  if (error) throw error
}

// ─── Document Archive ─────────────────────────────────────────────────────

export interface GetArchivedDocumentsParams {
  tenantId: string
  folderId?: string | null
  siteId?: string | null
}

export async function getArchivedDocuments(
  params: GetArchivedDocumentsParams,
): Promise<ArchivedDocument[]> {
  let query = (supabase.from('archived_documents') as any)
    .select('*')
    .eq('tenant_id', params.tenantId)
    .order('updated_at', { ascending: false })

  if (params.folderId !== undefined) {
    query = params.folderId
      ? query.eq('folder_id', params.folderId)
      : query.is('folder_id', null)
  }
  if (params.siteId) {
    query = query.eq('site_id', params.siteId)
  }

  const { data, error } = await query
  if (error) throw error
  return data ?? []
}

/**
 * Arxiva un document (soft-archive).
 * Permís: owner/manager global o de site.
 */
export async function archiveDocument(documentId: string): Promise<void> {
  const { error } = await supabase.rpc('archive_document', {
    p_document_id: documentId,
  })
  if (error) throw error
}

/**
 * Desarxiva un document (restaura a actiu).
 * Permís: owner/manager global o de site.
 */
export async function unarchiveDocument(documentId: string): Promise<void> {
  const { error } = await supabase.rpc('unarchive_document', {
    p_document_id: documentId,
  })
  if (error) throw error
}
