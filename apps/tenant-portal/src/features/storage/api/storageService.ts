/**
 * storageService — pure async functions, zero React dependencies.
 *
 * Every method throws `StorageServiceError` on failure so callers always get
 * a consistent error shape: { code, message, httpStatus }.
 *
 * Design highlights
 * ─────────────────
 * • callEdgeFunction() injects the JWT + x-tenant-id headers automatically.
 *   The x-tenant-id header is required by the Edge Functions' shared
 *   createUserClient() so that active_tenant_id() works for RLS checks.
 *
 * • uploadFile() orchestrates the 3-step lifecycle in one call:
 *   1. requestUpload  → reserve the node + get a pre-signed URL
 *   2. putFileToPresignedUrl → binary PUT with XHR progress events
 *   3. confirmUpload  → verify the object exists + mark node as 'done'
 *
 * • XHR (not fetch) is used for the binary PUT because XMLHttpRequest's
 *   upload.onprogress is still the most reliable cross-browser mechanism
 *   for tracking upload progress.
 *
 * • Every DB query uses the shared `supabase` client (api schema, RLS active).
 */

import { supabase } from '../../../lib/supabase'
import { publicStorageUploadUrl } from '../../../lib/storageUploadUrl'
import { StorageServiceError } from '../types/storage.types'
import type {
  RequestUploadParams,
  RequestUploadResult,
  ConfirmUploadResult,
  UploadFileParams,
  UploadFileResult,
  UploadProgress,
  ConfigureByosParams,
  ConfigureByosResult,
  DeleteByosParams,
  FileNode,
  TrashedNode,
  StarredFile,
  StorageUsage,
  TenantStorageBreakdown,
  SearchResult,
  GetFileUrlResult,
  NodePermission,
  UpdateNodePermissionsParams,
  TenantMember,
  StorageDrive,
} from '../types/storage.types'

// ─── Internal: Edge Function fetch wrapper ────────────────────────────────────

const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1`

async function getAccessTokenOrThrow(): Promise<string> {
  const {
    data: { session },
  } = await supabase.auth.getSession()

  if (session?.access_token) return session.access_token

  const { data, error } = await supabase.auth.refreshSession()
  if (error || !data.session?.access_token) {
    throw new StorageServiceError('unauthorized', 'No estàs autenticat')
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
  if (tenantId) {
    headers['x-tenant-id'] = tenantId
  }

  return fetch(`${FUNCTIONS_BASE}/${name}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  })
}

/**
 * POST to a Supabase Edge Function with auth header + optional x-tenant-id.
 * Parses the structured { error: { code, message } } body on non-2xx responses
 * and converts it into a StorageServiceError.
 */
async function callEdgeFunction<T>(
  name: string,
  body: Record<string, unknown>,
  tenantId?: string,
): Promise<T> {
  let token = await getAccessTokenOrThrow()
  let res: Response
  try {
    res = await postEdgeFunction(name, body, token, tenantId)
  } catch {
    throw new StorageServiceError(
      'network_error',
      "No s'ha pogut connectar amb el servidor. Comprova la connexió.",
    )
  }

  let json = await res.json().catch(() => null)

  if (res.status === 401) {
    const { data, error } = await supabase.auth.refreshSession()
    if (!error && data.session?.access_token) {
      token = data.session.access_token
      try {
        res = await postEdgeFunction(name, body, token, tenantId)
      } catch {
        throw new StorageServiceError(
          'network_error',
          "No s'ha pogut connectar amb el servidor. Comprova la connexió.",
        )
      }
      json = await res.json().catch(() => null)
    }
  }

  if (!res.ok) {
    // Edge Functions return { error: "code_string", message: "..." }
    const code = (typeof json?.error === 'string' ? json.error : json?.error?.code) ?? 'function_error'
    const message = json?.message ?? json?.error?.message ?? `HTTP ${res.status}`
    throw new StorageServiceError(code, message, res.status)
  }

  return json as T
}

// ─── Internal: binary PUT with progress ───────────────────────────────────────

/**
 * Uploads raw bytes to a pre-signed URL via XMLHttpRequest.
 *
 * XHR is used (instead of fetch) because XMLHttpRequest.upload.onprogress is
 * the only cross-browser API that fires reliably during a PUT upload.
 * An AbortSignal is bridged to xhr.abort() so a single AbortController can
 * cancel the entire 3-step upload flow.
 */
function putFileToPresignedUrl(
  url: string,
  file: File,
  onProgress: ((p: UploadProgress) => void) | undefined,
  signal: AbortSignal | undefined,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    // Local Docker Edge returns host `kong:8000` — rewrite for the browser.
    xhr.open('PUT', publicStorageUploadUrl(url), true)
    xhr.setRequestHeader('Content-Type', file.type || 'application/octet-stream')

    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && onProgress) {
        onProgress({
          percent: Math.round((e.loaded / e.total) * 100),
          loaded: e.loaded,
          total: e.total,
          stage: 'uploading',
        })
      }
    }

    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve()
      } else {
        reject(
          new StorageServiceError(
            'upload_put_failed',
            `La pujada ha fallat (HTTP ${xhr.status}). Torna-ho a intentar.`,
            xhr.status,
          ),
        )
      }
    }

    xhr.onerror = () =>
      reject(
        new StorageServiceError(
          'upload_network_error',
          "La connexió s'ha interromput durant la pujada. Torna-ho a intentar.",
        ),
      )

    xhr.onabort = () =>
      reject(new StorageServiceError('upload_aborted', "La pujada ha estat cancel·lada"))

    // Bridge AbortSignal → XHR cancel
    signal?.addEventListener('abort', () => xhr.abort(), { once: true })
    if (signal?.aborted) {
      xhr.abort()
      return
    }

    xhr.send(file)
  })
}

// ─── Public API ───────────────────────────────────────────────────────────────

// ── Edge Functions ──────────────────────────────────────────────────────────

/**
 * Step 1 of 3 — Requests a pre-signed upload URL from the backend.
 * Also creates a `pending` file_node reservation in the database.
 *
 * Possible errors: 'storage_blocked' | 'quota_exceeded' | 'not_a_member'
 * | 'forbidden' | 'pending_upload_limit_exceeded' | 'duplicate_name'
 * | 'drive_locked' | 'file_too_large' | 'mime_type_not_allowed'
 */
export async function requestUpload(
  params: RequestUploadParams,
): Promise<RequestUploadResult> {
  return callEdgeFunction<RequestUploadResult>(
    'request-upload',
    {
      tenant_id: params.tenant_id,
      file_name: params.file_name,
      size_bytes: params.size_bytes,
      parent_id: params.parent_id ?? null,
      mime_type: params.mime_type ?? null,
      metadata: params.metadata ?? null,
      storage_provider_id: params.storage_provider_id ?? null,
    },
    params.tenant_id,
  )
}

/**
 * Step 3 of 3 — Confirms that the binary upload succeeded.
 * The backend verifies the object exists in the bucket, then marks the
 * file_node as 'done' and commits the reserved bytes into the quota.
 *
 * Possible errors: 'file_not_found' | 'object_not_found' | 'already_processed'
 * | 'storage_access_denied' | 'storage_unreachable'
 */
export async function confirmUpload(fileId: string): Promise<ConfirmUploadResult> {
  return callEdgeFunction<ConfirmUploadResult>('confirm-upload', { file_id: fileId })
}

/**
 * Full 3-step upload orchestration:
 *   1. requestUpload    → reserve the node + get a pre-signed PUT URL
 *   2. putFileToUrl     → binary PUT with live progress callbacks
 *   3. confirmUpload    → verify the object + mark the node as 'done'
 *
 * `onProgress` fires throughout all three stages so the UI can show a single
 * continuous progress bar.  `signal` cancels at any point.
 */
export async function uploadFile(params: UploadFileParams): Promise<UploadFileResult> {
  const { tenant_id, file, parent_id, storage_provider_id, metadata, onProgress, signal } = params

  // Stage 1 ─ request pre-signed URL
  onProgress?.({ percent: 0, loaded: 0, total: file.size, stage: 'requesting' })

  const { upload_url, node_id, storage_key } = await requestUpload({
    tenant_id,
    file_name: file.name,
    size_bytes: file.size,
    parent_id: parent_id ?? null,
    mime_type: file.type || null,
    metadata: metadata ?? null,
    storage_provider_id: storage_provider_id ?? null,
  })

  if (signal?.aborted) {
    throw new StorageServiceError('upload_aborted', "La pujada ha estat cancel·lada")
  }

  // Stage 2 ─ binary PUT to pre-signed URL (progress events from XHR)
  onProgress?.({ percent: 0, loaded: 0, total: file.size, stage: 'uploading' })
  await putFileToPresignedUrl(upload_url, file, onProgress, signal)

  if (signal?.aborted) {
    throw new StorageServiceError('upload_aborted', "La pujada ha estat cancel·lada")
  }

  // Stage 3 ─ confirm upload
  onProgress?.({ percent: 100, loaded: file.size, total: file.size, stage: 'confirming' })
  const { size_bytes } = await confirmUpload(node_id)

  onProgress?.({ percent: 100, loaded: file.size, total: file.size, stage: 'done' })

  return { node_id, storage_key, size_bytes }
}

/**
 * Configures a BYOS (Bring Your Own Storage) provider for a tenant.
 * Pass `provider_id` to UPDATE an existing drive; omit it to INSERT a new one.
 * The backend validates credentials against the real bucket before persisting.
 * Only callable by tenant owners.
 *
 * Possible errors: 'credential_validation_failed' | 'forbidden'
 * | 'invalid_provider_type' | 'missing_field' | 'max_drives_exceeded'
 */
export async function configureByos(
  params: ConfigureByosParams,
): Promise<ConfigureByosResult> {
  return callEdgeFunction<ConfigureByosResult>(
    'configure-byos',
    {
      tenant_id: params.tenant_id,
      provider_type: params.provider_type,
      bucket_name: params.bucket_name,
      access_key: params.access_key,
      secret_access_key: params.secret_access_key,
      endpoint_url: params.endpoint_url ?? null,
      region: params.region ?? null,
      provider_id: params.provider_id ?? null,
      nickname: params.nickname ?? null,
      allowed_mime_types: params.allowed_mime_types ?? null,
      max_file_size_bytes: params.max_file_size_bytes ?? null,
      quota_limit_bytes: params.quota_limit_bytes ?? null,
    },
    params.tenant_id,
  )
}

/**
 * Deletes a BYOS storage provider (and its Vault secret).
 * Only callable by tenant owners.
 */
export async function deleteByos(params: DeleteByosParams): Promise<void> {
  const {
    data: { session },
  } = await supabase.auth.getSession()

  if (!session) {
    throw new StorageServiceError('unauthorized', 'No estàs autenticat')
  }

  const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1`
  let res: Response
  try {
    res = await fetch(
      `${FUNCTIONS_BASE}/configure-byos?provider_id=${encodeURIComponent(params.provider_id)}&tenant_id=${encodeURIComponent(params.tenant_id)}`,
      {
        method: 'DELETE',
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          'x-tenant-id': params.tenant_id,
        },
      },
    )
  } catch {
    throw new StorageServiceError('network_error', "No s'ha pogut connectar amb el servidor.")
  }

  if (!res.ok) {
    const json = await res.json().catch(() => null)
    const code = (typeof json?.error === 'string' ? json.error : json?.error?.code) ?? 'function_error'
    const message = json?.message ?? json?.error?.message ?? `HTTP ${res.status}`
    throw new StorageServiceError(code, message, res.status)
  }
}

/**
 * Lists all BYOS storage drives for a tenant from the api.storage_provider view.
 * Returns an empty array if no BYOS providers have been configured.
 */
export async function listStorageDrives(tenantId: string): Promise<StorageDrive[]> {
  const { data, error } = await supabase
    .from('storage_provider')
    .select('*')
    .eq('tenant_id', tenantId)
    .neq('provider_type', 'supabase')
    .order('created_at', { ascending: true })

  if (error) throw error
  return (data ?? []) as StorageDrive[]
}

// ── Database queries ─────────────────────────────────────────────────────────

/**
 * Lists the direct children of a directory (or the root if parentId is null).
 * RLS on api.file_nodes ensures only tenant-member files are returned.
 * Folders are sorted before files; within each group entries are alphabetical.
 */
export async function listFileNodes(
  tenantId: string,
  parentId: string | null = null,
  storageProviderId?: string | null,
  options?: { hideFieldWork?: boolean },
): Promise<FileNode[]> {
  let query = supabase
    .from('file_nodes')
    .select('*')
    .eq('tenant_id', tenantId)
    .neq('processing_status', 'pending') // exclude in-flight uploads not yet confirmed
    .order('node_type', { ascending: false }) // 'folder' > 'file' alphabetically
    .order('name', { ascending: true })

  // Drive filter: folders are shared across drives (always shown); files filter by drive.
  // null → App Drive (Supabase default); string → specific BYOS drive.
  if (storageProviderId) {
    // Show folders + files from this specific BYOS drive
    query = query.or(`node_type.eq.folder,storage_provider_id.eq.${storageProviderId}`)
  } else {
    // App Drive: show folders + files with no provider (default storage)
    query = query.or('node_type.eq.folder,storage_provider_id.is.null')
  }

  const { data, error } = parentId
    ? await query.eq('parent_id', parentId)
    : await query.is('parent_id', null)

  if (error) throw new StorageServiceError('list_failed', error.message)

  let nodes = (data ?? []) as unknown as FileNode[]

  // Hide field-work roots at drive root (server filter via metadata.kind)
  if (options?.hideFieldWork && !parentId) {
    nodes = nodes.filter((n) => {
      const kind = (n.metadata as Record<string, unknown> | null)?.kind
      return kind !== 'field_work_root'
    })
  }

  // Hide light derivatives in listings
  nodes = nodes.filter((n) => {
    const variant = (n.metadata as Record<string, unknown> | null)?.variant
    return variant !== 'light'
  })

  return nodes
}

/**
 * Fetches the storage quota summary for a tenant.
 * Returns null when no row exists yet (tenant has never uploaded anything).
 */
export async function getStorageUsage(tenantId: string): Promise<StorageUsage | null> {
  const { data, error } = await supabase
    .from('storage_usage')
    .select('*')
    .eq('tenant_id', tenantId)
    .maybeSingle()

  if (error) throw new StorageServiceError('usage_fetch_failed', error.message)

  return data as unknown as StorageUsage | null
}

/**
 * Computes usage scoped to a specific drive from api.file_nodes.
 * storageProviderId = null -> App Drive files only.
 */
export async function getStorageUsageByDrive(
  tenantId: string,
  storageProviderId?: string | null,
): Promise<StorageUsage | null> {
  let query = supabase
    .from('file_nodes')
    .select('size_bytes,processing_status')
    .eq('tenant_id', tenantId)
    .eq('node_type', 'file')

  if (storageProviderId) {
    query = query.eq('storage_provider_id', storageProviderId)
  } else {
    query = query.is('storage_provider_id', null)
  }

  const { data, error } = await query

  if (error) throw new StorageServiceError('usage_fetch_failed', error.message)

  const rows = (data ?? []) as Array<{ size_bytes: number | null; processing_status: string | null }>
  const committed = rows
    .filter((r) => r.processing_status !== 'pending')
    .reduce((acc, r) => acc + (r.size_bytes ?? 0), 0)
  const reserved = rows
    .filter((r) => r.processing_status === 'pending')
    .reduce((acc, r) => acc + (r.size_bytes ?? 0), 0)
  const fileCount = rows.filter((r) => r.processing_status !== 'pending').length
  const total = committed + reserved

  return {
    tenant_id: tenantId,
    file_count: fileCount,
    committed_bytes: committed,
    reserved_bytes: reserved,
    total_bytes: total,
    total_mb: total / (1024 * 1024),
    updated_at: new Date().toISOString(),
  }
}

/** Reads plan storage cap (max_storage_mb) for App Drive from api.my_tenant. */
export async function getAppDriveCapBytes(tenantId: string): Promise<number | null> {
  const { data, error } = await supabase
    .from('my_tenant')
    .select('max_storage_mb')
    .eq('id', tenantId)
    .maybeSingle()

  if (error) throw new StorageServiceError('usage_fetch_failed', error.message)

  const maxMb = (data as { max_storage_mb?: number | null } | null)?.max_storage_mb ?? null
  if (maxMb == null || maxMb <= 0) return null
  return Math.round(maxMb * 1024 * 1024)
}

/**
 * Reads the pre-computed storage breakdown for a tenant from api.storage_usage.
 * Includes both Drive (file_nodes) and Documents (DMS) bytes.
 * Only accessible to owner/manager via RLS. Returns null for other roles.
 */
export async function getTenantStorageBreakdown(
  tenantId: string,
): Promise<TenantStorageBreakdown | null> {
  const { data, error } = await supabase
    .from('storage_usage')
    .select(
      'tenant_id,file_count,committed_bytes,reserved_bytes,total_bytes,documents_committed_bytes,documents_reserved_bytes,documents_file_count,grand_total_bytes,updated_at',
    )
    .eq('tenant_id', tenantId)
    .maybeSingle()

  if (error) return null // Non-owner/manager gets RLS-filtered null — silently ignore
  if (!data) return null

  const row = data as Record<string, unknown>
  return {
    tenant_id:                 tenantId,
    committed_bytes:           Number(row.committed_bytes ?? 0),
    reserved_bytes:            Number(row.reserved_bytes ?? 0),
    total_bytes:               Number(row.total_bytes ?? 0),
    documents_committed_bytes: Number(row.documents_committed_bytes ?? 0),
    documents_reserved_bytes:  Number(row.documents_reserved_bytes ?? 0),
    documents_file_count:      Number(row.documents_file_count ?? 0),
    grand_total_bytes:         Number(row.grand_total_bytes ?? 0),
    file_count:                Number(row.file_count ?? 0),
    updated_at:                String(row.updated_at ?? ''),
  }
}

/**
 * Lists top-level trashed nodes for a tenant (descendants are implicit).
 * Sorted by most-recently-trashed first.
 */
export async function listTrash(
  tenantId: string,
  storageProviderId?: string | null,
): Promise<TrashedNode[]> {
  let query = supabase
    .from('trash')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('deleted_at', { ascending: false })

  if (storageProviderId) {
    query = query.eq('storage_provider_id', storageProviderId)
  } else {
    query = query.is('storage_provider_id', null)
  }

  const { data, error } = await query

  if (error) throw new StorageServiceError('trash_fetch_failed', error.message)

  return (data ?? []) as unknown as TrashedNode[]
}

/**
 * Lists starred files for the currently authenticated user.
 * api.starred_files already filters by auth.uid() server-side.
 */
export async function listStarredFiles(
  tenantId: string,
  storageProviderId?: string | null,
): Promise<StarredFile[]> {
  let query = supabase
    .from('starred_files')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('starred_at', { ascending: false })

  if (storageProviderId) {
    query = query.eq('storage_provider_id', storageProviderId)
  } else {
    query = query.is('storage_provider_id', null)
  }

  const { data, error } = await query

  if (error) throw new StorageServiceError('starred_fetch_failed', error.message)

  return (data ?? []) as unknown as StarredFile[]
}

/**
 * Full-text search across file names within a tenant using pg_trgm similarity.
 * Returns up to 50 results ordered by relevance.
 *
 * TIP: debounce before calling this to avoid firing a DB query on every keystroke.
 */
export async function searchFiles(
  tenantId: string,
  query: string,
): Promise<SearchResult[]> {
  const { data, error } = await supabase.rpc('search_files', {
    p_query: query,
    p_tenant_id: tenantId,
  })

  if (error) throw new StorageServiceError('search_failed', error.message)

  return (data ?? []) as SearchResult[]
}

/**
 * Moves a node to the trash (soft delete, 30-day retention) or deletes it
 * permanently when `forcePermanent = true` (enqueues physical Storage cleanup).
 * Returns the number of affected nodes (>1 when a folder with contents).
 *
 * Possible errors: 'node_not_found' | 'forbidden' | 'system_node_protected'
 */
export async function trashNode(
  nodeId: string,
  forcePermanent = false,
): Promise<number> {
  const { data, error } = await supabase.rpc('trash_node', {
    p_node_id: nodeId,
    force_permanent: forcePermanent,
  })

  if (error) {
    const code = error.message.includes('node_not_found')
      ? 'node_not_found'
      : error.message.includes('system_node_protected')
        ? 'system_node_protected'
        : error.message.includes('forbidden')
          ? 'forbidden'
          : 'trash_failed'
    throw new StorageServiceError(code, error.message)
  }

  return (data as number) ?? 0
}

/**
 * Restores a trashed node (and all its descendants if it's a folder).
 * Returns the number of restored nodes.
 *
 * Possible errors: 'node_not_found' | 'parent_in_trash' | 'forbidden'
 */
export async function restoreNode(nodeId: string): Promise<number> {
  const { data, error } = await supabase.rpc('restore_node', {
    p_node_id: nodeId,
  })

  if (error) {
    const code = error.message.includes('node_not_found')
      ? 'node_not_found'
      : error.message.includes('parent_in_trash')
        ? 'parent_in_trash'
        : error.message.includes('forbidden')
          ? 'forbidden'
          : 'restore_failed'
    throw new StorageServiceError(code, error.message)
  }

  return (data as number) ?? 0
}

/**
 * Adds a node to the current user's starred list.
 * Silently ignores duplicate stars (code: 'already_starred').
 */
export async function starNode(nodeId: string): Promise<void> {
  const { error } = await supabase.rpc('star_node', {
    p_node_id: nodeId,
  })

  if (error) {
    const code = error.code === '23505' ? 'already_starred' : 'star_failed'
    throw new StorageServiceError(code, error.message)
  }
}

/**
 * Removes a node from the current user's starred list.
 */
export async function unstarNode(nodeId: string): Promise<void> {
  const { error } = await supabase.rpc('unstar_node', {
    p_node_id: nodeId,
  })

  if (error) throw new StorageServiceError('unstar_failed', error.message)
}

/**
 * Generates a URL for viewing or downloading a file.
 *
 * • expiry_seconds ≤ 7 days → returns a direct signed URL (works for BYOS too).
 * • expiry_seconds > 7 days → creates a persistent share token in data.share_links
 *   and returns a resolver URL (…/functions/v1/resolve-share?token=…).
 *
 * Pass download=true to force a Content-Disposition: attachment header so the
 * browser downloads the file rather than displaying it inline.
 */
export async function getFileUrl(
  fileId: string,
  expirySeconds: number,
  tenantId: string,
  download = false,
): Promise<GetFileUrlResult> {
  const result = await callEdgeFunction<GetFileUrlResult>(
    'get-file-url',
    { file_id: fileId, expiry_seconds: expirySeconds, download },
    tenantId,
  )
  return { ...result, url: publicStorageUploadUrl(result.url) }
}

/**
 * Creates a new folder inside `parentId` (null = root).
 * Uses the INSERT rule on api.file_nodes which sets created_by = auth.uid().
 *
 * Returns the new folder's UUID.
 * Possible error codes: 'duplicate_name' | 'create_folder_failed'
 */
export async function createFolder(
  tenantId: string,
  name: string,
  parentId: string | null,
): Promise<void> {
  const { error } = await supabase
    .from('file_nodes')
    .insert({
      tenant_id: tenantId,
      parent_id: parentId,
      node_type: 'folder',
      name,
      namespace: 'repository',
    })

  if (error) {
    if (error.code === '23505') {
      throw new StorageServiceError('duplicate_name', `Ja existeix un element amb el nom '${name}'`)
    }
    throw new StorageServiceError('create_folder_failed', error.message)
  }
}

/**
 * Renames a file or folder node.
 * The UPDATE rule on api.file_nodes cascades path updates via DB trigger.
 *
 * Possible error codes: 'duplicate_name' | 'rename_failed'
 */
export async function renameNode(nodeId: string, newName: string): Promise<void> {
  const { error } = await supabase
    .from('file_nodes')
    .update({ name: newName })
    .eq('id', nodeId)

  if (error) {
    if (error.code === '23505') {
      throw new StorageServiceError('duplicate_name', `Ja existeix un element amb el nom '${newName}'`)
    }
    throw new StorageServiceError('rename_failed', error.message)
  }
}

/**
 * Returns all permission entries for a node (user + access_level + profile data).
 * Only owner/manager see the full list; regular users see only their own entry.
 */
export async function getNodePermissions(nodeId: string): Promise<NodePermission[]> {
  const { data, error } = await supabase
    .from('node_permissions')
    .select('*')
    .eq('node_id', nodeId)
    .order('created_at', { ascending: true })

  if (error) throw new StorageServiceError('permissions_fetch_failed', error.message)

  return (data ?? []) as unknown as NodePermission[]
}

/**
 * Atomically updates the ACL for a node:
 *  - Sets `is_restricted` on the node.
 *  - Replaces ALL node_permissions entries for the node.
 *
 * Only callable by tenant owner/manager (enforced server-side).
 *
 * Possible errors: 'node_not_found' | 'insufficient_permissions'
 *   | 'invalid_access_level' | 'user_not_tenant_member'
 */
export async function updateNodePermissions(
  params: UpdateNodePermissionsParams,
): Promise<void> {
  const { error } = await supabase.rpc('update_node_permissions', {
    p_node_id:          params.nodeId,
    p_is_restricted:    params.isRestricted,
    p_permissions_json: params.permissions,
  })

  if (error) {
    const msg = error.message
    const code = msg.includes('node_not_found')
      ? 'node_not_found'
      : msg.includes('insufficient_permissions')
        ? 'insufficient_permissions'
        : msg.includes('invalid_access_level')
          ? 'invalid_access_level'
          : msg.includes('user_not_tenant_member')
            ? 'user_not_tenant_member'
            : 'permissions_update_failed'
    throw new StorageServiceError(code, msg)
  }
}

/**
 * Lists active members of a tenant. Used by PermissionsModal to search for users.
 */
export async function listTenantMembers(tenantId: string): Promise<TenantMember[]> {
  const { data, error } = await supabase
    .from('tenant_members')
    .select('*')
    .eq('tenant_id', tenantId)
    .eq('is_active', true)
    .order('full_name', { ascending: true })

  if (error) throw new StorageServiceError('members_fetch_failed', error.message)

  return (data ?? []) as unknown as TenantMember[]
}
