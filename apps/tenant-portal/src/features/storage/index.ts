// =============================================================================
// Storage feature — public API
// =============================================================================
// Import from this barrel instead of reaching into subdirectories:
//
//   import { useFileNodes, useUploadFile, StorageServiceError } from '@/features/storage'
// =============================================================================

// Types
export type {
  FileNode,
  TrashedNode,
  StarredFile,
  StorageUsage,
  SearchResult,
  NodeType,
  ProcessingStatus,
  NodeNamespace,
  StorageProviderType,
  AccessLevel,
  NodePermission,
  UpdateNodePermissionsParams,
  TenantMember,
  RequestUploadParams,
  RequestUploadResult,
  ConfirmUploadResult,
  ConfigureByosParams,
  ConfigureByosResult,
  UploadFileParams,
  UploadFileResult,
  UploadProgress,
} from './types/storage.types'
export { StorageServiceError } from './types/storage.types'

// Pure service (framework-agnostic)
export {
  requestUpload,
  confirmUpload,
  uploadFile,
  configureByos,
  listFileNodes,
  getStorageUsage,
  listTrash,
  listStarredFiles,
  searchFiles,
  trashNode,
  restoreNode,
  starNode,
  unstarNode,
  getNodePermissions,
  updateNodePermissions,
  listTenantMembers,
} from './api/storageService'

// React Query hooks
export { storageKeys } from './api/storageKeys'
export { useStorageProvider } from './api/useStorageProvider'
export type { StorageProviderConfig } from './api/useStorageProvider'
export { useFileNodes } from './api/useFileNodes'
export { useStorageUsage } from './api/useStorageUsage'
export { useUploadFile } from './api/useUploadFile'
export type { UseUploadFileParams } from './api/useUploadFile'
export { useTrashNode } from './api/useTrashNode'
export { useRestoreNode } from './api/useRestoreNode'
export { useTrash } from './api/useTrash'
export { useStarredFiles, useStarNode, useUnstarNode } from './api/useStarredFiles'
export { useSearchFiles } from './api/useSearchFiles'
export { useNodePermissions } from './api/useNodePermissions'
export { useUpdateNodePermissions } from './api/useUpdateNodePermissions'
export { useTenantMembers } from './api/useTenantMembers'
export { useConfigureByos } from './api/useConfigureByos'

// Components
export { ByosConfigForm } from './components/ByosConfigForm'
export { FileExplorer } from './components/FileExplorer'
