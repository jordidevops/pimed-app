// =============================================================================
// Storage feature — domain types & error class
// =============================================================================
// All types are derived directly from the backend contracts:
//   • api.file_nodes / api.trash / api.starred_files / api.storage_usage views
//   • api.search_files / api.trash_node / api.restore_node RPCs
//   • request-upload / confirm-upload / configure-byos Edge Functions
// =============================================================================

// ─── Structured error ────────────────────────────────────────────────────────

/**
 * Thrown by every method in storageService. The `code` maps 1-to-1 with the
 * backend error codes so the UI can switch on it for i18n or recovery flows.
 *
 * @example
 * try {
 *   await uploadFile(...)
 * } catch (err) {
 *   if (err instanceof StorageServiceError && err.code === 'storage_blocked') {
 *     showAdminBlockedBanner()
 *   }
 * }
 */
export class StorageServiceError extends Error {
  constructor(
    /** Machine-readable code from the backend (e.g. 'storage_blocked') */
    public readonly code: string,
    message: string,
    /** HTTP status code when available (e.g. 403, 404, 429) */
    public readonly httpStatus?: number,
  ) {
    super(message)
    this.name = 'StorageServiceError'
  }
}

// ─── Domain types ─────────────────────────────────────────────────────────────

export type NodeType = 'file' | 'folder'
export type ProcessingStatus = 'pending' | 'done' | 'error' | 'none'
export type NodeNamespace = 'repository' | 'system'
/** 'supabase' = default hosted storage; the others = BYOS */
export type StorageProviderType = 's3' | 'r2' | 'gcs' | 'supabase'
/** Level of access granted in node_permissions */
export type AccessLevel = 'viewer' | 'editor' | 'owner'

/**
 * A file or folder node from the api.file_nodes view.
 * Columns mirror the view definition — storage internals (storage_key,
 * storage_provider_id, ancestor_paths) are intentionally not exposed.
 */
export interface FileNode {
  id: string
  tenant_id: string
  parent_id: string | null
  created_by: string
  node_type: NodeType
  name: string
  /** Materialised path of the parent directory, e.g. '/docs/contracts/' */
  path: string
  namespace: NodeNamespace
  mime_type: string | null
  /** File size in bytes. Null for folders or in-progress uploads. */
  size_bytes: number | null
  checksum: string | null
  processing_status: ProcessingStatus
  metadata: Record<string, unknown> | null
  /** True when this node has an ACL — show a lock icon in the UI. */
  is_restricted: boolean
  /** True when the current user has explicit grant access to this node. */
  can_access_for_me: boolean
  /** Storage object key — used to create signed download URLs. */
  storage_key: string | null
  /** Which storage provider owns this file. null = Supabase default storage. */
  storage_provider_id: string | null
  site_id?: string | null
  entity_type?: string | null
  entity_id?: string | null
  created_at: string
  updated_at: string
}

/**
 * A top-level trashed node from the api.trash view.
 * Only root-level trashed items are returned (descendants are implicit).
 */
export interface TrashedNode {
  id: string
  tenant_id: string
  parent_id: string | null
  storage_provider_id: string | null
  node_type: NodeType
  name: string
  path: string
  mime_type: string | null
  size_bytes: number | null
  deleted_at: string
  deleted_by: string | null
  created_at: string
}

/** A node from the api.starred_files view (current user's favourites). */
export interface StarredFile {
  id: string
  tenant_id: string
  parent_id: string | null
  storage_provider_id: string | null
  node_type: NodeType
  name: string
  path: string
  mime_type: string | null
  size_bytes: number | null
  created_at: string
  updated_at: string
  starred_at: string
  storage_key: string | null
}

/**
 * Quota summary from the api.storage_usage view.
 * committed_bytes = confirmed uploads; reserved_bytes = in-progress uploads.
 */
/**
 * A BYOS storage provider as returned by api.storage_provider view.
 * The secret_key_id is never exposed — only public metadata is included.
 */
export interface StorageDrive {
  id: string
  tenant_id: string
  provider_type: StorageProviderType
  endpoint_url: string | null
  bucket_name: string | null
  region: string | null
  is_verified: boolean
  is_active: boolean
  is_locked: boolean
  nickname: string | null
  allowed_mime_types: string[] | null
  max_file_size_bytes: number | null
  quota_limit_bytes: number | null
  created_at: string
  updated_at: string
}

export interface StorageUsage {
  tenant_id: string
  file_count: number
  committed_bytes: number
  reserved_bytes: number
  /** committed_bytes + reserved_bytes (precomputed by the DB view) */
  total_bytes: number
  total_mb: number
  updated_at: string
}

/**
 * Full tenant storage breakdown from api.storage_usage.
 * Includes both Drive (file_nodes) and Documents (DMS) usage.
 * Only accessible to owner/manager via RLS.
 */
export interface TenantStorageBreakdown {
  tenant_id: string
  /** Drive (file_nodes) committed + reserved */
  committed_bytes: number
  reserved_bytes: number
  total_bytes: number
  /** Documents (DMS) committed + reserved */
  documents_committed_bytes: number
  documents_reserved_bytes: number
  documents_file_count: number
  /** Drive + Documents total */
  grand_total_bytes: number
  file_count: number
  updated_at: string
}

/** A permission entry from the api.node_permissions view (user + role on a node). */
export interface NodePermission {
  id: string
  node_id: string
  user_id: string
  access_level: AccessLevel
  granted_by: string
  created_at: string
  /** From joined data.profiles */
  email: string
  full_name: string | null
  avatar_url: string | null
}

/** Params for `updateNodePermissions`. Replaces ALL permissions atomically. */
export interface UpdateNodePermissionsParams {
  nodeId: string
  isRestricted: boolean
  permissions: Array<{ user_id: string; access_level: AccessLevel }>
}

/** A tenant member from the api.tenant_members view (used in PermissionsModal). */
export interface TenantMember {
  id: string
  tenant_id: string
  user_id: string
  role: string
  is_active: boolean
  joined_at: string
  email: string
  full_name: string | null
  avatar_url: string | null
}

/**
 * Result from the get-file-url Edge Function.
 * type='signed' → direct URL valid for `expires_in` seconds.
 * type='share'  → persistent resolver URL backed by a data.share_links token.
 */
export interface GetFileUrlResult {
  type: 'signed' | 'share'
  url: string
  /** Only present for type='signed' */
  expires_in?: number
  /** Only present for type='share' (ISO timestamp) */
  expires_at?: string
}

/**
 * Result from the get-file-url Edge Function.
 * type='signed' → direct URL valid for `expires_in` seconds.
 * type='share'  → persistent resolver URL backed by a data.share_links token.
 */
export interface GetFileUrlResult {
  type: 'signed' | 'share'
  url: string
  /** Only present for type='signed' */
  expires_in?: number
  /** Only present for type='share' (ISO timestamp) */
  expires_at?: string
}

/** A lightweight result row from api.search_files (pg_trgm search). */
export interface SearchResult {
  id: string
  tenant_id: string
  parent_id: string | null
  node_type: NodeType
  name: string
  path: string
  mime_type: string | null
  size_bytes: number | null
  created_at: string
  updated_at: string
}

// ─── Edge Function request / response shapes ──────────────────────────────────

export interface RequestUploadParams {
  tenant_id: string
  file_name: string
  size_bytes: number
  parent_id?: string | null
  mime_type?: string | null
  metadata?: Record<string, unknown> | null
  /** If set, upload to this specific BYOS drive */
  storage_provider_id?: string | null
}

export interface RequestUploadResult {
  upload_url: string
  method: 'PUT'
  node_id: string
  storage_key: string
}

export interface ConfirmUploadResult {
  node_id: string
  size_bytes: number
  processing_status: 'done'
}

export interface ConfigureByosParams {
  tenant_id: string
  /** Only BYOS providers — 'supabase' cannot be set via this RPC */
  provider_type: Exclude<StorageProviderType, 'supabase'>
  bucket_name: string
  access_key: string
  secret_access_key: string
  endpoint_url?: string | null
  region?: string | null
  /** If set, UPDATE the existing provider; if absent, INSERT a new one */
  provider_id?: string | null
  nickname?: string | null
  allowed_mime_types?: string[] | null
  max_file_size_bytes?: number | null
  quota_limit_bytes?: number | null
}

export interface DeleteByosParams {
  provider_id: string
  tenant_id: string
}

export interface ConfigureByosResult {
  provider_id: string
  message: string
}

// ─── Upload lifecycle ─────────────────────────────────────────────────────────

export interface UploadFileParams {
  tenant_id: string
  /** The native browser File (or Blob) to upload */
  file: File
  parent_id?: string | null
  storage_provider_id?: string | null
  metadata?: Record<string, unknown> | null
  /** Called repeatedly during the binary PUT for real-time progress feedback */
  onProgress?: (progress: UploadProgress) => void
  /** Pass an AbortController.signal to cancel the upload at any stage */
  signal?: AbortSignal
}

export interface UploadProgress {
  /** 0–100 percentage */
  percent: number
  loaded: number
  total: number
  /** Which phase of the 3-step flow is currently executing */
  stage: 'requesting' | 'uploading' | 'confirming' | 'done'
}

export interface UploadFileResult {
  node_id: string
  storage_key: string
  size_bytes: number
}
