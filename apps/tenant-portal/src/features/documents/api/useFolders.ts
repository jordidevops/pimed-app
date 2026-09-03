import { useQuery } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { getFolders, type Folder, type GetFoldersOptions } from './documentsService'
import { useTenant } from '@/contexts/TenantContext'

export function useFolders(parentId?: string | null, opts: GetFoldersOptions = {}) {
  const { activeTenant } = useTenant()
  const { scopeMode, entityType, entityId, siteId } = opts
  return useQuery<Folder[]>({
    queryKey: documentsKeys.folders(
      activeTenant?.id ?? '',
      parentId,
      scopeMode,
      entityType,
      entityId,
      siteId,
    ),
    queryFn: () => getFolders(activeTenant!.id!, parentId, opts),
    enabled: !!activeTenant,
  })
}
